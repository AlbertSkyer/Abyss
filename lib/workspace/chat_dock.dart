import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'chat_grid.dart';
import 'dock_layout.dart';

/// Coordinates conversations in a dock without knowing the workspace that owns
/// them. References are supplied by the owner; this class only maps them to
/// stable panel IDs and arranges those IDs in a [DockController].
class ChatDock<T extends Object> {
  ChatDock({
    required this._referenceOf,
    required this._resolveReference,
    this._hasDraft,
    this._onChanged,
    List<String> availablePanelIds = dockDefaultPanelIds,
  }) : controller = DockController(
         requiredPanelId: null,
         availablePanelIds: availablePanelIds
             .where((id) => id != dockMainPanelId && !id.startsWith('chat:'))
             .toList(),
       ) {
    controller.addListener(_layoutChanged);
  }

  final Object Function(T thread) _referenceOf;
  final T? Function(Object reference, String panelId) _resolveReference;
  final bool Function(T thread)? _hasDraft;
  final VoidCallback? _onChanged;
  final DockController controller;

  final Map<String, T> _threads = {};
  final Map<String, Object> _references = {};
  final Map<T, String> _panels = {};
  final Map<String, String> _legacyPanels = {};
  final Set<String> _previews = {};
  final List<String> _openingOrder = [];
  String? _selectedPanel;
  bool _changing = false;
  bool _notifying = false;

  static const _newReferencePrefix = 'new:';

  T? get selected => threadFor(_selectedPanel);

  /// The last focused group, including a group containing only tool panels.
  DockTabs? get focusedGroup => controller.focusedGroup;

  List<T> get openChats =>
      List.unmodifiable([for (final panel in _openingOrder) ?_threads[panel]]);

  List<T> get visibleChats => List.unmodifiable([
    for (final panel in _visiblePanels(_visibleNode)) ?_threads[panel],
  ]);

  DockNode get _visibleNode {
    final maximized = controller.maximizedPanelId;
    if (maximized == null) return controller.root;
    final group = groupFor(maximized);
    return group ?? controller.root;
  }

  String panelId(T thread) {
    final panel = _panels[thread];
    if (panel == null) throw StateError('The chat is not open.');
    return panel;
  }

  T? threadFor(String? panelId) => _threads[panelId];

  List<T> tabsOf(T thread) {
    final panel = _panels[thread];
    final group = panel == null ? null : groupFor(panel);
    return List.unmodifiable([
      for (final id in group?.orderedPanelIds ?? const <String>[])
        ?_threads[id],
    ]);
  }

  DockTabs? groupOf(T thread) {
    final panel = _panels[thread];
    return panel == null ? null : groupFor(panel);
  }

  DockTabs? groupFor(String panelId) => _groupFor(controller.root, panelId);

  DockTabs? _groupFor(DockNode node, String panelId) => switch (node) {
    DockTabs() => node.orderedPanelIds.contains(panelId) ? node : null,
    DockSplit() =>
      _groupFor(node.first, panelId) ?? _groupFor(node.second, panelId),
  };

  DockTabs? _groupById(DockNode node, String groupId) => switch (node) {
    DockTabs() => node.groupId == groupId ? node : null,
    DockSplit() =>
      _groupById(node.first, groupId) ?? _groupById(node.second, groupId),
  };

  /// Opens [thread], replacing only a preview in the destination group.
  bool open(T thread, {bool preview = false, T? target, DockSide? side}) {
    var result = false;
    _commit(() {
      result = _open(thread, preview: preview, target: target, side: side);
    });
    return result;
  }

  bool _open(T thread, {bool preview = false, T? target, DockSide? side}) {
    if (groupOf(thread) case final group?) {
      if (preview) {
        _markPreview(_panels[thread]!, group.groupId);
      } else {
        _previews.remove(_panels[thread]);
      }
      if (side != null && target != null) {
        return _move(thread, target: panelId(target), side: side);
      }
      return activate(thread);
    }

    final panel = _register(thread);
    final oldPreview = preview ? _previewIn(_targetGroup(target)) : null;
    final opened = side == null
        ? controller.open(panel)
        : _openBeside(panel, target: target, side: side);
    if (!opened) {
      _forget(panel);
      return false;
    }
    if (side == null) {
      final destinationGroup = _targetGroup(target);
      if (destinationGroup != null) {
        controller.move(panel, target: destinationGroup.groupId);
      }
    }
    if (preview && !_hasThreadDraft(thread)) {
      if (oldPreview != null && oldPreview != panel) {
        final oldGroup = groupFor(oldPreview);
        controller.close(oldPreview);
        _forget(oldPreview);
        if (oldGroup != null && target != null) {
          controller.move(panel, target: _targetId(target));
        }
      }
      _previews.add(panel);
    } else {
      _previews.remove(panel);
    }
    _select(panel);
    return true;
  }

  bool _openBeside(String panel, {T? target, required DockSide side}) {
    final targetThread = target ?? selected;
    if (targetThread == null || _panels[targetThread] == null) {
      return controller.open(panel);
    }
    if (!controller.open(panel)) return false;
    final id = _panels[targetThread]!;
    if (!controller.move(panel, target: id, side: side)) {
      controller.close(panel);
      return false;
    }
    return true;
  }

  DockTabs? _targetGroup(T? target) {
    if (target != null) return groupOf(target);
    final focused = controller.focusedGroup;
    if (focused != null &&
        focused.orderedPanelIds.any((id) => _threads.containsKey(id))) {
      return focused;
    }
    return selected == null ? null : groupOf(selected as T);
  }

