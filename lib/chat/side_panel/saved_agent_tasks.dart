import 'package:flutter/material.dart';

import '../../kernel/kernel_types.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../chat_session.dart';
import '../widgets/agent_step.dart';
import 'side_panel_controller.dart';

/// Durable run records are an index, not synthetic transcript AgentItems.
class SavedAgentTasks extends StatelessWidget {
  const SavedAgentTasks({
    super.key,
    required this.panel,
    required this.session,
  });
  final AgentSidePanel panel;
  final ChatSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final memberId = panel.tabsOf(session).agentMemberId;
    final tasks = session.agentTasks
        .where((task) => memberId == null || task.memberId == memberId)
        .toList();
    final indexed = {
      for (final task in session.agentTasks) ...[task.toolUseId, ?task.cardId],
    };
    final legacy = memberId == null
        ? session.agentTree
              .where(
                (entry) =>
                    entry.depth == 0 && !indexed.contains(entry.agent.id),
              )
              .toList()
        : const [];
    final member = session.agentMembers
        .where((member) => member.id == memberId)
        .firstOrNull;
    return Column(
      key: const ValueKey(('page', SidePanelSection.agents)),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  member?.name ?? l10n.sidePanelAgentTasks,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (memberId != null)
                TextButton(
                  key: const ValueKey('agent-tasks-all'),
                  onPressed: () => panel.showAgentTasks(session),
                  child: Text(l10n.agentTasksAll),
                ),
            ],
          ),
        ),
        if (session.loadingAgentTasks) const LinearProgressIndicator(),
        if (session.agentTasksError case final error?)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('${l10n.agentTasksLoadFailed}\n$error'),
          ),
        Expanded(
          child: tasks.isEmpty && legacy.isEmpty
              ? Center(
                  child: Text(
                    session.loadingAgentTasks
                        ? l10n.agentTasksLoading
                        : l10n.agentTasksMemberEmpty,
                  ),
                )
              : ListView(
                  children: [
                    for (final task in tasks.reversed)
                      _SavedRun(
                        key: ValueKey((session, task.toolUseId)),
                        session: session,
                        task: task,
                      ),
                    for (final entry in legacy)
                      ListTile(
                        title: Text(entry.agent.description),
                        onTap: () => session.openAgentPath(entry.path),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _SavedRun extends StatefulWidget {
  const _SavedRun({super.key, required this.session, required this.task});
  final ChatSession session;
  final KernelAgentTask task;
  @override
  State<_SavedRun> createState() => _SavedRunState();
}

class _SavedRunState extends State<_SavedRun> {
  bool _reading = false;
  bool _attempted = false;
  bool _failed = false;

  Future<void> _read() async {
    if (_reading) return;
    setState(() {
      _reading = true;
      _failed = false;
    });
    try {
      final session = widget.session;
      final task = widget.task;
      await session.loadAgentTaskHistory(
        task,
        shouldContinue: () =>
            mounted &&
            identical(widget.session, session) &&
            widget.task.toolUseId == task.toolUseId,
      );
      if (!mounted) return;
      setState(() => _attempted = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final task = widget.task;
    final session = widget.session;
    final path = session.agentTaskPath(task);
    final status = switch (task.status) {
      KernelAgentTaskStatus.running => l10n.sidePanelAgentRunning,
      KernelAgentTaskStatus.completed => l10n.sidePanelAgentDone,
      KernelAgentTaskStatus.failed => l10n.sidePanelAgentFailed,
      KernelAgentTaskStatus.cancelled => l10n.sidePanelAgentCancelled,
      KernelAgentTaskStatus.interrupted => l10n.sidePanelAgentInterrupted,
    };
    final model = AgentStep.modelName(task.model ?? '');
    return ExpansionTile(
      key: ValueKey(('saved-task', task.toolUseId)),
      title: Text(
        task.description?.trim().isNotEmpty == true
            ? task.description!
            : task.taskId,
      ),
      subtitle: Text(
        [
          status,
          if (task.model != null) model.label,
          if (task.runId != null) task.runId!,
        ].join(' · '),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.agentTasksReport,
          style: TextStyle(color: AppColors.textFaint, fontSize: 12),
        ),
        const SizedBox(height: 6),
        SelectableText(
          task.result?.trim().isNotEmpty == true
              ? task.result!
              : l10n.agentTasksNoReport,
        ),
        const SizedBox(height: 8),
        if (task.status == KernelAgentTaskStatus.running)
          if (session.stopOf(task.cardId ?? task.toolUseId) case final stop?)
            TextButton(onPressed: stop, child: Text(l10n.chatStop)),
        if (_reading) ...[
          const LinearProgressIndicator(),
          Text(l10n.agentTasksLoading),
        ] else if (path != null)
          TextButton(
            onPressed: () => session.openAgentPath(path),
            child: Text(l10n.agentTasksOpenDetails),
          )
        else ...[
          Text(
            _failed
                ? l10n.agentTasksLoadFailed
                : session.hasEarlierHistory || session.loadingHistory
                ? l10n.agentTasksEarlierDetails
                : l10n.agentTasksMissingHistory,
          ),
          if (session.hasEarlierHistory || session.loadingHistory || _failed)
            TextButton(
              key: ValueKey(('read-task-history', task.toolUseId)),
              onPressed: _read,
              child: Text(
                _attempted
                    ? l10n.agentTasksLoadEarlier
                    : l10n.agentTasksReadDetails,
              ),
            ),
        ],
      ],
    );
  }
}

/// A plain transcript board must not confuse an unread page with no tasks.
class AgentHistoryAvailability extends StatefulWidget {
  const AgentHistoryAvailability({super.key, required this.session});
  final ChatSession session;
  @override
  State<AgentHistoryAvailability> createState() =>
      _AgentHistoryAvailabilityState();
}

class _AgentHistoryAvailabilityState extends State<AgentHistoryAvailability> {
  bool _reading = false;
  bool _failed = false;

  Future<void> _read() async {
    if (_reading) return;
    setState(() {
      _reading = true;
      _failed = false;
    });
    try {
      await widget.session.loadEarlier();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final loading =
        _reading ||
        widget.session.loadingHistory ||
        widget.session.loadingEarlier;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading) const CircularProgressIndicator(),
            Text(
              loading
                  ? l10n.agentTasksLoading
                  : _failed
                  ? l10n.agentTasksLoadFailed
                  : l10n.agentTasksEarlierDetails,
            ),
            if (!loading && widget.session.hasEarlierHistory)
              TextButton(
                onPressed: _read,
                child: Text(l10n.agentTasksLoadEarlier),
              ),
          ],
        ),
      ),
    );
  }
}
