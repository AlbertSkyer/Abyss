import 'package:flutter/material.dart';

import '../../ide/ide_hover.dart';
import '../../l10n/l10n.dart';
import '../../models/model_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../chat_models.dart';
import '../chat_feed.dart';
import '../chat_session.dart';
import '../agent_view.dart';
import '../widgets/agent_step.dart';
import '../widgets/hover_builder.dart';
import '../widgets/pixel_loader.dart';
import 'side_panel_controller.dart';

/// The conversation's child agents (Agent/Task), read-only: one row for
/// each, under the one it was started by, with how it went and whether it
/// is unread. A click opens the child's own conversation, where it has no
/// composer: nothing there is the user's to send it.
///
/// The groups fold, one by one or all at once (the bar's button); which
/// are folded is kept between runs ([AgentSidePanel]).
class AgentTasksPage extends StatelessWidget {
  const AgentTasksPage({super.key, required this.panel, required this.session});

  final AgentSidePanel panel;
  final ChatSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tree = session.agentTree;
    final roots = [
      for (final entry in tree)
        if (entry.depth == 0) entry,
    ];
    panel.noteAgentGroups([for (final entry in roots) entry.agent.id!]);
    if (roots.isEmpty) {
      return Center(
        key: const ValueKey(('page', SidePanelSection.agents)),
        child: Text(
          l10n.sidePanelAgentsEmpty,
          style: TextStyle(color: AppColors.textFaint, fontSize: 12.5),
        ),
      );
    }
    final unread = [
      for (final entry in tree)
        if (session.agentUnread(entry.agent)) entry,
    ].length;
    return Column(
      key: const ValueKey(('page', SidePanelSection.agents)),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          unread: unread,
          allFolded: panel.agentsAllFolded,
          onToggleAll: panel.toggleAllAgents,
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              for (final entry in tree)
                if (entry.depth == 0 || !_foldedAbove(panel, entry))
                  _AgentRow(
                    key: ValueKey(('task', entry.agent.id)),
                    agent: entry.agent,
                    depth: entry.depth,
                    folded: entry.depth == 0
                        ? panel.agentGroupFolded(entry.agent.id!)
                        : null,
                    unread: session.agentUnread(entry.agent),
                    onToggleGroup: entry.depth == 0
                        ? () => panel.toggleAgentGroup(entry.agent.id!)
                        : null,
                    onOpen: () => session.openAgentPath(entry.path),
                    onStop:
                        entry.agent.status == CommandStatus.running &&
                            !entry.agent.queued &&
                            !entry.agent.readOnly
                        ? session.stopOf(entry.agent.id)
                        : null,
                    onRetry:
                        entry.agent.status == CommandStatus.running ||
                            entry.agent.readOnly
                        ? null
                        : () => confirmAgentRetry(
                            context,
                            session,
                            SubagentFeed(session, entry.path),
                          ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  /// Whether [entry], a child of a root group, is out of sight under a
  /// root that is folded (its root's row still shows).
  static bool _foldedAbove(
    AgentSidePanel panel,
    ({AgentItem agent, List<String> path, int depth}) entry,
  ) {
    if (entry.depth == 0) return false;
    final rootId = entry.path.first;
    return panel.agentGroupFolded(rootId);
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.unread,
    required this.allFolded,
    required this.onToggleAll,
  });

  final int unread;
  final bool allFolded;
  final VoidCallback onToggleAll;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.sidePanelAgentTasks,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ),
          if (unread > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '$unread ${l10n.sidePanelAgentUnread}',
                style: TextStyle(
                  color: themeColors['list.warningForeground'],
                  fontSize: 11,
                ),
              ),
            ),
          IdeHover(
            message: allFolded
                ? l10n.sidebarExpandAll
                : l10n.sidebarCollapseAll,
            excludeFromSemantics: true,
            child: IconButton(
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 22, height: 22),
              icon: Icon(
                allFolded ? Codicons.expandAll : Codicons.collapseAll,
                color: AppColors.textFaint,
                semanticLabel: allFolded
                    ? l10n.sidebarExpandAll
                    : l10n.sidebarCollapseAll,
              ),
              onPressed: onToggleAll,
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({
    super.key,
    required this.agent,
    required this.depth,
    required this.folded,
    required this.unread,
    this.onToggleGroup,
    required this.onOpen,
    this.onStop,
    this.onRetry,
  });

  final AgentItem agent;
  final int depth;

  /// For a root: whether its children are out of sight, and the fold's
  /// toggle.
  final bool? folded;
  final VoidCallback? onToggleGroup;
  final bool unread;
  final VoidCallback onOpen;
  final VoidCallback? onStop;
  final VoidCallback? onRetry;

  static String _status(AppLocalizations l10n, AgentItem agent) =>
      switch (agent.status) {
        CommandStatus.running => l10n.sidePanelAgentRunning,
        CommandStatus.succeeded => l10n.sidePanelAgentDone,
        CommandStatus.failed => l10n.sidePanelAgentFailed,
        CommandStatus.interrupted => l10n.sidePanelAgentInterrupted,
      };

  /// The first line of [text] with anything in it.
  static String? _excerpt(String? text) {
    if (text == null) return null;
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (:label, :upstream) = AgentStep.modelName(
      agent.assignedModel ?? agent.model ?? '',
      providers: ModelProviders.current,
    );
    final model = agent.assignedModel ?? agent.model;
    final status = agent.queued
        ? l10n.sidePanelAgentQueued
        : agent.outcome == 'cancelled'
        ? l10n.sidePanelAgentCancelled
        : _status(l10n, agent);
    // What it did last, or, ended, the start of its report.
    final detail = switch (agent.status) {
      CommandStatus.running =>
        AgentStep.latest(agent, l10n: l10n) ?? agent.activity ?? agent.prompt,
      _ => _excerpt(agent.result) ?? AgentStep.latest(agent, l10n: l10n),
    };
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          padding: EdgeInsets.fromLTRB(6 + depth * 14.0, 6, 6, 6),
          decoration: BoxDecoration(
            color: hovered ? AppColors.bubbleHover : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (folded case final folded?)
                    GestureDetector(
                      onTap: onToggleGroup,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          folded
                              ? Icons.keyboard_arrow_right_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: AppColors.textFaint,
                        ),
                      ),
                    )
                  else
                    const SizedBox(width: 20),
                  SizedBox.square(
                    dimension: 14,
                    child:
                        agent.status == CommandStatus.running && !agent.queued
                        ? const PixelLoader.subagent()
                        : Icon(
                            Codicons.hubot,
                            size: 14,
                            color: AppColors.textFaint,
                          ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      agent.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: unread ? AppColors.textPrimary : AppColors.text,
                        fontSize: 12.5,
                        fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (unread) ...[
                    const SizedBox(width: 6),
                    Container(
                      key: ValueKey('unread-${agent.id}'),
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: themeColors['list.warningForeground'],
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  Text(
                    status,
                    style: TextStyle(
                      color: agent.status == CommandStatus.failed
                          ? themeColors['list.errorForeground']
                          : AppColors.textFaint,
                      fontSize: 11,
                    ),
                  ),
                  if (onStop != null) ...[
                    const SizedBox(width: 4),
                    IdeHover(
                      message: l10n.chatStop,
                      excludeFromSemantics: true,
                      child: GestureDetector(
                        onTap: onStop,
                        child: Icon(
                          Icons.stop_rounded,
                          size: 14,
                          color: AppColors.textFaint,
                        ),
                      ),
                    ),
                  ],
                  if (onRetry != null) ...[
                    const SizedBox(width: 4),
                    IdeHover(
                      message: l10n.sidePanelAgentRetry,
                      excludeFromSemantics: true,
                      child: GestureDetector(
                        onTap: onRetry,
                        child: Icon(
                          Icons.refresh_rounded,
                          size: 14,
                          color: AppColors.textFaint,
                          semanticLabel: l10n.sidePanelAgentRetry,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (agent.agentType != null || model != null)
                Padding(
                  padding: const EdgeInsets.only(left: 42, top: 2),
                  child: Text(
                    [
                      ?agent.agentType,
                      if (model != null)
                        upstream == null ? label : '$label · $upstream',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textFaint,
                      fontSize: 10.5,
                    ),
                  ),
                ),
              if (detail != null && detail.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 42, top: 3),
                  child: Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
