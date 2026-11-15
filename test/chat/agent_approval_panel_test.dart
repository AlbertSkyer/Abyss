import 'package:baocode/chat/panels/interaction_panel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The card a child agent's start is confirmed on: its task, and the model
/// picked for it. Cancelled, the answer denies it; confirmed, it allows it
/// with the pick.
void main() {
  AgentApprovalRequest request({
    bool forced = false,
    List<String> models = const ['claude-opus-5-5', 'claude-haiku-5-5'],
  }) => AgentApprovalRequest(
    id: 'a1',
    title: 'Run a subagent?',
    description: 'Look through the games',
    prompt: 'Compare the three games and report the differences.',
    agentType: 'Explore',
    model: 'claude-opus-5-5',
    models: models,
    modelSource: 'pool',
    forced: forced,
  );

  Future<List<InteractionAnswer>> pump(
    WidgetTester tester,
    AgentApprovalRequest request,
  ) async {
    final answers = <InteractionAnswer>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: InteractionPanel(request: request, onAnswer: answers.add),
        ),
      ),
    );
    await tester.pump();
    return answers;
  }

  testWidgets('shows what it is to do and the models it may run on', (
    tester,
  ) async {
    await pump(tester, request());
    expect(find.text('Run a subagent?'), findsOneWidget);
    expect(find.text('Look through the games'), findsWidgets);
    expect(find.textContaining('Compare the three games'), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsOneWidget);
    // The assigned model first.
    expect(
      find.descendant(
        of: find.byType(DropdownButton<String>),
        matching: find.text('Opus 5.5'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('confirmed as assigned, allows it with that model', (
    tester,
  ) async {
    final answers = await pump(tester, request());
    await tester.tap(find.text('Start agent'));
    await tester.pump();
    final answer = answers.single as ApprovalAnswer;
    expect(answer.decision, ApprovalDecision.allowOnce);
    expect(answer.model, 'claude-opus-5-5');
  });

  testWidgets('a model picked is the one allowed', (tester) async {
    final answers = await pump(tester, request());
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Haiku 5.5').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start agent'));
    await tester.pump();
    final answer = answers.single as ApprovalAnswer;
    expect(answer.decision, ApprovalDecision.allowOnce);
    expect(answer.model, 'claude-haiku-5-5');
  });

  testWidgets('cancelled, it denies it: no model goes back', (tester) async {
    final answers = await pump(tester, request());
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    final answer = answers.single as ApprovalAnswer;
    expect(answer.decision, ApprovalDecision.deny);
    expect(answer.model, isNull);
  });

  testWidgets('a forced model offers none, and says which it is', (
    tester,
  ) async {
    await pump(tester, request(forced: true, models: const []));
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.textContaining('CLAUDE_CODE_SUBAGENT_MODEL_FORCE'), findsOne);
    expect(find.textContaining('Opus 5.5'), findsOneWidget);
  });
}
