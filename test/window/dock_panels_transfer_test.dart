import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/ide/ide_hover.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/main.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:baocode/window/app_windows.dart';
import 'package:baocode/workspace/dock_host.dart';
import 'package:baocode/workspace/dock_layout.dart';
import 'package:baocode/workspace/terminal_deck.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ide/terminal/fake_pty.dart';
import '../ide/terminal/fake_terminal.dart';
import '../workspace/chat_dock_workspace_test.dart' show kernel;
import 'fake_window_host.dart';

Finder inView(int id, Finder child) => find.descendant(
  of: find.byWidgetPredicate((w) => w is View && w.view.viewId == id),
  matching: child,
);

class PanelHost extends FakeWindowHost {
  PanelHost(super.implicit);
  bool fail = false;

  @override
  Future<FakeView?> waitForView(int viewId) async =>
      fail ? null : views[viewId];
}

void main() {
  testWidgets(
    'every dock tab has a native floating view and docks back',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final workspace = Workspace(kernels: [kernel]);
      await workspace.load();
      final owner = workspace.threads.firstWhere((t) => t.id == 'a');
      final other = workspace.threads.firstWhere((t) => t.id == 'b');
      workspace.select(owner);
      final host = PanelHost(tester.view);
      final windows = AppWindows(
        workspace: workspace,
        host: host,
        l10n: () => englishLocalizations,
        nextFrame: () => tester.binding.endOfFrame,
      );
      addTearDown(windows.dispose);
      await windows.start();
      final ptys = <FakePty>[];
      await tester.pumpWidget(
        BaoCodeApp(
          workspace: workspace,
          windows: windows,
          terminalBackend: fakeTerminalBackend(ptys),
        ),
        wrapWithView: false,
      );
      await tester.pump();
      Future<void> frames() async {
        for (var i = 0; i < 7; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      DockHost dock() => tester.widget(inView(0, find.byType(DockHost)));
      void release(String id, Offset position, {bool inside = false}) =>
          dock().onPanelDragEnd!(
            id,
            globalPosition: position,
            insideDock: inside,
          );
      const outside = Offset(1500, 300);

      for (final id in dockDefaultPanelIds.where(
        (id) => id != dockMainPanelId,
      )) {
        workspace.select(owner);
        dock().controller.open(id);
        await frames();
        if (id == 'files') {
          final lock = find.byKey(const ValueKey('file-panel-lock'));
          expect(tester.widget<IdeActionButton>(lock).icon, Codicons.unlock);
          await tester.tap(lock);
          await tester.pump();
          expect(tester.widget<IdeActionButton>(lock).icon, Codicons.lock);
          expect(find.text('Float Files Panel'), findsNothing);
          release(id, const Offset(50, 10));
          await frames();
          expect(windows.panelWindows, isEmpty);
          host.fail = true;
          release(id, outside);
          await frames();
          expect(dock().controller.openPanelIds, contains(id));
          expect(windows.panelWindows, isEmpty);
          host.fail = false;
        }
        Object? service;
        if (id == 'terminal') {
          final deck = tester.widget<TerminalDeck>(
            inView(0, find.byType(TerminalDeck)),
          );
          service = deck.terminals;
          expect(service, isNotNull);
          deck.terminals!.create();
          await frames();
          expect(ptys, hasLength(1));
        }
        release(id, outside);
        await frames();
        final window = windows.windowForTab(id)!;
        expect(window.panel!.kind.name, id);
        expect(dock().controller.openPanelIds, isNot(contains(id)));
        expect(dock().controller.open(id), isFalse);
        expect(
          inView(window.viewId, find.text('Dock Back to Main Window')),
          findsOneWidget,
        );
        if (id == 'terminal') {
          expect(
            tester
                .widget<TerminalDeck>(
                  inView(window.viewId, find.byType(TerminalDeck)),
                )
                .terminals,
            same(service),
          );
          expect(ptys, hasLength(1));
        }
        workspace.select(other);
        await frames();
        expect(window.panel!.ownerId, owner.id);
        final back = windows.dockPanel(window.panel!.id);
        await frames();
        expect(await back, same(windows.chat));
        expect(windows.windowForTab(id), isNull);
        expect(dock().controller.openPanelIds, contains(id));
        if (id == 'terminal') {
          expect(
            tester
                .widget<TerminalDeck>(inView(0, find.byType(TerminalDeck)))
                .terminals,
            same(service),
          );
          expect(ptys, hasLength(1));
        }
        dock().controller.close(id);
        await frames();
      }

      final draft = workspace.create(project: owner.project);
      await frames();
      final tab = workspace.chatDock.panelId(draft);
      release(tab, outside);
      await frames();
      final floating = windows.windowForTab(tab)!;
      expect(floating.panel!.kind, PanelKind.chat);
      expect(workspace.isChatDetached(draft), isTrue);
      expect(workspace.chatDock.openChats, isNot(contains(draft)));
      final view = inView(floating.viewId, find.byType(ChatScreen));
      expect(tester.widget<ChatScreen>(view).session, same(draft.session));
      workspace.select(draft);
      await frames();
      expect(workspace.chatDock.openChats, isNot(contains(draft)));
      final close = windows.requestClose(floating);
      await frames();
      expect(await close, isTrue);
      expect(workspace.chatDock.openChats, contains(draft));
      expect(windows.panelWindows, isEmpty);
      await tester.pumpWidget(
        const ViewCollection(views: []),
        wrapWithView: false,
      );
    },
    semanticsEnabled: false,
    skip: !AppEdition.isAbyss,
  );
}
