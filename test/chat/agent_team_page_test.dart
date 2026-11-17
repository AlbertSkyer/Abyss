import 'dart:async';

import 'package:baocode/chat/side_panel/agent_team_page.dart';
import 'package:baocode/ide/ide_button.dart';
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
      status: AgentMemberStatus.stopped,
      enabled: false,
    ),
    KernelAgentMember(
      id: 'running',
      name: 'Busy',
      status: AgentMemberStatus.running,
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
    Future<void> Function(String id)? onDelete,
    ValueChanged<String>? onShowTasks,
  }) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: AgentTeamPage(
          members: members,
          onUpdate: onUpdate ?? (_, {name, role, enabled, archived}) {},
          onDelete: onDelete ?? (_) async {},
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

  testWidgets('toggles availability without changing archive state', (
    tester,
  ) async {
    final calls = <String>[];
    await pump(
      tester,
      onUpdate: (id, {name, role, enabled, archived}) {
        calls.add('$id:$enabled:$archived');
      },
    );
    await tester.tap(find.widgetWithText(GestureDetector, 'Disable').first);
    await tester.tap(find.widgetWithText(GestureDetector, 'Enable'));
    expect(calls, ['one:false:null', 'two:true:null']);
    expect(find.text('Archive'), findsNothing);
    expect(find.text('Restore'), findsNothing);
  });

  testWidgets('delete cancel does not call onDelete', (tester) async {
    var calls = 0;
    await pump(tester, onDelete: (_) async => calls++);
    await tester.tap(find.byKey(const ValueKey(('team-member-delete', 'one'))));
    await tester.pumpAndSettle();
    expect(find.text('Delete Researcher?'), findsOneWidget);
    expect(
      find.textContaining('permanently delete this member'),
      findsOneWidget,
    );
    expect(find.textContaining('main conversation'), findsOneWidget);
    expect(find.textContaining('project files'), findsOneWidget);
    expect(find.textContaining('shared CLI history'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    await tester.tap(find.widgetWithText(GestureDetector, 'Cancel'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('Delete Researcher?'), findsNothing);
  });

  testWidgets('confirmed delete awaits completion and guards duplicates', (
    tester,
  ) async {
    final pending = Completer<void>();
    final deleted = <String>[];
    await pump(
      tester,
      onDelete: (id) {
        deleted.add(id);
        return pending.future;
      },
    );
    final button = find.byKey(const ValueKey(('team-member-delete', 'one')));
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(GestureDetector, 'Delete'));
    await tester.pump();
    expect(deleted, ['one']);
    expect(tester.widget<IdeButton>(button).onPressed, isNull);
    await tester.tap(button, warnIfMissed: false);
    await tester.pump();
    expect(deleted, ['one']);
    expect(
      tester
          .widget<IdeButton>(
            find.byKey(const ValueKey(('team-member-delete', 'two'))),
          )
          .onPressed,
      isNotNull,
    );

    pending.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<IdeButton>(button).onPressed, isNotNull);
  });

  testWidgets('running members cannot delete but archived members can', (
    tester,
  ) async {
    final deleted = <String>[];
    await pump(
      tester,
      members: const [
        KernelAgentMember(
          id: 'running',
          name: 'Busy',
          status: AgentMemberStatus.running,
        ),
        KernelAgentMember(
          id: 'archived',
          name: 'Archived',
          status: AgentMemberStatus.stopped,
          archived: true,
        ),
      ],
      onDelete: (id) async => deleted.add(id),
    );
    expect(
      find.byKey(const ValueKey(('team-member-delete', 'running'))),
      findsNothing,
    );
    final button = find.byKey(
      const ValueKey(('team-member-delete', 'archived')),
    );
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(GestureDetector, 'Delete'));
    await tester.pumpAndSettle();
    expect(deleted, ['archived']);
  });

  testWidgets('failed delete shows error and can be retried', (tester) async {
    var calls = 0;
    await pump(
      tester,
      onDelete: (_) async {
        calls++;
        if (calls == 1) throw StateError('storage is locked');
      },
    );
    final button = find.byKey(const ValueKey(('team-member-delete', 'one')));
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(GestureDetector, 'Delete'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Could not delete the team member: Bad state: storage is locked',
      ),
      findsOneWidget,
    );
    expect(tester.widget<IdeButton>(button).onPressed, isNull);
    await tester.tap(find.widgetWithText(GestureDetector, 'OK'));
    await tester.pumpAndSettle();
    expect(tester.widget<IdeButton>(button).onPressed, isNotNull);

    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(GestureDetector, 'Delete'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.textContaining('Could not delete'), findsNothing);
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
