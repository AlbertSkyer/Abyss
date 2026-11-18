import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/main.dart';
import 'package:baocode/ide/ide_button.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/workspace/dock_host.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/mock_claude_code_transport.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _history = 'test/fixtures/claude_code/history.jsonl';

class _Catalog implements SessionCatalog {
  static final source = SessionRecord(
    id: 'eafc328b-0000-4000-8000-000000000001',
    title: 'Source conversation',
    updatedAt: DateTime(2026, 9, 27, 16),
    cwd: '/tmp/project',
    path: _history,
  );

  static final forks = <SessionRecord>[];
  static final deleted = <String>[];

  @override
  Future<List<ProjectRecord>> projects() async => [
    ProjectRecord(path: '/tmp/project', sessions: [source, ...forks]),
  ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];

  @override
  Future<void> delete(String id) async => deleted.add(id);
}

final _launches = <({ClaudeLaunch launch, List<Map<String, Object?>> sent})>[];

final KernelDescriptor _claude = KernelDescriptor(
  id: 'claude-code',
  label: 'Claude Code',
  icon: Icons.auto_awesome_rounded,
  description: '',
  catalog: _Catalog(),
  create: (context) => ClaudeCodeKernel(
    _claude,
    context,
    start: (launch) async {
      final cli = await MockClaudeCodeTransport.start(launch);
      final sent = <Map<String, Object?>>[];
      _launches.add((launch: launch, sent: sent));
      return _Recording(cli, launch.resume, sent);
    },
    readHistory: (session) async => [
      for (final line in File(session.path!).readAsLinesSync())
        if (line.isNotEmpty) (jsonDecode(line) as Map).cast<String, Object?>(),
    ],
    forkSession: (cwd, id, into, {before, title}) async {
      _Catalog.forks.add(
        SessionRecord(
          id: into,
          title: title ?? '',
          updatedAt: DateTime(2026, 9, 28),
          cwd: cwd,
          path: _history,
        ),
      );
      return _history;
    },
  ),
);

class _Recording implements ClaudeCodeTransport {
  _Recording(this._cli, this._resumed, this.sent);

  final ClaudeCodeTransport _cli;
  final String? _resumed;
  final List<Map<String, Object?>> sent;

  @override
  Stream<Map<String, Object?>> get messages => _cli.messages.map(
    (message) => switch (_resumed) {
      final id? when message.containsKey('session_id') => {
        ...message,
        'session_id': id,
      },
      _ => message,
    },
  );

  @override
  void write(Map<String, Object?> message) {
    sent.add(message);
    _cli.write(message);
  }

  @override
  void close() => _cli.close();

  @override
  Future<void> get exited => _cli.exited;
}

Future<Workspace> _load({PreferenceStore? preferences}) async {
  final workspace = Workspace(kernels: [_claude], preferences: preferences);
  await workspace.load();
  await Future<void>.delayed(Duration.zero);
  return workspace;
}

AgentThread _thread(Workspace workspace, String id) =>
    workspace.threads.singleWhere((thread) => thread.id == id);

