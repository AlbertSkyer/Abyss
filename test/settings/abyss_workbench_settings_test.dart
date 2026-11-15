import 'dart:async';
import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/settings/abyss_workbench_settings.dart';
import 'package:baocode/settings/pages/general_page.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _TaskKernel implements AgentKernel {
  _TaskKernel(this.descriptor);

  @override
  final KernelDescriptor descriptor;
  final _events = StreamController<KernelEvent>.broadcast();
  var _seq = 0;

  void report(AgentItem item) =>
      _events.add(ItemUpserted(++_seq, item.id!, item));

  @override
  Stream<KernelEvent> get events => _events.stream;
  @override
  String? get sessionId => null;
  @override
  KernelHealth get health => KernelHealth.ready;
  @override
  Future<void> get stopped => _events.done;
  @override
  void send(KernelTurn turn) {}
  @override
  void answer(String requestId, InteractionAnswer answer) {}
  @override
  void cancel() {}
  @override
  void restart() {}
  @override
  void prepare() {}
  @override
  void release() {}
  @override
  void dispose() => _events.close();
}

class _SessionCatalog implements SessionCatalog {
  @override
  Future<List<ProjectRecord>> projects() async => const [];
  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];
  @override
  Future<void> delete(String id) async {}
}

Future<(Workspace, _TaskKernel)> _pumpSidebar(
  WidgetTester tester,
  SettingsFiles files,
) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late final _TaskKernel kernel;
  late final KernelDescriptor descriptor;
  descriptor = KernelDescriptor(
    id: 'abyss-sidebar-test',
    label: 'Test',
    icon: Icons.smart_toy_outlined,
    description: '',
    catalog: _SessionCatalog(),
    create: (_) => kernel = _TaskKernel(descriptor),
  );
  final workspace = Workspace(
    kernels: [descriptor],
    projects: const [Project('test', '/tmp/abyss-workbench-test')],
  );
  final thread = workspace.create();
  workspace.select(thread);
  SettingsFiles.instance = files;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            SizedBox(
              width: 280,
              child: Sidebar(workspace: workspace, onCollapse: () {}),
            ),
            const Expanded(child: SizedBox()),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  return (workspace, kernel);
}

void main() {
  late Directory directory;
  late SettingsFiles files;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('abyss-workbench-test');
    files = SettingsFiles(DataDirectory(directory.path));
    await files.load();
    SettingsFiles.instance = files;
  });

  tearDown(() async {
    files.dispose();
    await directory.delete(recursive: true);
  });

  test('sidebar visibility default follows the edition', () {
    expect(AbyssWorkbenchSettings.parse(null), !AppEdition.isAbyss);
    expect(AbyssWorkbenchSettings.parse(true), isTrue);
    expect(AbyssWorkbenchSettings.parse(false), !AppEdition.isAbyss);
  });

  test('automatic dispatch defaults on and only false disables it', () {
    expect(AbyssWorkbenchSettings.autoDispatchKey, 'abyss.agents.autoDispatch');
    expect(AbyssWorkbenchSettings.parseAuto(null), AppEdition.isAbyss);
    expect(AbyssWorkbenchSettings.parseAuto(true), AppEdition.isAbyss);
    expect(AbyssWorkbenchSettings.parseAuto(false), isFalse);
    expect(AbyssWorkbenchSettings.parseAuto('false'), AppEdition.isAbyss);
  });

  test('automatic dispatch reads current settings and has a test seam', () {
    expect(AbyssWorkbenchSettings.automatic(), AppEdition.isAbyss);
    final original = AbyssWorkbenchSettings.automatic;
    addTearDown(() => AbyssWorkbenchSettings.automatic = original);
    AbyssWorkbenchSettings.automatic = () => false;
    expect(AbyssWorkbenchSettings.automatic(), isFalse);
  });

  testWidgets('Abyss automatic dispatch switch writes false and removes on', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GeneralSettingsPage(settings: files.settings)),
      ),
    );
    await tester.pump();
    final label = find.text('Automatically dispatch and select models');
    expect(label, findsOneWidget);
    expect(
      find.textContaining('Permissions for dangerous tools are unchanged.'),
      findsOneWidget,
    );
    await tester.ensureVisible(label);
    await tester.runAsync(() async {
      await tester.tap(label);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(files.settings[AbyssWorkbenchSettings.autoDispatchKey], isFalse);
    expect(AbyssWorkbenchSettings.automatic(), isFalse);

    await tester.ensureVisible(label);
    await tester.runAsync(() async {
      await tester.tap(label);
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (files.settings[AbyssWorkbenchSettings.autoDispatchKey] != null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    expect(files.settings[AbyssWorkbenchSettings.autoDispatchKey], isNull);
    expect(AbyssWorkbenchSettings.automatic(), AppEdition.isAbyss);

    await tester.pumpWidget(const SizedBox());
  }, skip: !AppEdition.isAbyss);

  testWidgets('Abyss persists the switch and only filters task rows', (
    tester,
  ) async {
    expect(AbyssWorkbenchSettings.parse(null), isFalse);
    final (workspace, kernel) = await _pumpSidebar(tester, files);
    final thread = workspace.current!;
    kernel.report(
      const AgentItem(
        id: 'task',
        description: 'Kept task',
        status: CommandStatus.succeeded,
      ),
    );
    await tester.pump();
    expect(thread.session.agentTree, hasLength(1));
    expect(find.text('Subagent tasks'), findsNothing);
    expect(find.text('Kept task'), findsNothing);
    final unread = thread.session.agentUnread(
      thread.session.agentTree.first.agent,
    );
    expect(unread, isTrue);
    workspace.toggleAgentTasksFolded(thread);
    final folded = workspace.agentTasksFolded(thread);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GeneralSettingsPage(settings: files.settings)),
      ),
    );
    await tester.pump();
    final label = find.text('Show subagent tasks in the sidebar');
    expect(label, findsOneWidget);
    await tester.ensureVisible(label);
    await tester.runAsync(() async {
      await tester.tap(label);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(files.settings[AbyssWorkbenchSettings.sidebarAgentTasksKey], isTrue);
    expect(AbyssWorkbenchSettings.shown.value, isTrue);
    expect(workspace.agentTasksFolded(thread), folded);
    expect(thread.session.agentTree, hasLength(1));
    expect(
      thread.session.agentUnread(thread.session.agentTree.first.agent),
      unread,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: Sidebar(workspace: workspace, onCollapse: () {}),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Subagent tasks'), findsOneWidget);
    // The existing folded state is not a side effect of hiding the rows.
    expect(find.text('Kept task'), findsNothing);

    await tester.runAsync(() => AbyssWorkbenchSettings.setShown(false));
    await tester.pump();
    expect(files.settings[AbyssWorkbenchSettings.sidebarAgentTasksKey], isNull);
    expect(find.text('Subagent tasks'), findsNothing);
    expect(thread.session.agentTree, hasLength(1));
    expect(workspace.agentTasksFolded(thread), folded);
    await tester.pumpWidget(const SizedBox());
    workspace.dispose();
  }, skip: !AppEdition.isAbyss);
}
