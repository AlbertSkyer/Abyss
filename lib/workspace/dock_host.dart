import 'dart:math' as math;

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

/// Renders a [DockController]. Business panel contents are supplied by the
/// caller and are looked up only by stable panel ID.
class DockHost extends StatelessWidget {
  const DockHost({
    super.key,
    required this.controller,
    required this.panelBuilder,
    this.titleBuilder,
    this.onClosePanel,
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
  final ValueChanged<String>? onClosePanel;
  final bool showCloseButtons;
  final bool showMaximizeButtons;
  final double minPanelExtent;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final maximized = controller.maximizedPanelId;
      final group = maximized == null
          ? null
          : _findGroup(controller.root, maximized);
      return ColoredBox(
        color: AppColors.background,
        child: Padding(
          padding: const EdgeInsets.all(Islands.gap),
          child: group == null
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
                ),
        ),
      );
    },
  );

  static DockTabs? _findGroup(DockNode node, String panelId) {
    switch (node) {
      case DockTabs():
        return node.orderedPanelIds.contains(panelId) ? node : null;
      case DockSplit():
        return _findGroup(node.first, panelId) ??
            _findGroup(node.second, panelId);
    }
  }
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
    this.groupId,
    this.active = false,
    this.atStart = false,
    this.onClose,
  });

  final String panelId;
  final Widget? title;
  final String? groupId;
  final bool active;
  final bool atStart;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final tab = IdeHover(
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
                    overflow: TextOverflow.ellipsis,
                  ),
                  child:
                      title ?? Text(panelId, overflow: TextOverflow.ellipsis),
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
    );
    if (groupId == null) return tab;
    return Draggable<_DockDrag>(
      data: _DockDrag(panelId, groupId!),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(Islands.controlRadius),
            border: Border.all(color: Islands.border),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              panelId,
              style: TextStyle(
                color: themeColors['tab.activeForeground'],
                fontSize: 12,
              ),
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
    final size = box.size;
    final horizontalEdge = math.min(96.0, size.width * 0.3);
    final verticalEdge = math.min(72.0, size.height * 0.3);
    DockSide? side;
    final distances = <(double, DockSide)>[
      (position.dx / horizontalEdge, DockSide.left),
      ((size.width - position.dx) / horizontalEdge, DockSide.right),
      (position.dy / verticalEdge, DockSide.top),
      ((size.height - position.dy) / verticalEdge, DockSide.bottom),
    ];
    distances.sort((a, b) => a.$1.compareTo(b.$1));
    if (distances.first.$1 < 1) side = distances.first.$2;
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
    widget.controller.move(
      drag.panelId,
      target: widget.group.groupId,
      side: side,
    );
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
        controller.move(details.data.panelId, target: group.groupId);
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
            IgnorePointer(child: _DropPreview(side: _dropSide!)),
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
          widget.controller.move(details.data.panelId, target: panelId),
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
            onTap: () => widget.controller.reveal(panelId),
            onClose: panelId != dockMainPanelId && host.showCloseButtons
                ? () => (host.onClosePanel ?? widget.controller.close)(panelId)
                : null,
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
  const _DropPreview({required this.side});
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
