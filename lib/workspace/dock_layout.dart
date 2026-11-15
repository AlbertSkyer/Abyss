import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

const dockMainPanelId = 'main-chat';
const dockLayoutVersion = 1;
const dockDefaultPanelIds = <String>[
  dockMainPanelId,
  'files',
  'changes',
  'terminal',
  'usage',
  'plan',
  'agents',
  'ports',
  'team',
  'scratch',
];

enum DockAxis { horizontal, vertical }

enum DockSide { left, right, top, bottom }

/// A node in the dock tree. Panel IDs, not panel contents, live in this tree.
@immutable
sealed class DockNode {
  const DockNode._();

  Map<String, Object?> toJson();

  /// Reads a standalone node. Unknown panel IDs cannot be inferred safely here,
  /// so all non-empty IDs in the value are accepted and de-duplicated.
  static DockNode fromJson(Object? value) {
    final allowed = <String>{dockMainPanelId};
    _collectPanelIds(value, allowed);
    final seen = <String>{};
    final groups = <String>{};
    final node = _readNode(value, allowed, seen, groups);
    if (node == null) {
      return DockTabs(
        groupId: 'main-chat-group',
        orderedPanelIds: const [dockMainPanelId],
        active: dockMainPanelId,
      );
    }
    return seen.contains(dockMainPanelId)
        ? node
        : DockController._addMainToFirstGroup(node);
  }

  static void _collectPanelIds(Object? value, Set<String> ids) {
    if (value is! Map) return;
    if (value['type'] == 'tabs') {
      final panels = value['orderedPanelIds'];
      if (panels is Iterable) {
        for (final id in panels) {
          if (id is String && id.isNotEmpty) ids.add(id);
        }
      }
    } else if (value['type'] == 'split') {
      _collectPanelIds(value['first'], ids);
      _collectPanelIds(value['second'], ids);
    }
  }
}

@immutable
final class DockTabs extends DockNode {
  DockTabs({
    required this.groupId,
    required List<String> orderedPanelIds,
    required String active,
  }) : orderedPanelIds = List.unmodifiable(
         LinkedHashSet<String>.from(
           orderedPanelIds.where((id) => id.isNotEmpty),
         ),
       ),
       active = orderedPanelIds.contains(active)
           ? active
           : orderedPanelIds.isEmpty
           ? active
           : orderedPanelIds.first,
       assert(groupId != ''),
       super._();

  final String groupId;
  final List<String> orderedPanelIds;
  final String active;

  DockTabs copyWith({
    String? groupId,
    List<String>? orderedPanelIds,
    String? active,
  }) {
    final ids = orderedPanelIds ?? this.orderedPanelIds;
    return DockTabs(
      groupId: groupId ?? this.groupId,
      orderedPanelIds: ids,
      active: active ?? (ids.contains(this.active) ? this.active : ids.first),
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'type': 'tabs',
    'groupId': groupId,
    'orderedPanelIds': orderedPanelIds,
    'active': active,
  };
}

@immutable
final class DockSplit extends DockNode {
  factory DockSplit({
    required DockAxis axis,
    required double ratio,
    required DockNode first,
    required DockNode second,
  }) {
    final safeRatio = ratio.isFinite ? ratio.clamp(0.05, 0.95).toDouble() : 0.5;
    return DockSplit._(
      axis: axis,
      ratio: safeRatio,
      first: first,
      second: second,
    );
  }

  const DockSplit._({
    required this.axis,
    required this.ratio,
    required this.first,
    required this.second,
  }) : super._();

  final DockAxis axis;

  /// The share allocated to [first], always between 0.05 and 0.95.
  final double ratio;
  final DockNode first;
  final DockNode second;

  DockSplit copyWith({double? ratio, DockNode? first, DockNode? second}) =>
      DockSplit(
        axis: axis,
        ratio: ratio ?? this.ratio,
        first: first ?? this.first,
        second: second ?? this.second,
      );

  @override
  Map<String, Object?> toJson() => {
    'type': 'split',
    'axis': axis.name,
    'ratio': ratio,
    'first': first.toJson(),
    'second': second.toJson(),
  };
}

/// Owns only dock layout state. It never owns or constructs panel contents.
class DockController extends ChangeNotifier {
  DockController({
    List<String> availablePanelIds = dockDefaultPanelIds,
    DockNode? root,
  }) : _availablePanelIds = <String>{
         dockMainPanelId,
         ...availablePanelIds.where((id) => id.isNotEmpty),
       } {
    _root = root == null
        ? _defaultRoot(_availablePanelIds)
        : _sanitize(root.toJson(), _availablePanelIds) ??
              _defaultRoot(_availablePanelIds);
  }

