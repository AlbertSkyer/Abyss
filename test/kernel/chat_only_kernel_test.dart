import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
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
      expect(initialize, contains('hooks'));
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
      expect(content, [
        const {'type': 'text', 'text': 'Only talk'},
      ]);
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
            'tool_input': const {'recipient': 'member'},
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
