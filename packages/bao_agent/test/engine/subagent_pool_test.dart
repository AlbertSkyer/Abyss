import 'dart:convert';

import 'package:bao_agent/bao_agent.dart';
import 'package:bao_agent/src/engine/subagent_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// Where a subagent's model comes from: the call, its definition, the
/// scalar model set for agents, the session, and the host's pool, taken in
/// turn when nothing above names one.
void main() {
  group('the selector', () {
    test('precedence, and the pool only where nothing else names a model', () {
      final selector = SubagentModelSelector(['pool-a', 'pool-b']);
      SubagentModelAssignment assign({
        bool forced = false,
        String? asked,
        String? definition,
        String? configured,
      }) => selector.assign(
        forced: forced,
        sessionModel: 'session-model',
        asked: asked,
        definitionModel: definition,
        configuredSubagent: configured,
      );

      expect(assign(asked: 'asked').model, 'asked');
      expect(assign(asked: 'asked').source, SubagentModelSource.requested);
      expect(assign(definition: 'defined').model, 'defined');
      expect(
        assign(definition: 'defined').source,
        SubagentModelSource.definition,
      );
      expect(assign(configured: 'sub-model').model, 'sub-model');
      expect(
        assign(configured: 'sub-model').source,
        SubagentModelSource.subagentDefault,
      );

      // None of those used up a place: the first pool model comes now.
      final first = assign();
      expect(first.model, 'pool-a');
      expect(first.source, SubagentModelSource.pool);
      expect(first.poolModel, 'pool-a');
      expect(first.poolIndex, 0);
      final second = assign();
      expect(second.model, 'pool-b');
      expect(second.poolIndex, 1);
      // Wraps around.
      expect(assign().model, 'pool-a');

      // An explicit model again: no place taken, so the pool goes on.
      expect(assign(asked: 'opus').model, 'opus');
      expect(assign().model, 'pool-b');
    });

    test('inherit is the session\'s model, and does not take a place', () {
      final selector = SubagentModelSelector(['pool-a', 'pool-b']);
      final defined = selector.assign(
        forced: false,
        sessionModel: 'session-model',
        definitionModel: 'inherit',
      );
      expect(defined.model, 'session-model');
      expect(defined.source, SubagentModelSource.inherit);
      final asked = selector.assign(
        forced: false,
        sessionModel: 'session-model',
        asked: 'inherit',
      );
      expect(asked.model, 'session-model');
      expect(asked.source, SubagentModelSource.inherit);
      // Neither took a place.
      expect(
        selector.assign(forced: false, sessionModel: 'session-model').model,
        'pool-a',
      );
    });

    test('forced: the model set for agents over everything but inherit', () {
      final selector = SubagentModelSelector(['pool-a']);
      final forced = selector.assign(
        forced: true,
        sessionModel: 'session-model',
        asked: 'asked',
        definitionModel: 'defined',
        configuredSubagent: 'forced-model',
      );
      expect(forced.model, 'forced-model');
      expect(forced.source, SubagentModelSource.forced);
      expect(
        selector
            .assign(
              forced: true,
              sessionModel: 'session-model',
              asked: 'inherit',
              configuredSubagent: 'forced-model',
            )
            .model,
        'session-model',
      );
      // As before: forced with nothing set falls back to the session.
      expect(
        selector
            .assign(forced: true, sessionModel: 'session-model', asked: 'asked')
            .model,
        'session-model',
      );
      // None of it used the pool's only place.
      expect(
        selector.assign(forced: false, sessionModel: 'session-model').poolIndex,
        0,
      );
    });

    test('an empty or blank pool falls back to the session', () {
      for (final pool in [
        const <String>[],
        const ['', '   '],
      ]) {
        final assignment = SubagentModelSelector(pool)
            .assign(forced: false, sessionModel: 'session-model');
        expect(assignment.model, 'session-model');
        expect(assignment.source, SubagentModelSource.session);
      }
      // A blank entry among good ones is left out.
      final selector = SubagentModelSelector(['', 'pool-a']);
      expect(
        selector.assign(forced: false, sessionModel: 'session-model').model,
        'pool-a',
      );
    });

    test('aliases resolve through the session catalog; refs are kept', () {
      final selector = SubagentModelSelector(['@other/model']);
      final resolved = selector.assign(
        forced: false,
        sessionModel: 'session-model',
        asked: 'haiku',
        resolve: (alias) => 'resolved-$alias',
      );
      expect(resolved.model, 'resolved-haiku');
      expect(
        selector
            .assign(
              forced: false,
              sessionModel: 'session-model',
              resolve: (alias) => 'resolved-$alias',
            )
            .model,
        '@other/model',
      );
    });
  });

  group('in a session', () {
    late Harness h;

    tearDown(() => h.dispose());

    /// The first message of a request: a subagent's prompt for its own, the
    /// user's text for the main agent's.
    String sentIn(ModelRequest request) =>
        jsonEncode((request.body['messages'] as List).first);

    /// The subagent requests, by the marker in their prompt.
    Map<String, ModelRequest> subagents(Harness h) {
      final seen = <String, ModelRequest>{};
      h.model.route = (request) {
        final messages = sentIn(request);
        for (final marker in ['SUB:one', 'SUB:two', 'SUB:three']) {
          if (messages.contains(marker)) {
            seen[marker] = request;
            return Reply.text('$marker done');
          }
        }
        return null;
      };
      return seen;
    }

    test('agents launched together take the pool in turn, and the model '
        'reaches their requests', () async {
      h = await Harness.start(
        model: 'opus',
        subagentPool: ['claude-sonnet-5-5', 'claude-haiku-5-5'],
      );
      final requests = subagents(h);
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

      expect(requests['SUB:one']!.model, 'claude-sonnet-5-5');
      expect(requests['SUB:two']!.model, 'claude-haiku-5-5');

      // The task events say what each was assigned and why, as their
      // results do.
      final started = {
        for (final event in h.of('system', 'task_started'))
          '${event['description']}': event,
      };
      expect(started['One']!['model'], 'claude-sonnet-5-5');
      expect(started['One']!['model_source'], 'pool');
      expect(started['One']!['requested_model'], isNull);
      expect(started['Two']!['model'], 'claude-haiku-5-5');
      expect(started['Two']!['model_source'], 'pool');

      final results = {
        for (final result in h.toolResults)
          '${(result['tool_use_result'] as Map)['prompt']}':
              result['tool_use_result'] as Map,
      };
      expect(results['SUB:one']!['status'], 'completed');
      expect(results['SUB:one']!['resolvedModel'], 'claude-sonnet-5-5');
      expect(results['SUB:one']!['assignedModel'], 'claude-sonnet-5-5');
      expect(results['SUB:one']!['modelSource'], 'pool');
      expect(results['SUB:one']!['poolModel'], 'claude-sonnet-5-5');
      expect(results['SUB:one']!['poolIndex'], 0);
      expect(results['SUB:two']!['assignedModel'], 'claude-haiku-5-5');
      expect(results['SUB:two']!['poolIndex'], 1);
    });

    test('the pool wraps around', () async {
      h = await Harness.start(
        model: 'opus',
        subagentPool: ['claude-sonnet-5-5', 'claude-haiku-5-5'],
      );
      final requests = subagents(h);
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
          (
            'Agent',
            {
              'description': 'Three',
              'prompt': 'SUB:three',
              'run_in_background': false,
            },
          ),
        ]),
        Reply.text('done'),
      ]);
      await h.turn('go');

      expect(requests['SUB:one']!.model, 'claude-sonnet-5-5');
      expect(requests['SUB:two']!.model, 'claude-haiku-5-5');
      expect(requests['SUB:three']!.model, 'claude-sonnet-5-5');
    });

    test('an explicit model wins and does not use up a pool place', () async {
      h = await Harness.start(
        model: 'opus',
        subagentPool: ['claude-sonnet-5-5', 'claude-haiku-5-5'],
      );
      final requests = subagents(h);
      h.model.script.addAll([
        Reply.tools([
          (
            'Agent',
            {
              'description': 'One',
              'prompt': 'SUB:one',
              'model': 'haiku',
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

      expect(requests['SUB:one']!.model, 'claude-haiku-5-5');
      expect(requests['SUB:two']!.model, 'claude-sonnet-5-5');
      final results = {
        for (final result in h.toolResults)
          '${(result['tool_use_result'] as Map)['prompt']}':
              result['tool_use_result'] as Map,
      };
      expect(results['SUB:one']!['modelSource'], 'requested');
      expect(results['SUB:one']!['requestedModel'], 'haiku');
      expect(results['SUB:two']!['poolIndex'], 0);
    });

    test('a forced model wins over the pool, for every agent', () async {
      h = await Harness.start(
        model: 'opus',
        environment: {
          'CLAUDE_CODE_SUBAGENT_MODEL': 'claude-sonnet-5-5',
          'CLAUDE_CODE_SUBAGENT_MODEL_FORCE': '1',
        },
        subagentPool: ['claude-haiku-5-5'],
      );
      final requests = subagents(h);
      h.model.script.addAll([
        Reply.tools([
          (
            'Agent',
            {
              'description': 'One',
              'prompt': 'SUB:one',
              'model': 'haiku',
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

      expect(requests['SUB:one']!.model, 'claude-sonnet-5-5');
      expect(requests['SUB:two']!.model, 'claude-sonnet-5-5');
      final results = [
        for (final result in h.toolResults) result['tool_use_result'] as Map,
      ];
      expect({for (final result in results) result['modelSource']}, {'forced'});
    });

    test('a pool model the provider lacks falls back to the session, as '
        'before', () async {
      h = await Harness.start(
        model: 'opus',
        subagentPool: ['a-model-the-upstream-lacks'],
      );
      final models = <String>[];
      h.model.route = (request) {
        if (!sentIn(request).contains('SUB:one')) return null;
        models.add(request.model);
        return models.length == 1
            ? Reply.failing(const ApiError('model: not found', status: 404))
            : Reply.text('found');
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

      expect(models.first, 'a-model-the-upstream-lacks');
      expect(models.last, h.model.turns.first.model);
      final result = h.toolResults.single['tool_use_result'] as Map;
      // What it was assigned is what is reported; what answered may differ.
      expect(result['assignedModel'], 'a-model-the-upstream-lacks');
      expect(result['resolvedModel'], 'a-model-the-upstream-lacks');
      expect(result['status'], 'completed');
    });

    test('with no pool, a subagent keeps the session model', () async {
      h = await Harness.start(model: 'opus');
      final requests = subagents(h);
      h.model.script.addAll([
        Reply.tool('Agent', {
          'description': 'One',
          'prompt': 'SUB:one',
          'run_in_background': false,
        }),
        Reply.text('done'),
      ]);
      await h.turn('go');

      expect(requests['SUB:one']!.model, h.model.turns.first.model);
      final result = h.toolResults.single['tool_use_result'] as Map;
      expect(result['modelSource'], 'session');
    });
  });
}