  factory DockController.fromJson(
    Object? json, {
    List<String> availablePanelIds = dockDefaultPanelIds,
  }) {
    final controller = DockController(availablePanelIds: availablePanelIds);
    controller.loadJson(json);
    return controller;
  }

  late DockNode _root;
  final Set<String> _availablePanelIds;
  String? _maximizedPanelId;
  var _groupSerial = 0;

  DockNode get root => _root;
  String? get maximizedPanelId => _maximizedPanelId;
  Set<String> get availablePanelIds => UnmodifiableSetView(_availablePanelIds);
  Set<String> get openPanelIds => UnmodifiableSetView(_panelsIn(_root));

  static Set<String> _panelsIn(DockNode node) => switch (node) {
    DockTabs() => node.orderedPanelIds.toSet(),
    DockSplit() => {..._panelsIn(node.first), ..._panelsIn(node.second)},
  };

  static DockNode _defaultRoot(Iterable<String> available) {
    final main = DockTabs(
      groupId: 'main-chat-group',
      orderedPanelIds: const [dockMainPanelId],
      active: dockMainPanelId,
    );
    if (!available.contains('files')) return main;
    return DockSplit(
      axis: DockAxis.horizontal,
      ratio: 0.68,
      first: main,
      second: DockTabs(
        groupId: 'right-group',
        orderedPanelIds: const ['files'],
        active: 'files',
      ),
    );
  }

  DockTabs? _groupForPanel(DockNode node, String panelId) {
    switch (node) {
      case DockTabs():
        return node.orderedPanelIds.contains(panelId) ? node : null;
      case DockSplit():
        return _groupForPanel(node.first, panelId) ??
            _groupForPanel(node.second, panelId);
    }
  }

  DockTabs? _groupById(DockNode node, String groupId) {
    switch (node) {
      case DockTabs():
        return node.groupId == groupId ? node : null;
      case DockSplit():
        return _groupById(node.first, groupId) ??
            _groupById(node.second, groupId);
    }
  }

  DockTabs _rightmostGroup(DockNode node) => switch (node) {
    DockTabs() => node,
    DockSplit() => _rightmostGroup(node.second),
  };

  DockNode _replaceGroup(
    DockNode node,
    String groupId,
    DockNode Function(DockTabs group) replace,
  ) {
    switch (node) {
      case DockTabs():
        return node.groupId == groupId ? replace(node) : node;
      case DockSplit():
        return node.copyWith(
          first: _replaceGroup(node.first, groupId, replace),
          second: _replaceGroup(node.second, groupId, replace),
        );
    }
  }

  DockNode? _removeFrom(DockNode node, String panelId) {
    switch (node) {
      case DockTabs():
        if (!node.orderedPanelIds.contains(panelId)) return node;
        final ids = node.orderedPanelIds.where((id) => id != panelId).toList();
        if (ids.isEmpty) return null;
        final oldIndex = node.orderedPanelIds.indexOf(panelId);
        return node.copyWith(
          orderedPanelIds: ids,
          active: node.active == panelId
              ? ids[oldIndex.clamp(0, ids.length - 1)]
              : node.active,
        );
      case DockSplit():
        final first = _removeFrom(node.first, panelId);
        final second = _removeFrom(node.second, panelId);
        if (first == null) return second;
        if (second == null) return first;
        if (identical(first, node.first) && identical(second, node.second)) {
          return node;
        }
        return node.copyWith(first: first, second: second);
    }
  }

