import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_dialog.dart';
import '../../kernel/kernel_types.dart';
import '../../models/model_providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/agent_step.dart';

/// Host-managed members. Editing their identity or availability does not
/// send a message, dispatch work, or stop a running task.
class AgentTeamPage extends StatelessWidget {
  const AgentTeamPage({
    super.key,
    required this.members,
    required this.onUpdate,
    required this.onShowTasks,
    required this.statusLabel,
    required this.description,
    required this.emptyLabel,
    required this.editLabel,
    required this.saveLabel,
    required this.nameLabel,
    required this.roleLabel,
    required this.disableLabel,
    required this.enableLabel,
    required this.archiveLabel,
    required this.unarchiveLabel,
    required this.showTasksLabel,
    required this.tasksLabel,
  });

  final List<KernelAgentMember> members;
  final void Function(
    String id, {
    String? name,
    String? role,
    bool? enabled,
    bool? archived,
  })
  onUpdate;
  final ValueChanged<String> onShowTasks;
  final String Function(AgentMemberStatus status) statusLabel;
  final String description;
  final String emptyLabel;
  final String editLabel;
  final String saveLabel;
  final String nameLabel;
  final String roleLabel;
  final String disableLabel;
  final String enableLabel;
  final String archiveLabel;
  final String unarchiveLabel;
  final String showTasksLabel;
  final String Function(int count) tasksLabel;

  Future<void> _edit(BuildContext context, KernelAgentMember member) async {
    final result = await showIdeInputDialog(
      context,
      message: member.name,
      buttons: [saveLabel],
      inputs: [
        IdeDialogInput(placeholder: nameLabel, value: member.name),
        IdeDialogInput(placeholder: roleLabel, value: member.role),
      ],
      type: IdeDialogType.question,
    );
    if (result == null || result.button != 0) return;
    final name = result.values[0].trim();
    final role = result.values[1].trim();
    if (name.isEmpty || (name == member.name && role == member.role)) return;
    onUpdate(member.id, name: name, role: role);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Text(
            description,
            style: TextStyle(
              color: AppColors.textFaint,
              fontSize: 11,
              height: 1.4,
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: members.isEmpty
              ? Center(
                  child: Text(
                    emptyLabel,
                    style: TextStyle(
                      color: AppColors.textFaint,
                      fontSize: 12.5,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: members.length,
                  itemBuilder: (context, index) {
                    final member = members[index];
                    return _MemberRow(
                      key: ValueKey(('team-member', member.id)),
                      member: member,
                      page: this,
                      onEdit: () => _edit(context, member),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    super.key,
    required this.member,
    required this.page,
    required this.onEdit,
  });

  final KernelAgentMember member;
  final AgentTeamPage page;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final model = switch (member.model) {
      final model? when model.trim().isNotEmpty => AgentStep.modelName(
        model,
        providers: ModelProviders.current,
      ),
      _ => null,
    };
    final modelLabel = model == null
        ? null
        : model.upstream == null
        ? model.label
        : '${model.label} · ${model.upstream}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  member.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: member.enabled
                        ? AppColors.textPrimary
                        : AppColors.textFaint,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                page.statusLabel(member.status),
                key: ValueKey(('team-member-status', member.id)),
                style: TextStyle(color: AppColors.textFaint, fontSize: 11),
              ),
            ],
          ),
          if (member.role.isNotEmpty || modelLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                [
                  if (member.role.isNotEmpty) member.role,
                  ?modelLabel,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.textFaint, fontSize: 11),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IdeButton(
                  label: page.editLabel,
                  onPressed: onEdit,
                  secondary: true,
                ),
                IdeButton(
                  label: member.enabled ? page.disableLabel : page.enableLabel,
                  onPressed: () =>
                      page.onUpdate(member.id, enabled: !member.enabled),
                  secondary: true,
                ),
                if (member.status != AgentMemberStatus.running)
                  IdeButton(
                    label: member.archived
                        ? page.unarchiveLabel
                        : page.archiveLabel,
                    onPressed: () =>
                        page.onUpdate(member.id, archived: !member.archived),
                    secondary: true,
                  ),
                TextButton(
                  key: ValueKey(('team-member-tasks', member.id)),
                  onPressed: () => page.onShowTasks(member.id),
                  child: Text(
                    '${page.showTasksLabel} · ${page.tasksLabel(member.tasks)}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
