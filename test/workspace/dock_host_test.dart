import 'package:baocode/workspace/dock_host.dart';
import 'package:baocode/workspace/dock_layout.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kMiddleMouseButton, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(
  DockController controller,
  DockPanelBuilder builder, {
  double minPanelExtent = 120,
  DockPanelBuilder? titleBuilder,
  DockEmptyBuilder? emptyBuilder,
  ValueChanged<String>? onActivatePanel,
  ValueChanged<String>? onDragPanel,
  DockPanelDragEnd? onPanelDragEnd,
  void Function(String panelId, Offset position)? onPanelMenu,
  ValueChanged<String>? onKeepPanel,
  bool Function(String panelId)? isPreviewPanel,
  ValueChanged<String>? onClosePanel,
  DockMovePanel? onMovePanel,
  bool showCloseButtons = true,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 800,
      height: 600,
      child: DockHost(
        controller: controller,
        panelBuilder: builder,
        titleBuilder: titleBuilder,
        emptyBuilder: emptyBuilder,
        onActivatePanel: onActivatePanel,
        onDragPanel: onDragPanel,
        onPanelDragEnd: onPanelDragEnd,
        onPanelMenu: onPanelMenu,
        onKeepPanel: onKeepPanel,
        isPreviewPanel: isPreviewPanel,
        onClosePanel: onClosePanel,
        onMovePanel: onMovePanel,
        minPanelExtent: minPanelExtent,
        showCloseButtons: showCloseButtons,
      ),
    ),
  ),
);

