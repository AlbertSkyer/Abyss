import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/link/interaction_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// A child agent's ask reaches a paired phone as an approval, and the
/// phone's answer comes back as one, its model with it.
void main() {
  test('a child agent is put to the phone as an approval with its task', () {
    const request = AgentApprovalRequest(
      id: 'a1',
      title: 'Run a subagent?',
      description: 'Look through the games',
      prompt: 'Compare the three games.',
      agentType: 'Explore',
      model: 'claude-opus-5-5',
      models: ['claude-opus-5-5', 'claude-haiku-5-5'],
      background: true,
    );
    final json = InteractionCodec.encode(request);
    expect(json['t'], 'approval');
    expect(json['id'], 'a1');
    expect(json['agent'], isTrue);
    expect(json['model'], 'claude-opus-5-5');
    expect(json['reason'], 'Look through the games');
    expect(
      (json['preview'] as Map)['text'],
      contains('Compare the three games.'),
    );
  });

  test('the phone allows it, or denies it, with the model it names', () {
    final allowed = InteractionCodec.decodeAnswer({
      't': 'agent',
      'decision': 'allowOnce',
      'model': 'claude-haiku-5-5',
    }) as ApprovalAnswer;
    expect(allowed.decision, ApprovalDecision.allowOnce);
    expect(allowed.model, 'claude-haiku-5-5');

    final denied = InteractionCodec.decodeAnswer({
      't': 'agent',
      'decision': 'deny',
      'message': 'Not now.',
    }) as ApprovalAnswer;
    expect(denied.decision, ApprovalDecision.deny);
    expect(denied.message, 'Not now.');
    expect(denied.model, isNull);
  });
}
