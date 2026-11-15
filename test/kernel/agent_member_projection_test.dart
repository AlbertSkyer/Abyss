import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/claude_code/agent_task_ledger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;
  late String path;
  late AgentTaskLedger ledger;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('agent-member-state');
    path = p.join(directory.path, 'ledger.json');
    ledger = await AgentTaskLedger.open(path: path);
  });

  tearDown(() async {
    await ledger.flush();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'legacy members default to enabled and editable fields survive reload',
    () async {
      final legacyPath = p.join(directory.path, 'legacy.json');
      File(legacyPath).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'members': [
            {
              'sessionId': 'main',
              'memberId': 'member-1',
              'cliAgentId': 'cli-1',
              'model': 'bound-model',
              'description': 'original',
              'futureField': 'preserved',
            },
          ],
          'tasks': <Object?>[],
        }),
      );
      ledger = await AgentTaskLedger.open(path: legacyPath);

      final member = ledger.membersFor('main').single;
      expect(member.enabled, isTrue);
      expect(member.archived, isFalse);
      expect(member.name, isNull);
      expect(member.role, isNull);

      final updated = ledger.updateMember(
        'main',
        'member-1',
        name: 'Researcher',
        role: 'reader',
        enabled: false,
        archived: true,
      );
      expect(updated.cliAgentId, 'cli-1');
      expect(updated.model, 'bound-model');
      expect(updated.description, 'original');
      await ledger.flush();

      final copy = await File(ledger.path)
          .copy(p.join(directory.path, 'copy.json'));
      final restored = await AgentTaskLedger.open(path: copy.path);
      final saved = restored.member('main', 'member-1')!;
      expect(saved.name, 'Researcher');
      expect(saved.role, 'reader');
      expect(saved.enabled, isFalse);
      expect(saved.archived, isTrue);
      expect(saved.cliAgentId, 'cli-1');
      expect(saved.model, 'bound-model');
      expect(restored.membersFor('other'), isEmpty);
      expect(
        () => restored.updateMember('main', 'missing', name: 'Nobody'),
        throwsStateError,
      );
    },
  );

  test('late metadata preserves disabled state and bound model', () async {
    ledger.recordMember(
      sessionId: 'main',
      memberId: 'member-1',
      cliAgentId: 'cli-1',
      model: 'bound-model',
    );
    ledger.updateMember('main', 'member-1', enabled: false);
    final late = ledger.recordMember(
      sessionId: 'main',
      memberId: 'member-1',
      name: 'Late name',
      role: 'reviewer',
      description: 'Late metadata',
    );
    expect(late.enabled, isFalse);
    expect(late.model, 'bound-model');
    expect(late.cliAgentId, 'cli-1');
    expect(
      ledger.projectMember('main', 'member-1').state,
      AgentMemberState.disabled,
    );
  });

  test('projects tasks without treating completed as online', () async {
    ledger.recordMember(
      sessionId: 'main',
      memberId: 'member-1',
      cliAgentId: 'cli-1',
    );
    ledger.recordStart(
      sessionId: 'main',
      toolUseId: 'tool-1',
      memberId: 'member-1',
      taskId: 'task-1',
    );
    expect(
      ledger.projectMember('main', 'member-1').state,
      AgentMemberState.running,
    );
    ledger.recordEnd('main', 'tool-1', status: AgentTaskStatus.completed);
    final standby = ledger.projectMember('main', 'member-1');
    expect(standby.state, AgentMemberState.standby);
    expect(standby.contextRecoverable, isTrue);

    ledger.updateMember('main', 'member-1', enabled: false);
    expect(
      ledger.projectMember('main', 'member-1').state,
      AgentMemberState.disabled,
    );
    ledger.recordStart(
      sessionId: 'main',
      toolUseId: 'tool-2',
      memberId: 'member-1',
      taskId: 'task-2',
    );
    // An already observed running task wins; projection never starts a new one.
    expect(
      ledger.projectMember('main', 'member-1').state,
      AgentMemberState.running,
    );
  });

  test(
    'stopped and unverified are distinct from recoverable standby',
    () async {
      for (final id in ['stopped', 'failed', 'unknown', 'recoverable']) {
        ledger.recordMember(
          sessionId: 'main',
          memberId: id,
          cliAgentId: id == 'unknown' ? null : 'cli-$id',
        );
      }
      ledger.recordStart(
        sessionId: 'main',
        toolUseId: 'tool-stopped',
        memberId: 'stopped',
        taskId: 'task-stopped',
      );
      ledger.stopTask('main', 'tool-stopped');
      ledger.recordStart(
        sessionId: 'main',
        toolUseId: 'tool-failed',
        memberId: 'failed',
        taskId: 'task-failed',
      );
      ledger.recordEnd('main', 'tool-failed', status: AgentTaskStatus.failed);
      ledger.recordStart(
        sessionId: 'main',
        toolUseId: 'tool-recoverable',
        memberId: 'recoverable',
        taskId: 'task-recoverable',
      );
      ledger.reconcileInterrupted('main');

      expect(
        ledger.memberStatesFor('main').map((projection) => projection.state),
        [
          AgentMemberState.stopped,
          AgentMemberState.unverified,
          AgentMemberState.unverified,
          AgentMemberState.unverified,
        ],
      );
      expect(ledger.memberStatesFor('other'), isEmpty);
    },
  );
}
