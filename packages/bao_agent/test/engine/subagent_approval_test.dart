import 'dart:convert';

import 'package:bao_agent/bao_agent.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Before a child Agent/Task starts, the host is asked for leave with what
/// it is to do and the model it would run on. Cancelled, no child is made;
/// confirmed, the model picked goes through the call's own `model` path.
void main() {
  late Harness h;

  tearDown(() => h.dispose());

  /// The text of the first message of [request]: a subagent's prompt for
  /// its own, the user's text for the main agent's.
  String promptOf(ModelRequest request) =>
      jsonEncode((request.body['messages'] as List).first);

  /// Answers subagent requests by the marker in their prompt.
  Map<String, ModelRequest> subagents() {
    final seen = <String, ModelRequest>{};
    h.model.route = (request) {
      final prompt = promptOf(request);
      for (final marker in ['SUB:one', 'SUB:two']) {
        if (prompt.contains(marker)) {
          seen[marker] = request;
          return Reply.text('$marker done');
        }
      }
      return null;
    };
    return seen;
  }

  test(
    'cancelled, no child is made: no task, no subagent, no request',
    () async {
      h = await Harness.start(model: 'opus');
      final seen = subagents();
      h.onAgentApproval = (_) async => {
        'behavior': 'deny',
        'message': 'Not this one.',
      };
      h.model.script.addAll([
        Reply.tool('Agent', {
          'description': 'One',
          'prompt': 'SUB:one',
          'run_in_background': false,
        }),
        Reply.text('done'),
      ]);

      await h.turn('go');

      expect(h.approvalRequests, hasLength(1));
      final asked = h.approvalRequests.single;
      expect(asked['description'], 'One');
      expect(asked['prompt'], 'SUB:one');
      expect(asked['model'], h.model.turns.first.model);
      expect(asked['models'], contains(asked['model']));
      expect(asked['forced'], isFalse);
      expect(asked['run_in_background'], isFalse);

      // Nothing started: no model call for it, and no task event.
      expect(seen, isEmpty);
      expect(h.of('system', 'task_started'), isEmpty);
      // The model is told it did not run, not left to think it did.
      final result = h.toolResults.single;
      expect(result['is_error'], isTrue);
      expect((result['tool_use_result'] as Map)['status'], 'declined');
    },
  );

  test('confirmed with a model, the child runs on it', () async {
    h = await Harness.start(model: 'opus');
    final seen = subagents();
    h.onAgentApproval = (_) async => {'behavior': 'allow', 'model': 'haiku'};
    h.model.script.addAll([
      Reply.tool('Agent', {
        'description': 'One',
        'prompt': 'SUB:one',
        'run_in_background': false,
      }),
      Reply.text('done'),
    ]);

    await h.turn('go');

    // Through the call's own model path: the alias resolved as one asked
    // for in `model` would be.
    expect(seen['SUB:one']!.model, 'claude-haiku-5-5');
    final started = h.of('system', 'task_started').single;
    expect(started['model'], 'claude-haiku-5-5');
    expect(started['model_source'], 'requested');
    final result = h.toolResults.single['tool_use_result'] as Map;
    expect(result['assignedModel'], 'claude-haiku-5-5');
    expect(result['requestedModel'], 'haiku');
    expect(result['status'], 'completed');
  });

  test(
    'confirmed as assigned, the pool place and its source are kept',
    () async {
      h = await Harness.start(
        model: 'opus',
        subagentPool: ['claude-sonnet-5-5', 'claude-haiku-5-5'],
      );
      final seen = subagents();
      h.onAgentApproval = (_) async => {'behavior': 'allow'};
      h.model.script.addAll([
        Reply.tools([
          (
            'Agent',
            {
              'description': 'One',
              'prompt': 'SUB:one',
              'run_in_background': false,
            },
          ),
          (
            'Agent',
            {
              'description': 'Two',
              'prompt': 'SUB:two',
              'run_in_background': false,
            },
          ),
        ]),
        Reply.text('done'),
      ]);

      await h.turn('go');

      expect(seen['SUB:one']!.model, 'claude-sonnet-5-5');
      expect(seen['SUB:two']!.model, 'claude-haiku-5-5');
      final started = {
        for (final event in h.of('system', 'task_started'))
          '${event['description']}': event,
      };
      expect(started['One']!['model_source'], 'pool');
      expect(started['Two']!['model_source'], 'pool');
    },
  );

  test('forced, no model is offered and a picked one is not used', () async {
    h = await Harness.start(
      model: 'opus',
      environment: {
        'CLAUDE_CODE_SUBAGENT_MODEL': 'claude-sonnet-5-5',
        'CLAUDE_CODE_SUBAGENT_MODEL_FORCE': '1',
      },
      subagentPool: ['claude-haiku-5-5'],
    );
    final seen = subagents();
    h.onAgentApproval = (_) async => {
      'behavior': 'allow',
      'model': 'claude-haiku-5-5',
    };
    h.model.script.addAll([
      Reply.tool('Agent', {
        'description': 'One',
        'prompt': 'SUB:one',
        'run_in_background': false,
      }),
      Reply.text('done'),
    ]);

    await h.turn('go');

    final asked = h.approvalRequests.single;
    expect(asked['forced'], isTrue);
    expect(asked['models'], isEmpty);
    expect(asked['model'], 'claude-sonnet-5-5');
    // The forced model wins, as over the call's own.
    expect(seen['SUB:one']!.model, 'claude-sonnet-5-5');
    final result = h.toolResults.single['tool_use_result'] as Map;
    expect(result['modelSource'], 'forced');
  });

  test(
    'calls made together ask one at a time, in the order they were made',
    () async {
      h = await Harness.start(
        model: 'opus',
        subagentPool: ['claude-sonnet-5-5', 'claude-haiku-5-5'],
      );
      final seen = subagents();
      var active = 0;
      var most = 0;
      final asked = <String>[];
      h.onAgentApproval = (request) async {
        active++;
        most = active > most ? active : most;
        asked.add('${request['description']}');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        active--;
        return {'behavior': 'allow'};
      };
      h.model.script.addAll([
        Reply.tools([
          (
            'Agent',
            {
              'description': 'One',
              'prompt': 'SUB:one',
              'run_in_background': false,
            },
          ),
          (
            'Agent',
            {
              'description': 'Two',
              'prompt': 'SUB:two',
              'run_in_background': false,
            },
          ),
        ]),
        Reply.text('done'),
      ]);

      await h.turn('go');

      expect(most, 1);
      expect(asked, ['One', 'Two']);
      // The pool order is as the calls were made, whatever the answers took.
      expect(seen['SUB:one']!.model, 'claude-sonnet-5-5');
      expect(seen['SUB:two']!.model, 'claude-haiku-5-5');
    },
  );

  test('with no host to ask, the child starts as it did before', () async {
    h = await Harness.start(model: 'opus', canAsk: false);
    final seen = subagents();
    h.model.script.addAll([
      Reply.tool('Agent', {
        'description': 'One',
        'prompt': 'SUB:one',
        'run_in_background': false,
      }),
      Reply.text('done'),
    ]);

    await h.turn('go');

    expect(h.approvalRequests, isEmpty);
    expect(seen['SUB:one'], isNotNull);
    expect(h.of('system', 'task_started'), hasLength(1));
  });

  test(
    'a child confirmed to the background reports its result when done',
    () async {
      h = await Harness.start(model: 'opus');
      final seen = subagents();
      h.onAgentApproval = (_) async => {'behavior': 'allow'};
      final done = h.messages.firstWhere(
        (message) =>
            message['type'] == 'system' &&
            message['subtype'] == 'task_notification',
        orElse: () => const {},
      );
      h.model.script.addAll([
        Reply.tool('Agent', {
          'description': 'One',
          'prompt': 'SUB:one',
          'run_in_background': true,
        }),
        Reply.text('done'),
      ]);

      await h.turn('go');

      expect(seen['SUB:one'], isNotNull);
      expect(h.of('system', 'task_started').single['is_backgrounded'], isTrue);
      final notification = await done.timeout(const Duration(seconds: 10));
      expect(notification['status'], 'completed');
      expect(notification['summary'], contains('One'));
    },
  );
}
