import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/chat/side_panel/agent_tasks_page.dart';
import 'package:baocode/chat/side_panel/side_panel_controller.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class TaskKernel implements AgentKernel, ReportsAgentTasks, LoadsHistory {
  TaskKernel(this.descriptor);
  @override
  final KernelDescriptor descriptor;
  final stream = StreamController<KernelEvent>.broadcast(sync: true);
  @override
  Stream<KernelEvent> get events => stream.stream;
  @override
  List<KernelAgentTask> agentTasks = [
    const KernelAgentTask(
      memberId: 'member',
      toolUseId: 'first',
      taskId: 'agent',
      cardId: 'first',
      description: 'First run',
      status: KernelAgentTaskStatus.completed,
      result: 'FIRST report',
    ),
    const KernelAgentTask(
      memberId: 'member',
      toolUseId: 'second',
      taskId: 'agent',
      cardId: 'first',
      description: 'Second run',
      status: KernelAgentTaskStatus.completed,
      result: 'SECOND report',
    ),
    const KernelAgentTask(
      memberId: 'other',
      toolUseId: 'third',
      taskId: 'other-agent',
      cardId: 'third',
      description: 'Other run',
      status: KernelAgentTaskStatus.interrupted,
    ),
  ];
  @override
  bool loadingAgentTasks = false;
  @override
  String? agentTasksError;
  @override
  bool loadingHistory = false;
  @override
  bool loadingEarlier = false;
  @override
  bool hasEarlierHistory = true;
  int pages = 0;
  int sends = 0;
  bool throwRead = false;
  bool addCard = false;
  Completer<void>? gate;
  @override
  Future<void> loadEarlier() async {
    pages++;
    if (gate case final pending?) await pending.future;
    if (throwRead) throw StateError('fixture read failed');
    stream.add(
      HistoryPrepended(pages, [
        (
          'old-$pages',
          addCard
              ? const AgentItem(
                  id: 'first',
                  description: 'Shared member history',
                  status: CommandStatus.succeeded,
                  readOnly: true,
                )
              : UserMessageItem(text: 'older page $pages'),
        ),
      ]),
    );
    if (addCard) hasEarlierHistory = false;
    stream.add(KernelInfoChanged(pages + 10));
  }

  @override
  void send(KernelTurn turn) {
    sends++;
  }

  @override
  void dispose() {
    stream.close();
  }

  @override
  Future<void> get stopped => Future.value();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

({ChatSession session, TaskKernel kernel}) fixture() {
  late final KernelDescriptor descriptor;
  late TaskKernel kernel;
  descriptor = KernelDescriptor(
    id: 'fixture',
    label: 'Fixture',
    icon: Icons.chat,
    description: '',
    create: (_) => kernel = TaskKernel(descriptor),
  );
  final session = ChatSession(
    kernel: descriptor,
    kernels: [descriptor],
    kernelContext: const KernelContext(cwd: '/fixture'),
    historyCount: 0,
  );
  addTearDown(session.dispose);
  return (session: session, kernel: kernel);
}

Future<void> board(
  WidgetTester tester,
  ChatSession session,
  AgentSidePanel panel,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: Listenable.merge([session, panel]),
          builder: (_, _) => AgentTasksPage(session: session, panel: panel),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'durable runs appear without transcript, filter by member and remain read-only',
    (tester) async {
      final (:session, :kernel) = fixture();
      final panel = AgentSidePanel();
      panel.showAgentTasks(session, memberId: 'member');
      await board(tester, session, panel);
      expect(session.agentTree, isEmpty);
      expect(find.text('First run'), findsOneWidget);
      expect(find.text('Second run'), findsOneWidget);
      expect(find.text('Other run'), findsNothing);
      await tester.tap(find.text('First run'));
      await tester.pumpAndSettle();
      expect(find.text('FIRST report'), findsOneWidget);
      expect(find.byType(ChatComposer), findsNothing);
      expect(kernel.sends, 0);
      await tester.tap(find.byKey(const ValueKey('agent-tasks-all')));
      await tester.pumpAndSettle();
      expect(find.text('Other run'), findsOneWidget);
    },
  );

  test(
    'detail reads are bounded, coalesced and stop once a real card is found',
    () async {
      final (:session, :kernel) = fixture();
      final task = kernel.agentTasks.first;
      kernel.gate = Completer<void>();
      final first = session.loadAgentTaskHistory(task);
      final second = session.loadAgentTaskHistory(task);
      kernel.gate!.complete();
      await Future.wait([first, second]);
      expect(kernel.pages, 3);
      expect(session.agentTaskPath(task), isNull);
      kernel.gate = null;
      kernel.addCard = true;
      await session.loadAgentTaskHistory(task);
      expect(kernel.pages, 4);
      expect(session.agentTaskPath(task), ['first']);
      expect(session.agentTaskPath(kernel.agentTasks[1]), ['first']);
      expect(kernel.sends, 0);
    },
  );

  testWidgets(
    'missing history keeps the saved report instead of an empty board',
    (tester) async {
      final (:session, :kernel) = fixture();
      kernel.hasEarlierHistory = false;
      await board(tester, session, AgentSidePanel());
      await tester.tap(find.text('Second run'));
      await tester.pumpAndSettle();
      expect(find.text('SECOND report'), findsOneWidget);
      expect(
        find.text(
          'The saved task is retained, but its full execution history is unavailable.',
        ),
        findsOneWidget,
      );
      expect(kernel.pages, 0);
    },
  );

  testWidgets('read error resets button and loading does not become empty', (
    tester,
  ) async {
    final (:session, :kernel) = fixture();
    kernel.throwRead = true;
    await board(tester, session, AgentSidePanel());
    await tester.tap(find.text('First run'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey(('read-task-history', 'first'))),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Could not read task history. You can retry.'),
      findsOneWidget,
    );
    kernel.throwRead = false;
    kernel.addCard = true;
    await tester.tap(
      find.byKey(const ValueKey(('read-task-history', 'first'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('Open shared member history'), findsOneWidget);
    expect(kernel.sends, 0);
  });

  test('leaving a task view stops subsequent history batches', () async {
    final (:session, :kernel) = fixture();
    kernel.gate = Completer<void>();
    var active = true;
    final read = session.loadAgentTaskHistory(
      kernel.agentTasks.first,
      shouldContinue: () => active,
    );
    active = false;
    kernel.gate!.complete();
    await read;
    expect(kernel.pages, 1);
    expect(kernel.sends, 0);
  });

  testWidgets('initial index and transcript loading show progress', (
    tester,
  ) async {
    final (:session, :kernel) = fixture();
    kernel.agentTasks = [];
    kernel.loadingAgentTasks = true;
    await board(tester, session, AgentSidePanel());
    expect(find.text('Reading saved tasks…'), findsOneWidget);
    kernel.loadingAgentTasks = false;
    kernel.loadingHistory = true;
    kernel.stream.add(const KernelInfoChanged(1));
    await tester.pump();
    expect(find.text('Reading saved tasks…'), findsOneWidget);
    expect(find.text('No subagents yet.'), findsNothing);
  });
}