  bool open(String panelId) {
    if (!_availablePanelIds.contains(panelId)) return false;
    if (openPanelIds.contains(panelId)) return reveal(panelId);

    // Keep the initial central conversation on its own; subsequent opens join
    // the existing right-hand group rather than creating a group per panel.
    if (_root case DockTabs group
        when group.orderedPanelIds.length == 1 &&
            group.active == dockMainPanelId) {
      _root = DockSplit(
        axis: DockAxis.horizontal,
        ratio: 0.68,
        first: group,
        second: DockTabs(
          groupId: _newGroupId(),
          orderedPanelIds: [panelId],
          active: panelId,
        ),
      );
    } else {
      final target = _rightmostGroup(_root);
      _root = _replaceGroup(
        _root,
        target.groupId,
        (group) => group.copyWith(
          orderedPanelIds: [...group.orderedPanelIds, panelId],
          active: panelId,
        ),
      );
    }
    if (_maximizedPanelId != null) _maximizedPanelId = panelId;
    notifyListeners();
    return true;
  }

  bool reveal(String panelId) {
    final group = _groupForPanel(_root, panelId);
    if (group == null) return false;
    final changedMaximize =
        _maximizedPanelId != null && _maximizedPanelId != panelId;
    if (group.active == panelId && !changedMaximize) return true;
    if (changedMaximize) _maximizedPanelId = panelId;
    _root = _replaceGroup(
      _root,
      group.groupId,
      (tabs) => tabs.copyWith(active: panelId),
    );
    notifyListeners();
    return true;
  }

  bool close(String panelId) {
    if (panelId == dockMainPanelId || !openPanelIds.contains(panelId)) {
      return false;
    }
    _root = _removeFrom(_root, panelId)!;
    if (_maximizedPanelId == panelId) _maximizedPanelId = null;
    notifyListeners();
    return true;
  }

  /// Moves a tab into [target]'s group, or splits that group on [side].
  /// [target] may be either an open panel ID or a group ID.
  bool move(String panelId, {required String target, DockSide? side}) {
    final source = _groupForPanel(_root, panelId);
    final targetGroup =
        _groupForPanel(_root, target) ?? _groupById(_root, target);
    if (source == null || targetGroup == null) return false;

    if (side == null && source.groupId == targetGroup.groupId) {
      if (panelId == target) return true;
      final ids = source.orderedPanelIds.toList();
      final from = ids.indexOf(panelId);
      final targetIndex = ids.indexOf(target);
      if (from < 0 || targetIndex < 0) return true;
      ids.removeAt(from);
      // Dropping to the right inserts after the target; to the left, before.
      ids.insert(targetIndex, panelId);
      _root = _replaceGroup(
        _root,
        source.groupId,
        (group) => group.copyWith(orderedPanelIds: ids, active: panelId),
      );
      notifyListeners();
      return true;
    }

    if (side != null &&
        source.groupId == targetGroup.groupId &&
        source.orderedPanelIds.length == 1) {
      return false;
    }

    var next = _removeFrom(_root, panelId)!;
    final remainingTarget = _groupById(next, targetGroup.groupId);
    if (remainingTarget == null) return false;

    if (side == null) {
      final ids = remainingTarget.orderedPanelIds.toList();
      final targetIndex = ids.indexOf(target);
      ids.insert(targetIndex < 0 ? ids.length : targetIndex, panelId);
      next = _replaceGroup(
        next,
        remainingTarget.groupId,
        (group) => group.copyWith(orderedPanelIds: ids, active: panelId),
      );
    } else {
      final moved = DockTabs(
        groupId: _newGroupId(next),
        orderedPanelIds: [panelId],
        active: panelId,
      );
      final horizontal = side == DockSide.left || side == DockSide.right;
      final movedFirst = side == DockSide.left || side == DockSide.top;
      next = _replaceGroup(
        next,
        remainingTarget.groupId,
        (group) => DockSplit(
          axis: horizontal ? DockAxis.horizontal : DockAxis.vertical,
          ratio: 0.5,
          first: movedFirst ? moved : group,
          second: movedFirst ? group : moved,
        ),
      );
    }
    _root = next;
    notifyListeners();
    return true;
  }

  /// Resizes the split at a root path: '' is root, '0' first, '1' second.
  bool resize(String splitPath, double ratio) {
    if (!ratio.isFinite || _splitAtPath(_root, splitPath) == null) return false;
    _root = _resizeAt(_root, splitPath, 0, ratio);
    notifyListeners();
    return true;
  }

  DockSplit? splitAtPath(String path) => _splitAtPath(_root, path);

  DockSplit? _splitAtPath(DockNode node, String path) {
    if (path.isEmpty) return node is DockSplit ? node : null;
    if (node is! DockSplit) return null;
    final unit = path.codeUnitAt(0);
    if (unit != 0x30 && unit != 0x31) return null;
    return _splitAtPath(
      unit == 0x30 ? node.first : node.second,
      path.substring(1),
    );
  }

