import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/claude_code/agent_task_ledger.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String path;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('agent-task-ledger-test-');
    path = p.join(temp.path, 'state', 'agent-task-ledger.json');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  var reloads = 0;
  Future<AgentTaskLedger> reload() async {
    final ledger = await AgentTaskLedger.open(path: path);
    await ledger.flush();
    final copy = await File(path)
        .copy(p.join(temp.path, 'reload-${reloads++}.json'));
    return AgentTaskLedger.open(path: copy.path);
  }

  test('a cancelled start survives reload and a late failure', () async {
    final ledger = await AgentTaskLedger.open(path: path);
    final cancelled = ledger.cancelStart('main', 'tool-1')!;
    expect(cancelled.memberId, 'pending:tool-1');
    expect(cancelled.taskId, 'task:tool-1');
    expect(cancelled.status, AgentTaskStatus.cancelled);
    expect(cancelled.hostCancelled, isTrue);
    await ledger.flush();

    final restored = await reload();
    final late = restored.recordEnd(
      'main',
      'tool-1',
      status: AgentTaskStatus.failed,
      result: 'late error',
    );
    expect(late!.status, AgentTaskStatus.cancelled);
    expect(late.hostCancelled, isTrue);
    expect(late.result, isNot('late error'));

    restored.recordMember(
      sessionId: 'main',
      memberId: 'member-1',
      cliAgentId: 'cli-1',
      description: 'Inspector',
    );
    final started = restored.recordStart(
      sessionId: 'main',
      toolUseId: 'tool-1',
      memberId: 'member-1',
      taskId: 'task-1',
      description: 'Inspector',
    );
    expect(started!.memberId, 'member-1');
    expect(started.status, AgentTaskStatus.cancelled);
    final completed = restored.recordEnd(
      'main',
      'tool-1',
      status: AgentTaskStatus.completed,
      result: 'late completion',
    );
    expect(completed!.memberId, 'member-1');
    expect(completed.status, AgentTaskStatus.cancelled);
    await restored.flush();
    final raw = jsonDecode(await File(restored.path).readAsString()) as Map;
    final saved = (raw['tasks'] as List).single as Map;
    expect(saved['memberId'], 'member-1');
    expect(saved['status'], 'cancelled');
    expect(saved['hostCancelled'], isTrue);
    expect(saved['result'], isNot('late completion'));
  });

  test(
    'delete removes member runs and reports durably without resurrection',
    () async {
      final ledger = await AgentTaskLedger.open(path: path);
      for (final session in ['main', 'other']) {
        ledger.recordMember(
          sessionId: session,
          memberId: 'm',
          cliAgentId: 'cli-m',
          archived: true,
        );
        for (final call in ['first', 'second']) {
          ledger.recordStart(
            sessionId: session,
            memberId: 'm',
            toolUseId: call,
            taskId: 'task:$call',
          );
          ledger.recordEnd(
            session,
            call,
            status: AgentTaskStatus.completed,
            result: 'private report',
          );
        }
      }
      await ledger.deleteMember('main', 'm');
      expect(ledger.membersFor('main'), isEmpty);
      expect(ledger.tasksFor('main'), isEmpty);
      expect(ledger.tasksFor('other'), hasLength(2));
      expect(ledger.deletedTaskIdsFor('main'), {'first', 'second'});
      final reopened = await reload();
      expect(reopened.isMemberDeleted('main', 'm'), isTrue);
      expect(reopened.isCliAgentDeleted('main', 'cli-m'), isTrue);
      expect(
        reopened.recordMember(
          sessionId: 'main',
          memberId: 'new-id',
          cliAgentId: 'cli-m',
        ),
        isNull,
      );
      expect(
        reopened.recordStart(
          sessionId: 'main',
          memberId: 'm',
          toolUseId: 'late',
          taskId: 'late',
        ),
        isNull,
      );
      expect(reopened.cancelStart('main', 'first'), isNull);
      expect(
        reopened.recordEnd('main', 'first', status: AgentTaskStatus.completed),
        isNull,
      );
      expect(reopened.reconcileInterrupted('main'), isEmpty);
      await reopened.deleteMember('main', 'm');
      expect(reopened.membersFor('main'), isEmpty);
      expect(reopened.tasksFor('main'), isEmpty);
      final raw = jsonDecode(await File(reopened.path).readAsString()) as Map;
      expect(
        raw['deletedMembers'].toString(),
        isNot(contains('private report')),
      );
    },
  );

  test(
    'delete refuses running and unknown members and surfaces write failures',
    () async {
      final ledger = await AgentTaskLedger.open(path: path);
      ledger.recordMember(
        sessionId: 'main',
        memberId: 'm',
        cliAgentId: 'cli-m',
      );
      ledger.recordStart(
        sessionId: 'main',
        memberId: 'm',
        toolUseId: 'call',
        taskId: 'task',
      );
      await expectLater(ledger.deleteMember('main', 'm'), throwsStateError);
      expect(ledger.membersFor('main'), hasLength(1));
      await expectLater(ledger.deleteMember('other', 'm'), throwsStateError);
      ledger.recordEnd('main', 'call', status: AgentTaskStatus.completed);
      await ledger.flush();
      await File(path).delete();
      await Directory(path).create();
      await expectLater(
        ledger.deleteMember('main', 'm'),
        throwsA(isA<FileSystemException>()),
      );
      expect(ledger.isMemberDeleted('main', 'm'), isTrue);
      await Directory(path).delete();
      await ledger.deleteMember('main', 'm');
      expect((await reload()).membersFor('main'), isEmpty);
    },
  );

  test('host stop is cancelled but keeps its distinct decision', () async {
    final ledger = await AgentTaskLedger.open(path: path);
    ledger.recordStart(
      sessionId: 'main',
      toolUseId: 'tool-1',
      memberId: 'member-1',
      taskId: 'task-1',
    );
    final stopped = ledger.stopTask('main', 'tool-1')!;
    expect(stopped.status, AgentTaskStatus.cancelled);
    expect(stopped.hostCancelled, isFalse);
    expect(stopped.hostStopped, isTrue);
    await ledger.flush();
    expect((await reload()).findTask('main', 'tool-1')!.hostStopped, isTrue);
  });

  test(
    'sessions and tool ids are independent; empty sessions are refused',
    () async {
      final ledger = await AgentTaskLedger.open(path: path);
      for (final session in ['one', 'two']) {
        ledger.recordStart(
          sessionId: session,
          toolUseId: 'same-tool',
          memberId: 'member-$session',
          taskId: 'task-$session',
        );
      }
      ledger.cancelStart('one', 'same-tool');
      await ledger.flush();

      final restored = await reload();
      expect(
        restored.findTask('one', 'same-tool')!.status,
        AgentTaskStatus.cancelled,
      );
      expect(
        restored.findTask('two', 'same-tool')!.status,
        AgentTaskStatus.running,
      );
      expect(restored.findTask('missing', 'same-tool'), isNull);
      expect(
        () => restored.recordStart(
          sessionId: '',
          toolUseId: 'tool-2',
          memberId: 'member-1',
          taskId: 'task-2',
        ),
        throwsArgumentError,
      );
      await restored.flush();
      expect(restored.findTask('', 'tool-2'), isNull);
      final raw = jsonDecode(await File(path).readAsString()) as Map;
      expect(raw['tasks'], hasLength(2));
      expect(
        (raw['tasks'] as List).every(
          (task) => task['sessionId'] == 'one' || task['sessionId'] == 'two',
        ),
        isTrue,
      );
    },
  );

  test('one member can associate with multiple tasks and runs', () async {
    final ledger = await AgentTaskLedger.open(path: path);
    ledger.recordMember(
      sessionId: 'main',
      memberId: 'member-1',
      cliAgentId: 'cli-agent-1',
      model: 'model-name',
      description: 'Research',
    );
    for (var index = 0; index < 2; index++) {
      ledger.recordStart(
        sessionId: 'main',
        toolUseId: 'tool-$index',
        memberId: 'member-1',
        taskId: 'task-$index',
        runId: 'run-$index',
      );
    }
    await ledger.flush();

    final restored = await reload();
    expect(restored.tasksFor('main'), hasLength(2));
    expect(restored.tasksFor('main').map((task) => task.memberId).toSet(), {
      'member-1',
    });
    expect(restored.tasksFor('main').map((task) => task.runId).toSet(), {
      'run-0',
      'run-1',
    });
    expect(restored.membersFor('main').single.cliAgentId, 'cli-agent-1');
    final duplicate = restored.recordStart(
      sessionId: 'main',
      toolUseId: 'tool-0',
      memberId: 'member-1',
      taskId: 'task-0',
    );
    expect(duplicate!.runId, 'run-0');
    expect(duplicate.model, 'model-name');
    expect(duplicate.description, 'Research');
    expect(restored.tasksFor('other'), isEmpty);
    expect(() => restored.tasksFor('main').clear(), throwsUnsupportedError);
    expect(() => restored.membersFor('main').clear(), throwsUnsupportedError);
  });

  test(
    'only running tasks in the selected session become interrupted',
    () async {
      final ledger = await AgentTaskLedger.open(path: path);
      ledger.recordStart(
        sessionId: 'main',
        toolUseId: 'running',
        memberId: 'member-1',
        taskId: 'task-1',
      );
      ledger.recordStart(
        sessionId: 'main',
        toolUseId: 'done',
        memberId: 'member-1',
        taskId: 'task-2',
      );
      ledger.recordEnd('main', 'done', status: AgentTaskStatus.completed);
      ledger.recordStart(
        sessionId: 'other',
        toolUseId: 'running',
        memberId: 'member-2',
        taskId: 'task-3',
      );
      final interrupted = ledger.reconcileInterrupted('main');
      expect(interrupted.single.toolUseId, 'running');
      expect(interrupted.single.status, AgentTaskStatus.interrupted);
      expect(
        ledger.findTask('main', 'done')!.status,
        AgentTaskStatus.completed,
      );
      expect(
        ledger.findTask('other', 'running')!.status,
        AgentTaskStatus.running,
      );
      final lateStart = ledger.recordStart(
        sessionId: 'main',
        toolUseId: 'running',
        memberId: 'member-1',
        taskId: 'task-1',
      );
      expect(lateStart!.status, AgentTaskStatus.interrupted);
      await ledger.flush();
      expect(
        (await reload()).findTask('main', 'running')!.status,
        AgentTaskStatus.interrupted,
      );
    },
  );

  test('member updates never claim another cancelled tool call', () async {
    final ledger = await AgentTaskLedger.open(path: path);
    ledger.cancelStart('main', 'tool-a');
    ledger.cancelStart('main', 'tool-b');
    ledger.recordMember(
      sessionId: 'main',
      memberId: 'member-a',
      cliAgentId: 'cli-a',
      description: 'A',
    );
    expect(ledger.findTask('main', 'tool-a')!.memberId, 'pending:tool-a');
    expect(ledger.findTask('main', 'tool-b')!.memberId, 'pending:tool-b');

    final associated = ledger.recordStart(
      sessionId: 'main',
      toolUseId: 'tool-a',
      memberId: 'member-a',
      taskId: 'task-a',
      description: 'A',
    );
    expect(associated!.memberId, 'member-a');
    expect(associated.taskId, 'task-a');
    expect(associated.status, AgentTaskStatus.cancelled);
    expect(ledger.findTask('main', 'tool-b')!.memberId, 'pending:tool-b');
    expect(ledger.findTask('main', 'tool-b')!.taskId, 'task:tool-b');
    await ledger.flush();
  });

  test(
    'bad data fails conservatively and is not made into a success',
    () async {
      final file = File(path)..createSync(recursive: true);
      const original = '{"version":1,"tasks":[';
      file.writeAsStringSync(original);
      await expectLater(
        AgentTaskLedger.open(path: path),
        throwsFormatException,
      );
      expect(file.readAsStringSync(), original);

      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'members': const [],
          'tasks': [
            {
              'sessionId': 'main',
              'memberId': 'member-1',
              'taskId': 'task-1',
              'toolUseId': 'tool-1',
              'status': 'completed',
              'hostCancelled': false,
              'hostStopped': false,
              'futureField': 'retained',
            },
          ],
          'futureTopLevel': {'kept': true},
        }),
      );
      final ledger = await AgentTaskLedger.open(path: path);
      final task = ledger.findTask('main', 'tool-1')!;
      expect(task.status, AgentTaskStatus.completed);
      ledger.stopTask('main', 'tool-1', result: 'Stopped while inspecting');
      await ledger.flush();
      final saved = jsonDecode(file.readAsStringSync()) as Map;
      expect(saved['futureTopLevel'], {'kept': true});
      expect((saved['tasks'] as List).single['futureField'], 'retained');
      expect((saved['tasks'] as List).single['hostStopped'], isTrue);
    },
  );

  test('flush reports a write failure and a later write can recover', () async {
    final blocker = File(p.join(temp.path, 'blocked'));
    blocker.writeAsStringSync('A file prevents creating its child directory.');
    final blockedPath = p.join(blocker.path, 'ledger.json');
    final blocked = await AgentTaskLedger.open(path: blockedPath);
    blocked.cancelStart('main', 'tool-1');
    await expectLater(blocked.flush(), throwsA(isA<FileSystemException>()));
    expect(
      blocked.findTask('main', 'tool-1')!.status,
      AgentTaskStatus.cancelled,
    );

    blocker.deleteSync();
    Directory(blocker.path).createSync();
    blocked.cancelStart('main', 'tool-2');
    await blocked.flush();
    final raw = jsonDecode(await File(blockedPath).readAsString()) as Map;
    expect(raw['tasks'], hasLength(2));
  });

  test(
    'same-path opens share serial state and the default is in state',
    () async {
      final previous = DataDirectory.current;
      DataDirectory.current = DataDirectory(temp.path);
      addTearDown(() => DataDirectory.current = previous);
      final both = await Future.wait([
        AgentTaskLedger.open(),
        AgentTaskLedger.open(),
      ]);
      expect(identical(both[0], both[1]), isTrue);
      expect(
        both[0].path,
        p.canonicalize(p.join(temp.path, 'state', 'agent-task-ledger.json')),
      );
      final queued = <Future<void>>[];
      for (var index = 0; index < 12; index++) {
        both[index % 2].recordStart(
          sessionId: 'main',
          toolUseId: 'tool-$index',
          memberId: 'member-$index',
          taskId: 'task-$index',
        );
        queued.add(both[0].flush());
      }
      await Future.wait(queued);
      final saved = jsonDecode(await File(path).readAsString()) as Map;
      expect(saved['tasks'], hasLength(12));
    },
  );
}