  String _targetId(T target) => _panels[target]!;

  String? _previewIn(DockTabs? group) {
    if (group == null) return null;
    return group.orderedPanelIds.where(_previews.contains).firstOrNull;
  }

  bool activate(T thread) {
    if (_changing) return _activate(thread);
    var result = false;
    _commit(() => result = _activate(thread));
    return result;
  }

  bool _activate(T thread) {
    final panel = _panels[thread];
    if (panel == null || groupFor(panel) == null) return false;
    final result = controller.reveal(panel);
    if (groupFor(panel) case final group?) controller.focusGroup(group.groupId);
    _select(panel);
    return result;
  }

  /// Focuses either a chat or a tool. Focusing a tool deliberately leaves the
  /// selected conversation unchanged; [visibleChats] follows tab activity.
  bool focusPanel(String panelId) {
    final group = groupFor(panelId);
    if (group == null) return false;
    if (_threads.containsKey(panelId)) {
      return activate(_threads[panelId] as T);
    }
    final result = controller.reveal(panelId);
    controller.focusGroup(group.groupId);
    _changed();
    return result;
  }

  bool movePanel(
    String panelId, {
    required String target,
    DockSide? side,
    bool root = false,
  }) {
    final thread = _threads[panelId];
    if (thread != null) {
      return move(thread, target: target, side: side, root: root);
    }
    if (groupFor(panelId) == null) return false;
    final destination = root ? target : _resolveTarget(target);
    if (!root && destination == null) return false;
    final moved = root
        ? side != null && controller.moveToRoot(panelId, side: side)
        : controller.move(panelId, target: destination!, side: side);
    if (!moved) return false;
    if (groupFor(panelId) case final group?) {
      controller.focusGroup(group.groupId);
    }
    _changed();
    return true;
  }

  bool focusGroup(String groupId) {
    final group = _groupById(controller.root, groupId);
    if (group == null) return false;
    final changed = controller.focusGroup(groupId);
    final chat = group.orderedPanelIds
        .where((id) => _threads.containsKey(id))
        .cast<String?>()
        .firstOrNull;
    if (chat != null) {
      controller.reveal(chat);
      _select(chat);
    }
    _changed();
    return changed;
  }

  bool close(T thread) {
    if (_changing) return _close(thread);
    var result = false;
    _commit(() => result = _close(thread));
    return result;
  }

  bool _close(T thread) {
    final panel = _panels[thread];
    if (panel == null || groupFor(panel) == null) return false;
    final group = groupFor(panel)!;
    final selected = _selectedPanel;
    final wasSelected = selected == panel;
    final next = _fallbackIn(group, panel);
    if (!controller.close(panel)) return false;
    _forget(panel);
    if (!wasSelected) {
      _selectedPanel = selected;
      return true;
    }
    if (next != null) {
      controller.reveal(next);
      _select(next);
    } else {
      final remaining = openChats;
      _select(remaining.isEmpty ? null : _panels[remaining.last]);
    }
    return true;
  }

  String? _fallbackIn(DockTabs group, String panel) {
    final chats = group.orderedPanelIds.where(_threads.containsKey).toList();
    if (chats.length < 2) return null;
    final index = chats.indexOf(panel);
    return chats[index == chats.length - 1 ? index - 1 : index + 1];
  }

  bool move(
    T thread, {
    required String target,
    DockSide? side,
    bool root = false,
  }) {
    if (_changing) {
      return _move(thread, target: target, side: side, root: root);
    }
    var result = false;
    _commit(
      () => result = _move(thread, target: target, side: side, root: root),
    );
    return result;
  }

  bool _move(
    T thread, {
    required String target,
    DockSide? side,
    bool root = false,
  }) {
    final panel = _panels[thread];
    if (panel == null || groupFor(panel) == null) return false;
    final destination = root ? target : _resolveTarget(target);
    if (!root && destination == null) return false;
    final moved = root
        ? side != null && controller.moveToRoot(panel, side: side)
        : controller.move(panel, target: destination!, side: side);
    if (!moved) return false;
    if (side == null && _threads.containsKey(destination)) {
      _insertBeforeInOrder(panel, destination!);
    }
    if (groupFor(panel) case final group?) controller.focusGroup(group.groupId);
    _select(panel);
    _changed();
    return true;
  }

  String? _resolveTarget(String target) {
    if (groupFor(target) != null ||
        _groupById(controller.root, target) != null ||
        target == dockMainPanelId) {
      return target;
    }
    final legacy = _legacyPanels[target];
    return legacy != null && groupFor(legacy) != null ? legacy : null;
  }

  /// Inserts [thread] immediately before [before], or last when it is null.
  /// [group] can be a chat/tool panel ID or a group ID.
  bool reorder(T thread, {required String group, T? before}) {
    final panel = _panels[thread];
    final destination = _resolveTarget(group);
    if (panel == null || destination == null) return false;
    final tabs =
        _groupById(controller.root, destination) ?? groupFor(destination);
    if (tabs == null) return false;
    final beforePanel = before == null ? null : _panels[before];
    if (before != null &&
        (beforePanel == null || !tabs.orderedPanelIds.contains(beforePanel))) {
      return false;
    }
    if (groupOf(thread)?.groupId != tabs.groupId) {
      if (!move(thread, target: tabs.groupId)) return false;
      return reorder(thread, group: tabs.groupId, before: before);
    }
    final ids = tabs.orderedPanelIds.toList()..remove(panel);
    var index = beforePanel == null ? ids.length : ids.indexOf(beforePanel);
    if (index < 0) return false;
    ids.insert(index, panel);
    if (!_replaceRoot(
      _replaceGroup(
        controller.root,
        tabs.groupId,
        (old) => old.copyWith(orderedPanelIds: ids, active: panel),
      ),
    )) {
      return false;
    }
    if (beforePanel != null) _insertBeforeInOrder(panel, beforePanel);
    controller.focusGroup(tabs.groupId);
    _select(panel);
    _changed();
    return true;
  }

