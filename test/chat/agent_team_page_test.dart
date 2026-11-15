import 'package:baocode/chat/side_panel/agent_team_page.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const members = [
    KernelAgentMember(
      id: 'one',
      name: 'Researcher',
      role: 'Read code',
      model: '@provider/model',
      status: AgentMemberStatus.standby,
      tasks: 3,
    ),
    KernelAgentMember(
      id: 'two',
      name: 'Worker',
      status: AgentMemberStatus.running,
      enabled: false,
    ),
  ];

  Future<void> pump(
    WidgetTester tester, {
    List<KernelAgentMember> members = members,
    void Function(
      String id, {
      String? name,
      String? role,
      bool? enabled,
      bool? archived,
    })?
    onUpdate,
    ValueChanged<String>? onShowTasks,
  }) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: AgentTeamPage(
          members: members,
          onUpdate: onUpdate ?? (_, {name, role, enabled, archived}) {},
          onShowTasks: onShowTasks ?? (_) {},
          statusLabel: (status) => 'status:${status.name}',
          description: 'Availability does not stop active tasks.',
          emptyLabel: 'No team members',
          editLabel: 'Edit',
          saveLabel: 'Save',
          nameLabel: 'Name',
          roleLabel: 'Responsibility',
          disableLabel: 'Disable',
          enableLabel: 'Enable',
          archiveLabel: 'Archive',
          unarchiveLabel: 'Restore',
          showTasksLabel: 'Tasks',
          tasksLabel: (count) => '$count total',
        ),
      ),
    ),
  );

  testWidgets('shows provided identity, model and pure projected status', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Researcher'), findsOneWidget);
    expect(find.textContaining('Read code · model'), findsOneWidget);
    expect(find.text('status:standby'), findsOneWidget);
    expect(find.text('status:running'), findsOneWidget);
    expect(find.text('Tasks · 3 total'), findsOneWidget);
    expect(
      find.text('Availability does not stop active tasks.'),
      findsOneWidget,
    );
  });

  testWidgets('edits real name and role inputs and cancels without updating', (
    tester,
  ) async {
    String? updatedId;
    String? updatedName;
    String? updatedRole;
    await pump(
      tester,
      onUpdate: (id, {name, role, enabled, archived}) {
        updatedId = id;
        updatedName = name;
        updatedRole = role;
      },
    );
    await tester.tap(find.widgetWithText(GestureDetector, 'Edit').first);
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '  New name  ');
    await tester.enterText(fields.at(1), '  New responsibility  ');
    await tester.tap(find.widgetWithText(GestureDetector, 'Save'));
    await tester.pumpAndSettle();
    expect(updatedId, 'one');
    expect(updatedName, 'New name');
    expect(updatedRole, 'New responsibility');

    await tester.tap(find.widgetWithText(GestureDetector, 'Edit').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(updatedName, 'New name');
  });

  testWidgets('toggles availability and archive, without archiving running', (
    tester,
  ) async {
    final calls = <String>[];
    await pump(
      tester,
      onUpdate: (id, {name, role, enabled, archived}) {
        calls.add('$id:$enabled:$archived');
      },
    );
    await tester.tap(find.widgetWithText(GestureDetector, 'Disable'));
    await tester.tap(find.widgetWithText(GestureDetector, 'Enable'));
    await tester.tap(find.widgetWithText(GestureDetector, 'Archive'));
    expect(calls, ['one:false:null', 'two:true:null', 'one:null:true']);
    expect(find.widgetWithText(GestureDetector, 'Archive'), findsOneWidget);
  });

  testWidgets('opens tasks by stable member id and supplies an empty state', (
    tester,
  ) async {
    String? id;
    await pump(tester, onShowTasks: (value) => id = value);
    await tester.tap(find.byKey(const ValueKey(('team-member-tasks', 'one'))));
    expect(id, 'one');

    await pump(tester, members: const []);
    expect(find.text('No team members'), findsOneWidget);
    expect(find.text('Researcher'), findsNothing);
  });
}
