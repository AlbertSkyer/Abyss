import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:flutter/material.dart';

import '../ide/ide_hover.dart';
import '../theme/app_theme.dart';
import '../theme/workbench_theme.dart';
import 'dock_layout.dart';
import 'islands.dart';

typedef DockPanelBuilder = Widget Function(
  BuildContext context,
  String panelId,
);

typedef DockEmptyBuilder = Widget Function(BuildContext context);

/// Business owners can route a drop themselves, including a root-edge drop.
/// [target] is a panel or group ID, and is null only for the root or empty
/// dock. A null [side] merges into the target group.
typedef DockMovePanel = void Function(
  String panelId,
  String? target,
  DockSide? side,
  bool root,
);

/// Renders a [DockController]. Panel IDs and all business behavior are opaque
/// to this module: it never imports or depends on Workspace.
class DockHost extends StatelessWidget {
  const DockHost({
    super.key,
    required this.controller,
    required this.panelBuilder,
    this.titleBuilder,
    this.emptyBuilder,
    this.onActivatePanel,
    this.onDragPanel,
    this.onPanelMenu,
    this.onKeepPanel,
    this.isPreviewPanel,
    this.onClosePanel,
    this.onMovePanel,
    this.showCloseButtons = true,
    this.showMaximizeButtons = true,
    this.minPanelExtent = 120,
    this.maximizeLabel = 'Maximize',
    this.restoreLabel = 'Restore',
  });
  final String maximizeLabel;
  final String restoreLabel;

  final DockController controller;
  final DockPanelBuilder panelBuilder;
  final DockPanelBuilder? titleBuilder;
  final DockEmptyBuilder? emptyBuilder;
  final ValueChanged<String>? onActivatePanel;
  final ValueChanged<String>? onDragPanel;
  final void Function(String panelId, Offset position)? onPanelMenu;
  final ValueChanged<String>? onKeepPanel;
  final bool Function(String panelId)? isPreviewPanel;

  /// If supplied, owns closing. The host never calls [DockController.close]
  /// before this callback, so an owner can ask for confirmation or veto.
  final ValueChanged<String>? onClosePanel;
  final DockMovePanel? onMovePanel;
  final bool showCloseButtons;
  final bool showMaximizeButtons;
  final double minPanelExtent;

  void activate(String panelId) => onActivatePanel == null
      ? controller.reveal(panelId)
      : onActivatePanel!(panelId);

  void close(String panelId) {
    if (panelId == dockMainPanelId || !showCloseButtons) return;
    if (onClosePanel case final callback?) {
      callback(panelId);
    } else {
      controller.close(panelId);
    }
  }

  void move(
    String panelId, {
    String? target,
    DockSide? side,
    bool root = false,
  }) {
    if (onMovePanel case final callback?) {
      callback(panelId, target, side, root);
    } else if (root && side != null) {
      controller.moveToRoot(panelId, side: side);
    } else if (target != null) {
      controller.move(panelId, target: target, side: side);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final maximized = controller.maximizedPanelId;
      final group = maximized == null
          ? null
          : _findGroup(controller.root, maximized);
      final content = _isEmpty(controller.root)
          ? _EmptyDock(host: this)
          : group == null
          ? _DockNodeView(
              node: controller.root,
              controller: controller,
              host: this,
              path: '',
            )
          : _DockGroupView(
              key: ValueKey(group.groupId),
              group: group,
              controller: controller,
              host: this,
              maximized: true,
            );
      return ColoredBox(
        color: AppColors.background,
        child: Padding(
          padding: const EdgeInsets.all(Islands.gap),
          child: group == null && !_isEmpty(controller.root)
              ? _DockRootDropTarget(host: this, child: content)
              : content,
        ),
      );
    },
  );

  static bool _isEmpty(DockNode node) => switch (node) {
    DockTabs() => node.orderedPanelIds.isEmpty,
    DockSplit() => _isEmpty(node.first) && _isEmpty(node.second),
  };

  static DockTabs? _findGroup(DockNode? node, String panelId) {
    switch (node) {
      case DockTabs():
        return node.orderedPanelIds.contains(panelId) ? node : null;
      case DockSplit():
        return _findGroup(node.first, panelId) ??
            _findGroup(node.second, panelId);
      case null:
        return null;
    }
  }
}

class _DockRootDropTarget extends StatefulWidget {
  const _DockRootDropTarget({required this.host, required this.child});