  void _insertBeforeInOrder(String panel, String before) {
    final old = _openingOrder.indexOf(panel);
    if (old < 0) return;
    _openingOrder.removeAt(old);
    var index = _openingOrder.indexOf(before);
    if (index < 0) index = _openingOrder.length;
    _openingOrder.insert(index, panel);
  }

  bool pin(T thread) {
    final panel = _panels[thread];
    if (panel == null || !_previews.remove(panel)) return false;
    _changed();
    return true;
  }

  bool isPreview(T thread) {
    final panel = _panels[thread];
    return panel != null && _previews.contains(panel);
  }

  Map<String, Object?> toJson() => {
    'version': 2,
    'layout': controller.toJson(),
    'bindings': {
      for (final panel in _openingOrder)
        if (_threads.containsKey(panel)) panel: _freshReference(panel),
    },
    'previews': _openingOrder.where(_previews.contains).toList(),
    if (_selectedPanel != null && _threads.containsKey(_selectedPanel))
      'selected': _selectedPanel,
  };

  Object _freshReference(String panel) {
    final thread = _threads[panel]!;
    try {
      final reference = _referenceOf(thread);
      if (_validReference(reference)) {
        _references[panel] = _copyReference(reference);
        if (reference is String) _legacyPanels[reference] = panel;
      }
    } on Object {
      // Keep the last usable reference: saving a layout must not close a chat.
    }
    return _copyReference(_references[panel]!);
  }

  /// Restores a version-2 map or JSON string. Bad individual bindings are
  /// skipped without discarding other sessions or any valid tool panels.
  bool restore(Object? json) {
    final value = _decode(json);
    if (value is! Map || value['version'] != 2) return false;
    final rawBindings = value['bindings'];
    if (rawBindings is! Map) return false;

    final resolved = <String, T>{};
    final references = <String, Object>{};
    final panels = <String>[];
    for (final entry in rawBindings.entries) {
      final panel = entry.key;
      final reference = entry.value;
      if (panel is! String || !panel.startsWith('chat:')) continue;
      if (!_validReference(reference) || resolved.containsKey(panel)) continue;
      final thread = _resolve(panel, reference);
      if (thread == null) continue;
      resolved[panel] = thread;
      references[panel] = _copyReference(reference);
      panels.add(panel);
    }

    final root = _readRestoredRoot(value['layout'], resolved.keys);
    if (root == null) return false;
    final restoredOrder = {
      for (final panel in _treePanels(root))
        if (resolved.containsKey(panel)) panel,
      for (final panel in panels)
        if (!_treePanels(root).contains(panel)) panel,
    }.toList();
    var keptPanels = _treePanels(root).toSet();
    final orphaned = restoredOrder
        .where((id) => !keptPanels.contains(id))
        .toList();
    var completeRoot = root;
    if (orphaned.isNotEmpty) {
      // A damaged tree may omit tabs, but their valid bindings still represent
      // sessions. Reattach them together rather than silently dropping them.
      completeRoot = DockTabs(
        groupId: 'chat-restored',
        orderedPanelIds: [..._treePanels(root), ...orphaned],
        active: orphaned.first,
      );
      keptPanels = _treePanels(completeRoot).toSet();
    }
    final completeRootValue = completeRoot;
    _commit(() {
      _clearBindings();
      final unique = <T>{};
      resolved.removeWhere((_, thread) => !unique.add(thread));
      _threads.addAll(resolved);
      _references.addAll(references);
      for (final entry in resolved.entries) {
        _panels[entry.value] = entry.key;
        final reference = references[entry.key];
        if (reference is String) _legacyPanels[reference] = entry.key;
      }
      _openingOrder.addAll(restoredOrder.where(resolved.containsKey));
      _previews.addAll(
        _stringList(value['previews'])
            .where((id) => resolved.containsKey(id) && keptPanels.contains(id)),
      );
      final selected = value['selected'];
      _selectedPanel = selected is String && resolved.containsKey(selected)
          ? selected
          : _activeChat(completeRootValue) ?? restoredOrder.firstOrNull;
      controller.registerPanels(resolved.keys);
      if (!controller.replaceRoot(completeRootValue)) {
        // [completeRootValue] was validated, so this is only a fallback.
        controller.loadJson({
          'version': dockLayoutVersion,
          'root': completeRootValue.toJson(),
        });
      }
      for (final panel
          in controller.availablePanelIds
              .where(
                (id) => id.startsWith('chat:') && !_threads.containsKey(id),
              )
              .toList()) {
        controller.unregisterPanel(panel);
      }
      _normalizePreviews();
      if (_selectedPanel case final selected?) {
        if (groupFor(selected) case final group?) {
          controller.focusGroup(group.groupId);
        }
      }
    });
    return true;
  }

  DockNode? _readRestoredRoot(Object? layout, Iterable<String> chats) {
    Object? raw = layout;
    if (raw is String) raw = _decode(raw);
    if (raw is! Map || raw['version'] != dockLayoutVersion) return null;
    final allowed = <String>{
      ...controller.availablePanelIds.where((id) => !id.startsWith('chat:')),
      ...chats,
    }..remove(dockMainPanelId);
    final seen = <String>{};
    final groups = <String>{};
    final node = _readNode(raw['root'], allowed, seen, groups);
    if (node != null) return node;
    if (raw['root'] case {'type': 'tabs', 'orderedPanelIds': final List ids}
        when ids.isEmpty) {
      return DockTabs(
        groupId: 'restored-empty',
        orderedPanelIds: const [],
        active: '',
      );
    }
    return null;
  }

