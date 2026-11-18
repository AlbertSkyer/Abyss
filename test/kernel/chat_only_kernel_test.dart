import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/transcript.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

void main() {
  group('chatOnly Claude Code', () {
    test('launch has no built-in, SDK, or user MCP tools', () async {
      final cli = FakeCli();
      ClaudeLaunch? launch;
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(
          cwd: '/p',
          chatOnly: true,
          workspace: _toolsFromWorkspace,
        ),
        start: (requested) async {
          launch = requested;
          return cli;
        },
        providerEnvironment: (_, _) async => const {},
      );
      addTearDown(kernel.dispose);
      kernel.prepare();
      await pumpEventQueue(times: 30);

      expect(kernel.health.status, KernelHealthStatus.ready);
      expect(launch!.tools, isEmpty);
      expect(launch!.sdkServers, isEmpty);
      expect(launch!.userServers, isFalse);
      expect(launch!.subagentPool, isEmpty);
      expect(launch!.arguments, contains('--tools'));
      expect(launch!.arguments, contains('--strict-mcp-config'));
      expect(launch!.arguments, isNot(contains('--mcp-config')));
      final initialize = cli.requests('initialize').single;
      expect(initialize, isNot(contains('sdkMcpServers')));
      expect(initialize.containsKey('hooks'), AppEdition.isAbyss);
    });

    test('text still sends without dispatch context', () async {
      final cli = FakeCli();
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p', chatOnly: true),
        start: (_) async => cli,
        providerEnvironment: (_, _) async => const {},
      );
      addTearDown(kernel.dispose);
      kernel.send(const KernelTurn(id: 'u1', text: 'Only talk'));
      await pumpEventQueue(times: 30);
      expect(cli.users, hasLength(1));
      final content = (cli.users.single['message']! as Map)['content']! as List;
      expect(content, hasLength(2));
      final reminder = (content.first as Map)['text'] as String;
      expect(reminder, contains('chat-only temporary conversation'));
      expect(reminder, contains('Inherited messages are context'));
      expect(reminder, contains('natural language'));
      expect(reminder, contains('DSML/function_calls'));
      expect(reminder, contains('quote or explain tool-call syntax'));
      expect(content.last, const {'type': 'text', 'text': 'Only talk'});
      expect(content.toString(), isNot(contains('Abyss dispatch mode')));
    });

    test(
      'ordinary agent turns do not receive the temporary chat note',
      () async {
        final cli = FakeCli();
        final kernel = ClaudeCodeKernel(
          MockKernels.claudeCode,
          const KernelContext(cwd: '/p'),
          start: (_) async => cli,
          providerEnvironment: (_, _) async => const {},
        );
        addTearDown(kernel.dispose);
        kernel.send(const KernelTurn(id: 'main', text: 'Agent task'));
        await pumpEventQueue(times: 30);
        final content = (cli.users.single['message'] as Map)['content'] as List;
        expect(
          content.toString(),
          isNot(contains('chat-only temporary conversation')),
        );
        expect(content.last, {'type': 'text', 'text': 'Agent task'});
      },
    );

    test('quoted DSML stays inert text and user text is preserved', () async {
      const dsml =
          '<·DSML·><·DSML·function_calls><·DSML·invoke name="Bash">'
          '<·DSML·parameter name="command">do-not-run</·DSML·parameter>'
          '</·DSML·invoke></·DSML·function_calls>';
      final cli = FakeCli();
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p', chatOnly: true),
        start: (_) async => cli,
        providerEnvironment: (_, _) async => const {},
      );
      addTearDown(kernel.dispose);
      final transcript = Transcript();
      kernel.events.listen(transcript.apply);
      kernel.send(
        const KernelTurn(id: 'quote', text: 'Explain this syntax: $dsml'),
      );
      await pumpEventQueue(times: 30);
      expect(((cli.users.single['message'] as Map)['content'] as List).last, {
        'type': 'text',
        'text': 'Explain this syntax: $dsml',
      });
      final before = cli.written.length;
      cli.push({
        'type': 'assistant',
        'message': {
          'id': 'quoted-dsml',
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': dsml},
          ],
        },
      });
      await pumpEventQueue();
      final texts = [
        for (final (_, item) in transcript.liveItems)
          if (item is AssistantTextItem) item.text,
      ];
      expect(texts, contains(dsml));
      expect([
        for (final (_, item) in transcript.liveItems)
          if (item is ToolCallItem) item,
      ], isEmpty);
      expect(cli.written.length, before);
    });

    test('permission and hook requests deny every tool directly', () async {
      for (final request in [
        {
          'subtype': 'can_use_tool',
          'tool_name': 'Read',
          'input': const {'file_path': '/p/secret'},
        },
        {
          'subtype': 'can_use_tool',
          'tool_name': 'Agent',
          'input': const {'description': 'Delegate'},
        },
        {
          'subtype': 'hook_callback',
          'callback_id': 'baocode-approve-agent',
          'input': const {
            'hook_event_name': 'PreToolUse',
            'tool_name': 'SendMessage',
            'tool_input': {'recipient': 'member'},
          },
        },
      ]) {
        final cli = FakeCli();
        final kernel = ClaudeCodeKernel(
          MockKernels.claudeCode,
          const KernelContext(cwd: '/p', chatOnly: true),
          start: (_) async => cli,
          providerEnvironment: (_, _) async => const {},
        );
        kernel.prepare();
        await pumpEventQueue(times: 30);
        cli.push({
          'type': 'control_request',
          'request_id': 'tool-1',
          'request': request,
        });
        await pumpEventQueue();
        final response =
            ((cli.written.singleWhere(
                      (message) =>
                          message['type'] == 'control_response' &&
                          (message['response'] as Map)['request_id'] ==
                              'tool-1',
                    )['response']
                    as Map)['response']
                as Map);
        if (request['subtype'] == 'hook_callback') {
          expect(
            (response['hookSpecificOutput']! as Map)['permissionDecision'],
            'deny',
          );
        } else {
          expect(response['behavior'], 'deny');
        }
        expect(cli.users, isEmpty);
        kernel.dispose();
      }
    });

    test('app MCP messages are refused too', () async {
      final cli = FakeCli();
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p', chatOnly: true),
        start: (_) async => cli,
        providerEnvironment: (_, _) async => const {},
      );
      addTearDown(kernel.dispose);
      kernel.prepare();
      await pumpEventQueue(times: 30);
      cli.push({
        'type': 'control_request',
        'request_id': 'mcp-1',
        'request': {
          'subtype': 'mcp_message',
          'server_name': 'baocode',
          'message': const {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'},
        },
      });
      await pumpEventQueue();
      expect(
        cli.written.any(
          (message) =>
              message['type'] == 'control_response' &&
              (message['response']! as Map)['request_id'] == 'mcp-1' &&
              (message['response']! as Map)['subtype'] == 'error',
        ),
        isTrue,
      );
    });
  });
}

KernelWorkspace _toolsFromWorkspace() => const KernelWorkspace(
  folders: [],
  tools: ['Read', 'Write', 'Agent'],
  userServers: true,
  allowedTools: ['Read'],
);
