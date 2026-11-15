import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../util/cancel.dart';
import '../util/ids.dart';
import '../tools/agent_tool.dart' show SubagentResult;
import '../util/processes.dart';
import 'session.dart';

/// Where a task stands.
enum TaskStatus {
  queued,
  running,
  completed,
  failed,
  killed,
  interrupted;

  bool get done => this != queued && this != running;
}

/// Work going on beside the conversation: a command run in the background,
/// a subagent working on its own.
class BackgroundTask {
  BackgroundTask({
    required this.id,
    required this.type,
    required this.description,
    required this.outputFile,
    this.toolUseId,
    this.command,
    this.agentType,
    this.model,
    this.requestedModel,
    this.modelSource,
    this.parentId,
  }) : queuedAt = DateTime.now();

  final String id;

  /// `local_bash` or `local_agent`.
  final String type;
  final String description;
  final String outputFile;
  final String? command;
  final String? agentType;

  /// A subagent's: the model it was assigned, the model its call asked
  /// for, and where the assignment came from (`pool`, `requested`, …).
  String? toolUseId;
  String? model;
  String? requestedModel;
  String? modelSource;
  final String? parentId;

  /// When this attempt was queued, and when it actually started.
  DateTime queuedAt;
  DateTime? started;
  CancelToken cancel = CancelToken();

  TaskStatus status = TaskStatus.running;
  int? exitCode;
  DateTime? ended;
  Process? process;

  /// Whether it was started in the background, or sent there.
  bool backgrounded = true;

  /// Completes when a subagent working in the foreground is sent to the
  /// background (`background_tasks`): its call returns, it goes on.
  final Completer<void> toBackground = Completer<void>();

  /// Whether it ran past its time and was stopped.
  bool timedOut = false;

  /// A subagent's last words, its tokens and calls.
  String? result;
  int tokens = 0;
  int toolUses = 0;
  String? error;

  final Completer<void> _done = Completer<void>();
  Completer<void> _attemptDone = Completer<void>();

  /// Set by AgentTool: called once a queue place has been assigned.
  void Function()? admit;

  /// Completes once it has ended.
  Future<void> get done => _attemptDone.future;

  bool get isShell => type == 'local_bash';

  /// What it has written so far.
  String output() {
    try {
      return File(outputFile).readAsStringSync();
    } on FileSystemException {
      return '';
    }
  }

  Map<String, Object?> toJson({bool readOnly = false}) => {
    'task_id': id,
    'task_type': type,
    'description': description,
    'status': status.name,
    'queue_state': status == TaskStatus.queued ? 'queued' : 'admitted',
    'tool_use_id': ?toolUseId,
    'output_file': outputFile,
    'exit_code': ?exitCode,
    'model': ?model,
    'requested_model': ?requestedModel,
    'model_source': ?modelSource,
    'parent_id': ?parentId,
    'agent_type': ?agentType,
    'command': ?command,
    'is_backgrounded': backgrounded,
    'queued_at': queuedAt.toUtc().toIso8601String(),
    'started_at': ?started?.toUtc().toIso8601String(),
    'ended_at': ?ended?.toUtc().toIso8601String(),
    'result': ?result,
    'error': ?error,
    'tokens': tokens,
    'tool_uses': toolUses,
    'read_only': readOnly,
  };
}

/// The session's background tasks: started, read, stopped, and each one's
/// end told the model (a `<task-notification>` it takes up as a turn of
/// its own) and the host (`task_notification`).
class TaskManager {
  TaskManager(this.session, {this.agentLimit = 2});

  /// How many children one supervisor may have actually running at once.
  /// Others are registered as queued only after their user approval.
  final int agentLimit;

  final AgentSession session;

  final Map<String, BackgroundTask> tasks = {};
  final Map<String, List<BackgroundTask>> _agentQueues = {};
  final Map<String, int> _activeAgents = {};

  /// Live queue counts for the host, never a license to start queued work.
  Map<String, Object?> agentQueueStatus(String parentId) => {
    'parent_id': parentId,
    'limit': agentLimit,
    'running': _activeAgents[parentId] ?? 0,
    'queued': _agentQueues[parentId]?.length ?? 0,
    'task_ids': [
      for (final task in _agentQueues[parentId] ?? const []) task.id,
    ],
  };

  /// Commands run in the foreground, by their call: one may be sent to the
  /// background (`background_tasks`).
  final Map<String, ForegroundCommand> foreground = {};

