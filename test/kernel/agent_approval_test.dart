import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/kernel/transcript.dart';
import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/settings/abyss_workbench_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli, claude, recordedResponse;

/// A child agent (Agent/Task) is put to the user before it starts: what it
/// is to do, and the model it would run on. The answer's model goes back to
/// the core with the leave; a denial starts nothing.
void main() {
  final automatic = AbyssWorkbenchSettings.automatic;
  setUp(() => AbyssWorkbenchSettings.automatic = () => false);
  tearDown(() => AbyssWorkbenchSettings.automatic = automatic);
  void ask(
    FakeCli cli, {
    String id = 'ask-1',
    String subtype = 'can_use_agent',
    String model = 'claude-opus-5-5',
    List<String> models = const ['claude-opus-5-5', 'claude-haiku-5-5'],
    bool forced = false,
    bool background = true,
  }) => cli.push({
    'type': 'control_request',
    'request_id': id,
    'request': {
      'subtype': subtype,
      'tool_name': 'Agent',
      'subagent_type': 'Explore',
      'description': 'Look through the games',
      'prompt': 'Compare the three games and report the differences.',
      'tool_use_id': 'call-1',
      'model': model,
      'model_source': 'pool',
      'models': models,
      'forced': forced,
      'run_in_background': background,
    },
  });

  void askHook(FakeCli cli, {String id = 'hook-1'}) => cli.push({
    'type': 'control_request',
    'request_id': id,
    'request': {
      'subtype': 'hook_callback',
      'callback_id': 'baocode-approve-agent',
      'input': {
        'hook_event_name': 'PreToolUse',
        'tool_name': 'Agent',
        'tool_use_id': 'call-hook',
        'tool_input': {
          'description': 'Look through the games',
          'prompt': 'Compare the three games and report the differences.',
          'subagent_type': 'Explore',
          'run_in_background': true,
          'model': 'haiku',
        },
      },
    },
  });

  Map<String, Object?> responseTo(FakeCli cli, String id) {
    final message = cli.written.lastWhere(
      (message) =>
          message['type'] == 'control_response' &&
          (message['response'] as Map)['request_id'] == id,
    );
    return ((message['response'] as Map)['response'] as Map)
        .cast<String, Object?>();
  }

  group('Abyss external CLI hooks', () {
    test(
      'missing hook acknowledgement blocks the session before user input',
      () async {
        final cli = FakeCli(
          answers: {
            'initialize': {
              ...recordedResponse(
                'question',
                (payload) => payload.containsKey('commands'),
              ),
              'hooks_applied': false,
            },
          },
        );
        final (:kernel, transcript: _, events: _) = claude(cli);
        addTearDown(kernel.dispose);
        kernel.prepare();
        await pumpEventQueue(times: 30);
        expect(kernel.health.status, KernelHealthStatus.failed);
        expect(cli.users, isEmpty);
        expect(cli.closed, isTrue);
      },
    );

    test(
      'external CLI PreToolUse waits, and allow keeps the original agent',
      () async {
        final cli = FakeCli();
        final (:kernel, :transcript, events: _) = claude(cli);
        kernel.prepare();
        await pumpEventQueue();
        final hooks = cli.requests('initialize').single['hooks'] as Map;
        final before = hooks['PreToolUse'] as List;
        final agent = before.singleWhere(
          (hook) => (hook as Map)['matcher'] == 'Agent|Task|SendMessage',
        ) as Map;
        expect(agent['onFailure'], 'block');
        askHook(cli);
        await pumpEventQueue();
        final approval = transcript.pendingInteraction as AgentApprovalRequest;
        expect(approval.prompt, contains('Compare the three games'));
        expect(approval.agentType, 'Explore');
        expect(approval.background, isTrue);
        kernel.answer(
          approval.id,
          const ApprovalAnswer(ApprovalDecision.allowOnce),
        );
        await pumpEventQueue();
        expect(responseTo(cli, 'hook-1'), {
          'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': 'allow',
            'permissionDecisionReason': 'Approved by the user in Abyss.',
          },
        });
        kernel.dispose();
      },
    );

    test(
      'external CLI cancel is a hook denial, never a private permission',
      () async {
        final cli = FakeCli();
        final (:kernel, :transcript, events: _) = claude(cli);
        kernel.prepare();
        await pumpEventQueue();
        askHook(cli);
        await pumpEventQueue();
        kernel.answer(
          transcript.pendingInteraction!.id,
          const ApprovalAnswer(ApprovalDecision.deny, message: 'Not now.'),
        );
        await pumpEventQueue();
        final output = responseTo(cli, 'hook-1')['hookSpecificOutput'] as Map;
        expect(output['permissionDecision'], 'deny');
        expect(output['permissionDecisionReason'], contains('Not now.'));
        expect(output, isNot(contains('updatedInput')));
        kernel.dispose();
      },
    );

    test('a denied external CLI start stays cancelled, not failed', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      addTearDown(kernel.dispose);
      kernel.send(const KernelTurn(id: 'u1', text: 'Delegate this'));
      await pumpEventQueue();
      cli.push({
        'type': 'assistant',
        'uuid': 'a1',
        'message': {
          'id': 'm1',
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'call-hook',
              'name': 'Agent',
              'input': {'description': 'Look through the games'},
            },
          ],
        },
      });
      askHook(cli);
      await pumpEventQueue();
      kernel.answer(
        transcript.pendingInteraction!.id,
        const ApprovalAnswer(ApprovalDecision.deny),
      );
      cli.push({
        'type': 'system',
        'subtype': 'permission_denied',
        'tool_use_id': 'call-hook',
      });
      cli.push({
        'type': 'user',
        'uuid': 'tool-result',
        'message': {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'call-hook',
              'content': 'Tool execution failed unexpectedly',
              'is_error': true,
            },
          ],
        },
      });
      await pumpEventQueue();
      final agent =
          transcript.itemAt(transcript.indexOf('call-hook')!) as AgentItem;
      expect(agent.status, CommandStatus.interrupted);
      expect(agent.approvalStatus, 'denied');
      expect(agent.outcome, 'cancelled');

      // The host decision is not persisted as a session message. Replaying
      // the CLI's error alone must not relabel a real execution failure.
      final reader = ClaudeHistoryPage([
        {
          'type': 'assistant',
          'uuid': 'a2',
          'message': {
            'id': 'm2',
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'call-failed',
                'name': 'Agent',
                'input': {'description': 'Actually ran'},
              },
            ],
          },
        },
        {
          'type': 'user',
          'uuid': 'result-2',
          'message': {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'call-failed',
                'content': 'The subagent was not started.',
                'is_error': true,
              },
            ],
          },
        },
      ]);
      final restored = ClaudeCodeKernel(
        MockKernels.claudeCode,
        KernelContext(
          cwd: '/p',
          resume: SessionRecord(
            id: 'restored',
            title: 'Restored',
            updatedAt: DateTime(2026),
            cwd: '/p',
          ),
        ),
        start: (_) async => cli,
        providerEnvironment: (_, _) async => const {},
        readHistoryPage: (_, {required turns, before}) async => reader,
      );
      final restoredTranscript = Transcript();
      restored.events.listen(restoredTranscript.apply);
      addTearDown(restored.dispose);
      await pumpEventQueue();
      final failed = restoredTranscript.itemAt(
        restoredTranscript.indexOf('call-failed')!,
      ) as AgentItem;
      expect(failed.status, CommandStatus.failed);
      expect(failed.outcome, isNot('cancelled'));
    });

    test('external CLI closing denies an unanswered hook', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.prepare();
      await pumpEventQueue();
      askHook(cli);
      await pumpEventQueue();
      kernel.dispose();
      await pumpEventQueue();
      final output = responseTo(cli, 'hook-1')['hookSpecificOutput'] as Map;
      expect(output['permissionDecision'], 'deny');
      expect(output['permissionDecisionReason'], contains('window closed'));
      expect(transcript.pendingInteraction, isNull);
    });

    test('CLI model alias rewrites preserve prompt and agent type', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      addTearDown(kernel.dispose);
      kernel.prepare();
      await pumpEventQueue();
      askHook(cli);
      await pumpEventQueue();
      kernel.answer(
        transcript.pendingInteraction!.id,
        const ApprovalAnswer(ApprovalDecision.allowOnce, model: 'opus'),
      );
      final output = responseTo(cli, 'hook-1')['hookSpecificOutput'] as Map;
      expect(output['permissionDecision'], 'allow');
      expect(output['updatedInput'], {
        'description': 'Look through the games',
        'prompt': 'Compare the three games and report the differences.',
        'subagent_type': 'Explore',
        'run_in_background': true,
        'model': 'opus',
      });
    });

    test(
      'unsupported full model IDs fail closed before tool execution',
      () async {
        final cli = FakeCli();
        final (:kernel, :transcript, events: _) = claude(cli);
        addTearDown(kernel.dispose);
        kernel.prepare();
        await pumpEventQueue();
        askHook(cli);
        await pumpEventQueue();
        kernel.answer(
          transcript.pendingInteraction!.id,
          const ApprovalAnswer(
            ApprovalDecision.allowOnce,
            model: '@other/model',
          ),
        );
        final output = responseTo(cli, 'hook-1')['hookSpecificOutput'] as Map;
        expect(output['permissionDecision'], 'deny');
        expect(output.containsKey('updatedInput'), isFalse);
      },
    );
  }, skip: !AppEdition.isAbyss);

  test(
    'shown with its task and models; the pick goes back with the leave',
    () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.prepare();
      await pumpEventQueue();
      ask(cli);
      await pumpEventQueue();

      final request = transcript.pendingInteraction;
      expect(request, isA<AgentApprovalRequest>());
      final approval = request as AgentApprovalRequest;
      expect(approval.description, 'Look through the games');
      expect(approval.prompt, contains('Compare the three games'));
      expect(approval.agentType, 'Explore');
      expect(approval.model, 'claude-opus-5-5');
      expect(approval.models, ['claude-opus-5-5', 'claude-haiku-5-5']);
      expect(approval.forced, isFalse);
      expect(approval.background, isTrue);

      kernel.answer(
        approval.id,
        const ApprovalAnswer(
          ApprovalDecision.allowOnce,
          model: 'claude-haiku-5-5',
        ),
      );
      await pumpEventQueue();

      final response = responseTo(cli, 'ask-1');
      expect(response['behavior'], 'allow');
      expect(response['model'], 'claude-haiku-5-5');
      expect(transcript.pendingInteraction, isNull);
      kernel.dispose();
    },
  );

  test('cancelled, the core is told no and no model goes back', () async {
    final cli = FakeCli();
    final (:kernel, :transcript, events: _) = claude(cli);
    kernel.prepare();
    await pumpEventQueue();
    ask(cli);
    await pumpEventQueue();

    kernel.answer(
      transcript.pendingInteraction!.id,
      const ApprovalAnswer(ApprovalDecision.deny, message: 'Not now.'),
    );
    await pumpEventQueue();

    final response = responseTo(cli, 'ask-1');
    expect(response['behavior'], 'deny');
    expect(response['message'], 'Not now.');
    expect(response['model'], isNull);
    kernel.dispose();
  });

  test('a forced model offers none to pick and says so', () async {
    final cli = FakeCli();
    final (:kernel, :transcript, events: _) = claude(cli);
    kernel.prepare();
    await pumpEventQueue();
    ask(cli, forced: true, models: const []);
    await pumpEventQueue();

    final approval = transcript.pendingInteraction as AgentApprovalRequest;
    expect(approval.forced, isTrue);
    expect(approval.models, isEmpty);
    expect(approval.model, 'claude-opus-5-5');
    kernel.dispose();
  });

  test('closing denies an unanswered child and resolves its request', () async {
    final cli = FakeCli();
    final (:kernel, :transcript, events: _) = claude(cli);
    kernel.prepare();
    await pumpEventQueue();
    ask(cli);
    await pumpEventQueue();
    expect(transcript.pendingInteraction, isA<AgentApprovalRequest>());

    kernel.dispose();
    await pumpEventQueue();

    final response = responseTo(cli, 'ask-1');
    expect(response['behavior'], 'deny');
    expect(response['message'], contains('window closed'));
    expect(response['model'], isNull);
    expect(transcript.pendingInteraction, isNull);
  });

  test(
    'an exited transport settles the question without a dead-pipe write',
    () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.prepare();
      await pumpEventQueue();
      ask(cli);
      await pumpEventQueue();
      expect(transcript.pendingInteraction, isA<AgentApprovalRequest>());

      cli.push({'type': 'transport_exit', 'code': 1, 'stderr': 'closed'});
      await pumpEventQueue();

      expect(transcript.pendingInteraction, isNull);
      expect(
        cli.written.where(
          (message) =>
              message['type'] == 'control_response' &&
              (message['response'] as Map)['request_id'] == 'ask-1',
        ),
        isEmpty,
      );
      kernel.dispose();
    },
  );

  test(
    'retry always asks explicitly, even with no one normally to ask',
    () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(
        cli,
        context: KernelContext(
          cwd: '/p',
          workspace: () =>
              const KernelWorkspace(folders: ['/p'], approvesAll: true),
        ),
      );
      kernel.prepare();
      await pumpEventQueue();
      ask(cli, subtype: 'retry_agent');
      await pumpEventQueue();
      final approval = transcript.pendingInteraction as AgentApprovalRequest;
      expect(approval.retry, isTrue);
      expect(approval.title, 'Retry this subagent?');
      kernel.answer(approval.id, const ApprovalAnswer(ApprovalDecision.deny));
      await pumpEventQueue();
      expect(responseTo(cli, 'ask-1')['behavior'], 'deny');
      kernel.dispose();
    },
  );

  test('an undeclared retry capability is reported, never faked', () async {
    final cli = FakeCli();
    final (:kernel, :transcript, events: _) = claude(cli);
    kernel.prepare();
    await pumpEventQueue();
    final error = await kernel.retryTask('a1', 'claude-haiku-5-5');
    expect(error, contains('unavailable'));
    expect(cli.requests('retry_agent'), isEmpty);
    expect(transcript.pendingInteraction, isNull);
    kernel.dispose();
  });

  test('a declared retry goes to the same live process', () async {
    final cli = FakeCli(
      answers: {
        'initialize': {
          ...recordedResponse(
            'question',
            (payload) => payload.containsKey('commands'),
          ),
          'hooks_applied': true,
          'capabilities': const ['agent_retry_v1'],
        },
      },
    );
    final (:kernel, :transcript, events: _) = claude(cli);
    kernel.prepare();
    await pumpEventQueue();
    expect(kernel.retryModels, isNotEmpty);
    expect(await kernel.retryTask('a1', 'opus'), isEmpty);
    expect(cli.requests('retry_agent').single, {
      'subtype': 'retry_agent',
      'task_id': 'a1',
      'model': 'opus',
    });
    expect(transcript.pendingInteraction, isNull);
    kernel.dispose();
  });
}

final cli = FakeCli();
