import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/src/engine/tasks.dart';
import 'package:bao_agent/src/tools/team_tools.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  late Harness h;

  tearDown(() => h.dispose());

  test(
    'per-parent FIFO, default two, cancellation and exactly-once admission',
    () async {
      h = await Harness.start();
      await h.request('initialize');
      final managers = h.engine.session.tasks;
      final admitted = <String>[];
      BackgroundTask make(String parent, String id) => managers.registerAgent(
        description: id,
        agentId: id,
        parentId: parent,
        admit: () => admitted.add(id),
      );
      final a = make('p1', 'a1');
      final b = make('p1', 'a2');
      final c = make('p1', 'a3');
      final other = make('p2', 'b1');
      expect(managers.agentLimit, 2);
      expect(admitted, ['a1', 'a2', 'b1']);
      expect(c.status, TaskStatus.queued);
      expect(managers.agentQueueStatus('p1')['task_ids'], ['a3']);
      expect(managers.agentQueueStatus('p2')['running'], 1);

      await managers.stop(c.id);
      expect(admitted, ['a1', 'a2', 'b1']);
      expect(managers.agentQueueStatus('p1')['running'], 2);

      final d = make('p1', 'a4');
      expect(admitted, ['a1', 'a2', 'b1']);
      await managers.stop(a.id);
      expect(admitted, ['a1', 'a2', 'b1', 'a4']);
      managers.finish(d, TaskStatus.completed);
      managers.finish(d, TaskStatus.completed);
      expect(managers.agentQueueStatus('p1')['running'], 1);
      managers.finish(b, TaskStatus.completed);
      managers.finish(other, TaskStatus.completed);
      expect(managers.agentQueueStatus('p1')['running'], 0);
    },
  );

  test(
    'pool assignments stay in order when registration queues excess work',
    () async {
      h = await Harness.start(
        subagentPool: ['claude-sonnet-5-5', 'claude-haiku-5-5'],
      );
      await h.request('initialize');
      final manager = h.engine.session.tasks;
      final admitted = <String>[];
      final tasks = <BackgroundTask>[];
      for (final id in ['one', 'two', 'three']) {
        final assignment = h.engine.session.subagentModels.assign(
          forced: false,
          sessionModel: 'claude-opus-5-5',
          resolve: (model) => model,
        );
        tasks.add(
          manager.registerAgent(
            description: id,
            agentId: id,
            parentId: 'parent',
            model: assignment.model,
            modelSource: assignment.source.name,
            admit: () => admitted.add(id),
          ),
        );
      }
      expect(tasks.map((t) => t.model), [
        'claude-sonnet-5-5',
        'claude-haiku-5-5',
        'claude-sonnet-5-5',
      ]);
      expect(tasks.map((t) => t.modelSource), everyElement('pool'));
      expect(admitted, ['one', 'two']);
      expect(tasks.last.status, TaskStatus.queued);
      await manager.stopAll();
    },
  );

  test('reopen restores a read-only interrupted index without restarting', () async {
    h = await Harness.start();
    await h.request('initialize');
    final tasks = h.engine.session.tasks;
    for (final (id, status) in [
      ('finished', TaskStatus.completed),
      ('errored', TaskStatus.failed),
      ('live-queued', TaskStatus.queued),
    ]) {
      final task = tasks.registerAgent(
        description: id,
        agentId: id,
        parentId: status == TaskStatus.queued ? 'p' : null,
        model: 'provider/claude-sonnet-5-5',
        requestedModel: 'sonnet',
        modelSource: 'pool',
        approvalStatus: 'approved',
      );
      if (status != TaskStatus.queued) tasks.finish(task, status);
    }
    // An unfinished record from before finished-task persistence, or from
    // a process that never wrote its end, is recovered as interrupted too.
    final file = File(h.sessionFile);
    file.writeAsStringSync(
      '${jsonEncode({
        'type': 'task_index',
        'task': {'task_id': 'legacy-running', 'task_type': 'local_agent', 'description': 'Old unfinished record', 'status': 'running', 'is_backgrounded': true},
      })}\n',
      mode: FileMode.append,
      flush: true,
    );
    tasks.registerAgent(
      description: 'Left running',
      agentId: 'stale-running',
      parentId: 'p',
    );
    h.engine.session.tasks.registerAgent(
      description: 'Left queued',
      agentId: 'stale-queued',
      parentId: 'p',
    );
    h.engine.session.tasks.registerAgent(
      description: 'Left queued 2',
      agentId: 'stale-queued-2',
      parentId: 'p',
    );
    final id = h.engine.session.sessionId;
    final previous = h;
    await previous.engine.close();
    // A lost process leaves no killed records. Remove only those written
    // by this harness's orderly close, keeping each task's last snapshot
    // from the previous process and its completed/failed final states.
    file.writeAsStringSync(
      '${file.readAsLinesSync().where((line) {
        final entry = jsonDecode(line);
        if (entry case {'type': 'task_index', 'task': {'status': 'killed'}}) {
          return false;
        }
        return true;
      }).join('\n')}\n',
      flush: true,
    );
    h = await Harness.start(from: previous, resume: id);
    await h.request('initialize');
    final restored = h.engine.session.tasks;
    expect(restored.tasks, hasLength(7));
    for (final id in [
      'stale-running',
      'stale-queued',
      'stale-queued-2',
      'live-queued',
      'legacy-running',
    ]) {
      expect(restored[id]?.status, TaskStatus.interrupted, reason: id);
    }
    expect(restored['finished']?.status, TaskStatus.completed);
    expect(restored['finished']?.model, 'provider/claude-sonnet-5-5');
    expect(restored['finished']?.requestedModel, 'sonnet');
    expect(restored['finished']?.modelSource, 'pool');
    expect(restored['finished']?.approvalStatus, 'approved');
    expect(restored['live-queued']?.parentId, 'p');
    expect(restored['errored']?.status, TaskStatus.failed);
    expect(restored.agentQueueStatus('p')['running'], 0);
    expect(restored.agentQueueStatus('p')['queued'], 0);
    expect(h.model.turns, isEmpty);
    expect(await restored.stop('stale-running'), isFalse);
    expect(
      () => SendMessageTool.find(h.engine.session, 'stale-running'),
      throwsStateError,
    );
    final events = h.of('system', 'task_started');
    expect(events, hasLength(7));
    expect(events.every((event) => event['read_only'] == true), isTrue);
    expect(events.where((event) => event['status'] == 'queued'), isEmpty);
  });

  test(
    'cancelling an admitted queued call completes its tool exactly once',
    () async {
      h = await Harness.start(
        script: [
          Reply.tool('Agent', {
            'description': 'Waiting child',
            'prompt': 'CHILD: must never run.',
            'run_in_background': false,
          }),
          Reply.text('Cancellation reported.'),
        ],
      );
      await h.request('initialize');
      final manager = h.engine.session.tasks;
      manager.registerAgent(
        description: 'Occupies slot',
        agentId: 'one',
        parentId: '',
      );
      manager.registerAgent(
        description: 'Occupies slot',
        agentId: 'two',
        parentId: '',
      );
      final approved = h.messages
          .where(
            (message) =>
                message['type'] == 'system' &&
                message['subtype'] == 'agent_approval' &&
                message['status'] == 'approved',
          )
          .first
          .timeout(const Duration(seconds: 10));
      h.send('Start the child');
      await approved;
      final waiting = manager.tasks.values
          .where((task) => task.description == 'Waiting child')
          .single;
      expect(waiting.status, TaskStatus.queued);
      await manager.stop(waiting.id);
      await h.nextIdle();
      expect(waiting.status, TaskStatus.killed);
      expect(manager.agentQueueStatus('')['running'], 2);
      expect(
        h.toolResults.where((result) => result['tool_use_id'] != ''),
        hasLength(1),
      );
      expect(h.model.turns, hasLength(2));
      expect(
        h.model.turns.where((request) {
          final messages = request.body['messages'] as List;
          return messages.isNotEmpty &&
              jsonEncode(messages.first).contains('CHILD:');
        }),
        isEmpty,
      );
    },
  );

  test('limit is configurable and clamped', () async {
    h = await Harness.start(environment: {'BAOCODE_SUBAGENT_CONCURRENCY': '1'});
    expect(h.engine.session.tasks.agentLimit, 1);
    await h.engine.close();
    h = await Harness.start(
      from: h,
      environment: {'BAOCODE_SUBAGENT_CONCURRENCY': 'not-a-number'},
    );
    expect(h.engine.session.tasks.agentLimit, 2);
  });
}
