import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/claude_code/claude_code_translator.dart';
import 'package:baocode/kernel/transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final status in ['completed', 'failed', 'interrupted']) {
    test('restored root agent retains its $status report', () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      );
      translator.translate({
        'type': 'system',
        'subtype': 'task_started',
        'task_id': 'restored-root',
        'task_type': 'local_agent',
        'description': 'Read-only prior task',
        'read_only': true,
        'status': status,
        'result': 'Prior task report: $status',
      });

      final agent = [
        for (final (_, item) in transcript.liveItems)
          if (item is AgentItem) item,
      ].single;
      expect(agent.result, 'Prior task report: $status');
      expect(agent.readOnly, isTrue);
      expect(agent.status, switch (status) {
        'completed' => CommandStatus.succeeded,
        'failed' => CommandStatus.failed,
        _ => CommandStatus.interrupted,
      });
    });
  }
}