  String get outputDir =>
      session.paths.tasksDir(session.cwd, session.sessionId);

  String newId(String prefix) {
    while (true) {
      final id = '$prefix${randomId(8)}';
      if (!tasks.containsKey(id)) return id;
    }
  }

  BackgroundTask? operator [](String id) => tasks[id];

  Iterable<BackgroundTask> get running =>
      tasks.values.where((task) => task.status == TaskStatus.running);

  BackgroundTask _register({
    required String type,
    required String description,
    String? toolUseId,
    String? command,
    String? agentType,
    String? model,
    String? requestedModel,
    String? modelSource,
    String? parentId,
    String? id,
    void Function()? admit,
  }) {
    final taskId = id ?? newId(type == 'local_bash' ? 'b' : 'a');
    if (session.options.persist) {
      Directory(outputDir).createSync(recursive: true);
    }
    final task = BackgroundTask(
      id: taskId,
      type: type,
      description: description,
      outputFile: p.join(outputDir, '$taskId.output'),
      toolUseId: toolUseId,
      command: command,
      agentType: agentType,
      model: model,
      requestedModel: requestedModel,
      modelSource: modelSource,
      parentId: parentId,
    );
    if (session.options.persist) {
      File(task.outputFile).writeAsStringSync('');
    }
    task.admit = admit;
    tasks[taskId] = task;
    return task;
  }

  void _started(BackgroundTask task, {bool admission = false}) {
    task.started = DateTime.now();
    _persist(task);
    if (admission) {
      session.emitSystem('task_updated', {
        'task_id': task.id,
        'patch': {
          'status': 'running',
          'queue_state': 'running',
          'queue': task.parentId == null
              ? null
              : agentQueueStatus(task.parentId!),
        },
      });
      return;
    }
    session.emitSystem('task_started', {
      'task_id': task.id,
      'task_type': task.type,
      'tool_use_id': ?task.toolUseId,
      'description': task.description,
      'is_backgrounded': task.backgrounded,
      'queue_state': 'running',
      'queue': task.parentId == null ? null : agentQueueStatus(task.parentId!),
      'output_file': task.outputFile,
      'model': ?task.model,
      'requested_model': ?task.requestedModel,
      'model_source': ?task.modelSource,
    });
  }

  void _queued(BackgroundTask task) {
    _persist(task);
    session.emitSystem('task_started', {
      'task_id': task.id,
      'task_type': task.type,
      'tool_use_id': ?task.toolUseId,
      'description': task.description,
      'is_backgrounded': task.backgrounded,
      'queue_state': 'queued',
      'queue': task.parentId == null ? null : agentQueueStatus(task.parentId!),
      'output_file': task.outputFile,
      'model': ?task.model,
      'requested_model': ?task.requestedModel,
      'model_source': ?task.modelSource,
    });
  }

  /// Runs [command] in the background, from [cwd], for [limit] at most.
  Future<BackgroundTask> startShell({
    required String command,
    required String description,
    required String cwd,
    String? toolUseId,
    Duration? limit,
  }) async {
    final task = _register(
      type: 'local_bash',
      description: description,
      toolUseId: toolUseId,
      command: command,
    );
    final shell = session.shell;
    final cwdFile = p.join(outputDir, '${task.id}.cwd');
    final process = await Process.start(
      shell.executable,
      shell.arguments(command, cwdFile),
      workingDirectory: cwd,
      environment: session.shellEnvironment,
      includeParentEnvironment: false,
    );
    task.process = process;
    unawaited(process.stdin.close().catchError((_) {}));
    final sink = File(task.outputFile).openWrite(mode: FileMode.append);
    final output = ProcessOutput(process, sink.add, sink.add);
    _started(task);
    final timer = limit == null
        ? null
        : Timer(limit, () {
            if (task.status.done) return;
            task.timedOut = true;
            unawaited(killTree(process.pid));
          });
    unawaited(() async {
      final code = await process.exitCode;
      timer?.cancel();
      await output.ended();
      await sink.flush();
      await sink.close();
      task.exitCode = code;
      finish(
        task,
        task.status == TaskStatus.killed
            ? TaskStatus.killed
            : code == 0 && !task.timedOut
            ? TaskStatus.completed
            : TaskStatus.failed,
      );
    }());
    return task;
  }