  final DockHost host;
  final Widget child;

  @override
  State<_DockRootDropTarget> createState() => _DockRootDropTargetState();
}

class _DockRootDropTargetState extends State<_DockRootDropTarget> {
  DockSide? _side;

  void _update(Offset globalPosition) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final position = box.globalToLocal(globalPosition);
    final side = _edgeSide(position, box.size, fraction: 0.08, maximum: 32);
    if (_side != side) setState(() => _side = side);
  }

  void _clear() {
    if (_side != null) setState(() => _side = null);
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      // These edge targets are painted after the groups, so a local group's
      // edge cannot steal a drop intended for the whole dock.
      for (final side in DockSide.values)
        Align(
          alignment: switch (side) {
            DockSide.left => Alignment.centerLeft,
            DockSide.right => Alignment.centerRight,
            DockSide.top => Alignment.topCenter,
            DockSide.bottom => Alignment.bottomCenter,
          },
          child: SizedBox(
            width: side == DockSide.left || side == DockSide.right
                ? 12
                : double.infinity,
            height: side == DockSide.top || side == DockSide.bottom
                ? 12
                : double.infinity,
            child: DragTarget<_DockDrag>(
              onWillAcceptWithDetails: (details) {
                _update(details.offset);
                return true;
              },
              onMove: (details) => _update(details.offset),
              onLeave: (_) => _clear(),
              onAcceptWithDetails: (details) {
                final dropSide = _side ?? side;
                _clear();
                widget.host.move(
                  details.data.panelId,
                  target: _rootTarget(widget.host.controller.root),
                  side: dropSide,
                  root: true,
                );
              },
              builder: (context, _, _) => const SizedBox.expand(),
            ),
          ),
        ),
      if (_side != null)
        IgnorePointer(
          child: _DropPreview(
            key: const ValueKey('dock-root-preview'),
            side: _side!,
          ),
        ),
    ],
  );

  static String? _rootTarget(DockNode? node) => switch (node) {
    DockTabs() => node.groupId,
    DockSplit() => _rootTarget(node.first),
    null => null,
  };
}

DockSide? _edgeSide(
  Offset position,
  Size size, {
  double fraction = 0.3,
  double maximum = 96,
}) {
  if (size.isEmpty) return null;
  final horizontalEdge = math.min(maximum, size.width * fraction);
  final verticalEdge = math.min(maximum, size.height * fraction);
  if (horizontalEdge <= 0 || verticalEdge <= 0) return null;
  final distances = <(double, DockSide)>[
    (position.dx / horizontalEdge, DockSide.left),
    ((size.width - position.dx) / horizontalEdge, DockSide.right),
    (position.dy / verticalEdge, DockSide.top),
    ((size.height - position.dy) / verticalEdge, DockSide.bottom),
  ];
  distances.sort((a, b) => a.$1.compareTo(b.$1));
  return distances.first.$1 < 1 ? distances.first.$2 : null;
}

class _EmptyDock extends StatefulWidget {
  const _EmptyDock({required this.host});

  final DockHost host;

  @override
  State<_EmptyDock> createState() => _EmptyDockState();
}

class _EmptyDockState extends State<_EmptyDock> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) => DragTarget<_DockDrag>(
    onWillAcceptWithDetails: (_) {
      if (!_hovered) setState(() => _hovered = true);
      return true;
    },
    onLeave: (_) {
      if (_hovered) setState(() => _hovered = false);
    },
    onAcceptWithDetails: (details) {
      setState(() => _hovered = false);
      widget.host.move(details.data.panelId, root: true);
    },
    builder: (context, _, _) => ColoredBox(
      key: const ValueKey('dock-empty-drop-target'),
      color: _hovered
          ? themeColors['tab.activeForeground'].withValues(alpha: 0.12)
          : AppColors.code,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child:
                widget.host.emptyBuilder?.call(context) ??
                const SizedBox.shrink(),
          ),
        ],
      ),
    ),
  );
}

class _DockNodeView extends StatelessWidget {
  const _DockNodeView({
    required this.node,
    required this.controller,
    required this.host,
    required this.path,
  });

  final DockNode node;
  final DockController controller;
  final DockHost host;
  final String path;

