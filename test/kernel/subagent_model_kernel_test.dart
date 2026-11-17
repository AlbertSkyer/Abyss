import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/claude_code/agent_task_ledger.dart';
import 'package:baocode/chat/widgets/agent_step.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_translator.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/kernel/transcript.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/settings/abyss_workbench_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

// Two upstreams with a model of one id, as relays often have.
const _first = ModelProvider(
  id: 'ap',
  name: 'apicc',
  protocol: ProviderProtocol.openaiResponses,
  baseUrl: 'https://ap.example.com/v1',
  models: [ProviderModel(id: 'gpt-6.1-sol', label: 'apicc GPT-6.1')],
);

const _second = ModelProvider(
  id: 'fx',
  name: 'fluxapi',
  protocol: ProviderProtocol.openaiResponses,
  baseUrl: 'https://fx.example.com/v1',
  models: [
    ProviderModel(id: 'gpt-6.1-sol', label: 'fluxapi GPT-6.1'),
    ProviderModel(id: 'gpt-6.1-mini'),
  ],
);

const _providers = [_first, _second];

void main() {
  final automatic = AbyssWorkbenchSettings.automatic;
  final concurrency = AbyssWorkbenchSettings.autoDispatchConcurrency;
  setUp(() {
    AbyssWorkbenchSettings.automatic = () => false;
    AbyssWorkbenchSettings.autoDispatchConcurrency = () => 3;
  });
  tearDown(() {
    AbyssWorkbenchSettings.automatic = automatic;
    AbyssWorkbenchSettings.autoDispatchConcurrency = concurrency;
  });
  test('Abyss routes selected pool models through CLI aliases without changing agent type', () async {
    final providers = ModelProviders.memory(providers: _providers);
    await providers.setSubagentPool(['@fx/gpt-6.1-sol', '@ap/gpt-6.1-sol']);
    late FakeCli cli;
    late ClaudeLaunch launched;
    final kernel = ClaudeCodeKernel(
      MockKernels.claudeCode,
      const KernelContext(cwd: '/p', settings: {'model': '@fx/gpt-6.1-sol'}),
      start: (launch) async {
        launched = launch;
        return cli = FakeCli();
      },
      providers: providers,
      providerEnvironment: (provider, model) async => {
        'ANTHROPIC_BASE_URL': 'http://local-proxy',
        'ANTHROPIC_MODEL': model,
      },
    );
    addTearDown(kernel.dispose);
    final transcript = Transcript();
    kernel.events.listen(transcript.apply);
    kernel.prepare();
    await pumpEventQueue(times: 20);
    expect(launched.env!['ANTHROPIC_DEFAULT_SONNET_MODEL'], 'gpt-6.1-sol');
    expect(launched.env!['ANTHROPIC_DEFAULT_OPUS_MODEL'], '@ap/gpt-6.1-sol');
    expect(launched.env!['ANTHROPIC_MODEL'], launched.model);
    cli.push({
      'type': 'control_request',
      'request_id': 'pool-hook',
      'request': {
        'subtype': 'hook_callback',
        'callback_id': 'baocode-approve-agent',
        'input': {
          'tool_name': 'Agent',
          'tool_input': {
            'description': 'Read files',
            'prompt': 'Read only.',
            'subagent_type': 'Explore',
          },
        },
      },
    });
    await pumpEventQueue();
    final approval = transcript.pendingInteraction as AgentApprovalRequest;
    expect(approval.models, ['@fx/gpt-6.1-sol', '@ap/gpt-6.1-sol']);
    kernel.answer(
      approval.id,
      const ApprovalAnswer(
        ApprovalDecision.allowOnce,
        model: '@ap/gpt-6.1-sol',
      ),
    );
    final response = cli.written.last['response'] as Map;
    final output = (response['response'] as Map)['hookSpecificOutput'] as Map;
    expect(output['updatedInput'], {
      'description': 'Read files',
      'prompt': 'Read only.',
      'subagent_type': 'Explore',
      'model': 'opus',
    });
  }, skip: !AppEdition.isAbyss);

  test(
    'automatic dispatch validates the parent choice without a dialog',
    () async {
      AbyssWorkbenchSettings.automatic = () => true;
      final providers = ModelProviders.memory(providers: _providers);
      await providers.setSubagentPool(['@fx/gpt-6.1-sol', '@ap/gpt-6.1-sol']);
      final cli = FakeCli();
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p', settings: {'model': '@fx/gpt-6.1-sol'}),
        start: (_) async => cli,
        providers: providers,
        providerEnvironment: (_, model) async => {'ANTHROPIC_MODEL': model},
      );
      addTearDown(kernel.dispose);
      final transcript = Transcript();
      kernel.events.listen(transcript.apply);
      kernel.prepare();
      await pumpEventQueue(times: 20);
      void hook(String id, String? model) => cli.push({
        'type': 'control_request',
        'request_id': id,
        'request': {
          'subtype': 'hook_callback',
          'callback_id': 'baocode-approve-agent',
          'input': {
            'tool_name': 'Agent',
            'tool_use_id': id,
            'tool_input': {
              'description': 'Independent analysis',
              'prompt': 'Read only',
              'subagent_type': 'general-purpose',
              'model': ?model,
            },
          },
        },
      });
      hook('allowed', '@ap/gpt-6.1-sol');
      await pumpEventQueue();
      expect(transcript.pendingInteraction, isNull);
      Map output() =>
          ((cli.written.lastWhere(
                        (m) => m['type'] == 'control_response',
                      )['response']
                      as Map)['response']
                  as Map)['hookSpecificOutput']
              as Map;
      expect(output()['permissionDecision'], 'allow');
      expect((output()['updatedInput'] as Map)['model'], 'opus');
      hook('missing-choice', null);
      await pumpEventQueue();
      expect(output()['permissionDecision'], 'deny');
      hook('outside-pool', '@unknown/model');
      await pumpEventQueue();
      expect(output()['permissionDecision'], 'deny');
      hook('slot-two', 'opus');
      hook('slot-three', 'opus');
      await pumpEventQueue();
      expect(output()['permissionDecision'], 'allow');
      hook('slot-four', 'opus');
      await pumpEventQueue();
      expect(output()['permissionDecision'], 'deny');
      AbyssWorkbenchSettings.automatic = () => false;
      hook('manual', '@ap/gpt-6.1-sol');
      await pumpEventQueue();
      expect(transcript.pendingInteraction, isA<AgentApprovalRequest>());
      AbyssWorkbenchSettings.automatic = () => true;
      expect(transcript.pendingInteraction, isNotNull);
    },
    skip: !AppEdition.isAbyss,
  );

  for (final initialLimit in [1, 2, 5]) {
    test(
      'automatic concurrency $initialLimit counts starts and running tasks live',
      () async {
        var limit = initialLimit;
        AbyssWorkbenchSettings.automatic = () => true;
        AbyssWorkbenchSettings.autoDispatchConcurrency = () => limit;
        final directory = await Directory.systemTemp.createTemp(
          'abyss-concurrency',
        );
        final ledger = await AgentTaskLedger.open(
          path: '${directory.path}/ledger.json',
        );
        final providers = ModelProviders.memory(providers: _providers);
        await providers.setSubagentPool(['@fx/gpt-6.1-sol']);
        final cli = FakeCli();
        final kernel = ClaudeCodeKernel(
          MockKernels.claudeCode,
          const KernelContext(
            cwd: '/p',
            settings: {'model': '@fx/gpt-6.1-sol'},
          ),
          start: (_) async => cli,
          providers: providers,
          taskLedger: Future.value(ledger),
          providerEnvironment: (_, model) async => {'ANTHROPIC_MODEL': model},
        );
        addTearDown(() async {
          kernel.dispose();
          await kernel.stopped;
          await ledger.flush();
          await directory.delete(recursive: true);
        });
        kernel.send(
          const KernelTurn(
            id: 'dispatch-turn',
            text: 'Analyze independent tasks',
          ),
        );
        await pumpEventQueue(times: 20);
        expect(
          cli.users.toString(),
          contains('concurrency limit for this main session: $initialLimit'),
        );
        cli.push({
          'type': 'system',
          'subtype': 'init',
          'session_id': 'concurrency-session',
        });
        await pumpEventQueue();

        Future<Map> dispatch(String id) async {
          cli.push({
            'type': 'control_request',
            'request_id': id,
            'request': {
              'subtype': 'hook_callback',
              'callback_id': 'baocode-approve-agent',
              'input': {
                'tool_name': 'Agent',
                'tool_use_id': id,
                'tool_input': {
                  'description': 'Independent task',
                  'prompt': 'Read only',
                  'subagent_type': 'general-purpose',
                  'model': 'sonnet',
                },
              },
            },
          });
          await pumpEventQueue();
          return cli.responses.last['hookSpecificOutput'] as Map;
        }

        for (var i = 0; i < initialLimit; i++) {
          expect((await dispatch('start-$i'))['permissionDecision'], 'allow');
        }
        expect((await dispatch('full'))['permissionDecision'], 'deny');
        cli.push({
          'type': 'system',
          'subtype': 'task_started',
          'task_id': 'member-first',
          'task_type': 'local_agent',
          'tool_use_id': 'start-0',
          'model': '@fx/gpt-6.1-sol',
        });
        await pumpEventQueue();
        expect(
          ledger.tasksFor('concurrency-session').single.status,
          AgentTaskStatus.running,
        );
        // Moving a reservation to the running ledger must neither free nor double-count it.
        expect((await dispatch('still-full'))['permissionDecision'], 'deny');
        limit++;
        expect((await dispatch('raised'))['permissionDecision'], 'allow');
        expect((await dispatch('raised-full'))['permissionDecision'], 'deny');
        limit = 1;
        final denied = await dispatch('lowered');
        expect(denied['permissionDecision'], 'deny');
        expect(denied['permissionDecisionReason'], contains('(limit: 1)'));
        expect(
          ledger.tasksFor('concurrency-session').single.status,
          AgentTaskStatus.running,
        );
        expect(cli.requests('interrupt'), isEmpty);

        // Failed starts release reservations, but lowering must leave running work alone.
        for (final id in [
          for (var i = 1; i < initialLimit; i++) 'start-$i',
          'raised',
        ]) {
          cli.push({
            'type': 'user',
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': id,
                  'is_error': true,
                  'content': 'Start failed',
                },
              ],
            },
          });
        }
        await pumpEventQueue();
        expect((await dispatch('running-full'))['permissionDecision'], 'deny');
        cli.push({
          'type': 'system',
          'subtype': 'task_notification',
          'task_id': 'member-first',
          'tool_use_id': 'start-0',
          'status': 'completed',
        });
        await pumpEventQueue();
        expect(
          ledger.tasksFor('concurrency-session').single.status,
          AgentTaskStatus.completed,
        );
        expect(
          (await dispatch('after-completion'))['permissionDecision'],
          'allow',
        );
      },
      skip: !AppEdition.isAbyss,
    );
  }

  test('a subagent\'s model, a bare id, is the upstream\'s the session is '
      'on, not the first with a model of that id', () async {
    late FakeCli cli;
    final kernel = ClaudeCodeKernel(
      MockKernels.claudeCode,
      const KernelContext(cwd: '/p', settings: {'model': '@fx/gpt-6.1-sol'}),
      start: (_) async => cli = FakeCli(),
      providers: ModelProviders.memory(providers: _providers),
      providerEnvironment: (provider, model) async => {
        'ANTHROPIC_BASE_URL': 'http://proxy/${provider.id}',
      },
    );
    addTearDown(kernel.dispose);
    final transcript = Transcript();
    kernel.events.listen(transcript.apply);
    kernel.prepare();
    await pumpEventQueue();

    void agent(String id) => cli.push({
      'type': 'assistant',
      'parent_tool_use_id': null,
      'message': {
        'id': 'msg-$id',
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': id,
            'name': 'Agent',
            'input': {'description': 'Look $id', 'prompt': 'look'},
          },
        ],
      },
    });
    void said(String parent, String model) => cli.push({
      'type': 'assistant',
      'parent_tool_use_id': parent,
      'message': {
        'id': 'msg-$parent',
        'role': 'assistant',
        'model': model,
        'content': [
          {'type': 'text', 'text': 'looking'},
        ],
      },
    });
    String? model(String id) => [
      for (final (key, item) in transcript.liveItems)
        if (key == id && item is AgentItem) item.model,
    ].single;

    agent('a1');
    said('a1', 'gpt-6.1-sol');
    // Another upstream's, set for subagents: the proxy sent it there.
    agent('a2');
    said('a2', '@ap/gpt-6.1-sol');
    // None of the session's upstream: as it is.
    agent('a3');
    said('a3', 'glm-5.3');
    await pumpEventQueue();

    expect(model('a1'), '@fx/gpt-6.1-sol');
    expect(model('a2'), '@ap/gpt-6.1-sol');
    expect(model('a3'), 'glm-5.3');
    final shown = AgentStep.modelName(
      model('a1')!,
      providers: ModelProviders.memory(providers: _providers),
    );
    expect(shown, (label: 'fluxapi GPT-6.1', upstream: 'fluxapi'));
  });

  test('the subagent pool reaches the launch: the session upstream\'s own '
      'models by id, another\'s as a ref, gone and off left out', () async {
    late ClaudeLaunch launched;
    final providers = ModelProviders.memory(providers: _providers);
    await providers.setSubagentPool([
      '@fx/gpt-6.1-sol',
      '@ap/gpt-6.1-sol',
      '@gone/gpt-6.1-sol',
      '@fx/gpt-6.1-mini',
    ]);
    final kernel = ClaudeCodeKernel(
      MockKernels.claudeCode,
      const KernelContext(cwd: '/p', settings: {'model': '@fx/gpt-6.1-sol'}),
      start: (launch) async {
        launched = launch;
        return FakeCli();
      },
      providers: providers,
      providerEnvironment: (provider, model) async => {
        'ANTHROPIC_BASE_URL': 'http://proxy/${provider.id}',
      },
    );
    addTearDown(kernel.dispose);
    kernel.prepare();
    await pumpEventQueue(times: 20);

    expect(launched.subagentPool, [
      'gpt-6.1-sol',
      '@ap/gpt-6.1-sol',
      'gpt-6.1-mini',
    ]);
  });

  test('a subagent\'s assigned model is kept apart from what its upstream '
      'answered with', () async {
    final transcript = Transcript();
    var seq = 0;
    final translator = ClaudeTranslator(
      emit: transcript.apply,
      nextSeq: () => ++seq,
    );
    translator.translate({
      'type': 'assistant',
      'parent_tool_use_id': null,
      'message': {
        'id': 'msg-main',
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': 'call-1',
            'name': 'Agent',
            'input': {'description': 'Look', 'prompt': 'look'},
          },
        ],
      },
    });
    // What it was assigned, before it says anything.
    translator.translate({
      'type': 'system',
      'subtype': 'task_started',
      'task_id': 'a1',
      'task_type': 'local_agent',
      'tool_use_id': 'call-1',
      'description': 'Look',
      'model': '@ap/gpt-6.1-sol',
      'requested_model': 'haiku',
    });
    // What its upstream answered with: its own name for the model.
    translator.translate({
      'type': 'assistant',
      'parent_tool_use_id': 'call-1',
      'message': {
        'id': 'msg-sub',
        'role': 'assistant',
        'model': 'gpt-6.1-sol',
        'content': [
          {'type': 'text', 'text': 'looking'},
        ],
      },
    });
    // Its result carries the assignment too; the actual model is not
    // overwritten by it.
    translator.translate({
      'type': 'user',
      'parent_tool_use_id': null,
      'message': {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'call-1',
            'content': 'looking',
          },
        ],
      },
      'tool_use_result': {
        'status': 'completed',
        'assignedModel': '@ap/gpt-6.1-sol',
        'resolvedModel': '@ap/gpt-6.1-sol',
        'requestedModel': 'haiku',
        'modelSource': 'pool',
      },
    });
    final agent = [
      for (final (_, item) in transcript.liveItems)
        if (item is AgentItem) item,
    ].single;
    expect(agent.assignedModel, '@ap/gpt-6.1-sol');
    expect(agent.requestedModel, 'haiku');
    // As its upstream answered, kept apart: not replaced by the assignment.
    expect(agent.model, 'gpt-6.1-sol');
  });
}