  /// A command in the foreground that has gone on a while: a task the
  /// host shows, that the user can send to the background.
  BackgroundTask registerForeground(ForegroundCommand command) {
    final task = _register(
      type: 'local_bash',
      description: command.description,
      toolUseId: command.toolUseId,
      command: command.command,
    );
    task
      ..process = command.process
      ..backgrounded = false;
    command.registered = task;
    _started(task);
    return task;
  }

  /// Takes on a command that was running in the foreground: its output so
  /// far and what follows go to its file.
  BackgroundTask adoptShell(ForegroundCommand command) {
    final BackgroundTask task;
    if (command.registered case final registered?) {
      task = registered..backgrounded = true;
      command.background(task);
      session.emitSystem('task_updated', {
        'task_id': task.id,
        'patch': {'is_backgrounded': true},
      });
    } else {
      task = _register(
        type: 'local_bash',
        description: command.description,
        toolUseId: command.toolUseId,
        command: command.command,
      );
      task.process = command.process;
      command.background(task);
      _started(task);
    }
    session.emitSystem('background_tasks_changed', {
      'tasks': [
        for (final t in running) {'task_id': t.id},
      ],
    });
    return task;
  }

  /// Starts a user-approved attempt of a previously finished agent task.
  void startRetry(BackgroundTask task) {
    if (!task.status.done) throw StateError('The agent is still running.');
    task
      ..backgrounded = true
      ..status = TaskStatus.queued
      ..queuedAt = DateTime.now()
      ..started = null
      ..ended = null
      ..error = null
      ..result = null
      ..exitCode = null
      ..cancel = CancelToken()
      .._attemptDone = Completer<void>();
    final parent = task.parentId;
    if (parent == null) {
      task.status = TaskStatus.running;
      _started(task);
      return;
    }
    (_agentQueues[parent] ??= []).add(task);
    _queued(task);
    _admitAgents(parent);
  }

  void _admitAgents(String parentId) {
    final queue = _agentQueues[parentId];
    if (queue == null) return;
    while ((_activeAgents[parentId] ?? 0) < agentLimit && queue.isNotEmpty) {
      final task = queue.removeAt(0);
      if (task.status != TaskStatus.queued) continue;
      _activeAgents[parentId] = (_activeAgents[parentId] ?? 0) + 1;
      task.status = TaskStatus.running;
      _started(task, admission: true);
      task.admit?.call();
    }
    if (queue.isEmpty) _agentQueues.remove(parentId);
  }

  void _releaseAgent(BackgroundTask task) {
    final parent = task.parentId;
    if (parent == null || task.started == null) return;
    final active = _activeAgents[parent] ?? 0;
    if (active <= 1) {
      _activeAgents.remove(parent);
    } else {
      _activeAgents[parent] = active - 1;
    }
    _admitAgents(parent);
  }

  /// A subagent working in the background.
  BackgroundTask registerAgent({
    required String description,
    required String agentId,
    String? toolUseId,
    String? agentType,
    String? model,
    String? requestedModel,
    String? modelSource,
    String? parentId,
    bool background = true,
    void Function()? admit,
  }) {
    final task = _register(
      type: 'local_agent',
      description: description,
      toolUseId: toolUseId,
      agentType: agentType,
      model: model,
      requestedModel: requestedModel,
      modelSource: modelSource,
      parentId: parentId,
      id: agentId,
      admit: admit,
    );
    task.backgrounded = background;
    if (parentId == null) {
      _started(task);
    } else {
      task.status = TaskStatus.queued;
      (_agentQueues[parentId] ??= []).add(task);
      _queued(task);
      _admitAgents(parentId);
    }
    return task;
  }

  /// Notes what a background subagent did: a step in its output file,
  /// and progress for the host.
  void agentProgress(BackgroundTask task, {String? lastTool, String? summary}) {
    session.emitSystem('task_progress', {
      'task_id': task.id,
      'tool_use_id': ?task.toolUseId,
      'description': ?summary,
      'last_tool_name': ?lastTool,
      'usage': {
        'total_tokens': task.tokens,
        'tool_uses': task.toolUses,
        'duration_ms': task.started == null
            ? 0
            : DateTime.now().difference(task.started!).inMilliseconds,
      },
    });
  }

