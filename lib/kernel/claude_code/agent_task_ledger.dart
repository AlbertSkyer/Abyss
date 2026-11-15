import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';

/// The host's durable record of a CLI task.
enum AgentTaskStatus { running, completed, failed, cancelled, interrupted }

/// A member's local projection, not a network presence indicator.
enum AgentMemberState { running, standby, disabled, stopped, unverified }

/// An immutable member of a host session. [memberId] is stable; the CLI's
/// agent id is kept separately because it may be reused across continuations.
final class AgentMemberRecord {
  const AgentMemberRecord({
    required this.sessionId,
    required this.memberId,
    this.cliAgentId,
    this.model,
    this.description,
    this.name,
    this.role,
    this.enabled = true,
    this.archived = false,
  });

  final String sessionId;
  final String memberId;
  final String? cliAgentId;
  final String? model;
  final String? description;
  final String? name;
  final String? role;
  final bool enabled;
  final bool archived;

  AgentMemberRecord _copyWith({
    String? name,
    String? role,
    bool? enabled,
    bool? archived,
  }) => AgentMemberRecord(
    sessionId: sessionId,
    memberId: memberId,
    cliAgentId: cliAgentId,
    model: model,
    description: description,
    name: name ?? this.name,
    role: role ?? this.role,
    enabled: enabled ?? this.enabled,
    archived: archived ?? this.archived,
  );

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'memberId': memberId,
    if (cliAgentId != null) 'cliAgentId': cliAgentId,
    if (model != null) 'model': model,
    if (description != null) 'description': description,
    if (name != null) 'name': name,
    if (role != null) 'role': role,
    'enabled': enabled,
    'archived': archived,
  };

  factory AgentMemberRecord.fromJson(Map<String, Object?> json) =>
      AgentMemberRecord(
        sessionId: _requiredString(json, 'sessionId'),
        memberId: _requiredString(json, 'memberId'),
        cliAgentId: _optionalString(json, 'cliAgentId'),
        model: _optionalString(json, 'model'),
        description: _optionalString(json, 'description'),
        name: _optionalString(json, 'name'),
        role: _optionalString(json, 'role'),
        enabled: _optionalBool(json, 'enabled') ?? true,
        archived: _optionalBool(json, 'archived') ?? false,
      );
}

/// A member and its state derived from durable records, without side effects.
final class AgentMemberProjection {
  const AgentMemberProjection({required this.member, required this.state});

  final AgentMemberRecord member;
  final AgentMemberState state;

  /// [AgentMemberState.standby] means its CLI context is recoverable, not
  /// that a process or network connection is currently online.
  bool get contextRecoverable => state == AgentMemberState.standby;
}

/// One tool call's task, isolated by both session and tool-use id.
final class AgentTaskRecord {
  const AgentTaskRecord({
    required this.sessionId,
    required this.memberId,
    required this.taskId,
    required this.toolUseId,
    this.runId,
    this.model,
    this.description,
    required this.status,
    this.hostCancelled = false,
    this.hostStopped = false,
    this.result,
  });

  final String sessionId;
  final String memberId;
  final String taskId;
  final String toolUseId;
  final String? runId;
  final String? model;
  final String? description;
  final AgentTaskStatus status;
  final bool hostCancelled;
  final bool hostStopped;
  final String? result;