  T? _resolve(String panel, Object reference) {
    try {
      return _resolveReference(_copyReference(reference), panel);
    } on Object {
      return null;
    }
  }

  /// Converts the former 2x2 [ChatGrid] into splits and carries over any tool
  /// panels from [oldDock]. [ChatGrid] retains object identity, so tabs that
  /// were covered in the old UI are preserved too.
  bool migrateLegacy(Object? oldDock, ChatGrid<T> grid) {
    var result = false;
    _commit(() => result = _migrateLegacy(oldDock, grid));
    return result;
  }

  bool _migrateLegacy(Object? oldDock, ChatGrid<T> grid) {
    final oldLayout = _decode(oldDock);
    final tools = oldLayout is Map ? oldLayout : const <Object?, Object?>{};
    final oldChats = _threads.values.toSet();
    final used = <T>{};
    final migrated = <DockTabs>[];

    DockTabs? tabGroup(T thread) {
      final panel = _panels[thread];
      if (panel == null) return null;
      return migrated
          .where((g) => g.orderedPanelIds.contains(panel))
          .firstOrNull;
    }

    T? claim(T thread) {
      if (used.contains(thread) || tabGroup(thread) != null) return null;
      used.add(thread);
      if (oldChats.contains(thread)) _unregisterThread(thread);
      return thread;
    }

    final gridGroups = <DockTabs>[];
    for (final pane in grid.panes) {
      final tabs = {
        ...grid.tabs(pane),
        pane,
      }.map(claim).whereType<T>().toList();
      if (tabs.isEmpty) continue;
      for (final tab in tabs) {
        _register(tab);
      }
      final activeThread = pane;
      final active = _panels[activeThread]!;
      final group = DockTabs(
        groupId: 'chat-migrated-${gridGroups.length + 1}',
        orderedPanelIds: [for (final tab in tabs) _panels[tab]!],
        active: active,
      );
      gridGroups.add(group);
      migrated.add(group);
    }

    DockNode? chatRoot = _migrateGridGeometry(grid, gridGroups);
    final toolRoot = _toolOnlyRoot(tools);
    final rawRoot = tools['root'];
    var inserted = false;
    DockNode? insertAtSlot(Object? raw) {
      if (raw is! Map) return null;
      if (raw['type'] == 'split') {
        final first = insertAtSlot(raw['first']);
        final second = insertAtSlot(raw['second']);
        if (first == null) return second;
        if (second == null) return first;
        return DockSplit(
          axis: raw['axis'] == 'vertical'
              ? DockAxis.vertical
              : DockAxis.horizontal,
          ratio: raw['ratio'] is num ? (raw['ratio'] as num).toDouble() : 0.5,
          first: first,
          second: second,
        );
      }
      final ids = raw['orderedPanelIds'];
      if (ids is! List) return null;
      final toolIds = ids
          .whereType<String>()
          .where(
            (id) =>
                id != dockMainPanelId &&
                controller.availablePanelIds.contains(id),
          )
          .toList();
      final tool = toolIds.isEmpty
          ? null
          : DockTabs(
              groupId: '${raw['groupId'] ?? 'tools'}',
              orderedPanelIds: toolIds,
              active: toolIds.contains(raw['active'])
                  ? raw['active'] as String
                  : toolIds.first,
            );
      if (!ids.contains(dockMainPanelId) || inserted || chatRoot == null) {
        return tool;
      }
      inserted = true;
      if (tool == null) return chatRoot;
      if (chatRoot case final DockTabs chats) {
        return chats.copyWith(
          orderedPanelIds: [...chats.orderedPanelIds, ...toolIds],
          active: raw['active'] == dockMainPanelId ? chats.active : tool.active,
        );
      }
      return DockSplit(
        axis: DockAxis.horizontal,
        ratio: 0.68,
        first: chatRoot,
        second: tool,
      );
    }

    final merged = insertAtSlot(rawRoot);
    if (inserted) {
      chatRoot = merged;
    } else if (toolRoot != null) {
      chatRoot = chatRoot == null
          ? toolRoot
          : DockSplit(
              axis: DockAxis.horizontal,
              ratio: 0.68,
              first: chatRoot,
              second: toolRoot,
            );
    }
    chatRoot ??= DockTabs(
      groupId: 'chat-migrated-empty',
      orderedPanelIds: const [],
      active: '',
    );

    for (final thread in oldChats) {
      if (!used.contains(thread)) _unregisterThread(thread);
    }
    controller.registerPanels(_threads.keys);
    controller.replaceRoot(chatRoot);
    _openingOrder
      ..clear()
      ..addAll([for (final group in gridGroups) ...group.orderedPanelIds]);
    _selectedPanel = grid.panes.isEmpty ? null : _panels[grid.panes.first];
    if (_selectedPanel != null && groupFor(_selectedPanel!) == null) {
      _selectedPanel = _openingOrder.firstOrNull;
    }
    _previews.removeWhere((id) => !_threads.containsKey(id));
    _normalizePreviews();
    _changed();
    return true;
  }

