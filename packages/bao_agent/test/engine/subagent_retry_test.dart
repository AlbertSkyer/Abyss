import 'dart:convert';

import 'package:bao_agent/bao_agent.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// A retry is never an automatic response to failure: the user confirms it
/// and chooses its model, once. Each confirmation starts exactly one run.
void main() {
  late Harness h;

  tearDown(() => h.dispose());

  String promptOf(ModelRequest request) => jsonEncode(request.body['messages']);

  Future<void> failedChild({bool background = true}) async {
    h.model.route = (request) {
      if (promptOf(request).contains('SUB:original')) {
        return Reply.failing(const ApiError('no connection'));
      }
      return null;
    };
    h.model.script.addAll([
      Reply.tool('Agent', {
        'description': 'Try me',
        'prompt': 'SUB:original',
        'run_in_background': background,
      }),
      Reply.text('done'),
    ]);
    await h.turn('go');
    h.approvalRequests.clear();
  }

  test('denying retry starts no child request and changes no task', () async {
    h = await Harness.start(model: 'opus');
    h.onAgentApproval = (_) async => const {'behavior': 'allow'};
    await failedChild();
    final requests = h.model.requests.length;
    h.onAgentApproval = (_) async => {
      'behavior': 'deny',
      'message': 'Leave it stopped.',
    };
    await expectLater(
      h.request('retry_agent', {
        'task_id': h.engine.session.tasks.tasks.keys.single,
        'model': 'claude-haiku-5-5',
      }),
      throwsA(isA<StateError>()),
    );
    expect(h.model.requests, hasLength(requests));
    expect(h.approvalRequests.single['retry'], isTrue);
    expect(h.engine.session.subagents.values.single.running, isFalse);
  });

  test('confirmed once, a fresh child runs on the picked model', () async {
    h = await Harness.start(model: 'opus');
    h.onAgentApproval = (_) async => const {'behavior': 'allow'};
    await failedChild();
    final original = h.engine.session.subagents.values.single;
    final originalStore = original.run;
    var retried = false;
    h.model.route = (request) {
      if (promptOf(request).contains('explicitly asked to retry')) {
        retried = true;
        return Reply.text('Recovered on the second attempt.');
      }
      return null;
    };
    h.onAgentApproval = (_) async => {
      'behavior': 'allow',
      'model': 'claude-haiku-5-5',
    };
    final id = h.engine.session.tasks.tasks.keys.single;
    final result = await h.request('retry_agent', {
      'task_id': id,
      'model': 'claude-haiku-5-5',
    });
    await h.engine.session.tasks[id]!.done.timeout(const Duration(seconds: 10));

    expect(retried, isTrue);
    expect(result['model'], 'claude-haiku-5-5');
    expect(
      h.engine.session.subagents.values,
      hasLength(1),
      reason: jsonEncode(h.approvalRequests),
    );
    final job = h.engine.session.subagents.values.single;
    expect(job.agentId, id);
    expect(job.run, isNot(same(originalStore)));
    expect(job.model, 'claude-haiku-5-5');
    expect(h.approvalRequests, hasLength(1));
    expect(h.of('system', 'task_started'), hasLength(2));
    final ended = h.of('system', 'task_notification').last;
    expect((ended['result'] as Map)['status'], 'completed');
    expect((ended['result'] as Map)['actualModel'], 'claude-haiku-5-5');
  });

  test(
    'a foreground call cannot be replaced while it still owns the task',
    () async {
      h = await Harness.start(model: 'opus');
      await failedChild(background: false);
      await expectLater(
        h.request('retry_agent', {
          'task_id': h.engine.session.tasks.tasks.keys.single,
          'model': 'opus',
        }),
        throwsA(isA<StateError>()),
      );
      expect(h.approvalRequests, isEmpty);
    },
  );
}