Future<AgentThread> _source(Workspace workspace) async {
  final source = _thread(workspace, _Catalog.source.id);
  workspace.select(source);
  for (var i = 0; i < 20 && source.session.forkEndsAt == null; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(source.session.forkEndsAt, isNotNull);
  return source;
}

void main() {
  testWidgets('scratch chooser creates inherited or blank chats after New', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late Workspace workspace;
    await tester.runAsync(() async {
      workspace = await _load();
      await _source(workspace);
    });
    await tester.pumpWidget(BaoCodeApp(workspace: workspace));
    await tester.pumpAndSettle();
    tester.widget<DockHost>(find.byType(DockHost)).controller.open('scratch');
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(
        find.widgetWithText(IdeButton, 'Inherit current conversation'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    final first = workspace.scratchChats.single;
    expect(first.id, isNotNull);
    await tester.tap(find.widgetWithText(IdeButton, 'New temporary chat'));
    await tester.pumpAndSettle();
    expect(find.text('Inherit current conversation'), findsOneWidget);
    expect(find.text('Start empty chat'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(
        find.widgetWithText(IdeButton, 'Inherit current conversation'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(workspace.scratchChats, hasLength(2));
    expect(workspace.scratchChats.last.id, isNot(first.id));
    await tester.tap(find.widgetWithText(IdeButton, 'New temporary chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(IdeButton, 'Start empty chat'));
    await tester.pumpAndSettle();
    expect(workspace.scratchChats, hasLength(3));
    expect(workspace.scratchChats.last.id, isNull);
    expect(workspace.scratchChats.last.session.itemCount, 0);
    await tester.pumpWidget(const SizedBox());
  }, skip: !AppEdition.isAbyss);

  tearDown(() {
    _Catalog.forks.clear();
    _Catalog.deleted.clear();
    _launches.clear();
  });

  test(
    'openScratchChat forks once without sending and keeps its origin',
    () async {
      final workspace = await _load();
      final source = await _source(workspace);
      final boundary = source.session.forkEndsAt;
      final count = _Catalog.forks.length;
      final users = _launches
          .expand((launch) => launch.sent)
          .where((message) => message['type'] == 'user')
          .length;

      final scratch = await workspace.openScratchChat(source);
      expect(scratch, isNotNull);
      expect(workspace.isScratch(scratch!), isTrue);
      expect(workspace.scratchOrigin(scratch), same(source));
      expect(workspace.scratchFor(source), same(scratch));
      expect(workspace.openScratchChat(source), completion(same(scratch)));
      expect(workspace.current, isNot(same(scratch)));
      expect(_Catalog.forks.length, count + 1);
      expect(
        _launches
            .expand((launch) => launch.sent)
            .where((message) => message['type'] == 'user')
            .length,
        users,
      );
      expect(workspace.parentOf(scratch), isNull);

      // The boundary belongs to scratch metadata, not /btw's inline cards.
      // scratch metadata, not to /btw's inline parent cards.
      expect(workspace.asidesAt(source), isEmpty);
      expect(boundary, isNotNull);
      workspace.dispose();
    },
  );

  test(
    'scratch metadata restores chatOnly by record id before opening',
    () async {
      final store = MemoryPreferenceStore();
      var workspace = await _load(preferences: store);
      final source = await _source(workspace);
      final scratch = (await workspace.openScratchChat(source))!;
      final id = scratch.id!;
      await Future<void>.delayed(Duration.zero);
      workspace.dispose();

      workspace = await _load(preferences: store);
      final restoredSource = _thread(workspace, source.id!);
      final restored = _thread(workspace, id);
      expect(restored.isOpen, isFalse);
      expect(workspace.isScratch(restored), isTrue);
      expect(workspace.scratchOrigin(restored), same(restoredSource));
      expect(workspace.scratchFor(restoredSource), same(restored));
      expect(workspace.isScratch(restoredSource), isFalse);
      restored.session.attach();
      for (var i = 0; i < 30 && _launches.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(_launches.last.launch.tools, isEmpty);
      expect(_launches.last.launch.sdkServers, isEmpty);
      expect(_launches.last.launch.userServers, isFalse);
      workspace.dispose();
    },
  );

  test('empty source cannot fork; empty scratch sends with no tools', () async {
    final workspace = await _load();
    final source = workspace.create();
    expect(source.id, isNull);
    expect(await workspace.openScratchChat(source), isNull);
    expect(_Catalog.forks, isEmpty);

    final scratch = await workspace.createEmptyScratch(source);
    expect(workspace.isScratch(scratch), isTrue);
    expect(workspace.scratchOrigin(scratch), same(source));
    expect(scratch.session.itemCount, 0);
    scratch.session.send(const ComposerMessage(text: 'Chat without tools'));
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (scratch.id == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(scratch.id, isNotNull);
    expect(_launches.last.launch.tools, isEmpty);
    expect(_launches.last.launch.sdkServers, isEmpty);
    expect(_launches.last.launch.userServers, isFalse);
    workspace.dispose();
  });

  test(
    'forceNew forks another history scratch and preserves every old scratch',
    () async {
      final workspace = await _load();
      final source = await _source(workspace);
      final first = (await workspace.openScratchChat(source))!;
      final second = (await workspace.openScratchChat(source, forceNew: true))!;
      final third = (await workspace.openScratchChat(source, forceNew: true))!;

      expect(second.id, isNot(first.id));
      expect(third.id, isNot(anyOf(first.id, second.id)));
      for (var i = 0; i < 30 && third.session.loadingHistory; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(third.session.itemCount, greaterThan(0));
      expect(workspace.scratchChats, containsAll([first, second, third]));
      expect(workspace.isScratch(first), isTrue);
      expect(workspace.isScratch(second), isTrue);
      expect(workspace.scratchOrigin(first), same(source));
      expect(workspace.scratchOrigin(second), same(source));
      expect(workspace.scratchOrigin(third), same(source));
      expect(workspace.scratchBoundary(first), isNotNull);
      expect(workspace.scratchBoundary(second), isNotNull);
      expect(_Catalog.deleted, isEmpty);
      workspace.dispose();
    },
  );

  test(
    'forced empty scratch is distinct, blank, and keeps old origin links',
    () async {
      final workspace = await _load();
      final source = workspace.create();
      final first = await workspace.createEmptyScratch(source);
      first.session.draft.save(
        'First draft',
        const TextSelection.collapsed(offset: 11),
        const [],
      );
      expect(
        await workspace.createEmptyScratch(source, forceNew: true),
        isNot(same(first)),
      );
      expect(await workspace.createEmptyScratch(source), same(first));
      final second = await workspace.createEmptyScratch(source, forceNew: true);

      expect(second, isNot(same(first)));
      expect(second.session.itemCount, 0);
      expect(second.session.draft.content, isNot('First draft'));
      expect(first.session.draft.content, 'First draft');
      expect(workspace.scratchChats, containsAll([first, second]));
      expect(workspace.scratchOrigin(first), same(source));
      expect(workspace.scratchOrigin(second), same(source));
      expect(_Catalog.deleted, isEmpty);
      workspace.dispose();
    },
  );

  test('deleting a saved scratch removes only its own metadata', () async {
    final workspace = await _load();
    final source = await _source(workspace);
    final first = (await workspace.openScratchChat(source))!;
    final other = (await workspace.openScratchChat(source, forceNew: true))!;
    final otherId = other.id!;

    workspace.delete(first);
    await Future<void>.delayed(Duration.zero);

    expect(workspace.threads, containsAll([source, other]));
    expect(workspace.isScratch(first), isFalse);
    expect(workspace.isScratch(other), isTrue);
    expect(workspace.scratchOrigin(other), same(source));
    expect(_Catalog.deleted, [first.id]);
    expect(_Catalog.deleted, isNot(contains(otherId)));
    expect(_Catalog.deleted, isNot(contains(source.id)));
    workspace.dispose();
  });

  test(
    'deleting a null-ID scratch leaves source and sibling scratch intact',
    () async {
      final workspace = await _load();
      final source = workspace.create();
      final first = await workspace.createEmptyScratch(source);
      final second = await workspace.createEmptyScratch(source, forceNew: true);

      workspace.delete(first);

      expect(first.id, isNull);
      expect(workspace.threads, containsAll([source, second]));
      expect(workspace.threads, isNot(contains(first)));
      expect(workspace.isScratch(second), isTrue);
      expect(workspace.scratchOrigin(second), same(source));
      expect(_Catalog.deleted, isEmpty);
      workspace.dispose();
    },
  );

  test('deleting origin main removes only its scratch links', () async {
    final workspace = await _load();
    final source = await _source(workspace);
    final scratch = (await workspace.openScratchChat(source))!;

    workspace.delete(source);
    await Future<void>.delayed(Duration.zero);

    expect(workspace.threads, contains(scratch));
    expect(workspace.isScratch(scratch), isTrue);
    expect(workspace.scratchOrigin(scratch), isNull);
    expect(_Catalog.deleted, [source.id]);
    workspace.dispose();
  });

  test('two unsent scratch drafts keep separate stable storage keys', () async {
    final store = MemoryPreferenceStore();
    final workspace = await _load(preferences: store);
    final source = workspace.create();
    final first = await workspace.createEmptyScratch(source);
    final second = await workspace.createEmptyScratch(source, forceNew: true);
    first.session.draft.save(
      'First only',
      const TextSelection.collapsed(offset: 10),
      const [],
    );
    second.session.draft.save(
      'Second only',
      const TextSelection.collapsed(offset: 11),
      const [],
    );
    first.session.draft.save(
      'First updated',
      const TextSelection.collapsed(offset: 13),
      const [],
    );
    expect(first.session.draft.content, 'First updated');
    expect(second.session.draft.content, 'Second only');
    workspace.delete(first);
    expect(workspace.isScratch(first), isFalse);
    expect(workspace.scratchFor(source), same(second));
    expect(second.session.draft.content, 'Second only');
    await Future<void>.delayed(Duration.zero);
    workspace.dispose();
  });

  test('new scratch retains old history and creates a replacement', () async {
    final workspace = await _load();
    final source = await _source(workspace);
    final first = (await workspace.openScratchChat(source))!;
    final replacement = await workspace.resetScratchChat(first);
    expect(replacement, isNotNull);
    expect(replacement!.id, isNot(first.id));
    expect(workspace.scratchOrigin(replacement), same(source));
    expect(workspace.scratchOrigin(first), same(source));
    expect(workspace.threads, containsAll([source, first]));
    expect(_Catalog.deleted, isEmpty);
    workspace.dispose();
  });

  test('resetScratchChat can explicitly choose a new empty scratch', () async {
    final workspace = await _load();
    final source = await _source(workspace);
    final first = (await workspace.openScratchChat(source))!;

    final replacement = await workspace.resetScratchChat(first, empty: true);

    expect(replacement, isNotNull);
    expect(replacement!.id, isNull);
    expect(replacement.session.itemCount, 0);
    expect(replacement.session.kernelContext.chatOnly, isTrue);
    expect(workspace.scratchOrigin(replacement), same(source));
    expect(workspace.scratchOrigin(first), same(source));
    expect(_Catalog.deleted, isEmpty);
    workspace.dispose();
  });
}