  @override
  Widget build(BuildContext context) {
    switch (node) {
      case final DockTabs group:
        return _DockGroupView(
          key: ValueKey(group.groupId),
          group: group,
          controller: controller,
          host: host,
          maximized: false,
        );
      case final DockSplit split:
        return LayoutBuilder(
          builder: (context, constraints) {
            final horizontal = split.axis == DockAxis.horizontal;
            final total = horizontal
                ? constraints.maxWidth
                : constraints.maxHeight;
            final body = math.max(0.0, total - Islands.gap);
            final minimum = math.min(host.minPanelExtent, body / 2);
            final firstExtent = (body * split.ratio)
                .clamp(minimum, body - minimum)
                .toDouble();
            final secondExtent = body - firstExtent;
            final children = <Widget>[
              _extent(
                horizontal,
                firstExtent,
                _DockNodeView(
                  node: split.first,
                  controller: controller,
                  host: host,
                  path: '${path}0',
                ),
              ),
              _extent(
                horizontal,
                Islands.gap,
                _DockSash(
                  controller: controller,
                  path: path,
                  axis: split.axis,
                  bodyExtent: body,
                  minPanelExtent: host.minPanelExtent,
                ),
              ),
              _extent(
                horizontal,
                secondExtent,
                _DockNodeView(
                  node: split.second,
                  controller: controller,
                  host: host,
                  path: '${path}1',
                ),
              ),
            ];
            return horizontal
                ? Row(children: children)
                : Column(children: children);
          },
        );
    }
  }

  Widget _extent(bool horizontal, double extent, Widget child) => SizedBox(
    width: horizontal ? extent : null,
    height: horizontal ? null : extent,
    child: child,
  );
}

class _DockSash extends StatefulWidget {
  const _DockSash({
    required this.controller,
    required this.path,
    required this.axis,
    required this.bodyExtent,
    required this.minPanelExtent,
  });

  final DockController controller;
  final String path;
  final DockAxis axis;
  final double bodyExtent;
  final double minPanelExtent;

  @override
  State<_DockSash> createState() => _DockSashState();
}

class _DockSashState extends State<_DockSash> {
  var _dragging = false;
  late double _startRatio;
  late Offset _startPosition;

  void _start(DragStartDetails details) {
    _startRatio = widget.controller.splitAtPath(widget.path)?.ratio ?? 0.5;
    _startPosition = details.globalPosition;
    setState(() => _dragging = true);
  }

  void _update(DragUpdateDetails details) {
    if (widget.bodyExtent <= 0) return;
    final distance = widget.axis == DockAxis.horizontal
        ? details.globalPosition.dx - _startPosition.dx
        : details.globalPosition.dy - _startPosition.dy;
    final minimum = math.min(0.5, widget.minPanelExtent / widget.bodyExtent);
    widget.controller.resize(
      widget.path,
      (_startRatio + distance / widget.bodyExtent).clamp(minimum, 1 - minimum),
    );
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.axis == DockAxis.horizontal
        ? SystemMouseCursors.resizeColumn
        : SystemMouseCursors.resizeRow,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: widget.axis == DockAxis.horizontal ? _start : null,
      onHorizontalDragUpdate: widget.axis == DockAxis.horizontal
          ? _update
          : null,
      onHorizontalDragEnd: widget.axis == DockAxis.horizontal
          ? (_) => setState(() => _dragging = false)
          : null,
      onHorizontalDragCancel: widget.axis == DockAxis.horizontal
          ? () => setState(() => _dragging = false)
          : null,
      onVerticalDragStart: widget.axis == DockAxis.vertical ? _start : null,
      onVerticalDragUpdate: widget.axis == DockAxis.vertical ? _update : null,
      onVerticalDragEnd: widget.axis == DockAxis.vertical
          ? (_) => setState(() => _dragging = false)
          : null,
      onVerticalDragCancel: widget.axis == DockAxis.vertical
          ? () => setState(() => _dragging = false)
          : null,
      child: Islands.sashLine(
        dragging: _dragging,
        axis: widget.axis == DockAxis.horizontal
            ? Axis.horizontal
            : Axis.vertical,
      ),
    ),
  );
}

@immutable
class _DockDrag {
  const _DockDrag(this.panelId, this.sourceGroupId);
  final String panelId;
  final String sourceGroupId;
}

/// One draggable dock tab. The host normally supplies [title] and [groupId].
class DockTab extends StatelessWidget {
  const DockTab({
    super.key,
    required this.panelId,
    required this.onTap,
    this.title,
    this.feedbackTitle,
    this.groupId,
    this.active = false,
    this.preview = false,
    this.atStart = false,
    this.onClose,
    this.onKeep,
    this.onMenu,
    this.onDragStarted,
  });

