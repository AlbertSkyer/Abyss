import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/chat/chat_session.dart';
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

  test('new scratch retains old history and creates a replacement', () async {
    final workspace = await _load();
    final source = await _source(workspace);
    final first = (await workspace.openScratchChat(source))!;
    final replacement = await workspace.resetScratchChat(first);
    expect(replacement, isNotNull);
    expect(replacement!.id, isNot(first.id));
    expect(workspace.scratchOrigin(replacement), same(source));
    expect(workspace.threads, contains(source));
    expect(_Catalog.deleted, isEmpty);
    expect(_Catalog.deleted, isNot(contains(source.id)));
    workspace.dispose();
  });
}
