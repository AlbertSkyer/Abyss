import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli, claude;

/// A child agent (Agent/Task) is put to the user before it starts: what it
/// is to do, and the model it would run on. The answer's model goes back to
/// the core with the leave; a denial starts nothing.
void main() {
  void ask(
    FakeCli cli, {
    String id = 'ask-1',
    String model = 'claude-opus-5-5',
    List<String> models = const ['claude-opus-5-5', 'claude-haiku-5-5'],
    bool forced = false,
    bool background = true,
  }) => cli.push({
    'type': 'control_request',
    'request_id': id,
    'request': {
      'subtype': 'can_use_agent',
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

  Map<String, Object?> responseTo(FakeCli cli, String id) {
    final message = cli.written.lastWhere(
      (message) =>
          message['type'] == 'control_response' &&
          (message['response'] as Map)['request_id'] == id,
    );
    return ((message['response'] as Map)['response'] as Map)
        .cast<String, Object?>();
  }

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

  test('with no one there to ask (a bot), it is allowed as assigned', () async {
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
    ask(cli);
    await pumpEventQueue();

    expect(transcript.pendingInteraction, isNull);
    final response = responseTo(cli, 'ask-1');
    expect(response['behavior'], 'allow');
    expect(response['model'], 'claude-opus-5-5');
    kernel.dispose();
  });
}
