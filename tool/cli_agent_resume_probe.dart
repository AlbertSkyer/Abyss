import 'dart:convert';
import 'dart:math';

/// Pure, local-only fixture for the real-CLI agent continuation probe.
///
/// The CLI is authoritative about Agent and SendMessage. In particular, this
/// never guesses an Agent resume field: a new SendMessage input is generated
/// only from the tool call produced by the CLI's model response.
class ResumeAgentFixture {
  ResumeAgentFixture({Random? random}) : marker = _marker(random ?? Random());

  static const model = '@other/provider-model';
  static const childModel = 'resume-child-model';

  final String marker;
  final List<Map<String, Object?>> requests = [];
  final List<Map<String, Object?>> toolCalls = [];
  String? agentId;
  String? resumedAgentId;
  bool deniedSend = false;

  int get childRequests =>
      requests.where((request) => request['model'] == model).length;

  static String _marker(Random random) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final suffix = List.generate(
      12,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
    return 'ABYSS-RESUME-$suffix';
  }

  Map<String, Object?> reply(Object? body) {
    final request = (body as Map).cast<String, Object?>();
    requests.add(request);
    final child = request['model'] == model;
    final messages = request['messages'] as List? ?? const [];
    final tools = _toolUses(messages);
    final results = _toolResults(messages);
    if (!child && tools.isEmpty && results.isEmpty) {
      return _agent();
    }
    if (!child) {
      for (final result in results) {
        if (result['tool_use_id'] != 'resume-agent-create') continue;
        final metadata = result['tool_use_result'];
        if (metadata is Map) agentId = metadata['agentId'] as String?;
        agentId ??= RegExp(r'agentId:\s*([A-Za-z0-9_-]+)')
            .firstMatch(_text(result['content']))
            ?.group(1);
        if (agentId == null || agentId!.isEmpty) {
          throw StateError('The real Agent result has no agentId');
        }
        final latest = messages.lastWhere(
          (message) => message is Map && message['role'] == 'user',
          orElse: () => const {},
        );
        if (latest is Map && _text(latest['content']).contains('Continue')) {
          return _sendMessage(agentId!);
        }
      }
    }
    final send = tools.where((tool) => tool['name'] == 'SendMessage').toList();
    if (send.isNotEmpty) {
      if (send.length != 1) {
        throw StateError('Unexpected duplicate SendMessage calls');
      }
      toolCalls.add(send.single);
      final input = (send.single['input'] as Map).cast<String, Object?>();
      resumedAgentId =
          '${input['to'] ?? input['recipient'] ?? input['agentId']}';
      deniedSend = messages.any(
        (message) =>
            message is Map &&
            jsonEncode(message).contains('Cancelled resume-agent SendMessage'),
      );
    }
    return _textReply(child ? marker : 'RESUME-PARENT-DONE');
  }

  Map<String, Object?> _agent() => _toolReply('Agent', 'resume-agent-create', {
    'description': 'Remember a local probe marker',
    'prompt':
        'Remember this exact marker for a later continuation: $marker. '
        'Do not use tools. Reply with the marker only.',
    'subagent_type': 'general-purpose',
    'model': 'haiku',
  });

  Map<String, Object?> _sendMessage(String id) =>
      _toolReply('SendMessage', 'resume-agent-send', {
        'to': id,
        'summary': 'Repeat the remembered local marker',
        'message': 'Repeat the exact marker I asked you to remember. No tools.',
      });

  Map<String, Object?> _toolReply(
    String name,
    String id,
    Map<String, Object?> input,
  ) => {
    'id': 'msg_${requests.length}',
    'type': 'message',
    'role': 'assistant',
    'model': 'resume-parent-model',
    'stop_reason': 'tool_use',
    'stop_sequence': null,
    'content': [
      {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
    ],
    'usage': {'input_tokens': 1, 'output_tokens': 1},
  };

  Map<String, Object?> _textReply(String text) => {
    'id': 'msg_${requests.length}',
    'type': 'message',
    'role': 'assistant',
    'model': 'resume-probe-model',
    'stop_reason': 'end_turn',
    'stop_sequence': null,
    'content': [
      {'type': 'text', 'text': text},
    ],
    'usage': {'input_tokens': 1, 'output_tokens': 1},
  };

  static List<Map<String, Object?>> _toolUses(List messages) => [
    for (final message in messages)
      if (message is Map &&
          message['role'] == 'assistant' &&
          message['content'] is List)
        for (final block in message['content'] as List)
          if (block is Map && block['type'] == 'tool_use')
            block.cast<String, Object?>(),
  ];

  static List<Map<String, Object?>> _toolResults(List messages) => [
    for (final message in messages)
      if (message is Map &&
          message['role'] == 'user' &&
          message['content'] is List)
        for (final block in message['content'] as List)
          if (block is Map && block['type'] == 'tool_result')
            block.cast<String, Object?>(),
  ];

  static String _text(Object? content) => content is List
      ? content
            .whereType<Map>()
            .map((block) => '${block['text'] ?? ''}')
            .join('\n')
      : '$content';
}
