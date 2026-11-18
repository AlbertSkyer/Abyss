import 'package:baocode/main.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:baocode/workspace/dock_host.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'new temporary chat returns to choices and deletion preserves source',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final workspace = Workspace.mock();
      await tester.pumpWidget(BaoCodeApp(workspace: workspace));
      await tester.pump();
      final source = workspace.current!;
      tester.widget<DockHost>(find.byType(DockHost)).controller.open('scratch');
      await tester.pumpAndSettle();
      expect(find.text('Inherit current conversation'), findsOneWidget);
      expect(find.text('Start empty chat'), findsOneWidget);
      await tester.tap(find.widgetWithText(IdeButton, 'Start empty chat'));
      await tester.pumpAndSettle();
      expect(workspace.scratchChats, hasLength(1));
      final first = workspace.scratchChats.single;
      expect(find.text('New temporary chat'), findsOneWidget);
      await tester.tap(find.widgetWithText(IdeButton, 'New temporary chat'));
      await tester.pumpAndSettle();
      expect(find.text('Inherit current conversation'), findsOneWidget);
      expect(find.text('Start empty chat'), findsOneWidget);
      expect(workspace.scratchChats, hasLength(1));
      await tester.pump();
      expect(find.text('Start empty chat'), findsOneWidget);
      await tester.tap(find.widgetWithText(IdeButton, 'Start empty chat'));
      await tester.pumpAndSettle();
      expect(workspace.scratchChats, hasLength(2));
      final second = workspace.scratchChats.last;
      expect(second, isNot(same(first)));
      await tester.tap(find.widgetWithText(IdeButton, 'New temporary chat'));
      await tester.pumpAndSettle();
      final historyDropdown = find.byType(DropdownButton<AgentThread>);
      final choices = tester.widget<DropdownButton<AgentThread>>(
        historyDropdown,
      );
      expect(
        choices.items!.map((item) => item.value),
        containsAll([first, second]),
      );
      choices.onChanged!(first);
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is ChatScreen && w.session == first.session,
        ),
        findsOneWidget,
      );
      tester
          .widget<DropdownButton<AgentThread>>(
            find.byType(DropdownButton<AgentThread>),
          )
          .onChanged!(second);
      await tester.pumpAndSettle();
      final preview = find.byWidgetPredicate(
        (w) => w is ChatScreen && w.session == second.session,
      );
      expect(preview, findsOneWidget);
      await tester.tap(find.byIcon(Codicons.trash).last);
      await tester.pumpAndSettle();
      expect(find.text('Delete this temporary chat?'), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(workspace.scratchChats, hasLength(2));
      await tester.tap(find.byIcon(Codicons.trash).last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GestureDetector, 'Delete').last);
      await tester.pumpAndSettle();
      expect(workspace.scratchChats, [first]);
      expect(workspace.threads, contains(source));
      expect(find.text('Inherit current conversation'), findsOneWidget);
      expect(find.text('Start empty chat'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is ChatScreen && w.session == second.session,
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
    skip: !AppEdition.isAbyss,
  );
}