  /// Ends [task] as [status]: the host told, and the model, unless it was
  /// stopped on purpose.
  void finish(
    BackgroundTask task,
    TaskStatus status, {
    String? result,
    SubagentResult? envelope,
  }) {
    if (task.ended != null) return;
    task.ended = DateTime.now();
    _releaseAgent(task);
    task.started = null;
    if (task.parentId case final parent?) _agentQueues[parent]?.remove(task);
    task.status = status;
    _persist(task);
    if (result != null) task.result = result;
    if (!task._attemptDone.isCompleted) task._attemptDone.complete();
    if (!task._done.isCompleted) task._done.complete();
    final summary = _summary(task);
    session.emitSystem('task_notification', {
      'task_id': task.id,
      'tool_use_id': ?task.toolUseId,
      'status': status.name,
      'summary': summary,
      'output_file': task.outputFile,
      if (envelope case final report?)
        'result': report.toJson(
          prompt: session.subagents[task.id]?.prompt,
          durationMs: task.ended!
              .difference(task.started ?? task.queuedAt)
              .inMilliseconds,
        ),
      'usage': {
        'total_tokens': task.tokens,
        'tool_uses': task.toolUses,
        'duration_ms': task.ended!
            .difference(task.started ?? task.queuedAt)
            .inMilliseconds,
      },
    });
    // A subagent in the foreground answers its call; one stopped on
    // purpose needs no telling.
    if (task.backgrounded && status != TaskStatus.killed) {
      session.taskEnded(task, notification(task, summary));
    }
  }

  void _persist(BackgroundTask task) {
    if (!session.options.persist) return;
    session.store.note({'type': 'task_index', 'task': task.toJson()});
  }

  /// Restores the read-only index of the previous process. Its processes
  /// and model calls are gone: no unfinished task is automatically rerun.
  void restore(Iterable<Map<String, Object?>> records) {
    // The index is append-only: a task's start, end and recovery are
    // successive records. Only its last snapshot says how it ended.
    final latest = <String, Map<String, Object?>>{};
    for (final entry in records) {
      if (entry['type'] != 'task_index' || entry['task'] is! Map) continue;
      final record = (entry['task'] as Map).cast<String, Object?>();
      if (record['task_id'] case final String id) latest[id] = record;
    }
    for (final record in latest.values) {
      final id = record['task_id'];
      final type = record['task_type'];
      if (id is! String || type is! String || tasks.containsKey(id)) continue;
      final status = TaskStatus.values
          .where((s) => s.name == record['status'])
          .firstOrNull;
      if (status == null) continue;
      final recovered = !status.done;
      final task =
          BackgroundTask(
              id: id,
              type: type,
              description: '${record['description'] ?? ''}',
              outputFile: '${record['output_file'] ?? ''}',
              toolUseId: record['tool_use_id'] as String?,
              command: record['command'] as String?,
              agentType: record['agent_type'] as String?,
              model: record['model'] as String?,
              requestedModel: record['requested_model'] as String?,
              modelSource: record['model_source'] as String?,
              parentId: record['parent_id'] as String?,
            )
            ..status = recovered ? TaskStatus.interrupted : status
            ..backgrounded = record['is_backgrounded'] != false
            ..started = DateTime.tryParse('${record['started_at'] ?? ''}')
            ..ended = DateTime.tryParse('${record['ended_at'] ?? ''}')
            ..result = record['result'] as String?
            ..error = record['error'] as String?
            ..tokens = record['tokens'] is int ? record['tokens'] as int : 0
            ..toolUses = record['tool_uses'] is int
                ? record['tool_uses'] as int
                : 0;
      task.queuedAt =
          DateTime.tryParse('${record['queued_at'] ?? ''}') ?? task.queuedAt;
      if (recovered) task.ended ??= DateTime.now();
      task.cancel.cancel('interrupted');
      if (!task._done.isCompleted) task._done.complete();
      if (!task._attemptDone.isCompleted) task._attemptDone.complete();
      tasks[id] = task;
    }
    for (final task in tasks.values) {
      task.backgrounded = true;
      session.emitSystem('task_started', {
        ...task.toJson(readOnly: true),
        'is_backgrounded': task.backgrounded,
        'queue_state': task.status == TaskStatus.queued ? 'queued' : 'admitted',
        'queue': task.parentId == null
            ? null
            : agentQueueStatus(task.parentId!),
      });
      if (task.status == TaskStatus.interrupted) {
        session.emitSystem('task_notification', {
          'task_id': task.id,
          'tool_use_id': ?task.toolUseId,
          'status': task.status.name,
          'summary': _summary(task),
          'output_file': task.outputFile,
          'read_only': true,
          'usage': {'total_tokens': task.tokens, 'tool_uses': task.toolUses},
        });
      }
      if (task.status == TaskStatus.interrupted) _persist(task);
    }
  }