  AgentTaskRecord _copyWith({
    String? memberId,
    String? taskId,
    String? runId,
    String? model,
    String? description,
    AgentTaskStatus? status,
    bool? hostCancelled,
    bool? hostStopped,
    String? result,
  }) => AgentTaskRecord(
    sessionId: sessionId,
    memberId: memberId ?? this.memberId,
    taskId: taskId ?? this.taskId,
    toolUseId: toolUseId,
    runId: runId ?? this.runId,
    model: model ?? this.model,
    description: description ?? this.description,
    status: status ?? this.status,
    hostCancelled: hostCancelled ?? this.hostCancelled,
    hostStopped: hostStopped ?? this.hostStopped,
    result: result ?? this.result,
  );

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'memberId': memberId,
    'taskId': taskId,
    'toolUseId': toolUseId,
    if (runId != null) 'runId': runId,
    if (model != null) 'model': model,
    if (description != null) 'description': description,
    'status': status.name,
    'hostCancelled': hostCancelled,
    'hostStopped': hostStopped,
    if (result != null) 'result': result,
  };

  factory AgentTaskRecord.fromJson(Map<String, Object?> json) {
    final statusName = _requiredString(json, 'status');
    final status = AgentTaskStatus.values
        .where((value) => value.name == statusName)
        .firstOrNull;
    if (status == null) throw const FormatException('Unknown task status');
    return AgentTaskRecord(
      sessionId: _requiredString(json, 'sessionId'),
      memberId: _requiredString(json, 'memberId'),
      taskId: _requiredString(json, 'taskId'),
      toolUseId: _requiredString(json, 'toolUseId'),
      runId: _optionalString(json, 'runId'),
      model: _optionalString(json, 'model'),
      description: _optionalString(json, 'description'),
      status: status,
      hostCancelled: _requiredBool(json, 'hostCancelled'),
      hostStopped: _requiredBool(json, 'hostStopped'),
      result: _optionalString(json, 'result'),
    );
  }
}

/// A small, host-owned ledger. No method schedules or restarts a task.
///
/// Mutations update the in-memory snapshot synchronously and enqueue their
/// whole-file write. [flush] waits for all writes queued so far and reports
/// their errors; a failed write does not poison later writes.
final class AgentTaskLedger {
  AgentTaskLedger._(this.path, this._tasks, this._members, this._unknownFields);

  static final Map<String, AgentTaskLedger> _instances = {};
  static final Map<String, Future<AgentTaskLedger>> _openings = {};

  final String path;
  final Map<String, AgentTaskRecord> _tasks;
  final Map<String, AgentMemberRecord> _members;
  final Map<String, Object?> _unknownFields;
  final Map<String, Map<String, Object?>> _taskExtras = {};
  final Map<String, Map<String, Object?>> _memberExtras = {};
  Future<void> _writes = Future<void>.value();
  Future<void>? _latestWrite;
  Object? _writeError;
  StackTrace? _writeStack;

  /// Opens [path], or the ledger in [DataDirectory.current]'s state folder.
  /// All instances for one normalized path share state and a write queue.
  /// A corrupt file throws [FormatException] and is never overwritten here.
  static Future<AgentTaskLedger> open({String? path}) {
    final resolved = p.canonicalize(
      p.absolute(
        path ??
            p.join(DataDirectory.current.stateDir, 'agent-task-ledger.json'),
      ),
    );
    final existing = _instances[resolved];
    if (existing != null) return Future<AgentTaskLedger>.value(existing);
    final opening = _openings[resolved];
    if (opening != null) return opening;

    final created = Future<AgentTaskLedger>.microtask(() async {
      final ledger = await _read(File(resolved));
      _instances[resolved] = ledger;
      return ledger;
    });
    _openings[resolved] = created;
    unawaited(
      created.then<void>(
        (_) {
          _openings.remove(resolved);
        },
        onError: (Object error, StackTrace stack) {
          _openings.remove(resolved);
        },
      ),
    );
    return created;
  }

