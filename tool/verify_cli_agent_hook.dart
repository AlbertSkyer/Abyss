import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cli_agent_resume_probe.dart';

// Deterministic local-only Claude Code protocol probe. No real credentials or
// upstream requests: all model requests are answered by this process.
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first.startsWith('--')) {
    throw ArgumentError(
      'Usage: dart tool/verify_cli_agent_hook.dart CLI_PATH '
      '[--deny|--alias|--full-model|--definition|--resume-agent '
      '[--deny-send|--restart-resume]]',
    );
  }
  if (args.contains('--resume-agent')) {
    await _runResumeAgentProbe(args);
    return;
  }
  final base = Directory.fromUri(
    Platform.script.resolve('../build/cli-hook-probes/'),
  )..createSync(recursive: true);
  final root = base.createTempSync('probe-');
  final cli = File(args.first).absolute.path;
  final home = Directory('${root.path}/home')..createSync(recursive: true);
  final config = Directory('${root.path}/config')..createSync(recursive: true);
  final cwd = Directory('${root.path}/work')..createSync(recursive: true);
  final calls = <Map<String, Object?>>[];
  var turn = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serving = server.forEach((request) async {
    final text = await utf8.decoder.bind(request).join();
    if (request.uri.path != '/v1/messages') {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final body = jsonDecode(text) as Map<String, Object?>;
    calls.add(body);
    final prior = body['messages'] as List? ?? const [];
    final parentToolReturned = prior.any(
      (message) =>
          message is Map &&
          message['role'] == 'user' &&
          message['content'] is List &&
          (message['content'] as List).any(
            (block) => block is Map && block['type'] == 'tool_result',
          ),
    );
    final n = turn++;
    final isChild = '${body['model']}'.startsWith('@other/');

    stdout.writeln(
      'ENDPOINT ${calls.length} parentToolReturned=$parentToolReturned model=${body['model']}',
    );

    final payload = <String, Object?>{
      'id': 'msg_smoke_$n',
      'type': 'message',
      'role': 'assistant',
      'model': isChild ? 'child-test-model' : 'parent-test-model',
      'stop_reason': !parentToolReturned && !isChild ? 'tool_use' : 'end_turn',
      'stop_sequence': null,
      'content': !parentToolReturned && !isChild
          ? [
              for (
                var task = 0;
                task < (args.contains('--parallel') ? 2 : 1);
                task++
              )
                {
                  'type': 'tool_use',
                  'id': 'toolu_smoke_agent_$task',
                  'name': 'Agent',
                  'input': {
                    'description': 'Inspect the smoke fixture',
                    'prompt': 'Return the word CHILD and nothing else.',
                    'subagent_type': 'general-purpose',
                  },
                },
            ]
          : [
              {'type': 'text', 'text': isChild ? 'CHILD' : 'PARENT-DONE'},
            ],
      'usage': {'input_tokens': 1, 'output_tokens': 1},
    };
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  });
  Process? process;
  var sequence = 0;
  try {
    process = await Process.start(
      cli,
      [
        '-p',
        '--input-format',
        'stream-json',
        '--output-format',
        'stream-json',
        '--verbose',
        '--include-partial-messages',
        '--permission-prompt-tool',
        'stdio',
        if (!args.contains('--persist')) '--no-session-persistence',
        '--setting-sources',
        '',
        '--strict-mcp-config',
        '--mcp-config',
        '{"mcpServers":{}}',
        '--tools',
        'default',
        '--agents',
        jsonEncode({
          'Explore': {
            'description': 'Read-only explorer.',
            'prompt': 'Use the original explorer instructions.',
            'model': '@other/provider-model',
          },
          'abyss-smoke': {
            'description': 'Abyss controlled smoke agent.',
            'prompt': 'Return the word CHILD and nothing else.',
            'model': '@other/provider-model',
          },
        }),
      ],
      workingDirectory: cwd.path,
      includeParentEnvironment: false,
      environment: {
        'PATH': Platform.environment['PATH'] ?? '',
        'SYSTEMROOT': Platform.environment['SYSTEMROOT'] ?? '',
        'COMSPEC': Platform.environment['COMSPEC'] ?? '',
        'PATHEXT': Platform.environment['PATHEXT'] ?? '',
        'TEMP': Platform.environment['TEMP'] ?? '',
        'TMP': Platform.environment['TMP'] ?? '',
        'USERPROFILE': home.path,
        'HOME': home.path,
        'APPDATA': home.path,
        'LOCALAPPDATA': home.path,
        'CLAUDE_CONFIG_DIR': config.path,
        'ANTHROPIC_BASE_URL': 'http://127.0.0.1:${server.port}',
        'ANTHROPIC_AUTH_TOKEN': 'local-smoke-token-not-a-credential',
        'ANTHROPIC_API_KEY': '',
        'ANTHROPIC_MODEL': 'smoke-model',
        if (args.contains('--alias') || args.contains('--parallel'))
          'ANTHROPIC_DEFAULT_HAIKU_MODEL': '@other/provider-model',
        if (args.contains('--parallel'))
          'ANTHROPIC_DEFAULT_OPUS_MODEL': '@other/second-model',
        'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
        'DISABLE_TELEMETRY': '1',
        'DISABLE_ERROR_REPORTING': '1',
        'NO_PROXY': '127.0.0.1,localhost',
        'no_proxy': '127.0.0.1,localhost',
        'HTTP_PROXY': '',
        'HTTPS_PROXY': '',
        'http_proxy': '',
        'https_proxy': '',
      },
    );
    final processRef = process;
    processRef.stderr
        .transform(utf8.decoder)
        .listen((s) => stdout.write('STDERR $s'));
    final lines = processRef.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    final outputDone = Completer<void>();
    final seenHook = Completer<Map<String, Object?>>();
    final secondHook = Completer<Map<String, Object?>>();
    final subscription = lines.listen((line) {
      if (line.trim().isEmpty) return;
      if (!line.contains('"commands":') &&
          !line.contains('"type":"stream_event"')) {
        stdout.writeln('OUT $line');
      }
      try {
        final message = (jsonDecode(line) as Map).cast<String, Object?>();
        if (message['type'] == 'control_request' &&
            (message['request'] as Map)['subtype'] == 'hook_callback') {
          if (!seenHook.isCompleted) {
            seenHook.complete(message);
          } else if (!secondHook.isCompleted) {
            secondHook.complete(message);
          }
        }
      } on FormatException {
        // Ignore non-protocol diagnostic output.
      }
    });
    subscription.onDone(() {
      if (!outputDone.isCompleted) outputDone.complete();
    });
    void send(Map<String, Object?> message) {
      stdout.writeln('IN ${jsonEncode(message)}');
      processRef.stdin.writeln(jsonEncode(message));
    }

    send({
      'type': 'control_request',
      'request_id': 'init-smoke',
      'request': {
        'subtype': 'initialize',
        'hooks': {
          'PreToolUse': [
            {
              'matcher': 'Agent|Task',
              'hookCallbackIds': ['agent-approval'],
              'onFailure': 'block',
            },
          ],
        },
      },
    });
    final init = await lines
        .map((line) => (jsonDecode(line) as Map).cast<String, Object?>())
        .firstWhere(
          (message) =>
              message['type'] == 'control_response' &&
              (message['response'] as Map)['request_id'] == 'init-smoke',
        )
        .timeout(const Duration(seconds: 25));
    final initPayload = ((init['response'] as Map)['response'] as Map)
        .cast<String, Object?>();
    stdout.writeln(
      'SMOKE INIT ${jsonEncode({'hooks_applied': initPayload['hooks_applied'], 'capabilities': initPayload['capabilities'], 'pid': initPayload['pid']})}',
    );
    send({
      'type': 'user',
      'uuid': 'smoke-user-1',
      'session_id': '',
      'parent_tool_use_id': null,
      'message': {'role': 'user', 'content': 'Delegate the smoke task.'},
    });
    final hook = await seenHook.future.timeout(const Duration(seconds: 35));
    final another = args.contains('--parallel')
        ? await secondHook.future.timeout(const Duration(seconds: 15))
        : null;
    final callsBeforeApproval = calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (calls.length != callsBeforeApproval) {
      throw StateError('Model request started before approval');
    }
    final id = hook['request_id'] as String;
    if (args.contains('--deny') || args.contains('--cancel-one')) {
      send({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': id,
          'response': {
            'hookSpecificOutput': {
              'hookEventName': 'PreToolUse',
              'permissionDecision': 'deny',
              'permissionDecisionReason': 'Cancelled by smoke probe.',
            },
          },
        },
      });
    } else {
      send({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': id,
          'response': {
            'hookSpecificOutput': {
              'hookEventName': 'PreToolUse',
              'permissionDecision': 'allow',
              'updatedInput': {
                'description': 'Inspect the smoke fixture',
                'prompt': 'Return the word CHILD and nothing else.',
                'subagent_type': args.contains('--definition')
                    ? 'abyss-smoke'
                    : args.contains('--original')
                    ? 'Explore'
                    : 'general-purpose',
                if (args.contains('--full-model'))
                  'model': '@other/provider-model'
                else if (args.contains('--alias') ||
                    args.contains('--parallel'))
                  'model': 'haiku',
              },
            },
          },
        },
      });
    }
    if (another != null) {
      final original =
          ((another['request'] as Map)['input'] as Map)['tool_input'] as Map;
      send({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': another['request_id'],
          'response': {
            'hookSpecificOutput': {
              'hookEventName': 'PreToolUse',
              'permissionDecision': 'allow',
              'updatedInput': {...original, 'model': 'opus'},
            },
          },
        },
      });
    }
    final result = await lines
        .map((line) => (jsonDecode(line) as Map).cast<String, Object?>())
        .firstWhere((message) => message['type'] == 'result')
        .timeout(const Duration(seconds: 50));
    if (result['is_error'] == true) throw StateError('CLI turn failed');
    bool modelsArrived() => args.contains('--parallel')
        ? calls.any((call) => call['model'] == '@other/second-model') &&
              (args.contains('--cancel-one') ||
                  calls.any((call) => call['model'] == '@other/provider-model'))
        : calls.any((call) => call['model'] == '@other/provider-model');
    if (args.contains('--definition') ||
        args.contains('--alias') ||
        args.contains('--parallel')) {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!modelsArrived() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    final customRequests = calls
        .where((call) => call['model'] == '@other/provider-model')
        .length;
    if ((args.contains('--definition') ||
            args.contains('--alias') ||
            args.contains('--parallel')) &&
        !modelsArrived()) {
      throw StateError('Chosen full model never reached the endpoint');
    }
    if ((args.contains('--deny') || args.contains('--cancel-one')) &&
        customRequests != 0) {
      throw StateError('Cancelled child started');
    }
    stdout.writeln('MODEL_REQUESTS ${calls.length}');
    for (var i = 0; i < calls.length; i++) {
      stdout.writeln('REQUEST_${i + 1} model=${calls[i]['model']}');
    }
    await processRef.stdin.close();
    await processRef.exitCode.timeout(const Duration(seconds: 8));
    if (args.contains('--persist')) {
      final transcripts = config
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.jsonl'))
          .toList();
      if (transcripts.isEmpty) throw StateError('No CLI session was written');
      stdout.writeln(
        'PERSISTED ${transcripts.length} JSONL files in ${config.path}',
      );
    }
    sequence++;
  } finally {
    process?.kill(ProcessSignal.sigkill);
    await server.close(force: true);
    await serving;
    stdout.writeln('DONE $sequence');
  }
}