  DockNode? _migrateGridGeometry(ChatGrid<T> grid, List<DockTabs> groups) {
    if (groups.isEmpty) return null;
    final byThread = <T, DockTabs>{};
    for (final group in groups) {
      for (final panel in group.orderedPanelIds) {
        final thread = _threads[panel];
        if (thread != null) byThread[thread] = group;
      }
    }
    final cells = grid.cells;
    if (cells.length != 4 || cells.any((cell) => !byThread.containsKey(cell))) {
      return DockTabs(
        groupId: 'chat-migrated-tabs',
        orderedPanelIds: groups.expand((g) => g.orderedPanelIds).toList(),
        active: groups.last.active,
      );
    }
    final at = <int, DockNode>{
      for (var i = 0; i < 4; i++) i: byThread[cells[i]]!,
    };
    if (identical(at[0], at[1]) &&
        identical(at[0], at[2]) &&
        identical(at[0], at[3])) {
      return at[0];
    }
    if (identical(at[0], at[2]) && identical(at[1], at[3])) {
      return DockSplit(
        axis: DockAxis.horizontal,
        ratio: grid.columnRatioIn(0),
        first: at[0]!,
        second: at[1]!,
      );
    }
    if (identical(at[0], at[1]) && identical(at[2], at[3])) {
      return DockSplit(
        axis: DockAxis.vertical,
        ratio: grid.rowRatioIn(0),
        first: at[0]!,
        second: at[2]!,
      );
    }
    if (identical(at[0], at[1])) {
      return DockSplit(
        axis: DockAxis.vertical,
        ratio: grid.rowRatioIn(0),
        first: at[0]!,
        second: DockSplit(
          axis: DockAxis.horizontal,
          ratio: grid.columnRatioIn(1),
          first: at[2]!,
          second: at[3]!,
        ),
      );
    }
    if (identical(at[2], at[3])) {
      return DockSplit(
        axis: DockAxis.vertical,
        ratio: grid.rowRatioIn(0),
        first: DockSplit(
          axis: DockAxis.horizontal,
          ratio: grid.columnRatioIn(0),
          first: at[0]!,
          second: at[1]!,
        ),
        second: at[2]!,
      );
    }
    if (identical(at[0], at[2])) {
      return DockSplit(
        axis: DockAxis.horizontal,
        ratio: grid.columnRatioIn(0),
        first: at[0]!,
        second: DockSplit(
          axis: DockAxis.vertical,
          ratio: grid.rowRatioIn(1),
          first: at[1]!,
          second: at[3]!,
        ),
      );
    }
    if (identical(at[1], at[3])) {
      return DockSplit(
        axis: DockAxis.horizontal,
        ratio: grid.columnRatioIn(0),
        first: DockSplit(
          axis: DockAxis.vertical,
          ratio: grid.rowRatioIn(0),
          first: at[0]!,
          second: at[2]!,
        ),
        second: at[1]!,
      );
    }
    return grid.columnsFirst
        ? DockSplit(
            axis: DockAxis.horizontal,
            ratio: grid.columnRatioIn(0),
            first: DockSplit(
              axis: DockAxis.vertical,
              ratio: grid.rowRatioIn(0),
              first: at[0]!,
              second: at[2]!,
            ),
            second: DockSplit(
              axis: DockAxis.vertical,
              ratio: grid.rowRatioIn(1),
              first: at[1]!,
              second: at[3]!,
            ),
          )
        : DockSplit(
            axis: DockAxis.vertical,
            ratio: grid.rowRatioIn(0),
            first: DockSplit(
              axis: DockAxis.horizontal,
              ratio: grid.columnRatioIn(0),
              first: at[0]!,
              second: at[1]!,
            ),
            second: DockSplit(
              axis: DockAxis.horizontal,
              ratio: grid.columnRatioIn(1),
              first: at[2]!,
              second: at[3]!,
            ),
          );
  }

  /// Replaces every main-chat slot in [json] with the current conversations.
  /// Chats never live in a saved preset, so applying one cannot discard them.
  bool applyPreset(Object? json) {
    final value = _decode(json);
    if (value is! Map) return false;
    final source = value['version'] == 2 ? value['layout'] : value;
    final raw = _decodeLayout(source);
    if (raw == null) return false;

    var slots = 0;
    void countSlots(Object? value) {
      if (value is! Map) return;
      if (value['type'] == 'split') {
        countSlots(value['first']);
        countSlots(value['second']);
      }
      final ids = value['orderedPanelIds'];
      if (ids is Iterable &&
          ids.any(
            (id) =>
                id == dockMainPanelId || id is String && id.startsWith('chat:'),
          )) {
        slots++;
      }
    }

    countSlots(raw);
    final groups = _allGroups(controller.root)
        .where((g) => g.orderedPanelIds.any(_threads.containsKey))
        .map((g) => g.orderedPanelIds.where(_threads.containsKey).toList())
        .toList();
    final assignments = List.generate(slots, (_) => <String>[]);
    for (var i = 0; i < groups.length && slots > 0; i++) {
      assignments[i < slots ? i : slots - 1].addAll(groups[i]);
    }
    final chatGroups = <List<String>>[];
    final root = _presetNode(raw, chatGroups, assignments);
    if (root == null || chatGroups.isEmpty) return false;
    if (chatGroups.expand((group) => group).toSet().length != _threads.length) {
      return false;
    }

    controller.registerPanels(_threads.keys);
    final active = _selectedPanel;
    if (!_replaceRoot(root)) return false;
    if (active != null && groupFor(active) != null) {
      controller.reveal(active);
      controller.focusGroup(groupFor(active)!.groupId);
    } else {
      _select(openChats.isEmpty ? null : _panels[openChats.first]);
    }
    _normalizePreviews();
    _changed();
    return true;
  }

