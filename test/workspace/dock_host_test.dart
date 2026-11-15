import 'package:baocode/workspace/dock_host.dart';
import 'package:baocode/workspace/dock_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(
  DockController controller,
  DockPanelBuilder builder, {
  double minPanelExtent = 120,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 800,
      height: 600,
      child: DockHost(
        controller: controller,
        panelBuilder: builder,
        minPanelExtent: minPanelExtent,
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