Future<void> _runResumeAgentProbe(List<String> args) async {
  final cli = File(args.first).absolute.path;
  final base = Directory.fromUri(
    Platform.script.resolve('../build/cli-hook-probes/'),
  )..createSync(recursive: true);
  final root = base.createTempSync('resume-agent-');
  final home = Directory('${root.path}/home')..createSync(recursive: true);
  Directory('${home.path}/temp').createSync(recursive: true);
  final config = Directory('${root.path}/config')..createSync(recursive: true);
  final cwd = Directory('${root.path}/work')..createSync(recursive: true);
  final fixture = ResumeAgentFixture();
  final deny = args.contains('--deny-send');
  final restart = args.contains('--restart-resume');
  if (deny && restart) {
    throw ArgumentError('--deny-send and --restart-resume are separate cases');
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serving = server.forEach((request) async {
    try {
      final text = await utf8.decoder.bind(request).join();
      if (request.uri.path != '/v1/messages') {
        request.response.statusCode = 404;
      } else {
        final payload = fixture.reply(jsonDecode(text));
        stdout.writeln(
          'ENDPOINT ${fixture.requests.length} '
          'model=${fixture.requests.last['model']} '
          'child=${fixture.requests.last['model'] == ResumeAgentFixture.model}',
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(payload));
      }
    } catch (error) {
      stdout.writeln('PROBE ERROR $error');
      request.response.statusCode = 500;
    }
    await request.response.close();
  });
  _ResumeCliSession? session;
  String? sessionId;
  var phase = 0;
  try {
    stdout.writeln('PROBE_ROOT ${root.path}');
    stdout.writeln('MARKER ${fixture.marker}');
    stdout.writeln(
      'RESUME_SCENARIO ${deny ? 'deny' : 'allow'} restart=$restart',
    );

    Future<void> start({String? resume}) async {
      phase++;
      session = _ResumeCliSession(
        await Process.start(
          cli,
          [
            '-p',
            '--input-format',
            'stream-json',
            '--output-format',
            'stream-json',
            '--verbose',
            '--include-partial-messages',
            '--permission-prompt-tool',
            'stdio',
            if (resume != null) ...['--resume', resume],
            '--setting-sources',
            '',
            '--strict-mcp-config',
            '--mcp-config',
            '{"mcpServers":{}}',
            '--tools',
            'default',
          ],
          workingDirectory: cwd.path,
          includeParentEnvironment: false,
          environment: _isolatedEnvironment(home, config, server.port),
        ),
        verbose: true,
      );
      final sessionRef = session!;
      await sessionRef.start();
      await sessionRef.initialize('resume-agent-init-$phase');
      stdout.writeln('SESSION phase=$phase id=${sessionRef.sessionId}');
      sessionId = sessionRef.sessionId;
    }

    Future<Map<String, Object?>> hook(String toolName) async {
      final request = await session!.nextHook(toolName);
      final input =
          ((request['request'] as Map)['input'] as Map)['tool_input'] as Map;
      stdout.writeln(
        'HOOK $toolName input_keys=${input.keys.toList()..sort()}',
      );
      return request;
    }

    Future<void> decide(
      Map<String, Object?> request, {
      required bool allow,
    }) async {
      final input =
          ((request['request'] as Map)['input'] as Map)['tool_input'] as Map;
      session!.send({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': request['request_id'],
          'response': {
            'hookSpecificOutput': {
              'hookEventName': 'PreToolUse',
              'permissionDecision': allow ? 'allow' : 'deny',
              if (!allow)
                'permissionDecisionReason':
                    'Cancelled resume-agent SendMessage.',
            },
          },
        },
      });
      stdout.writeln(
        'DECISION ${input['description'] ?? input['summary'] ?? 'tool'} '
        '${allow ? 'allow' : 'deny'}',
      );
    }

    Future<Map<String, Object?>> finish() => session!.nextResult();
    Future<void> stop() async {
      await session?.close();
      session = null;
    }

    await start();
    session!.user('Create the isolated agent and remember its marker.', 'one');
    await decide(await hook('Agent'), allow: true);
    var result = await finish();
    _checkResult(result);
    sessionId = session!.sessionId;
    final id = fixture.agentId;
    if (id == null) throw StateError('No actual agentId in tool result');
    final childDeadline = DateTime.now().add(const Duration(seconds: 15));
    while (fixture.childRequests < 1 &&
        DateTime.now().isBefore(childDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (fixture.requests.length < 2 || fixture.childRequests < 1) {
      throw StateError('The child did not make its own model request');
    }
    await session!.next(
      (message) =>
          message['type'] == 'system' &&
          message['subtype'] == 'task_notification' &&
          message['task_id'] == id,
    );
    stdout.writeln('AGENT_ID $id');
    stdout.writeln('CHILD_WAITED true requests=${fixture.requests.length}');

    final childrenBeforeSend = fixture.childRequests;
    session!.user('Continue the returned agent by its actual ID.', 'two');
    final sendHook = await hook('SendMessage');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (fixture.childRequests != childrenBeforeSend) {
      throw StateError('SendMessage ran before its approval was resolved');
    }
    await decide(sendHook, allow: !deny);
    result = await finish();
    _checkResult(result);
    if (deny) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (fixture.childRequests != childrenBeforeSend) {
        throw StateError('Denied SendMessage started a child request');
      }
      stdout.writeln('DENIED_SEND_CHILD_REQUESTS 0');
      await stop();
    } else {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (fixture.childRequests <= childrenBeforeSend &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (fixture.childRequests <= childrenBeforeSend) {
        throw StateError('The second child request never arrived');
      }
      final second = fixture.requests.lastWhere(
        (request) => request['model'] == ResumeAgentFixture.model,
      );
      final history = jsonEncode(second['messages']);
      if (!history.contains(fixture.marker)) {
        throw StateError('The resumed request lacks the original marker');
      }
      if (fixture.resumedAgentId != id) {
        throw StateError(
          'SendMessage used ${fixture.resumedAgentId}, expected $id',
        );
      }
      if (fixture.deniedSend) {
        throw StateError('Allowed continuation contains a denial result');
      }
      final resumed = await session!.next(
        (message) =>
            message['type'] == 'system' &&
            message['subtype'] == 'task_started' &&
            message['tool_use_id'] == 'resume-agent-send',
      );
      if (resumed['task_id'] != id) {
        throw StateError('CLI started a different member on continuation');
      }
      stdout.writeln('SAME_AGENT_ID true');
      stdout.writeln('HISTORY_MARKER true');
      stdout.writeln('CHILD_MODEL ${second['model']}');
      await stop();
    }

    if (restart) {
      final previousId = sessionId;
      final childrenBeforeRestart = fixture.childRequests;
      await start(resume: previousId);
      session!.user('Continue the same agent after CLI restart.', 'three');
      await decide(await hook('SendMessage'), allow: true);
      result = await finish();
      _checkResult(result);
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (fixture.childRequests <= childrenBeforeRestart &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (fixture.childRequests <= childrenBeforeRestart ||
          session!.sessionId != previousId) {
        throw StateError('Restart continuation did not reach the child');
      }
      final third = fixture.requests.lastWhere(
        (request) => request['model'] == ResumeAgentFixture.model,
      );
      if (third['model'] != ResumeAgentFixture.model ||
          !jsonEncode(third['messages']).contains(fixture.marker)) {
        throw StateError('Restart lost the child model or marker history');
      }
      final restored = await session!.next(
        (message) =>
            message['type'] == 'system' &&
            message['subtype'] == 'task_started' &&
            message['tool_use_id'] == 'resume-agent-send',
      );
      if (restored['task_id'] != id) {
        throw StateError('Restart continuation created a different member');
      }
      stdout.writeln('RESTART_SAME_SESSION true');
      stdout.writeln('RESTART_SAME_AGENT true');
      stdout.writeln('RESTART_HISTORY_MARKER true');
      await stop();
    }
    stdout.writeln(
      'RESUME_RESULT PASS child_requests=${fixture.childRequests} '
      'model=${ResumeAgentFixture.model}',
    );
  } finally {
    await session?.close();
    await server.close(force: true);
    await serving;
    stdout.writeln('RESUME_DONE');
  }
}

Map<String, String> _isolatedEnvironment(
  Directory home,
  Directory config,
  int port,
) => {
  'PATH': Platform.environment['PATH'] ?? '',
  'SYSTEMROOT': Platform.environment['SYSTEMROOT'] ?? '',
  'COMSPEC': Platform.environment['COMSPEC'] ?? '',
  'PATHEXT': Platform.environment['PATHEXT'] ?? '',
  'TEMP': '${home.path}/temp',
  'TMP': '${home.path}/temp',
  'USERPROFILE': home.path,
  'HOME': home.path,
  'APPDATA': home.path,
  'LOCALAPPDATA': home.path,
  'CLAUDE_CONFIG_DIR': config.path,
  'ANTHROPIC_BASE_URL': 'http://127.0.0.1:$port',
  'ANTHROPIC_AUTH_TOKEN': 'local-resume-token-not-a-credential',
  'ANTHROPIC_API_KEY': '',
  'ANTHROPIC_MODEL': 'smoke-model',
  'ANTHROPIC_DEFAULT_HAIKU_MODEL': ResumeAgentFixture.model,
  'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
  'DISABLE_TELEMETRY': '1',
  'DISABLE_ERROR_REPORTING': '1',
  'NO_PROXY': '127.0.0.1,localhost',
  'no_proxy': '127.0.0.1,localhost',
  'HTTP_PROXY': '',
  'HTTPS_PROXY': '',
  'http_proxy': '',
  'https_proxy': '',
};

void _checkResult(Map<String, Object?> result) {
  if (result['is_error'] == true) {
    throw StateError('CLI failed: ${result['subtype']}');
  }
  stdout.writeln(
    'RESULT ok session=${result['session_id']} '
    'spawned=${(result['subagent_stats'] as Map?)?['spawned']}',
  );
}

class _ResumeCliSession {
  _ResumeCliSession(this.process, {required this.verbose});

  final Process process;
  final bool verbose;
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  final Map<String, Completer<void>> _initialized = {};
  final List<Map<String, Object?>> _pending = [];
  final List<StreamSubscription<Object?>> _subscriptions = [];
  String? sessionId;

  Future<void> start() async {
    stdout.writeln('PROCESS_STARTED ${process.pid}');
    process.exitCode.then((code) => stdout.writeln('PROCESS_EXIT $code'));
    _subscriptions.add(
      process.stderr.transform(utf8.decoder).listen((text) {
        stdout.write('STDERR $text');
      }),
    );
    _subscriptions.add(
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isEmpty) return;
            try {
              final message = (jsonDecode(line) as Map).cast<String, Object?>();
              if (message['type'] == 'control_response') {
                final response = message['response'] as Map;
                _initialized.remove(response['request_id'])?.complete();
              } else {
                if (message['type'] == 'system' &&
                    message['subtype'] == 'init') {
                  sessionId = message['session_id'] as String;
                }
                if (verbose ||
                    const {
                      'system',
                      'result',
                      'user',
                      'control_request',
                    }.contains(message['type'])) {
                  stdout.writeln('OUT ${_summary(message)}');
                }
                _pending.add(message);
                _messages.add(message);
              }
            } on FormatException {
              // Diagnostics are not protocol messages.
            }
          }),
    );
  }

  Future<void> initialize(String id) async {
    final done = Completer<void>();
    _initialized[id] = done;
    send({
      'type': 'control_request',
      'request_id': id,
      'request': {
        'subtype': 'initialize',
        'hooks': {
          'PreToolUse': [
            {
              'matcher': 'Agent|Task|SendMessage',
              'hookCallbackIds': ['resume-agent-approval'],
              'onFailure': 'block',
            },
          ],
        },
      },
    });
    await done.future.timeout(const Duration(seconds: 25));
    // The CLI sends system/init only after the first user message, not as
    // part of the control initialize response.
  }

  void user(String text, String suffix) => send({
    'type': 'user',
    'uuid': 'resume-agent-user-$suffix',
    'session_id': '',
    'parent_tool_use_id': null,
    'message': {'role': 'user', 'content': text},
  });

  Future<Map<String, Object?>> nextHook(String toolName) => next((message) {
    if (message['type'] != 'control_request') return false;
    final request = message['request'] as Map;
    return request['subtype'] == 'hook_callback' &&
        (request['input'] as Map)['tool_name'] == toolName;
  });

  Future<Map<String, Object?>> nextResult() =>
      next((message) => message['type'] == 'result');

  Future<Map<String, Object?>> next(
    bool Function(Map<String, Object?>) predicate,
  ) async {
    final index = _pending.indexWhere(predicate);
    if (index >= 0) return _pending.removeAt(index);
    final message = await _messages.stream
        .firstWhere(predicate)
        .timeout(const Duration(seconds: 35));
    _pending.remove(message);
    return message;
  }

  void send(Map<String, Object?> message) {
    stdout.writeln('IN ${jsonEncode(message)}');
    process.stdin.writeln(jsonEncode(message));
  }

  Future<void> close() async {
    try {
      await process.stdin.close();
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on StateError {
      process.kill(ProcessSignal.sigkill);
    }
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _messages.close();
  }

  static String _summary(Map<String, Object?> message) {
    final copy = {...message};
    copy.remove('message');
    copy.remove('tools');
    copy.remove('slash_commands');
    copy.remove('agents');
    copy.remove('skills');
    copy.remove('plugins');
    copy.remove('capabilities');
    if (copy['type'] == 'user') copy['message'] = '[tool result redacted]';
    return jsonEncode(copy);
  }
}