  Object? _decodeLayout(Object? source) {
    final value = _decode(source);
    if (value is! Map) return null;
    if (value['version'] == dockLayoutVersion) return value['root'];
    return value['root'] is Map ? value['root'] : value;
  }

  DockNode? _presetNode(
    Object? raw,
    List<List<String>> chatGroups,
    List<List<String>> assignments,
  ) {
    if (raw is! Map) return null;
    switch (raw['type']) {
      case 'tabs':
        final ids = raw['orderedPanelIds'];
        if (ids is! Iterable) return null;
        final panels = <String>[];
        var hasSlot = false;
        final seen = <String>{};
        for (final id in ids) {
          if (id is! String || !seen.add(id)) continue;
          if (id == dockMainPanelId || id.startsWith('chat:')) {
            hasSlot = true;
          } else if (controller.availablePanelIds.contains(id)) {
            panels.add(id);
          }
        }
        if (hasSlot) {
          final index = chatGroups.length;
          final chats = index < assignments.length
              ? assignments[index]
              : <String>[];
          chatGroups.add(chats);
          panels.insertAll(0, chats);
        }
        if (panels.isEmpty) return null;
        final requestedActive = raw['active'];
        final groupId = chatGroups.isNotEmpty
            ? 'chat-preset-${chatGroups.length - 1}'
            : _presetGroupId(raw['groupId'], 'tools-preset');
        return DockTabs(
          groupId: groupId,
          orderedPanelIds: panels,
          active: hasSlot && chatGroups.isNotEmpty && chatGroups.last.isNotEmpty
              ? chatGroups.last.last
              : requestedActive is String && panels.contains(requestedActive)
              ? requestedActive
              : panels.first,
        );
      case 'split':
        final first = _presetNode(raw['first'], chatGroups, assignments);
        final second = _presetNode(raw['second'], chatGroups, assignments);
        if (first == null) return second;
        if (second == null) return first;
        return DockSplit(
          axis: raw['axis'] == 'vertical'
              ? DockAxis.vertical
              : DockAxis.horizontal,
          ratio: raw['ratio'] is num ? (raw['ratio']! as num).toDouble() : 0.5,
          first: first,
          second: second,
        );
    }
    return null;
  }

  String _presetGroupId(Object? raw, String fallback) =>
      raw is String && raw.isNotEmpty ? raw : fallback;

  /// Saves only geometry and tools. Every chat group becomes one main-chat
  /// slot; session references and preview state deliberately stay out.
  Map<String, Object?> presetJson() => {
    'version': dockLayoutVersion,
    'root': _presetSnapshot(controller.root).toJson(),
  };

  DockNode _presetSnapshot(DockNode node) {
    switch (node) {
      case DockTabs():
        final panels = <String>[];
        var chat = false;
        for (final id in node.orderedPanelIds) {
          if (_threads.containsKey(id)) {
            chat = true;
          } else {
            panels.add(id);
          }
        }
        if (chat) panels.insert(0, dockMainPanelId);
        return DockTabs(
          groupId: node.groupId,
          orderedPanelIds: panels,
          active: chat ? dockMainPanelId : node.active,
        );
      case DockSplit():
        final first = _presetSnapshotOrNull(node.first);
        final second = _presetSnapshotOrNull(node.second);
        if (first == null) return second!;
        if (second == null) return first;
        return DockSplit(
          axis: node.axis,
          ratio: node.ratio,
          first: first,
          second: second,
        );
    }
  }

  DockNode? _presetSnapshotOrNull(DockNode node) {
    if (node is DockTabs && node.orderedPanelIds.isEmpty) return null;
    if (node is DockSplit) {
      final first = _presetSnapshotOrNull(node.first);
      final second = _presetSnapshotOrNull(node.second);
      if (first == null) return second;
      if (second == null) return first;
    }
    return _presetSnapshot(node);
  }

  /// The first chat group touching the requested geometric direction.
  T? neighbor(T thread, DockSide side) {
    final panel = _panels[thread];
    if (panel == null) return null;
    final groups = <_GroupGeometry>[];
    _collectGeometry(controller.root, _Geometry.unit, groups);
    final source = groups
        .where((g) => g.tabs.orderedPanelIds.contains(panel))
        .firstOrNull;
    if (source == null) return null;
    final candidates = <_GroupGeometry>[];
    for (final other in groups) {
      if (other == source) continue;
      final bounds = source.bounds;
      final target = other.bounds;
      final directional = switch (side) {
        DockSide.left => target.right <= bounds.left,
        DockSide.right => target.left >= bounds.right,
        DockSide.top => target.bottom <= bounds.top,
        DockSide.bottom => target.top >= bounds.bottom,
      };
      if (!directional) continue;
      final overlaps = side == DockSide.left || side == DockSide.right
          ? target.bottom > bounds.top && target.top < bounds.bottom
          : target.right > bounds.left && target.left < bounds.right;
      if (overlaps) candidates.add(other);
    }
    candidates.sort((a, b) {
      final distance = _distance(
        source.bounds,
        a.bounds,
        side,
      ).compareTo(_distance(source.bounds, b.bounds, side));
      return distance != 0
          ? distance
          : _offset(
              source.bounds,
              a.bounds,
              side,
            ).compareTo(_offset(source.bounds, b.bounds, side));
    });
    for (final candidate in candidates) {
      for (final id in candidate.tabs.orderedPanelIds) {
        if (_threads[id] case final neighbor?) return neighbor;
      }
    }
    return null;
  }

