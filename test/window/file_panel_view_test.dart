import 'package:baocode/chat/side_panel/file_link.dart';
import 'package:baocode/chat/side_panel/file_open.dart';
import 'package:baocode/chat/side_panel/file_preview.dart';
import 'package:baocode/chat/side_panel/side_panel_view.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/main.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/window/app_windows.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workspace/chat_dock_workspace_test.dart' show kernel;
import 'fake_window_host.dart';

void main() {
  testWidgets(
    'file views keep the owner and independent tabs, then dock back',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final workspace = Workspace(kernels: [kernel]);
      await workspace.load();
      final a = workspace.threads.firstWhere((thread) => thread.id == 'a');
      final b = workspace.threads.firstWhere((thread) => thread.id == 'b');
      workspace.select(a);
      final host = FakeWindowHost(tester.view);
      final windows = AppWindows(
        host: host,
        workspace: workspace,
        l10n: () => englishLocalizations,
        nextFrame: () => tester.binding.endOfFrame,
      );
      addTearDown(windows.dispose);
      await windows.start();
      await tester.pumpWidget(
        BaoCodeApp(workspace: workspace, windows: windows),
        wrapWithView: false,
      );
      await tester.pump();

      Future<AppWindow> open(
        String id,
        int line, {
        bool readOnly = false,
      }) async {
        final pending = windows.openFilePanel(
          a.id!,
          projectPath: a.project.path,
          id: id,
          tabs: [
            FileOpenRequest('/dock/preview.md', range: FileLineRange(line)),
          ],
          activeFile: '/dock/preview.md',
          readOnly: readOnly,
        );
        for (var i = 0; i < 5; i++) {
          await tester.pump();
        }
        return (await pending)!;
      }

      Finder inWindow(AppWindow window, Finder matching) => find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is View && w.view.viewId == window.viewId,
        ),
        matching: matching,
      );

      final first = await open('file:first', 1);
      final second = await open('file:second', 8, readOnly: true);
      final firstView = inWindow(first, find.byType(AgentSidePanelView));
      final secondView = inWindow(second, find.byType(AgentSidePanelView));
      final firstPanel = tester.widget<AgentSidePanelView>(firstView).panel;
      final secondPanel = tester.widget<AgentSidePanelView>(secondView).panel;
      expect(firstPanel, isNot(same(secondPanel)));
      expect(firstPanel.tabsOf(a.session).active!.request.range!.start, 1);
      expect(secondPanel.tabsOf(a.session).active!.request.range!.start, 8);
      expect(
        tester
            .widget<FilePreview>(inWindow(second, find.byType(FilePreview)))
            .request
            .readOnly,
        isTrue,
      );

      workspace.select(b);
      await tester.pump();
      expect(
        tester.widget<AgentSidePanelView>(firstView).session,
        same(a.session),
      );
      expect(
        tester.widget<AgentSidePanelView>(secondView).session,
        same(a.session),
      );
      secondPanel.close(a.session, secondPanel.tabsOf(a.session).active!);
      await tester.pump();
      expect(firstPanel.tabsOf(a.session).files, hasLength(1));
      expect(second.panel!.tabs, isEmpty);

      final docking = windows.dockFilePanel(first.panel!.id);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(await docking, same(windows.chat));
      expect(workspace.current, same(b));
      expect(workspace.chatDock.controller.openPanelIds, contains('files'));
      expect(windows.panelWindows, [second]);
      final docked = tester.widget<AgentSidePanelView>(
        inWindow(windows.chat, find.byType(AgentSidePanelView)),
      );
      expect(docked.session, same(a.session));
      expect(docked.panel.tabsOf(a.session).active!.path, '/dock/preview.md');
    },
    skip: !AppEdition.isAbyss,
    semanticsEnabled: false,
  );
}