  DockNode _resizeAt(DockNode node, String path, int offset, double ratio) {
    if (node is! DockSplit) return node;
    if (offset == path.length) return node.copyWith(ratio: ratio);
    final first = path.codeUnitAt(offset) == 0x30;
    return node.copyWith(
      first: first
          ? _resizeAt(node.first, path, offset + 1, ratio)
          : node.first,
      second: first
          ? node.second
          : _resizeAt(node.second, path, offset + 1, ratio),
    );
  }

  bool maximize(String panelId) {
    if (!openPanelIds.contains(panelId)) return false;
    if (_maximizedPanelId == panelId) return true;
    _maximizedPanelId = panelId;
    notifyListeners();
    return true;
  }

  bool restore() {
    if (_maximizedPanelId == null) return false;
    _maximizedPanelId = null;
    notifyListeners();
    return true;
  }

  Map<String, Object?> toJson() => {
    'version': dockLayoutVersion,
    'root': _root.toJson(),
  };

  /// Loads a map or an encoded JSON string. Any bad preset safely restores the
  /// default layout; maximize state is deliberately not persisted.
  void loadJson(Object? json) {
    Object? value = json;
    if (value is String) {
      try {
        value = jsonDecode(value);
      } on FormatException {
        value = null;
      }
    }
    DockNode? next;
    if (value is Map && value['version'] == dockLayoutVersion) {
      next = _sanitize(value['root'], _availablePanelIds);
    }
    _root = next ?? _defaultRoot(_availablePanelIds);
    _maximizedPanelId = null;
    notifyListeners();
  }

  static DockNode? _sanitize(Object? value, Set<String> available) {
    final seen = <String>{};
    final groups = <String>{};
    final node = _readNode(value, available, seen, groups);
    if (node == null) return null;
    if (seen.contains(dockMainPanelId)) return node;
    return _addMainToFirstGroup(node);
  }

  static DockNode _addMainToFirstGroup(DockNode node) {
    switch (node) {
      case DockTabs():
        return node.copyWith(
          orderedPanelIds: [dockMainPanelId, ...node.orderedPanelIds],
        );
      case DockSplit():
        return node.copyWith(first: _addMainToFirstGroup(node.first));
    }
  }

  String _newGroupId([DockNode? node]) {
    final used = <String>{};
    void collect(DockNode current) {
      switch (current) {
        case DockTabs():
          used.add(current.groupId);
        case DockSplit():
          collect(current.first);
          collect(current.second);
      }
    }

    collect(node ?? _root);
    String id;
    do {
      id = 'dock-group-${++_groupSerial}';
    } while (used.contains(id));
    return id;
  }
}

DockNode? _readNode(
  Object? value,
  Set<String> allowed,
  Set<String> seen,
  Set<String> groups,
) {
  if (value is! Map) return null;
  switch (value['type']) {
    case 'tabs':
      final rawIds = value['orderedPanelIds'];
      if (rawIds is! Iterable) return null;
      final ids = <String>[];
      for (final id in rawIds) {
        if (id is String && allowed.contains(id) && seen.add(id)) ids.add(id);
      }
      if (ids.isEmpty) return null;
      final requestedGroup = value['groupId'];
      var groupId = requestedGroup is String && requestedGroup.isNotEmpty
          ? requestedGroup
          : 'dock-group';
      var suffix = 0;
      while (!groups.add(groupId)) {
        groupId = 'dock-group-${++suffix}';
      }
      final active = value['active'];
      return DockTabs(
        groupId: groupId,
        orderedPanelIds: ids,
        active: active is String && ids.contains(active) ? active : ids.first,
      );
    case 'split':
      final first = _readNode(value['first'], allowed, seen, groups);
      final second = _readNode(value['second'], allowed, seen, groups);
      if (first == null) return second;
      if (second == null) return first;
      final rawRatio = value['ratio'];
      final ratio = rawRatio is num ? rawRatio.toDouble() : double.nan;
      return DockSplit(
        axis: value['axis'] == 'vertical'
            ? DockAxis.vertical
            : DockAxis.horizontal,
        ratio: ratio,
        first: first,
        second: second,
      );
  }
  return null;
}
