import 'dart:async';
import 'dart:io';

import 'package:baocode/bots/bot_tools.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/claude_code/mock_claude_code_transport.dart';
import 'package:baocode/workspace/session_tools.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final launches = <ClaudeLaunch>[];
  late KernelDescriptor kernel;
  kernel = KernelDescriptor(
    id: 'claude-code',
    label: 'Claude Code',
    icon: Icons.auto_awesome_rounded,
    description: '',
    create: (context) => ClaudeCodeKernel(
      kernel,
      context,
      start: (launch) async {
        launches.add(launch);
        return _OwnSession(
          await MockClaudeCodeTransport.start(launch),
          launch.resume ?? 'session-${launches.length}',
        );
      },
    ),
  );
  late Workspace workspace;
  late String app;
  var on = true;

  setUp(() {
    launches.clear();
    on = true;
    SessionToolsSetting.current = () => on;
    app = Directory.systemTemp.createTempSync('session-tools').path;
    workspace = Workspace(kernels: [kernel], projects: [Project('app', app)]);
    SessionTools.register(workspace);
  });

  tearDown(() {
    SessionTools.unregister();
    SessionToolsSetting.current = () => false;
    workspace.dispose();
    Directory(app).deleteSync(recursive: true);
  });

  Future<List<String>> offered(String cwd) async {
    final answer = await ClaudeSdkTools.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/list',
    }, ClaudeSdkCall(cwd: cwd));
    return [
      for (final tool
          in ((answer['result'] as Map)['tools'] as List).cast<Map>())
        tool['name'] as String,
    ];
  }

  Future<String> call(
    String tool,
    Map<String, Object?> arguments, {
    String? from,
    String? cwd,
    Future<void>? cancelled,
  }) async {
    final answer = await ClaudeSdkTools.handle({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/call',
      'params': {'name': tool, 'arguments': arguments},
    }, ClaudeSdkCall(cwd: cwd ?? app, sessionId: from, cancelled: cancelled));
    final result = answer['result'] as Map;
    return ((result['content'] as List).single as Map)['text'] as String;
  }

  /// [thread] started (its session known) and its turn stopped: the
  /// mock's own runs long.
  Future<void> settle(AgentThread thread) async {
    for (var i = 0; i < 500 && thread.session.sessionId == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    thread.session.stop();
    for (var i = 0; i < 500 && thread.session.isStreaming; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test(
    'only with the setting on, and not to the app\'s own agents (#934)',
    () async {
      expect(await offered(app), containsAll(SessionTools.names));
      workspace.appFolderRoot = p.join(app, 'bots');
      expect(
        await offered(p.join(app, 'bots', 'mia')),
        isNot(contains('session_list')),
      );
      on = false;
      expect(await offered(app), isNot(contains('session_list')));
    },
  );

  test(
    'new sessions run in the caller project without focus or draft reuse',
    () async {
      final caller = workspace.create(project: workspace.projectAt(app));
      caller.session.send(const ComposerMessage(text: 'coordinate'));
      await settle(caller);
      final scratch = await workspace.createEmptyScratch(caller);
      scratch.session.draft.save(
        'Keep this draft',
        const TextSelection.collapsed(offset: 15),
        const [],
      );
      final before = workspace.threads.toSet();
      final current = workspace.current;
      final answer = await call('session_new', {
        'text': 'Analyze independently',
      }, from: caller.id);
      expect(answer, startsWith('Started: '));
      final created = workspace.threads.singleWhere(
        (thread) => !before.contains(thread),
      );
      final id = BotTools.idOf(created);
      expect(answer, contains(id));
      expect(created.project.path, app);
      expect(workspace.current, same(current));
      expect(workspace.isScratch(created), isFalse);
      expect(created.session.kernelContext.chatOnly, isFalse);
      expect(scratch.session.draft.content, 'Keep this draft');
      await settle(created);
      final read = await call('session_read', {'session': id}, from: caller.id);
      expect(read, contains('Analyze independently'));
      expect(
        read,
        contains('This first task comes from another agent conversation'),
      );
      expect(
        await call('session_send', {
          'session': id,
          'text': 'Continue this task',
        }, from: caller.id),
        startsWith('Sent:'),
      );
      await settle(created);
      expect(
        await call('session_wait', {'session': id}, from: caller.id),
        startsWith('It is idle now.'),
      );
    },
  );

  test('session_new validates inputs and gate before any creation', () async {
    final before = workspace.threads.length;
    for (final args in <Map<String, Object?>>[
      {},
      {'text': ''},
      {'text': 42},
      {'text': 'Task', 'project': 7},
      {'text': 'Task', 'project': 'not-a-project'},
    ]) {
      expect(await call('session_new', args), contains('Invalid argument'));
      expect(workspace.threads, hasLength(before));
    }
    on = false;
    expect(await call('session_new', {'text': 'Task'}), 'No tool session_new.');
    expect(workspace.threads, hasLength(before));
  });

  test('session_new deduplicates concurrent calls and permits replacement after deletion', () async {
    final before = workspace.threads.length;
    final answers = await Future.wait([
      call('session_new', {'text': 'Identical task'}),
      call('session_new', {'text': 'Identical task'}),
    ]);
    expect(workspace.threads, hasLength(before + 1));
    final created = workspace.threads.last;
    final id = BotTools.idOf(created);
    expect(answers.every((answer) => answer.contains(id)), isTrue);
    expect(
      await call('session_new', {'text': 'Identical task'}),
      startsWith('Already started:'),
    );
    await settle(created);
    workspace.delete(created);
    expect(
      await call('session_new', {'text': 'Identical task'}),
      startsWith('Started:'),
    );
    final replacement = workspace.threads.last;
    expect(BotTools.idOf(replacement), isNot(id));
    await settle(replacement);
  });

  test(
    'session_new resolves the caller project instead of the selected project',
    () async {
      final projectB = Project('other', p.join(app, 'other'));
      workspace.dispose();
      workspace = Workspace(
        kernels: [kernel],
        projects: [Project('app', app), projectB],
      );
      SessionTools.register(workspace);
      final caller = workspace.create(project: workspace.projectAt(app));
      caller.session.send(const ComposerMessage(text: 'coordinate'));
      await settle(caller);
      final focused = workspace.create(project: projectB);
      final answer = await call('session_new', {
        'text': 'Default project task',
      }, from: caller.id);
      expect(answer, contains(app));
      final created = workspace.threads.last;
      expect(created.project.path, app);
      expect(workspace.current, same(focused));
      await settle(created);
      final explicit = await call('session_new', {
        'text': 'Other project task',
        'project': 'other',
      }, from: caller.id);
      expect(explicit, contains(projectB.path));
      expect(workspace.threads.last.project, projectB);
      await settle(workspace.threads.last);
    },
  );

  test('session_new refuses ambiguous projects and cancelled calls without side effects', () async {
    workspace.dispose();
    workspace = Workspace(
      kernels: [kernel],
      projects: [Project('same', app), Project('same', p.join(app, 'another'))],
    );
    SessionTools.register(workspace);
    final before = workspace.threads.length;
    expect(
      await call('session_new', {'text': 'Task', 'project': 'same'}),
      contains('ambiguous'),
    );
    expect(workspace.threads, hasLength(before));
    final cancellation = Completer<void>()..complete();
    expect(
      await call('session_new', {
        'text': 'Cancelled task',
      }, cancelled: cancellation.future),
      contains('Cancelled'),
    );
    expect(workspace.threads, hasLength(before));
    workspace.appFolderRoot = p.join(app, 'bots');
    expect(
      await call('session_new', {
        'text': 'Blocked',
      }, cwd: p.join(app, 'bots', 'one')),
      'No tool session_new.',
    );
    expect(workspace.threads, hasLength(before));
  });

  test('new coordination tool unregisters and forceNew leaves old reuse behavior intact', () async {
    final project = workspace.projectAt(app);
    final empty = workspace.startAgent(project);
    expect(workspace.startAgent(project), same(empty));
    final fresh = workspace.startAgent(project, forceNew: true);
    expect(fresh, isNot(same(empty)));
    expect(workspace.startAgent(project), same(empty));
    SessionTools.unregister();
    expect(await offered(app), isNot(contains('session_new')));
    expect(
      await call('session_new', {'text': 'No tool'}),
      'No tool session_new.',
    );
  });

  test('an agent lists and reads the others, not itself; hands one work '
      'once, said so', () async {
    final lead = workspace.startAgent(workspace.projectAt(app));
    lead.session.send(const ComposerMessage(text: 'coordinate'));
    await settle(lead);
    final tests = workspace.startAgent(workspace.projectAt(app));
    workspace.rename(tests, 'Tests');
    tests.session.send(const ComposerMessage(text: 'run the tests'));
    await settle(tests);
    final leadId = lead.id!;
    final testsId = BotTools.idOf(tests);

    final listed = await call('session_list', {}, from: leadId);
    expect(listed, contains('$testsId | app | Tests | idle'));
    expect(listed, isNot(contains(BotTools.idOf(lead))));

    final started = launches.length;
    final read = await call('session_read', {'session': testsId}, from: leadId);
    expect(read, startsWith('"Tests" in app'));
    expect(read, contains('User: run the tests'));
    // Read, not woken.
    expect(launches, hasLength(started));

    expect(
      await call('session_send', {
        'session': testsId,
        'text': 'and lint',
      }, from: leadId),
      'Sent: it is on it.',
    );
    await settle(tests);
    final sent = [
      for (var i = 0; i < tests.session.itemCount; i++)
        if (tests.session.itemAt(i) case UserMessageItem(:final text)) text,
    ];
    expect(sent, contains('and lint'));
    expect(
      await call('session_send', {
        'session': testsId,
        'text': 'and lint',
      }, from: leadId),
      startsWith('Not delivered: the same message'),
    );
    expect(
      await call('session_send', {
        'session': BotTools.idOf(lead),
        'text': 'x',
      }, from: leadId),
      endsWith('That is this conversation.'),
    );

    expect(
      await call('session_wait', {
        'session': testsId,
        'seconds': 10,
      }, from: leadId),
      startsWith('It is idle now.'),
    );

    // At work: queued behind its turn, not cutting it short.
    tests.session.send(const ComposerMessage(text: 'and the docs'));
    for (var i = 0; i < 500 && !tests.session.isStreaming; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      await call('session_send', {
        'session': testsId,
        'text': 'then the changelog',
      }, from: leadId),
      startsWith('Queued'),
    );
    expect(tests.session.isStreaming, isTrue);
    expect(
      [for (final (_, message) in tests.session.queued) message.text],
      ['then the changelog'],
    );
    tests.session.stop();
  });
}

/// The mock's, each launch under a session id of its own.
class _OwnSession implements ClaudeCodeTransport {
  _OwnSession(this._inner, this._id);

  final ClaudeCodeTransport _inner;
  final String _id;

  @override
  Stream<Map<String, Object?>> get messages => _inner.messages.map(
    (message) => message.containsKey('session_id')
        ? {...message, 'session_id': _id}
        : message,
  );

  @override
  void write(Map<String, Object?> message) => _inner.write(message);

  @override
  void close() => _inner.close();

  @override
  Future<void> get exited => _inner.exited;
}
