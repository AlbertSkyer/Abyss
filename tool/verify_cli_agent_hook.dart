import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Deterministic local-only Claude Code protocol probe. No real credentials or
// upstream requests: all model requests are answered by this process.
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first.startsWith('--')) {
    throw ArgumentError(
      'Usage: dart tool/verify_cli_agent_hook.dart CLI_PATH '
      '[--deny|--alias|--full-model|--definition]',
    );
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