void main() {
  testWidgets('renders only one business widget per open panel', (
    tester,
  ) async {
    final controller = DockController();
    addTearDown(controller.dispose);
    final builds = <String, int>{};
    await tester.pumpWidget(
      _host(controller, (context, id) {
        builds[id] = (builds[id] ?? 0) + 1;
        return Text('body:$id');
      }),
    );
    await tester.pump();
    expect(find.text('body:main-chat'), findsOneWidget);
    expect(find.text('body:files'), findsOneWidget);
    expect(controller.openPanelIds.length, 2);
    expect(builds.keys.toSet(), {'main-chat', 'files'});
  });

  testWidgets('reveal, close, maximize and restore update the host', (
    tester,
  ) async {
    final controller = DockController()
      ..open('terminal')
      ..open('changes');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(controller, (context, id) => Text('body:$id')),
    );
    await tester.tap(find.text('files'));
    await tester.pump();
    expect(controller.maximizedPanelId, isNull);
    expect(_activePanel(controller, 'terminal'), 'files');
    expect(_activePanel(controller, 'files'), 'files');

    await tester.tap(find.byIcon(Icons.open_in_full).last);
    await tester.pump();
    expect(controller.maximizedPanelId, 'files');
    expect(find.text('body:main-chat'), findsNothing);
    expect(find.text('body:files'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_fullscreen));
    await tester.pump();
    expect(controller.maximizedPanelId, isNull);
    expect(find.text('body:main-chat'), findsOneWidget);

    final terminalClose = find.descendant(
      of: find.byKey(const ValueKey('dock-tab-terminal')),
      matching: find.byIcon(Icons.close),
    );
    await tester.ensureVisible(terminalClose);
    await tester.pumpAndSettle();
    await tester.tap(terminalClose);
    await tester.pump();
    expect(controller.openPanelIds.contains('terminal'), isFalse);
    expect(find.text('body:terminal'), findsNothing);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('main-chat').last,
          matching: find.byType(DockTab),
        ),
        matching: find.byIcon(Icons.close),
      ),
      findsNothing,
    );
  });

  testWidgets('moving preserves one GlobalKey state and no duplicate mount', (
    tester,
  ) async {
    final controller = DockController();
    addTearDown(controller.dispose);
    final panelKey = GlobalKey();
    final exceptions = <FlutterErrorDetails>[];
    final oldOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      exceptions.add(details);
      oldOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = oldOnError);
    await tester.pumpWidget(
      _host(
        controller,
        (context, id) =>
            StatefulCounter(key: id == 'files' ? panelKey : null, panelId: id),
      ),
    );
    await tester.pump();
    final initial = tester.widget<StatefulCounter>(find.byKey(panelKey));
    expect(initial.panelId, 'files');

    controller.move('files', target: 'main-chat');
    await tester.pump();
    expect(find.byKey(panelKey), findsOneWidget);
    expect(controller.openPanelIds.length, 2);
    expect(exceptions, isEmpty);
    expect(tester.state<StatefulCounterState>(find.byKey(panelKey)).mounts, 1);
  });

  testWidgets('sash enforces the minimum physical panel extent', (
    tester,
  ) async {
    final controller = DockController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(controller, (context, id) => Text('body:$id'), minPanelExtent: 200),
    );
    final sash = find
        .byType(GestureDetector)
        .evaluate()
        .firstWhere(
          (element) =>
              (element.widget as GestureDetector).onHorizontalDragUpdate !=
              null,
        );
    await tester.drag(
      find.byElementPredicate((element) => element == sash),
      const Offset(-2000, 0),
    );
    await tester.pump();
    final currentSash = find.byElementPredicate((element) => element == sash);
    // Body is 782 wide: a 200px minimum gives 200 / 782.
    expect(controller.splitAtPath('')!.ratio, closeTo(200 / 782, 0.001));
    await tester.drag(currentSash, const Offset(2000, 0));
    await tester.pump();
    expect(controller.splitAtPath('')!.ratio, closeTo(582 / 782, 0.001));
  });

  testWidgets('real tab drag moves across groups without duplicate keys', (
    tester,
  ) async {
    final controller = DockController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(controller, (context, id) => Text('body:$id')),
    );
    final filesTab = find.byKey(const ValueKey('dock-tab-files'));
    final mainTab = find.byKey(const ValueKey('dock-tab-main-chat'));
    await tester.timedDrag(
      filesTab,
      tester.getCenter(mainTab) +
          const Offset(18, 0) -
          tester.getCenter(filesTab),
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();
    expect(controller.openPanelIds.toList()..sort(), ['files', 'main-chat']);
    expect(find.text('body:files'), findsOneWidget);
    expect(find.byKey(const ValueKey('dock-tab-main-chat')), findsOneWidget);
    expect(_activePanel(controller, 'files'), 'files');
    controller.reveal('main-chat');
    await tester.pump();
    expect(find.text('body:main-chat'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dynamic panel IDs share activation, preview and owner actions', (
    tester,
  ) async {
    final controller = DockController(
      availablePanelIds: const ['chat:alpha', 'chat:beta', 'tool:terminal'],
      root: DockTabs(
        groupId: 'mixed',
        orderedPanelIds: const ['chat:alpha', 'chat:beta', 'tool:terminal'],
        active: 'chat:alpha',
      ),
    );
    addTearDown(controller.dispose);
    final activations = <String>[];
    final kept = <String>[];
    final closed = <String>[];
    final menus = <(String, Offset)>[];
    await tester.pumpWidget(
      _host(
        controller,
        (context, id) => Text('body:$id'),
        titleBuilder: (context, id) => Text('title:$id'),
        isPreviewPanel: (id) => id == 'chat:beta',
        onActivatePanel: activations.add,
        onKeepPanel: kept.add,
        onClosePanel: closed.add,
        onPanelMenu: (id, position) => menus.add((id, position)),
      ),
    );

    expect(find.byKey(const ValueKey('dock-tab-chat:beta')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('dock-tab-tool:terminal')),
      findsOneWidget,
    );
    final previewTab = tester.widget<DockTab>(
      find.byKey(const ValueKey('dock-tab-chat:beta')),
    );
    expect(previewTab.preview, isTrue);

    await tester.tap(find.text('title:chat:beta'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(activations, ['chat:beta']);
    expect(_activePanel(controller, 'chat:beta'), 'chat:alpha');

    await tester.tap(find.text('title:chat:beta'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('title:chat:beta'));
    await tester.pump();
    expect(kept, ['chat:beta']);

    await tester.tap(
      find.text('title:chat:beta'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    expect(menus, hasLength(1));
    expect(menus.single.$1, 'chat:beta');
    expect(menus.single.$2, tester.getCenter(find.text('title:chat:beta')));

    await tester.tap(find.text('title:chat:beta'), buttons: kMiddleMouseButton);
    await tester.pump();
    expect(closed, ['chat:beta']);
    expect(controller.openPanelIds, contains('chat:beta'));
    expect(find.text('body:chat:beta', skipOffstage: false), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('close button is delegated without forcing controller close', (
    tester,
  ) async {
    final controller = DockController();
    addTearDown(controller.dispose);
    String? closed;
    await tester.pumpWidget(
      _host(
        controller,
        (context, id) => Text('body:$id'),
        onClosePanel: (id) => closed = id,
      ),
    );
    final close = find.descendant(
      of: find.byKey(const ValueKey('dock-tab-files')),
      matching: find.byIcon(Icons.close),
    );
    await tester.ensureVisible(close);
    await tester.pumpAndSettle();
    await tester.tap(close);
    await tester.pump();
    expect(closed, 'files');
    expect(controller.openPanelIds, contains('files'));
    expect(find.text('body:files'), findsOneWidget);
  });

  testWidgets('drag uses the real title and notifies drag owner', (
    tester,
  ) async {
    final controller = DockController();
    addTearDown(controller.dispose);
    String? dragged;
    await tester.pumpWidget(
      _host(
        controller,
        (context, id) => Text('body:$id'),
        titleBuilder: (context, id) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder),
            Flexible(
              child: Text('business:$id', overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        onDragPanel: (id) => dragged = id,
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('dock-tab-files'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(dragged, 'files');
    final feedback = find.byKey(const ValueKey('dock-drag-feedback-files'));
    expect(feedback, findsOneWidget);
    expect(
      find.descendant(of: feedback, matching: find.text('business:files')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: feedback, matching: find.byIcon(Icons.folder)),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag release inside the dock reports insideDock', (
    tester,
  ) async {
    final controller = DockController();
    addTearDown(controller.dispose);
    final releases = <(String, Offset, bool)>[];
    await tester.pumpWidget(
      _host(
        controller,
        (context, id) => Text('body:$id'),
        onPanelDragEnd: (id, {required globalPosition, required insideDock}) =>
            releases.add((id, globalPosition, insideDock)),
      ),
    );
    final dock = tester.getRect(find.byType(DockHost));
    final destination = Offset(dock.center.dx, dock.bottom - 80);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('dock-tab-files'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveTo(destination);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(releases, hasLength(1));
    expect(releases.single.$1, 'files');
    expect(releases.single.$2, destination);
    expect(releases.single.$3, isTrue);
    expect(controller.openPanelIds.length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag release outside the dock reports outside', (tester) async {
    final controller = DockController();
    addTearDown(controller.dispose);
    final releases = <(String, Offset, bool)>[];
    await tester.pumpWidget(
      _host(
        controller,
        (context, id) => Text('body:$id'),
        onPanelDragEnd: (id, {required globalPosition, required insideDock}) =>
            releases.add((id, globalPosition, insideDock)),
      ),
    );
    final dock = tester.getRect(find.byType(DockHost));
    final destination = Offset(dock.right + 60, dock.center.dy);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('dock-tab-files'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveTo(destination);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(releases, hasLength(1));
    expect(releases.single.$1, 'files');
    expect(releases.single.$2, destination);
    expect(releases.single.$3, isFalse);
    expect(controller.openPanelIds.toList()..sort(), ['files', 'main-chat']);
    expect(find.text('body:files'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local drops use controller move and root edges are dispatched', (
    tester,
  ) async {
    final controller = DockController();
    addTearDown(controller.dispose);
    final moves = <(String, String?, DockSide?, bool)>[];
    await tester.pumpWidget(
      _host(
        controller,
        (context, id) => Text('body:$id'),
        onMovePanel: (id, target, side, root) =>
            moves.add((id, target, side, root)),
      ),
    );

    final files = find.byKey(const ValueKey('dock-tab-files'));
    final main = find.byKey(const ValueKey('dock-tab-main-chat'));
    await tester.timedDrag(
      files,
      Offset(tester.getCenter(main).dx + 18, tester.getRect(main).bottom - 4) -
          tester.getCenter(files),
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();
    expect(moves.single, ('files', 'main-chat', null, false));
    expect(controller.openPanelIds.length, 2);
    expect(_activePanel(controller, 'files'), 'files');
    moves.clear();

    for (final side in DockSide.values) {
      final destination = _rootEdge(tester, side);
      final origin = tester.getCenter(files);
      final gesture = await tester.startGesture(
        origin,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(origin + const Offset(20, 20));
      await tester.pump();
      await gesture.moveTo(destination);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('dock-root-preview')),
        findsOneWidget,
        reason: 'root $side preview',
      );
      expect(find.byKey(const ValueKey('dock-local-preview')), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(moves, hasLength(1), reason: 'root $side drop');
      expect(moves.single.$1, 'files');
      expect(moves.single.$2, 'main-chat-group');
      expect(moves.single.$3, side);
      expect(moves.single.$4, isTrue);
      moves.clear();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty dock shows builder and accepts a root drop', (
    tester,
  ) async {
    final controller = EmptyDockController();
    addTearDown(controller.dispose);
    final moves = <(String, String?, DockSide?, bool)>[];
    await tester.pumpWidget(
      _host(
        controller,
        (context, id) => Text('body:$id'),
        emptyBuilder: (context) => const Text('dock is empty'),
        onMovePanel: (id, target, side, root) =>
            moves.add((id, target, side, root)),
      ),
    );
    expect(find.text('dock is empty'), findsOneWidget);
    expect(find.byType(DockTab), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: 20,
              top: 20,
              child: DockTab(
                key: const ValueKey('empty-source'),
                panelId: 'chat:empty',
                groupId: 'source',
                onTap: () {},
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: SizedBox(
                width: 500,
                height: 400,
                child: DockHost(
                  controller: controller,
                  panelBuilder: (context, id) => Text('body:$id'),
                  emptyBuilder: (context) => const Text('dock is empty'),
                  onMovePanel: (id, target, side, root) =>
                      moves.add((id, target, side, root)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final target = tester.getCenter(
      find.byKey(const ValueKey('dock-empty-drop-target')),
    );
    await tester.timedDrag(
      find.byKey(const ValueKey('empty-source')),
      target - tester.getCenter(find.byKey(const ValueKey('empty-source'))),
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();
    expect(moves.single, ('chat:empty', null, null, true));
    expect(tester.takeException(), isNull);
  });
}

Offset _rootEdge(WidgetTester tester, DockSide side) {
  final root = tester.getRect(find.byType(DockHost));
  return switch (side) {
    DockSide.left => Offset(root.left + 10, root.center.dy),
    DockSide.right => Offset(root.right - 10, root.center.dy),
    DockSide.top => Offset(root.center.dx, root.top + 10),
    DockSide.bottom => Offset(root.center.dx, root.bottom - 10),
  };
}

class EmptyDockController extends DockController {
  EmptyDockController() : super(availablePanelIds: const []);

  @override
  DockNode get root =>
      DockTabs(groupId: 'empty', orderedPanelIds: const [], active: '');
}

String _activePanel(DockController controller, String panelId) {
  String active(DockNode node) {
    switch (node) {
      case DockTabs():
        if (node.orderedPanelIds.contains(panelId)) return node.active;
        return '';
      case DockSplit():
        final first = active(node.first);
        return first.isEmpty ? active(node.second) : first;
    }
  }

  return active(controller.root);
}

class StatefulCounter extends StatefulWidget {
  const StatefulCounter({super.key, required this.panelId});
  final String panelId;

  @override
  State<StatefulCounter> createState() => StatefulCounterState();
}

class StatefulCounterState extends State<StatefulCounter> {
  var mounts = 0;

  @override
  void initState() {
    super.initState();
    mounts++;
  }

  @override
  Widget build(BuildContext context) => Text('${widget.panelId}:$mounts');
}
