import 'dart:io';

import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/transcript.dart';
import 'package:baocode/kernel/claude_code/agent_task_ledger.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

Map<String, Object?> call(String id) => {
  'type': 'assistant',
  'uuid': 'assistant-$id',
  'message': {
    'id': 'message-$id',
    'role': 'assistant',
    'content': [
      {
        'type': 'tool_use',
        'id': id,
        'name': 'Agent',
        'input': {'description': 'Read-only task'},
      },
    ],
  },
};

Map<String, Object?> result(String id, {bool error = true}) => {
  'type': 'user',
  'uuid': 'result-$id',
  'message': {
    'role': 'user',
    'content': [
      {
        'type': 'tool_result',
        'tool_use_id': id,
        'is_error': error,
        'content': 'Execution returned',
      },
    ],
  },
};

void main() {
  group('Abyss durable host task decisions', skip: !AppEdition.isAbyss, () {
    late Directory directory;
    late AgentTaskLedger ledger;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('abyss-ledger-kernel');
      ledger = await AgentTaskLedger.open(
        path: '${directory.path}/ledger.json',
      );
    });
    tearDown(() async {
      await ledger.flush();
      await directory.delete(recursive: true);
    });

    test(
      'a cancelled start survives kernel recreation and late error',
      () async {
        final cli = FakeCli();
        final kernel = ClaudeCodeKernel(
          MockKernels.claudeCode,
          const KernelContext(cwd: '/p'),
          start: (_) async => cli,
          taskLedger: Future.value(ledger),
        );
        final transcript = Transcript();
        kernel.events.listen(transcript.apply);
        kernel.send(const KernelTurn(id: 'turn', text: 'Delegate'));
        await pumpEventQueue();
        cli.push({
          'type': 'system',
          'subtype': 'init',
          'session_id': 'ledger-session',
        });
        cli.push(call('cancelled'));
        cli.push({
          'type': 'control_request',
          'request_id': 'approval',
          'request': {
            'subtype': 'hook_callback',
            'callback_id': 'baocode-approve-agent',
            'input': {
              'tool_name': 'Agent',
              'tool_use_id': 'cancelled',
              'tool_input': {
                'description': 'Read-only task',
                'prompt': 'Read only',
              },
            },
          },
        });
        await pumpEventQueue();
        kernel.answer('approval', const ApprovalAnswer(ApprovalDecision.deny));
        cli.push(result('cancelled'));
        await pumpEventQueue();
        expect(
          ledger.findTask('ledger-session', 'cancelled')!.hostCancelled,
          isTrue,
        );
        kernel.dispose();
        await kernel.stopped;

        final diskCopy = File('${directory.path}/ledger.json')
            .copySync('${directory.path}/reopened.json');
        final reopened = await AgentTaskLedger.open(path: diskCopy.path);
        final restored = ClaudeCodeKernel(
          MockKernels.claudeCode,
          KernelContext(
            cwd: '/p',
            resume: SessionRecord(
              id: 'ledger-session',
              title: 'Restored',
              updatedAt: DateTime(2026),
              cwd: '/p',
            ),
          ),
          start: (_) async => FakeCli(),
          taskLedger: Future.value(reopened),
          readHistoryPage: (_, {required turns, before}) async =>
              ClaudeHistoryPage([
                call('cancelled'),
                result('cancelled'),
                call('failed'),
                result('failed'),
              ]),
        );
        final replay = Transcript();
        restored.events.listen(replay.apply);
        await pumpEventQueue();
        final cancelled =
            replay.itemAt(replay.indexOf('cancelled')!) as AgentItem;
        expect(cancelled.status, CommandStatus.interrupted);
        expect(cancelled.outcome, 'cancelled');
        final failed = replay.itemAt(replay.indexOf('failed')!) as AgentItem;
        expect(failed.status, CommandStatus.failed);
        restored.dispose();
        await restored.stopped;
      },
    );

    test('one CLI member retains two independent run records', () async {
      final cli = FakeCli();
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p'),
        start: (_) async => cli,
        taskLedger: Future.value(ledger),
      );
      kernel.events.listen((_) {});
      kernel.prepare();
      await pumpEventQueue();
      cli.push({'type': 'system', 'subtype': 'init', 'session_id': 'team'});
      cli.push(call('first'));
      cli.push({
        'type': 'system',
        'subtype': 'task_started',
        'task_type': 'local_agent',
        'task_id': 'member',
        'tool_use_id': 'first',
        'run_id': 'one',
      });
      cli.push({
        'type': 'system',
        'subtype': 'task_notification',
        'task_id': 'member',
        'tool_use_id': 'first',
        'run_id': 'one',
        'status': 'completed',
      });
      await pumpEventQueue();
      cli.push({
        'type': 'system',
        'subtype': 'task_started',
        'task_type': 'local_agent',
        'task_id': 'member',
        'tool_use_id': 'continuation',
        'run_id': 'two',
      });
      await pumpEventQueue();
      expect(ledger.membersFor('team'), hasLength(1));
      expect(ledger.tasksFor('team'), hasLength(2));
      expect(
        ledger.findTask('team', 'first')!.status,
        AgentTaskStatus.completed,
      );
      expect(
        ledger.findTask('team', 'continuation')!.status,
        AgentTaskStatus.running,
      );
      kernel.dispose();
      await kernel.stopped;
      expect(
        ledger.findTask('team', 'continuation')!.status,
        AgentTaskStatus.interrupted,
      );
    });

    test('task stop keeps its decision when CLI reports failed', () async {
      final cli = FakeCli();
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p'),
        start: (_) async => cli,
        taskLedger: Future.value(ledger),
      );
      final transcript = Transcript();
      kernel.events.listen(transcript.apply);
      kernel.prepare();
      await pumpEventQueue();
      cli.push({
        'type': 'system',
        'subtype': 'init',
        'session_id': 'stop-session',
      });
      cli.push(call('start'));
      cli.push({
        'type': 'system',
        'subtype': 'task_started',
        'task_type': 'local_agent',
        'task_id': 'cli-member',
        'tool_use_id': 'start',
        'run_id': 'run-one',
        'description': 'Task',
      });
      await pumpEventQueue();
      kernel.stopTask('cli-member');
      cli.push({
        'type': 'system',
        'subtype': 'task_notification',
        'task_id': 'cli-member',
        'tool_use_id': 'start',
        'status': 'failed',
      });
      await pumpEventQueue();
      expect(ledger.findTask('stop-session', 'start')!.hostStopped, isTrue);
      final agent =
          transcript.itemAt(transcript.indexOf('start')!) as AgentItem;
      expect(agent.status, CommandStatus.interrupted);
      expect(agent.outcome, 'cancelled');
      kernel.dispose();
      await kernel.stopped;
    });
  });
}
