import 'package:flutter/material.dart';

import '../../kernel/kernel_types.dart';
import 'interaction_panel.dart';

/// The result of the one dialog which owns [request].
///
/// Dismissing it explicitly denies the child. Closing it because its request
/// changed or its host went away returns null, never an implicit answer.
class AgentApprovalDialogResult {
  const AgentApprovalDialogResult(this.requestId, this.answer);

  final String requestId;
  final ApprovalAnswer? answer;
}

/// A child agent's approval, in the same panel as its inline presentation.
class AgentApprovalDialog extends StatelessWidget {
  const AgentApprovalDialog({super.key, required this.request});

  final AgentApprovalRequest request;

  void _close(BuildContext context, [ApprovalAnswer? answer]) {
    Navigator.of(context).pop(AgentApprovalDialogResult(request.id, answer));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: InteractionPanel(
            request: request,
            onAnswer: (answer) {
              if (answer case final ApprovalAnswer answer) {
                _close(context, answer);
              }
            },
          ),
        ),
      ),
    );
  }
}