  double _distance(_Geometry from, _Geometry to, DockSide side) =>
      switch (side) {
        DockSide.left => from.left - to.right,
        DockSide.right => to.left - from.right,
        DockSide.top => from.top - to.bottom,
        DockSide.bottom => to.top - from.bottom,
      };

  double _offset(_Geometry from, _Geometry to, DockSide side) =>
      side == DockSide.left || side == DockSide.right
      ? ((from.top + from.bottom) - (to.top + to.bottom)).abs()
      : ((from.left + from.right) - (to.left + to.right)).abs();

  void _collectGeometry(
    DockNode node,
    _Geometry bounds,
    List<_GroupGeometry> groups,
  ) {
    switch (node) {
      case DockTabs():
        if (node.orderedPanelIds.isNotEmpty) {
          groups.add(_GroupGeometry(node, bounds));
        }
      case DockSplit():
        final first = node.axis == DockAxis.horizontal
            ? bounds.copyWith(right: bounds.left + bounds.width * node.ratio)
            : bounds.copyWith(bottom: bounds.top + bounds.height * node.ratio);
        final second = node.axis == DockAxis.horizontal
            ? bounds.copyWith(left: first.right)
            : bounds.copyWith(top: first.bottom);
        _collectGeometry(node.first, first, groups);
        _collectGeometry(node.second, second, groups);
    }
  }

  String _register(T thread) {
    if (_panels[thread] case final existing?) return existing;
    Object reference;
    try {
      reference = _referenceOf(thread);
    } on Object {
      rethrow;
    }
    if (!_validReference(reference)) {
      throw ArgumentError.value(reference, 'thread', 'Invalid chat reference');
    }
    final copy = _copyReference(reference);
    final token = _token(copy);
    var panel = 'chat:$token';
    var serial = 1;
    while (_threads.containsKey(panel) ||
        controller.availablePanelIds.contains(panel)) {
      panel = 'chat:$token-${serial++}';
    }
    _threads[panel] = thread;
    _references[panel] = copy;
    _panels[thread] = panel;
    _openingOrder.add(panel);
    if (reference is String) _legacyPanels[reference] = panel;
    controller.registerPanel(panel);
    return panel;
  }

  bool _validReference(Object? reference) =>
      reference is String && reference.isNotEmpty ||
      reference is Map &&
          reference['new'] is String &&
          (reference['new'] as String).isNotEmpty;

  String _token(Object reference) {
    if (reference is String) return 'id-${Uri.encodeComponent(reference)}';
    final map = reference as Map;
    final buffer = StringBuffer(_newReferencePrefix)
      ..write(Uri.encodeComponent(map['new']! as String));
    if (map['slot'] != null) {
      buffer
        ..write('-slot-')
        ..write(Uri.encodeComponent(map['slot'].toString()));
    }
    return buffer.toString();
  }

  Object _copyReference(Object reference) => reference is String
      ? reference
      : Map<String, Object?>.unmodifiable({
          for (final entry in (reference as Map).entries)
            if (entry.key is String) entry.key as String: entry.value,
        });

  bool _hasThreadDraft(T thread) {
    try {
      return _hasDraft?.call(thread) ?? false;
    } on Object {
      return true;
    }
  }

  void _markPreview(String panel, String groupId) {
    final group = _groupById(controller.root, groupId);
    if (group == null) return;
    for (final id in group.orderedPanelIds) {
      if (id != panel && _previews.contains(id)) {
        close(_threads[id] as T);
      }
    }
    if (_hasThreadDraft(_threads[panel] as T)) {
      _previews.remove(panel);
    } else {
      _previews.add(panel);
    }
  }

  void _normalizePreviews() {
    for (final group in _allGroups(controller.root)) {
      final previews = group.orderedPanelIds.where(_previews.contains).toList();
      for (final panel in previews.take(
        previews.length > 1 ? previews.length - 1 : 0,
      )) {
        _previews.remove(panel);
      }
    }
    _previews.removeWhere((id) {
      final thread = _threads[id];
      return thread == null || groupFor(id) == null || _hasThreadDraft(thread);
    });
  }

  Iterable<DockTabs> _allGroups(DockNode node) sync* {
    switch (node) {
      case DockTabs():
        yield node;
      case DockSplit():
        yield* _allGroups(node.first);
        yield* _allGroups(node.second);
    }
  }

  void _select(String? panel) {
    _selectedPanel = panel != null && _threads.containsKey(panel)
        ? panel
        : null;
  }

  void _forget(String panel) {
    final thread = _threads.remove(panel);
    _references.remove(panel);
    _previews.remove(panel);
    _openingOrder.remove(panel);
    if (thread != null) _panels.remove(thread);
    _legacyPanels.removeWhere((_, value) => value == panel);
    controller.unregisterPanel(panel);
    if (_selectedPanel == panel) _selectedPanel = null;
  }

  void _unregisterThread(T thread) {
    final panel = _panels[thread];
    if (panel == null) return;
    controller.close(panel);
    _forget(panel);
  }

  void _clearBindings() {
    for (final panel in _threads.keys.toList()) {
      controller.unregisterPanel(panel);
    }
    _threads.clear();
    _references.clear();
    _panels.clear();
    _legacyPanels.clear();
    _openingOrder.clear();
    _previews.clear();
    _selectedPanel = null;
  }

  String? _activeChat(DockNode node) {
    for (final group in _allGroups(node)) {
      if (_threads.containsKey(group.active)) return group.active;
      for (final id in group.orderedPanelIds) {
        if (_threads.containsKey(id)) return id;
      }
    }
    return null;
  }