  final String panelId;
  final Widget? title;
  final Widget? feedbackTitle;
  final String? groupId;
  final bool active;
  final bool preview;
  final bool atStart;
  final VoidCallback onTap;
  final VoidCallback? onClose;
  final VoidCallback? onKeep;
  final ValueChanged<Offset>? onMenu;
  final VoidCallback? onDragStarted;

  @override
  Widget build(BuildContext context) {
    final tab = Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (event.buttons & kMiddleMouseButton != 0) onClose?.call();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: onKeep,
        onSecondaryTapUp: onMenu == null
            ? null
            : (details) => onMenu!(details.globalPosition),
        child: IdeHover(
          message: panelId,
          child: IslandTab(
            active: active,
            atStart: atStart,
            color: AppColors.code,
            onTap: onTap,
            builder: (context, foreground) => Container(
              constraints: const BoxConstraints(minWidth: 72, maxWidth: 190),
              padding: const EdgeInsets.only(left: 12, right: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: DefaultTextStyle.merge(
                      style: TextStyle(
                        color: foreground,
                        fontSize: 12,
                        fontStyle: preview ? FontStyle.italic : null,
                        overflow: TextOverflow.ellipsis,
                      ),
                      child:
                          title ??
                          Text(panelId, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  if (onClose != null)
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: InkResponse(
                        onTap: onClose,
                        radius: 12,
                        hoverColor: Islands.segmentFill(
                          selected: false,
                          hovered: true,
                        ),
                        child: Icon(Icons.close, size: 14, color: foreground),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (groupId == null) return tab;
    return Draggable<_DockDrag>(
      data: _DockDrag(panelId, groupId!),
      onDragStarted: onDragStarted,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: DecoratedBox(
          key: ValueKey('dock-drag-feedback-$panelId'),
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(Islands.controlRadius),
            border: Border.all(color: Islands.border),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: themeColors['tab.activeForeground'],
                fontSize: 12,
                fontStyle: preview ? FontStyle.italic : null,
              ),
              child:
                  feedbackTitle ??
                  title ??
                  Text(panelId, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: tab),
      child: tab,
    );
  }
}

class _DockGroupView extends StatefulWidget {
  const _DockGroupView({
    super.key,
    required this.group,
    required this.controller,
    required this.host,
    required this.maximized,
  });

  final DockTabs group;
  final DockController controller;
  final DockHost host;
  final bool maximized;

  @override
  State<_DockGroupView> createState() => _DockGroupViewState();
}

class _DockGroupViewState extends State<_DockGroupView> {
  DockSide? _dropSide;
  var _mergeTarget = false;

  void _updateSide(Offset globalPosition) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final position = box.globalToLocal(globalPosition);
    final side = _edgeSide(position, box.size, fraction: 0.3, maximum: 96);
    if (_dropSide != side || _mergeTarget) {
      setState(() {
        _dropSide = side;
        _mergeTarget = false;
      });
    }
  }

  void _accept(_DockDrag drag) {
    final side = _dropSide;
    setState(() {
      _dropSide = null;
      _mergeTarget = false;
    });
    widget.host.move(drag.panelId, target: widget.group.groupId, side: side);
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final controller = widget.controller;
    final host = widget.host;
    final maximized = controller.maximizedPanelId != null;

    final tabs = <Widget>[
      for (var i = 0; i < group.orderedPanelIds.length; i++)
        _tabTarget(group.orderedPanelIds[i], i),
    ];
    final strip = DragTarget<_DockDrag>(
      onWillAcceptWithDetails: (details) {
        if (!_mergeTarget) setState(() => _mergeTarget = true);
        return true;
      },
      onLeave: (_) => setState(() => _mergeTarget = false),
      onAcceptWithDetails: (details) {
        setState(() => _mergeTarget = false);
        widget.host.move(details.data.panelId, target: group.groupId);
      },
      builder: (context, candidates, _) => ColoredBox(
        color: candidates.isEmpty
            ? Colors.transparent
            : Islands.segmentFill(selected: false, hovered: true) ??
                  Colors.transparent,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: tabs),
              ),
            ),
            if (host.showMaximizeButtons)
              _MaximizeButton(
                label: maximized ? host.restoreLabel : host.maximizeLabel,
                maximized: maximized,
                onPressed: maximized
                    ? controller.restore
                    : () => controller.maximize(group.active),
              ),
          ],
        ),
      ),
    );

    final body = DragTarget<_DockDrag>(
      onWillAcceptWithDetails: (details) {
        _updateSide(details.offset);
        return true;
      },
      onMove: (details) => _updateSide(details.offset),
      onLeave: (_) {
        if (_dropSide != null) setState(() => _dropSide = null);
      },
      onAcceptWithDetails: (details) => _accept(details.data),
      builder: (context, _, _) => Stack(
        fit: StackFit.expand,
        children: [
          IndexedStack(
            index: math.max(0, group.orderedPanelIds.indexOf(group.active)),
            children: [
              for (final panelId in group.orderedPanelIds)
                KeyedSubtree(
                  key: ValueKey('dock-panel-$panelId'),
                  child: Builder(
                    builder: (context) => host.panelBuilder(context, panelId),
                  ),
                ),
            ],
          ),
          if (_dropSide != null)
            IgnorePointer(
              child: _DropPreview(
                key: const ValueKey('dock-local-preview'),
                side: _dropSide!,
              ),
            ),
        ],
      ),
    );

    return IslandTabbedCard(
      tabs: SizedBox(height: 36, child: strip),
      tabsHeight: 36,
      color: AppColors.code,
      body: body,
    );
  }

  Widget _tabTarget(String panelId, int index) {
    final group = widget.group;
    final host = widget.host;
    return DragTarget<_DockDrag>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) =>
          widget.host.move(details.data.panelId, target: panelId),
      builder: (context, candidates, _) => DecoratedBox(
        decoration: BoxDecoration(
          border: candidates.isEmpty
              ? null
              : Border(
                  left: BorderSide(
                    color: themeColors['tab.activeForeground'],
                    width: 2,
                  ),
                ),
        ),
        child: SizedBox(
          height: 36,
          child: DockTab(
            key: ValueKey('dock-tab-$panelId'),
            panelId: panelId,
            groupId: group.groupId,
            active: group.active == panelId,
            atStart: index == 0,
            title: host.titleBuilder == null
                ? null
                : Builder(
                    builder: (context) => host.titleBuilder!(context, panelId),
                  ),
            feedbackTitle: host.titleBuilder == null
                ? null
                : Builder(
                    builder: (context) => host.titleBuilder!(context, panelId),
                  ),
            preview: host.isPreviewPanel?.call(panelId) ?? false,
            onTap: () => host.activate(panelId),
            onClose: panelId != dockMainPanelId && host.showCloseButtons
                ? () => host.close(panelId)
                : null,
            onKeep: host.onKeepPanel == null
                ? null
                : () => host.onKeepPanel!(panelId),
            onMenu: host.onPanelMenu == null
                ? null
                : (position) => host.onPanelMenu!(panelId, position),
            onDragStarted: host.onDragPanel == null
                ? null
                : () => host.onDragPanel!(panelId),
          ),
        ),
      ),
    );
  }
}