  static String _summary(BackgroundTask task) {
    final what = task.isShell
        ? 'Background command "${task.description}"'
        : 'Agent "${task.description}"';
    return switch (task.status) {
      TaskStatus.completed =>
        task.isShell
            ? '$what completed (exit code ${task.exitCode ?? 0})'
            : '$what completed',
      TaskStatus.failed =>
        task.isShell
            ? task.timedOut
                  ? '$what ran out of time and was stopped'
                  : '$what failed with exit code ${task.exitCode}'
            : '$what failed: ${task.error ?? 'unknown error'}',
      TaskStatus.killed => '$what was stopped',
      TaskStatus.interrupted => '$what was interrupted with its session',
      TaskStatus.queued => '$what is queued for a concurrency slot',
      TaskStatus.running => '$what is running',
    };
  }

  /// What the model is told when [task] ends.
  static String notification(BackgroundTask task, String summary) {
    final out = StringBuffer('<task-notification>\n')
      ..writeln('<task-id>${task.id}</task-id>')
      ..writeln('<tool-use-id>${task.toolUseId ?? ''}</tool-use-id>')
      ..writeln('<status>${task.status.name}</status>')
      ..writeln('<summary>$summary</summary>');
    if (task.isShell) {
      out.writeln('<output-file>${task.outputFile}</output-file>');
    } else if (task.result != null) {
      out.writeln('<result>${task.result}</result>');
    }
    out.write('</task-notification>');
    if (task.isShell) {
      out.write(
        '\nRead the output file to retrieve the result: ${task.outputFile}',
      );
    }
    return out.toString();
  }

  /// Stops [id]; false when there is no such task running.
  Future<bool> stop(String id) async {
    final task = tasks[id];
    if (task == null || task.status.done) return false;
    task.cancel.cancel('stopped');
    if (task.parentId case final parent?) {
      _agentQueues[parent]?.remove(task);
    }
    if (task.process case final process?) {
      await killTree(process.pid);
    }
    if (!task.isShell) finish(task, TaskStatus.killed);
    // A shell's end is noted when its process exits: soon after.
    await task.done.timeout(const Duration(seconds: 3), onTimeout: () {});
    // Or not, where it does not end on being killed: stopped all the same,
    // for the host, which would show it running on.
    finish(task, TaskStatus.killed);
    return true;
  }

  /// Stops them all: the session is ending.
  Future<void> stopAll() async {
    for (final task in [...tasks.values.where((task) => !task.status.done)]) {
      await stop(task.id);
    }
    for (final command in [...foreground.values]) {
      await killTree(command.process.pid);
    }
  }
}

/// A command running in the foreground, its output gathered for its call's
/// result, until it ends or is sent to the background.
class ForegroundCommand {
  ForegroundCommand({
    required this.process,
    required this.command,
    required this.description,
    required this.toolUseId,
  });

  final Process process;
  final String command;
  final String description;
  final String toolUseId;

  final StringBuffer stdout = StringBuffer();
  final StringBuffer stderr = StringBuffer();

  /// Set once it went to the background, as that task.
  BackgroundTask? task;

  /// Its task while it runs in the foreground, once it has gone on long
  /// enough to be shown as one.
  BackgroundTask? registered;
  IOSink? _sink;
  final Completer<BackgroundTask> _backgrounded = Completer();

  /// Completes when it is sent to the background.
  Future<BackgroundTask> get backgrounded => _backgrounded.future;

  void addStdout(List<int> bytes) {
    if (_sink case final sink?) {
      sink.add(bytes);
    } else {
      stdout.write(utf8.decode(bytes, allowMalformed: true));
    }
  }

  void addStderr(List<int> bytes) {
    if (_sink case final sink?) {
      sink.add(bytes);
    } else {
      stderr.write(utf8.decode(bytes, allowMalformed: true));
    }
  }

  void background(BackgroundTask task) {
    this.task = task;
    final sink = _sink = File(task.outputFile).openWrite(mode: FileMode.append);
    sink.write(stdout.toString());
    sink.write(stderr.toString());
    if (!_backgrounded.isCompleted) _backgrounded.complete(task);
  }

  Future<void> closeSink() async {
    final sink = _sink;
    if (sink == null) return;
    await sink.flush();
    await sink.close();
  }
}