  static Future<AgentTaskLedger> _read(File file) async {
    if (!await file.exists()) {
      return AgentTaskLedger._(file.path, {}, {}, {});
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException catch (error) {
      throw FormatException('Invalid agent task ledger ${file.path}: $error');
    }
    if (decoded is! Map) {
      throw FormatException('Agent task ledger ${file.path} is not an object');
    }
    final json = decoded.cast<String, Object?>();
    final version = json['version'];
    if (version != null && version != 1) {
      throw const FormatException('Unsupported agent task ledger version');
    }

    final rawTasks = json['tasks'];
    final rawMembers = json['members'];
    if (rawTasks != null && rawTasks is! List ||
        rawMembers != null && rawMembers is! List) {
      throw const FormatException('Agent task ledger lists are invalid');
    }
    final tasks = <String, AgentTaskRecord>{};
    for (final raw in rawTasks as List<Object?>? ?? const []) {
      if (raw is! Map) throw const FormatException('Invalid task record');
      final task = AgentTaskRecord.fromJson(raw.cast<String, Object?>());
      final key = _key(task.sessionId, task.toolUseId);
      if (tasks.containsKey(key)) {
        throw const FormatException('Duplicate task record');
      }
      tasks[key] = task;
    }
    final members = <String, AgentMemberRecord>{};
    for (final raw in rawMembers as List<Object?>? ?? const []) {
      if (raw is! Map) throw const FormatException('Invalid member record');
      final member = AgentMemberRecord.fromJson(raw.cast<String, Object?>());
      final key = _key(member.sessionId, member.memberId);
      if (members.containsKey(key)) {
        throw const FormatException('Duplicate member record');
      }
      members[key] = member;
    }
    final ledger = AgentTaskLedger._(file.path, tasks, members, {
      for (final entry in json.entries)
        if (entry.key != 'version' &&
            entry.key != 'tasks' &&
            entry.key != 'members')
          entry.key: entry.value,
    });
    for (final raw in rawTasks ?? const []) {
      final values = (raw as Map).cast<String, Object?>();
      ledger._taskExtras[_key(
            values['sessionId']! as String,
            values['toolUseId']! as String,
          )] =
          values;
    }
    for (final raw in rawMembers ?? const []) {
      final values = (raw as Map).cast<String, Object?>();
      ledger._memberExtras[_key(
            values['sessionId']! as String,
            values['memberId']! as String,
          )] =
          values;
    }
    return ledger;
  }

  AgentTaskRecord? findTask(String sessionId, String toolUseId) =>
      _tasks[_key(sessionId, toolUseId)];

  List<AgentTaskRecord> tasksFor(String sessionId) => List.unmodifiable(
    _tasks.values.where((task) => task.sessionId == sessionId),
  );

  List<AgentMemberRecord> membersFor(String sessionId) => List.unmodifiable(
    _members.values.where((member) => member.sessionId == sessionId),
  );

  AgentMemberRecord? member(String sessionId, String memberId) =>
      _members[_key(sessionId, memberId)];

  /// Changes only the editable member fields. A bound CLI id and model are
  /// deliberately not parameters, so an update cannot rebind its identity.
  AgentMemberRecord updateMember(
    String sessionId,
    String memberId, {
    String? name,
    String? role,
    bool? enabled,
    bool? archived,
  }) {
    _requireId(sessionId, 'sessionId');
    _requireId(memberId, 'memberId');
    final previous = _members[_key(sessionId, memberId)];
    if (previous == null) {
      throw StateError('Unknown member $memberId in session $sessionId');
    }
    final next = previous._copyWith(
      name: name,
      role: role,
      enabled: enabled,
      archived: archived,
    );
    if (!_memberDiffers(previous, next)) return previous;
    _members[_key(sessionId, memberId)] = next;
    _persist();
    return next;
  }

  /// Projects local durable state; this never starts, stops or resumes a CLI.
  AgentMemberProjection projectMember(String sessionId, String memberId) {
    final member = this.member(sessionId, memberId);
    if (member == null) {
      throw StateError('Unknown member $memberId in session $sessionId');
    }
    final tasks = _tasks.values
        .where(
          (task) => task.sessionId == sessionId && task.memberId == memberId,
        )
        .toList();
    final state = tasks.any((task) => task.status == AgentTaskStatus.running)
        ? AgentMemberState.running
        : !member.enabled || member.archived
        ? AgentMemberState.disabled
        : tasks.any((task) => task.hostStopped || task.hostCancelled)
        ? AgentMemberState.stopped
        : member.cliAgentId != null &&
              tasks.isNotEmpty &&
              tasks.last.status == AgentTaskStatus.completed
        ? AgentMemberState.standby
        : AgentMemberState.unverified;
    return AgentMemberProjection(member: member, state: state);
  }

  List<AgentMemberProjection> memberStatesFor(String sessionId) =>
      List.unmodifiable(
        membersFor(sessionId)
            .map((member) => projectMember(sessionId, member.memberId)),
      );

  /// Records a newly started call. A completed or interrupted record is not
  /// restarted by a late start event.
  AgentTaskRecord recordStart({
    required String sessionId,
    required String toolUseId,
    required String memberId,
    required String taskId,
    String? runId,
    String? model,
    String? description,
  }) {
    _requireId(sessionId, 'sessionId');
    _requireId(toolUseId, 'toolUseId');
    _requireId(memberId, 'memberId');
    _requireId(taskId, 'taskId');
    final key = _key(sessionId, toolUseId);
    final previous = _tasks[key];
    final member = _members[_key(sessionId, memberId)];
    model ??= member?.model;
    description ??= member?.description;
    final next = previous == null
        ? AgentTaskRecord(
            sessionId: sessionId,
            memberId: memberId,
            taskId: taskId,
            toolUseId: toolUseId,
            runId: runId,
            model: model,
            description: description,
            status: AgentTaskStatus.running,
          )
        : previous.memberId.startsWith('pending:')
        ? previous._copyWith(
            memberId: memberId,
            taskId: taskId,
            runId: runId,
            model: model,
            description: description,
          )
        : previous._copyWith(
            runId: runId,
            model: model,
            description: description,
          );
    if (previous != null && _sameTask(previous, next)) return previous;
    _tasks[key] = next;
    _persist();
    return next;
  }

  /// Associates a stable member with a CLI agent, without changing a task's
  /// terminal decision. Placeholder ids from [cancelStart] can be replaced.
  AgentMemberRecord recordMember({
    required String sessionId,
    required String memberId,
    String? cliAgentId,
    String? model,
    String? description,
    String? name,
    String? role,
    bool? enabled,
    bool? archived,
  }) {
    _requireId(sessionId, 'sessionId');
    _requireId(memberId, 'memberId');
    final key = _key(sessionId, memberId);
    final previous = _members[key];
    var changed = previous == null;
    final next = AgentMemberRecord(
      sessionId: sessionId,
      memberId: memberId,
      cliAgentId: cliAgentId ?? previous?.cliAgentId,
      model: model ?? previous?.model,
      description: description ?? previous?.description,
      name: name ?? previous?.name,
      role: role ?? previous?.role,
      // Late metadata does not re-enable a member disabled by the host.
      enabled: enabled ?? previous?.enabled ?? true,
      archived: archived ?? previous?.archived ?? false,
    );
    _members[key] = next;

    for (final entry in _tasks.entries.toList()) {
      final task = entry.value;
      if (task.sessionId != sessionId || task.memberId != memberId) continue;
      final updated = task._copyWith(model: task.model == null ? model : null);
      if (!_sameTask(task, updated)) {
        _tasks[entry.key] = updated;
        changed = true;
      }
    }
    if (changed || _memberDiffers(previous, next)) _persist();
    return _members[key]!;
  }

  /// Marks a host-denied start, even if its start was never recorded.
  AgentTaskRecord cancelStart(
    String sessionId,
    String toolUseId, {
    String? result,
  }) {
    _requireId(sessionId, 'sessionId');
    _requireId(toolUseId, 'toolUseId');
    final key = _key(sessionId, toolUseId);
    final previous = _tasks[key];
    final next = (previous ?? _placeholder(sessionId, toolUseId))._copyWith(
      status: AgentTaskStatus.cancelled,
      hostCancelled: true,
      hostStopped: false,
      result: result ?? previous?.result ?? 'Cancelled by host',
    );
    if (previous != null && _sameTask(previous, next)) return previous;
    _tasks[key] = next;
    _persist();
    return next;
  }

  /// Stopping a running child is also cancelled, with its own host flag.
  AgentTaskRecord? stopTask(
    String sessionId,
    String toolUseId, {
    String? result,
  }) {
    _requireId(sessionId, 'sessionId');
    _requireId(toolUseId, 'toolUseId');
    final key = _key(sessionId, toolUseId);
    final previous = _tasks[key];
    if (previous == null) return null;
    final next = previous._copyWith(
      status: AgentTaskStatus.cancelled,
      hostCancelled: false,
      hostStopped: true,
      result: result ?? 'Stopped by host',
    );
    if (_sameTask(previous, next)) return previous;
    _tasks[key] = next;
    _persist();
    return next;
  }

  /// Projects a CLI outcome. Host cancellation remains authoritative over a
  /// late failure, and an interrupted task never silently starts again.
  AgentTaskRecord? recordEnd(
    String sessionId,
    String toolUseId, {
    required AgentTaskStatus status,
    String? result,
  }) {
    _requireId(sessionId, 'sessionId');
    _requireId(toolUseId, 'toolUseId');
    if (status == AgentTaskStatus.running) {
      throw ArgumentError.value(status, 'status', 'Use recordStart');
    }
    final key = _key(sessionId, toolUseId);
    final previous = _tasks[key];
    if (previous == null ||
        previous.status == AgentTaskStatus.cancelled ||
        previous.status == AgentTaskStatus.interrupted) {
      return previous;
    }
    final next = previous._copyWith(status: status, result: result);
    if (_sameTask(previous, next)) return previous;
    _tasks[key] = next;
    _persist();
    return next;
  }

  /// Explicit recovery of tasks left running by a previous process. It never
  /// starts anything and leaves other sessions and terminal outcomes alone.
  List<AgentTaskRecord> reconcileInterrupted(String sessionId) {
    _requireId(sessionId, 'sessionId');
    final changed = <AgentTaskRecord>[];
    for (final entry in _tasks.entries) {
      final task = entry.value;
      if (task.sessionId != sessionId ||
          task.status != AgentTaskStatus.running) {
        continue;
      }
      final next = task._copyWith(
        status: AgentTaskStatus.interrupted,
        result: 'Interrupted when host state was rebuilt',
      );
      _tasks[entry.key] = next;
      changed.add(next);
    }
    if (changed.isNotEmpty) _persist();
    return List.unmodifiable(changed);
  }

  static AgentTaskRecord _placeholder(String sessionId, String toolUseId) =>
      AgentTaskRecord(
        sessionId: sessionId,
        memberId: 'pending:$toolUseId',
        taskId: 'task:$toolUseId',
        toolUseId: toolUseId,
        status: AgentTaskStatus.cancelled,
      );

  void _persist() {
    final snapshot = {
      ..._unknownFields,
      'version': 1,
      'members': [
        for (final member in _members.values)
          {
            ...?_memberExtras[_key(member.sessionId, member.memberId)],
            ...member.toJson(),
          },
      ],
      'tasks': [
        for (final task in _tasks.values)
          {
            ...?_taskExtras[_key(task.sessionId, task.toolUseId)],
            ...task.toJson(),
          },
      ],
    };
    final file = File(path);
    final result = _writes.then((_) async {
      try {
        await file.parent.create(recursive: true);
        await writeFileAtomically(
          file,
          '${const JsonEncoder.withIndent('  ').convert(snapshot)}\n',
        );
        _writeError = null;
        _writeStack = null;
      } catch (error, stack) {
        _writeError = error;
        _writeStack = stack;
        rethrow;
      }
    });
    _latestWrite = result;
    _writes = result.then<void>((_) {}, onError: (_) {});
    unawaited(result.then<void>((_) {}, onError: (_) {}));
  }

  Future<void> flush() async {
    while (true) {
      final writes = _writes;
      final latest = _latestWrite;
      await writes;
      if (identical(writes, _writes) && identical(latest, _latestWrite)) {
        if (_writeError case final error?) {
          Error.throwWithStackTrace(error, _writeStack!);
        }
        return;
      }
    }
  }

  static String _key(String sessionId, String id) =>
      '${sessionId.length}:$sessionId$id';

  static bool _sameTask(AgentTaskRecord a, AgentTaskRecord b) =>
      jsonEncode(a.toJson()) == jsonEncode(b.toJson());

  static bool _memberDiffers(AgentMemberRecord? a, AgentMemberRecord b) =>
      a == null || jsonEncode(a.toJson()) != jsonEncode(b.toJson());

  static void _requireId(String value, String name) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, name, 'Must not be empty');
    }
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Missing or invalid $key');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('Invalid $key');
  return value;
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('Missing or invalid $key');
  return value;
}

bool? _optionalBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! bool) throw FormatException('Invalid $key');
  return value;
}