  Iterable<String> _treePanels(DockNode node) sync* {
    switch (node) {
      case DockTabs():
        yield* node.orderedPanelIds;
      case DockSplit():
        yield* _treePanels(node.first);
        yield* _treePanels(node.second);
    }
  }

  Iterable<String> _visiblePanels(DockNode node) sync* {
    switch (node) {
      case DockTabs():
        if (node.active.isNotEmpty) yield node.active;
      case DockSplit():
        yield* _visiblePanels(node.first);
        yield* _visiblePanels(node.second);
    }
  }

  bool _replaceRoot(DockNode root) {
    controller.registerPanels(
      root is DockTabs
          ? root.orderedPanelIds.where((id) => _threads.containsKey(id))
          : _treePanels(root).where((id) => _threads.containsKey(id)),
    );
    return controller.replaceRoot(root);
  }

  DockNode _replaceGroup(
    DockNode node,
    String groupId,
    DockTabs Function(DockTabs group) replace,
  ) => switch (node) {
    DockTabs() => node.groupId == groupId ? replace(node) : node,
    DockSplit() => node.copyWith(
      first: _replaceGroup(node.first, groupId, replace),
      second: _replaceGroup(node.second, groupId, replace),
    ),
  };

  DockNode? _toolOnlyRoot(Object? oldDock) {
    if (oldDock is! Map) return null;
    final source = oldDock['root'] ?? oldDock;
    final allowed = controller.availablePanelIds
        .where((id) => id != dockMainPanelId && !id.startsWith('chat:'))
        .toSet();
    final seen = <String>{};
    final groups = <String>{};
    return _readNode(source, allowed, seen, groups, skipChats: true);
  }

  void _layoutChanged() {
    if (_changing || _notifying) return;
    // Tool operations also come through this controller. Reconcile any dynamic
    // IDs removed through it so the public queries never expose stale chats.
    final open = controller.openPanelIds;
    for (final panel in _threads.keys.toList()) {
      if (!open.contains(panel)) {
        _threads.remove(panel);
        _references.remove(panel);
        _previews.remove(panel);
        _openingOrder.remove(panel);
        final thread = _panels.entries
            .where((entry) => entry.value == panel)
            .firstOrNull
            ?.key;
        if (thread != null) _panels.remove(thread);
        _legacyPanels.removeWhere((_, value) => value == panel);
        if (_selectedPanel == panel) _selectedPanel = null;
      }
    }
    _selectedPanel ??= _activeChat(controller.root);
    _changed();
  }

  void _commit(VoidCallback change) {
    _changing = true;
    try {
      change();
    } finally {
      _changing = false;
    }
    _changed();
  }

  void _changed() {
    if (_notifying) return;
    _notifying = true;
    try {
      _onChanged?.call();
    } finally {
      _notifying = false;
    }
  }

  static List<String> _stringList(Object? value) =>
      value is Iterable ? value.whereType<String>().toList() : const [];

  static Object? _decode(Object? value) {
    if (value is! String) return value;
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }

  void dispose() {
    controller.removeListener(_layoutChanged);
    controller.dispose();
  }
}

final class _Geometry {
  const _Geometry(this.left, this.top, this.right, this.bottom);
  static const unit = _Geometry(0, 0, 1, 1);
  final double left;
  final double top;
  final double right;
  final double bottom;
  double get width => right - left;
  double get height => bottom - top;
  _Geometry copyWith({
    double? left,
    double? top,
    double? right,
    double? bottom,
  }) => _Geometry(
    left ?? this.left,
    top ?? this.top,
    right ?? this.right,
    bottom ?? this.bottom,
  );
}

final class _GroupGeometry {
  const _GroupGeometry(this.tabs, this.bounds);
  final DockTabs tabs;
  final _Geometry bounds;
}

/// A strict reader used for untrusted saved layouts and old tool trees.
DockNode? _readNode(
  Object? value,
  Set<String> allowed,
  Set<String> seen,
  Set<String> groups, {
  bool skipChats = false,
}) {
  if (value is! Map) return null;
  switch (value['type']) {
    case 'tabs':
      final rawIds = value['orderedPanelIds'];
      if (rawIds is! Iterable) return null;
      final ids = <String>[];
      var hasChat = false;
      for (final id in rawIds) {
        if (id is! String) continue;
        if (skipChats && (id == dockMainPanelId || id.startsWith('chat:'))) {
          hasChat = true;
          continue;
        }
        if (allowed.contains(id) && seen.add(id)) ids.add(id);
      }
      if (ids.isEmpty) return null;
      var groupId =
          value['groupId'] is String && (value['groupId'] as String).isNotEmpty
          ? value['groupId'] as String
          : hasChat
          ? 'migrated-tools'
          : 'dock-group';
      var suffix = 0;
      final base = groupId;
      while (!groups.add(groupId)) {
        groupId = '$base-${++suffix}';
      }
      final active = value['active'];
      return DockTabs(
        groupId: groupId,
        orderedPanelIds: ids,
        active: active is String && ids.contains(active) ? active : ids.first,
      );
    case 'split':
      final first = _readNode(
        value['first'],
        allowed,
        seen,
        groups,
        skipChats: skipChats,
      );
      final second = _readNode(
        value['second'],
        allowed,
        seen,
        groups,
        skipChats: skipChats,
      );
      if (first == null) return second;
      if (second == null) return first;
      return DockSplit(
        axis: value['axis'] == 'vertical'
            ? DockAxis.vertical
            : DockAxis.horizontal,
        ratio: value['ratio'] is num
            ? (value['ratio']! as num).toDouble()
            : 0.5,
        first: first,
        second: second,
      );
  }
  return null;
}