class _MaximizeButton extends StatelessWidget {
  const _MaximizeButton({
    required this.maximized,
    required this.onPressed,
    required this.label,
  });
  final String label;
  final bool maximized;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 32,
    height: 32,
    child: IdeHover(
      message: label,
      child: InkResponse(
        onTap: onPressed,
        radius: 14,
        hoverColor: Islands.segmentFill(selected: false, hovered: true),
        child: Icon(
          maximized ? Icons.close_fullscreen : Icons.open_in_full,
          size: 15,
          color: themeColors['tab.inactiveForeground'],
        ),
      ),
    ),
  );
}

class _DropPreview extends StatelessWidget {
  const _DropPreview({super.key, required this.side});
  final DockSide side;

  @override
  Widget build(BuildContext context) {
    final alignment = switch (side) {
      DockSide.left => Alignment.centerLeft,
      DockSide.right => Alignment.centerRight,
      DockSide.top => Alignment.topCenter,
      DockSide.bottom => Alignment.bottomCenter,
    };
    final horizontal = side == DockSide.left || side == DockSide.right;
    return Align(
      alignment: alignment,
      child: FractionallySizedBox(
        widthFactor: horizontal ? 0.4 : 1,
        heightFactor: horizontal ? 1 : 0.4,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: themeColors['tab.activeForeground'].withValues(alpha: 0.12),
            border: Border.all(
              color: themeColors['tab.activeForeground'].withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}
