import 'dart:async';
import 'dart:io';

import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/transcript.dart';
import 'package:baocode/kernel/claude_code/agent_task_ledger.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/settings/abyss_workbench_settings.dart';
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
  final automatic = AbyssWorkbenchSettings.automatic;
  setUp(() => AbyssWorkbenchSettings.automatic = () => false);
  tearDown(() => AbyssWorkbenchSettings.automatic = automatic);
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

    test(
      'resumed ledger reports independent runs without an Agent in history',
      () async {
        ledger.recordMember(
          sessionId: 'resume-runs',
          memberId: 'member-one',
          cliAgentId: 'cli-one',
          model: 'model-one',
        );
        ledger.recordStart(
          sessionId: 'resume-runs',
          toolUseId: 'original-call',
          memberId: 'member-one',
          taskId: 'task-one',
          runId: 'run-one',
          model: 'model-one',
          description: 'First task',
        );
        ledger.recordEnd(
          'resume-runs',
          'original-call',
          status: AgentTaskStatus.completed,
          result: 'First result',
        );
        ledger.recordStart(
          sessionId: 'resume-runs',
          toolUseId: 'second-call',
          memberId: 'member-one',
          taskId: 'task-two',
          runId: 'run-two',
          description: 'Second task',
        );
        ledger.recordMember(sessionId: 'other-session', memberId: 'member-two');
        ledger.recordStart(
          sessionId: 'other-session',
          toolUseId: 'other-call',
          memberId: 'member-two',
          taskId: 'other-task',
        );
        await ledger.flush();
        final path = '${directory.path}/resumed-ledger.json';
        File(ledger.path).copySync(path);
        final reopened = await AgentTaskLedger.open(path: path);
        var historyReads = 0;
        var cliStarts = 0;
        final ready = Completer<AgentTaskLedger>();
        final loadingStates = <bool>[];
        var changes = 0;
        final kernel = ClaudeCodeKernel(
          MockKernels.claudeCode,
          KernelContext(
            cwd: '/p',
            resume: SessionRecord(
              id: 'resume-runs',
              title: 'Resumed runs',
              updatedAt: DateTime(2026),
              cwd: '/p',
            ),
          ),
          start: (_) async {
            cliStarts++;
            return FakeCli();
          },
          readHistoryPage: (_, {required turns, before}) async {
            historyReads++;
            return const ClaudeHistoryPage([]);
          },
          taskLedger: ready.future,
        );
        kernel.events.listen((event) {
          if (event is KernelInfoChanged) {
            changes++;
            loadingStates.add(kernel.loadingAgentTasks);
          }
        });
        expect(kernel.loadingAgentTasks, isTrue);
        ready.complete(reopened);
        await pumpEventQueue();
        await pumpEventQueue();
        expect(loadingStates, containsAllInOrder([true, false]));
        expect(changes, greaterThanOrEqualTo(2));
        await pumpEventQueue();
        expect(kernel, isA<ReportsAgentTasks>());
        expect(kernel.loadingAgentTasks, isFalse);
        expect(kernel.agentTasksError, isNull);
        expect(kernel.agentTasks, hasLength(2));
        final first = kernel.agentTasks[0];
        final second = kernel.agentTasks[1];
        expect(first.memberId, 'member-one');
        expect(first.toolUseId, 'original-call');
        expect(first.taskId, 'task-one');
        expect(first.runId, 'run-one');
        expect(first.model, 'model-one');
        expect(first.description, 'First task');
        expect(first.status, KernelAgentTaskStatus.completed);
        expect(first.result, 'First result');
        expect(first.cardId, 'original-call');
        expect(first.hostStopped, isFalse);
        expect(first.hostCancelled, isFalse);
        expect(second.toolUseId, 'second-call');
        expect(second.taskId, 'task-two');
        expect(second.runId, 'run-two');
        expect(second.status, KernelAgentTaskStatus.interrupted);
        expect(second.result, 'Interrupted when host state was rebuilt');
        expect(second.cardId, 'original-call');
        expect(
          kernel.agentTasks.any((t) => t.toolUseId == 'other-call'),
          isFalse,
        );
        expect(cliStarts, 0);
        expect(historyReads, 1);
        expect(() => kernel.agentTasks.add(first), throwsUnsupportedError);
        kernel.dispose();
        await kernel.stopped;
      },
    );

    test(
      'manual member continuation is gated and cannot change its model',
      () async {
        ledger.recordMember(
          sessionId: 'resume-team',
          memberId: 'm',
          cliAgentId: 'cli-m',
          model: '@p/model',
        );
        ledger.recordStart(
          sessionId: 'resume-team',
          toolUseId: 'old',
          memberId: 'm',
          taskId: 'old-run',
        );
        ledger.recordEnd(
          'resume-team',
          'old',
          status: AgentTaskStatus.completed,
        );
        final cli = FakeCli();
        final kernel = ClaudeCodeKernel(
          MockKernels.claudeCode,
          KernelContext(
            cwd: '/p',
            resume: SessionRecord(
              id: 'resume-team',
              title: 'Team',
              updatedAt: DateTime(2026),
              cwd: '/p',
            ),
          ),
          start: (_) async => cli,
          taskLedger: Future.value(ledger),
        );
        final transcript = Transcript();
        kernel.events.listen(transcript.apply);
        kernel.prepare();
        await pumpEventQueue();
        cli.push({
          'type': 'control_request',
          'request_id': 'continue',
          'request': {
            'subtype': 'hook_callback',
            'callback_id': 'baocode-approve-agent',
            'input': {
              'tool_name': 'SendMessage',
              'tool_use_id': 'continue-call',
              'tool_input': {
                'to': 'cli-m',
                'message': 'Continue read only',
                'summary': 'Continue',
              },
            },
          },
        });
        await pumpEventQueue();
        final request = transcript.pendingInteraction as AgentApprovalRequest;
        expect(request.prompt, 'Continue read only');
        expect(request.forced, isTrue);
        kernel.answer(
          request.id,
          const ApprovalAnswer(
            ApprovalDecision.allowOnce,
            model: '@wrong/model',
          ),
        );
        final output =
            ((cli.written.last['response'] as Map)['response']
                    as Map)['hookSpecificOutput']
                as Map;
        expect(output['permissionDecision'], 'allow');
        expect(output.containsKey('updatedInput'), isFalse);
        expect(kernel.agentMembers.single.status, AgentMemberStatus.standby);
        kernel.updateAgentMember(
          'm',
          name: 'Research member',
          role: 'analysis',
          enabled: false,
        );
        expect(kernel.agentMembers.single.status, AgentMemberStatus.disabled);
        cli.push({
          'type': 'control_request',
          'request_id': 'disabled',
          'request': {
            'subtype': 'hook_callback',
            'callback_id': 'baocode-approve-agent',
            'input': {
              'tool_name': 'SendMessage',
              'tool_input': {'to': 'cli-m', 'message': 'Work'},
            },
          },
        });
        await pumpEventQueue();
        expect(transcript.pendingInteraction, isNull);
        final disabled =
            ((cli.written.last['response'] as Map)['response']
                    as Map)['hookSpecificOutput']
                as Map;
        expect(disabled['permissionDecision'], 'deny');
        kernel.updateAgentMember('m', enabled: true);
        expect(kernel.agentMembers.single.name, 'Research member');
        cli.push({
          'type': 'control_request',
          'request_id': 'denied-continuation',
          'request': {
            'subtype': 'hook_callback',
            'callback_id': 'baocode-approve-agent',
            'input': {
              'tool_name': 'SendMessage',
              'tool_use_id': 'cancelled-continuation',
              'tool_input': {
                'to': 'cli-m',
                'message': 'New work',
                'summary': 'New work',
              },
            },
          },
        });
        await pumpEventQueue();
        kernel.answer(
          'denied-continuation',
          const ApprovalAnswer(ApprovalDecision.deny),
        );
        expect(
          ledger.findTask('resume-team', 'cancelled-continuation')!.memberId,
          'm',
        );
        AbyssWorkbenchSettings.automatic = () => true;
        cli.push({
          'type': 'control_request',
          'request_id': 'blocked-resume',
          'request': {
            'subtype': 'hook_callback',
            'callback_id': 'baocode-approve-agent',
            'input': {
              'tool_name': 'SendMessage',
              'tool_input': {'to': 'cli-m', 'message': 'Retry'},
            },
          },
        });
        await pumpEventQueue();
        final blocked =
            ((cli.written.last['response'] as Map)['response']
                    as Map)['hookSpecificOutput']
                as Map;
        expect(blocked['permissionDecision'], 'deny');
        expect('${blocked['permissionDecisionReason']}', contains('stopped'));
        kernel.dispose();
        await kernel.stopped;
      },
    );

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
