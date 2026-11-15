import 'dart:async';

import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/panels/agent_approval_dialog.dart';
import 'package:baocode/chat/panels/interaction_panel.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  AgentApprovalRequest requestId(String id) => AgentApprovalRequest(
    id: id,
    title: 'Run $id?',
    description: 'Task for $id',
    prompt: 'Read-only details for $id',
    agentType: 'Explore',
    model: 'claude-opus-5-5',
    models: const ['claude-opus-5-5', 'claude-haiku-5-5'],
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

  testWidgets('Abyss modal confirms the picked model once', (tester) async {
    if (!AppEdition.isAbyss) return;
    final live = _LiveSession();
    await live.pump(tester);
    live.request(requestId('one'));
    await tester.pumpAndSettle();
    expect(find.byType(AgentApprovalDialog), findsOneWidget);
    expect(find.text('Read-only details for one'), findsOneWidget);
    expect(
      tester
          .widgetList<EditableText>(
            find.descendant(
              of: find.byType(AgentApprovalDialog),
              matching: find.byType(EditableText),
            ),
          )
          .every((text) => text.readOnly),
      isTrue,
    );
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Haiku 5.5').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start agent'));
    await tester.pumpAndSettle();
    expect(live.answers, [
      ('one', ApprovalDecision.allowOnce, 'claude-haiku-5-5'),
    ]);
    live.resolve('one');
    await tester.pumpAndSettle();
    expect(find.byType(AgentApprovalDialog), findsNothing);
  });

  testWidgets('Abyss dismissal denies once and external answer only closes', (
    tester,
  ) async {
    if (!AppEdition.isAbyss) return;
    final live = _LiveSession();
    await live.pump(tester);
    live.request(requestId('cancel'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(live.answers, [('cancel', ApprovalDecision.deny, null)]);
    live.resolve('cancel');
    live.request(requestId('external'));
    await tester.pumpAndSettle();
    live.resolve('external');
    await tester.pumpAndSettle();
    expect(live.answers, hasLength(1));
    expect(find.byType(AgentApprovalDialog), findsNothing);
  });

  testWidgets('Abyss replaces a stale request without duplicate dialogs', (
    tester,
  ) async {
    if (!AppEdition.isAbyss) return;
    final live = _LiveSession();
    await live.pump(tester, secondHost: true);
    live.request(requestId('old'));
    await tester.pumpAndSettle();
    live.resolve('old');
    live.request(requestId('new'));
    await tester.pumpAndSettle();
    expect(find.byType(AgentApprovalDialog), findsOneWidget);
    expect(find.text('Read-only details for new'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(live.answers, [('new', ApprovalDecision.deny, null)]);
    live.resolve('new');
  });

  testWidgets('other editions keep the inline approval panel', (tester) async {
    if (AppEdition.isAbyss) return;
    final live = _LiveSession();
    await live.pump(tester);
    live.request(requestId('inline'));
    await tester.pumpAndSettle();
    expect(find.byType(AgentApprovalDialog), findsNothing);
    expect(find.byType(InteractionPanel), findsOneWidget);
    expect(find.text('Read-only details for inline'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    expect(live.answers, [('inline', ApprovalDecision.deny, null)]);
  });
}

class _Kernel implements AgentKernel {
  _Kernel(this.descriptor, this.events, this.answers);

  @override
  final KernelDescriptor descriptor;

  @override
  final Stream<KernelEvent> events;

  final List<(String, ApprovalDecision, String?)> answers;

  @override
  KernelHealth get health => KernelHealth.ready;
  @override
  Future<void> get stopped => Future.value();

  @override
  void answer(String id, InteractionAnswer answer) {
    final approval = answer as ApprovalAnswer;
    answers.add((id, approval.decision, approval.model));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _LiveSession {
  final events = StreamController<KernelEvent>.broadcast(sync: true);
  final answers = <(String, ApprovalDecision, String?)>[];
  late final ChatSession session;
  var _seq = 0;

  Future<void> pump(WidgetTester tester, {bool secondHost = false}) async {
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'test',
      label: 'Test',
      icon: Icons.abc,
      description: '',
      create: (_) => _Kernel(descriptor, events.stream, answers),
    );
    session = ChatSession(
      kernel: descriptor,
      kernels: [descriptor],
      kernelContext: const KernelContext(cwd: '/p'),
      historyCount: 0,
    );
    addTearDown(() async {
      session.dispose();
      await events.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: secondHost
              ? Column(
                  children: [
                    Expanded(
                      child: ChatScreen(session: session, focused: false),
                    ),
                    Expanded(child: ChatScreen(session: session)),
                  ],
                )
              : ChatScreen(session: session),
        ),
      ),
    );
    await tester.pump();
  }

  void request(AgentApprovalRequest request) {
    events.add(InteractionRequested(++_seq, request));
  }

  void resolve(String id) {
    events.add(InteractionResolved(++_seq, id));
  }
}
