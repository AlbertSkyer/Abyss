import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/chat/side_panel/agent_tasks_page.dart';
import 'package:baocode/chat/side_panel/side_panel_controller.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;
import '../kernel_ui_test.dart' show assistant, pumpScripted, result;

/// The side panel's task board: a conversation's child agents, read-only,
/// with how each went, whether it is unread, and its group folded or not.
void main() {
  Future<({ChatSession session, FakeCli cli})> scripted(
    WidgetTester tester, {
    bool done = false,
  }) async {
    final (:session, :cli) = await pumpScripted(tester);
    cli
      ..push(
        assistant(null, 'toolu_a', {
          'name': 'Agent',
          'input': {
            'description': 'Compare the games',
            'subagent_type': 'Explore',
            'prompt': 'Compare the three games.',
          },
        }),
      )
      ..push({
        'type': 'system',
        'subtype': 'task_started',
        'task_id': 't1',
        'tool_use_id': 'toolu_a',
        'description': 'Compare the games',
        'task_type': 'local_agent',
        'is_backgrounded': true,
        'model': 'claude-opus-5-5',
        'model_source': 'pool',
      })
      ..push(
        assistant('toolu_a', 'toolu_r', {
          'name': 'Read',
          'input': {'file_path': '/p/game.js'},
        }),
      )
      ..push(result('toolu_a', 'toolu_r', '1\tconst plane = 1;'));
    if (done) {
      cli.push(
        result(null, 'toolu_a', 'The plane game is best.', {
          'status': 'completed',
          'content': [
            {'type': 'text', 'text': 'The plane game is best.'},
          ],
          'totalDurationMs': 74000,
          'totalTokens': 9100,
          'totalToolUseCount': 1,
        }),
      );
    }
    await tester.pump(const Duration(milliseconds: 100));
    return (session: session, cli: cli);
  }

  Future<void> pumpBoard(
    WidgetTester tester,
    ChatSession session,
    AgentSidePanel panel,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 520,
            height: 600,
            // As the side panel's view builds it: anew as the panel
            // changes.
            child: ListenableBuilder(
              listenable: panel,
              builder: (context, _) =>
                  AgentTasksPage(panel: panel, session: session),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows a running child with its model, and stops it', (
    tester,
  ) async {
    final (:session, :cli) = await scripted(tester);
    final panel = AgentSidePanel();
    await pumpBoard(tester, session, panel);

    expect(find.text('Compare the games'), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
    expect(find.textContaining('Opus 5.5'), findsOneWidget);
    expect(find.byKey(const ValueKey('unread-toolu_a')), findsNothing);

    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      cli.requests('stop_task').map((request) => request['task_id']),
      contains('t1'),
    );
  });

  testWidgets('a child that ended is unread until it is opened, and opens '
      'read-only', (tester) async {
    final (:session, cli: _) = await scripted(tester, done: true);
    final panel = AgentSidePanel();
    await pumpBoard(tester, session, panel);

    expect(find.text('Done'), findsOneWidget);
    expect(find.byKey(const ValueKey('unread-toolu_a')), findsOneWidget);

    // The board's row opens the child in the conversation's view.
    await tester.tap(find.text('Compare the games'));
    await tester.pump();
    // The view it was opened from is gone (the board replaced it), so the
    // path is marked read all the same.
    expect(session.agentUnread(session.agentTree.single.agent), isFalse);
  });

  testWidgets('a child opens to its own conversation, which takes no '
      'composer', (tester) async {
    final (:session, cli: _) = await scripted(tester, done: true);
    // From the conversation's view, as the board asks it to.
    session.openAgentPath(const ['toolu_a']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ChatComposer), findsNothing);
    expect(find.text('Conversation'), findsOneWidget);
    expect(session.openAgents, ['toolu_a']);
    expect(find.byKey(const ValueKey('unread-toolu_a')), findsNothing);
  });

  testWidgets('a group folds, and all of them, kept between runs', (
    tester,
  ) async {
    final (:session, cli: _) = await scripted(tester);
    final saved = <Map<String, Object?>>[];
    late final AgentSidePanel panel;
    panel = AgentSidePanel(onSave: () => saved.add(panel.toJson()));
    await pumpBoard(tester, session, panel);

    // Its child steps are under it; folded, it alone shows.
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pump();
    expect(find.byIcon(Icons.keyboard_arrow_right_rounded), findsOneWidget);
    expect(panel.agentGroupFolded('toolu_a'), isTrue);

    // Kept: a panel read from what it saved has them folded.
    final restored = AgentSidePanel(state: saved.last);
    expect(restored.agentGroupFolded('toolu_a'), isTrue);

    // All at once, and back.
    panel.toggleAllAgents();
    expect(panel.agentsAllFolded, isTrue);
    expect(AgentSidePanel(state: panel.toJson()).agentsAllFolded, isTrue);
    panel.toggleAllAgents();
    expect(panel.agentsAllFolded, isFalse);
    expect(AgentSidePanel(state: panel.toJson()).agentsAllFolded, isFalse);
  });

  testWidgets('queued and restored interrupted states are not running', (
    tester,
  ) async {
    final (:session, :cli) = await scripted(tester);
    final panel = AgentSidePanel();
    cli.push({
      'type': 'system',
      'subtype': 'task_started',
      'task_id': 't1',
      'tool_use_id': 'toolu_a',
      'description': 'Compare the games',
      'task_type': 'local_agent',
      'is_backgrounded': true,
      'queue_state': 'queued',
    });
    await tester.pump(const Duration(milliseconds: 100));
    await pumpBoard(tester, session, panel);
    expect(find.text('Queued'), findsOneWidget);
    expect(find.byIcon(Icons.stop_rounded), findsNothing);

    cli.push({
      'type': 'system',
      'subtype': 'task_started',
      'task_id': 't1',
      'tool_use_id': 'toolu_a',
      'description': 'Compare the games',
      'task_type': 'local_agent',
      'status': 'interrupted',
      'read_only': true,
      'is_backgrounded': true,
    });
    cli.push({
      'type': 'system',
      'subtype': 'task_notification',
      'task_id': 't1',
      'tool_use_id': 'toolu_a',
      'status': 'interrupted',
      'summary': 'The previous session closed',
    });
    await tester.pump(const Duration(milliseconds: 100));
    await pumpBoard(tester, session, panel);
    expect(find.text('Queued'), findsNothing);
    expect(find.text('Interrupted'), findsOneWidget);
    expect(find.text('Failed'), findsNothing);
    expect(session.agentTree.single.agent.readOnly, isTrue);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    expect(cli.requests('retry_agent'), isEmpty);

    cli.push({
      'type': 'system',
      'subtype': 'task_started',
      'task_id': 'stale-completed',
      'description': 'Finished before close',
      'task_type': 'local_agent',
      'status': 'completed',
      'read_only': true,
      'is_backgrounded': true,
    });
    await tester.pump(const Duration(milliseconds: 100));
    await pumpBoard(tester, session, panel);
    expect(find.text('Finished before close'), findsOneWidget);
    expect(
      find.text('Done'),
      findsOneWidget,
      reason:
          '${session.agentTree.map((e) => '${e.agent.description}:${e.agent.status}:${e.agent.readOnly}').toList()}',
    );

    cli.push({
      'type': 'system',
      'subtype': 'task_started',
      'task_id': 'stale-failed',
      'description': 'Failed before close',
      'task_type': 'local_agent',
      'status': 'failed',
      'read_only': true,
      'is_backgrounded': true,
    });
    await tester.pump(const Duration(milliseconds: 100));
    await pumpBoard(tester, session, panel);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Interrupted'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    expect(cli.requests('retry_agent'), isEmpty);
  });

  testWidgets('a queued child stays queued while it is live', (tester) async {
    final (:session, :cli) = await scripted(tester);
    final panel = AgentSidePanel();
    cli.push({
      'type': 'system',
      'subtype': 'task_started',
      'task_id': 't1',
      'tool_use_id': 'toolu_a',
      'description': 'Compare the games',
      'task_type': 'local_agent',
      'status': 'queued',
      'queue_state': 'queued',
      'is_backgrounded': true,
    });
    await tester.pump(const Duration(milliseconds: 100));
    await pumpBoard(tester, session, panel);
    expect(find.text('Queued'), findsOneWidget);
    expect(find.text('Interrupted'), findsNothing);
    expect(find.byIcon(Icons.stop_rounded), findsNothing);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
  });

  testWidgets('with no child, it says so', (tester) async {
    final session = ChatSession(historyCount: 0);
    addTearDown(session.dispose);
    final panel = AgentSidePanel();
    await pumpBoard(tester, session, panel);
    expect(find.text('No subagents yet.'), findsOneWidget);
  });
}
