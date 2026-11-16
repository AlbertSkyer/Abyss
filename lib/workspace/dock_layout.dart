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

  bool get isEmpty;
  bool get isNotEmpty => !isEmpty;

  Map<String, Object?> toJson();

  /// Reads a standalone node using the legacy main-panel requirement.
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
        : DockController._addPanelToFirstGroup(node, dockMainPanelId);
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
  factory DockTabs({
    required String groupId,
    required List<String> orderedPanelIds,
    required String active,
  }) {
    final ids = List<String>.unmodifiable(
      LinkedHashSet<String>.from(orderedPanelIds.where((id) => id.isNotEmpty)),
    );
    return DockTabs._(
      groupId: groupId,
      orderedPanelIds: ids,
      active: ids.contains(active)
          ? active
          : ids.isEmpty
          ? ''
          : ids.first,
    );
  }

  const DockTabs._({
    required this.groupId,
    required this.orderedPanelIds,
    required this.active,
  }) : assert(groupId != ''),
       super._();

  final String groupId;
  final List<String> orderedPanelIds;
  final String active;

  @override
  bool get isEmpty => orderedPanelIds.isEmpty;

  DockTabs copyWith({
    String? groupId,
    List<String>? orderedPanelIds,
    String? active,
  }) {
    final ids = orderedPanelIds ?? this.orderedPanelIds;
    return DockTabs(
      groupId: groupId ?? this.groupId,
      orderedPanelIds: ids,
      active:
          active ??
          (ids.contains(this.active)
              ? this.active
              : ids.isEmpty
              ? ''
              : ids.first),
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

  @override
  bool get isEmpty => first.isEmpty && second.isEmpty;

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

/// Owns only generic dock layout state, never panel contents or business types.
class DockController extends ChangeNotifier {
  DockController({
    List<String> availablePanelIds = dockDefaultPanelIds,
    DockNode? root,
    String? requiredPanelId = dockMainPanelId,
  }) : _requiredPanelId = requiredPanelId,
       _availablePanelIds = <String>{
         if (requiredPanelId != null && requiredPanelId.isNotEmpty)
           requiredPanelId,
         ...availablePanelIds.where((id) => id.isNotEmpty),
       } {
    assert(requiredPanelId == null || requiredPanelId.isNotEmpty);
    _root = _initialRoot(root);
  }

  factory DockController.fromJson(
    Object? json, {
    List<String> availablePanelIds = dockDefaultPanelIds,
    String? requiredPanelId = dockMainPanelId,
  }) {
    final controller = DockController(
      availablePanelIds: availablePanelIds,
      requiredPanelId: requiredPanelId,
    );
    controller.loadJson(json);
    return controller;
  }

  late DockNode _root;
  final Set<String> _availablePanelIds;
  final String? _requiredPanelId;
  String? _maximizedPanelId;
  String? _focusedGroupId;
  var _groupSerial = 0;

  DockNode get root => _root;
  String? get maximizedPanelId => _maximizedPanelId;
  String? get requiredPanelId => _requiredPanelId;
  Set<String> get availablePanelIds => UnmodifiableSetView(_availablePanelIds);
  Set<String> get openPanelIds => UnmodifiableSetView(_panelsIn(_root));
  bool get isEmpty => _root.isEmpty;
  bool get isNotEmpty => !isEmpty;

  /// The group selected as the target for new tabs, if the tree is non-empty.
  DockTabs? get focusedGroup {
    if (_focusedGroupId != null) {
      final focused = _groupById(_root, _focusedGroupId!);
      if (focused != null) return focused;
    }
    return _root.isEmpty ? null : _rightmostGroup(_root);
  }

  static Set<String> _panelsIn(DockNode node) => switch (node) {
    DockTabs() => node.orderedPanelIds.toSet(),
    DockSplit() => {..._panelsIn(node.first), ..._panelsIn(node.second)},
  };

  static DockTabs _emptyRoot() =>
      DockTabs(groupId: 'dock-empty', orderedPanelIds: const [], active: '');

  DockNode _initialRoot(DockNode? root) {
    if (root == null) return _defaultRoot(_availablePanelIds);
    _focusedGroupId = root is DockTabs ? root.groupId : null;
    return _sanitize(
          root.toJson(),
          _availablePanelIds,
          requiredPanelId: _requiredPanelId,
        ) ??
        _defaultRoot(_availablePanelIds);
  }

  DockNode _defaultRoot(Iterable<String> available) {
    final required = _requiredPanelId;
    if (required == null) return _emptyRoot();
    final main = DockTabs(
      groupId: required == dockMainPanelId
          ? 'main-chat-group'
          : 'required-panel-group',
      orderedPanelIds: [required],
      active: required,
    );
    if (required != dockMainPanelId || !available.contains('files')) {
      return main;
    }
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

  /// Registers an ID as available to open; it does not open a panel.
  bool registerPanel(String panelId) {
    if (panelId.isEmpty || _availablePanelIds.contains(panelId)) return false;
    _availablePanelIds.add(panelId);
    notifyListeners();
    return true;
  }

  /// Registers several IDs in one notification, without opening any panels.
  void registerPanels(Iterable<String> panelIds) {
    var changed = false;
    for (final id in panelIds) {
      if (id.isNotEmpty && _availablePanelIds.add(id)) changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Closes an open ID and removes it from future [open] operations.
  bool unregisterPanel(String panelId) {
    if (panelId == _requiredPanelId || !_availablePanelIds.contains(panelId)) {
      return false;
    }
    _availablePanelIds.remove(panelId);
    if (openPanelIds.contains(panelId)) {
      _root = _removeFrom(_root, panelId) ?? _emptyRoot();
    }
    if (_maximizedPanelId == panelId) _maximizedPanelId = null;
    notifyListeners();
    return true;
  }

  /// Removes an open panel, including a required panel, without unregistering.
  bool removePanel(String panelId) {
    if (!openPanelIds.contains(panelId)) return false;
    _root = _removeFrom(_root, panelId) ?? _emptyRoot();
    if (_maximizedPanelId == panelId) _maximizedPanelId = null;
    notifyListeners();
    return true;
  }

  bool focusGroup(String groupId) {
    if (_groupById(_root, groupId) == null) return false;
    if (_focusedGroupId == groupId) return true;
    _focusedGroupId = groupId;
    notifyListeners();
    return true;
  }

  /// Replaces the entire tree atomically after validating registered panel IDs.
  /// Unlike [loadJson], this never treats tree IDs as newly available panels.
  bool replaceRoot(DockNode next) {
    final raw = next.toJson();
    final ids = <String>{};
    DockNode._collectPanelIds(raw, ids);
    if (!ids.every(_availablePanelIds.contains)) return false;
    final sanitized = _sanitize(
      raw,
      _availablePanelIds,
      requiredPanelId: _requiredPanelId,
    );
    if (sanitized == null) return false;
    _root = sanitized;
    if (_maximizedPanelId != null &&
        !openPanelIds.contains(_maximizedPanelId)) {
      _maximizedPanelId = null;
    }
    notifyListeners();
    return true;
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

    if (_root.isEmpty) {
      _root = DockTabs(
        groupId: _newGroupId(),
        orderedPanelIds: [panelId],
        active: panelId,
      );
      _focusedGroupId = (_root as DockTabs).groupId;
    } else if (_root case DockTabs group
        when group.orderedPanelIds.length == 1 &&
            group.active == _requiredPanelId) {
      // Keep the initial central conversation on its own; subsequent opens
      // join the existing right-hand group rather than making one per panel.
      final target = DockTabs(
        groupId: _newGroupId(),
        orderedPanelIds: [panelId],
        active: panelId,
      );
      _root = DockSplit(
        axis: DockAxis.horizontal,
        ratio: 0.68,
        first: group,
        second: target,
      );
      _focusedGroupId = target.groupId;
    } else {
      final target = focusedGroup!;
      _root = _replaceGroup(
        _root,
        target.groupId,
        (group) => group.copyWith(
          orderedPanelIds: [...group.orderedPanelIds, panelId],
          active: panelId,
        ),
      );
      _focusedGroupId = target.groupId;
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
    if (group.active == panelId && !changedMaximize) {
      return focusGroup(group.groupId);
    }
    if (changedMaximize) _maximizedPanelId = panelId;
    _focusedGroupId = group.groupId;
    _root = _replaceGroup(
      _root,
      group.groupId,
      (tabs) => tabs.copyWith(active: panelId),
    );
    notifyListeners();
    return true;
  }

  bool close(String panelId) {
    if (panelId == _requiredPanelId || !openPanelIds.contains(panelId)) {
      return false;
    }
    _root = _removeFrom(_root, panelId) ?? _emptyRoot();
    if (_maximizedPanelId == panelId) _maximizedPanelId = null;
    notifyListeners();
    return true;
  }

  /// Moves a panel to an edge of the complete tree, not just its current group.
  bool moveToRoot(String panelId, {required DockSide side}) {
    if (_groupForPanel(_root, panelId) == null) return false;
    if (_root case DockTabs group) {
      if (group.orderedPanelIds.length == 1) return false;
      return move(panelId, target: group.groupId, side: side);
    }
    final next = _removeFrom(_root, panelId);
    if (next == null) return false;
    final moved = DockTabs(
      groupId: _newGroupId(next),
      orderedPanelIds: [panelId],
      active: panelId,
    );
    final horizontal = side == DockSide.left || side == DockSide.right;
    final movedFirst = side == DockSide.left || side == DockSide.top;
    _root = DockSplit(
      axis: horizontal ? DockAxis.horizontal : DockAxis.vertical,
      ratio: 0.5,
      first: movedFirst ? moved : next,
      second: movedFirst ? next : moved,
    );
    _focusedGroupId = moved.groupId;
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
      _focusedGroupId = source.groupId;
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
    _focusedGroupId = _groupForPanel(_root, panelId)?.groupId;
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

  /// Loads a map or encoded JSON string. Version 1 remains the wire format.
  /// Valid `chat:` IDs are registered first so dynamic panels can restore.
  /// Other IDs retain the available-panel whitelist and legacy sanitization.
  /// Maximize state is deliberately not persisted.
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
      final ids = <String>{};
      DockNode._collectPanelIds(value['root'], ids);
      _availablePanelIds.addAll(
        ids.where((id) => id.startsWith('chat:') && id.length > 5),
      );
      next = _sanitize(
        value['root'],
        _availablePanelIds,
        requiredPanelId: _requiredPanelId,
      );
    }
    _root = next ?? _defaultRoot(_availablePanelIds);
    _focusedGroupId = _root.isEmpty ? null : _rightmostGroup(_root).groupId;
    _maximizedPanelId = null;
    notifyListeners();
  }

  static DockNode? _sanitize(
    Object? value,
    Set<String> available, {
    required String? requiredPanelId,
  }) {
    final seen = <String>{};
    final groups = <String>{};
    final node = _readNode(value, available, seen, groups);
    if (node == null) return null;
    if (requiredPanelId == null || seen.contains(requiredPanelId)) return node;
    return _addPanelToFirstGroup(node, requiredPanelId);
  }

  static DockNode _addPanelToFirstGroup(DockNode node, String panelId) {
    switch (node) {
      case DockTabs():
        return node.copyWith(
          orderedPanelIds: [panelId, ...node.orderedPanelIds],
        );
      case DockSplit():
        return node.copyWith(first: _addPanelToFirstGroup(node.first, panelId));
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
      final requestedGroup = value['groupId'];
      var groupId = requestedGroup is String && requestedGroup.isNotEmpty
          ? requestedGroup
          : 'dock-group';
      var suffix = 0;
      while (!groups.add(groupId)) {
        groupId = 'dock-group-${++suffix}';
      }
      if (ids.isEmpty) {
        return DockTabs(
          groupId: groupId,
          orderedPanelIds: const [],
          active: '',
        );
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
      if (first == null || first.isEmpty) return second;
      if (second == null || second.isEmpty) return first;
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
