import 'dart:convert';

import 'package:baocode/workspace/dock_layout.dart';
import 'package:flutter_test/flutter_test.dart';

DockTabs _group(DockNode node, String panelId) {
  switch (node) {
    case DockTabs():
      if (node.orderedPanelIds.contains(panelId)) return node;
      throw StateError('Missing $panelId');
    case DockSplit():
      try {
        return _group(node.first, panelId);
      } on StateError {
        return _group(node.second, panelId);
      }
  }
}

void main() {
  test('default, open, reveal and protected main panel', () {
    final controller = DockController();
    addTearDown(controller.dispose);
    expect(controller.openPanelIds, {'main-chat', 'files'});
    expect((controller.root as DockSplit).ratio, 0.68);
    expect(controller.open('unknown'), isFalse);

    expect(controller.open('terminal'), isTrue);
    expect(_group(controller.root, 'files').orderedPanelIds, [
      'files',
      'terminal',
    ]);
    expect(_group(controller.root, 'files').active, 'terminal');
    expect(controller.open('terminal'), isTrue);
    expect(controller.openPanelIds.length, 3);
    expect(controller.reveal('files'), isTrue);
    expect(_group(controller.root, 'files').active, 'files');
    expect(controller.close('main-chat'), isFalse);
    expect(controller.openPanelIds, contains('main-chat'));
  });

  test('tab reorder and cross-group move never duplicate a panel', () {
    final controller = DockController();
    addTearDown(controller.dispose);
    controller
      ..open('terminal')
      ..open('changes');

    expect(controller.move('terminal', target: 'files'), isTrue);
    expect(_group(controller.root, 'terminal').orderedPanelIds, [
      'terminal',
      'files',
      'changes',
    ]);
    expect(controller.move('terminal', target: 'changes'), isTrue);
    expect(_group(controller.root, 'terminal').orderedPanelIds, [
      'files',
      'changes',
      'terminal',
    ]);

    expect(controller.move('terminal', target: 'main-chat'), isTrue);
    expect(_group(controller.root, 'main-chat').orderedPanelIds, [
      'terminal',
      'main-chat',
    ]);
    expect(controller.openPanelIds, {
      'main-chat',
      'files',
      'changes',
      'terminal',
    });
    expect(
      _group(controller.root, 'main-chat').orderedPanelIds.toSet().length,
      _group(controller.root, 'main-chat').orderedPanelIds.length,
    );
  });

  for (final side in DockSide.values) {
    test('${side.name} drop creates the requested binary split', () {
      final controller = DockController();
      addTearDown(controller.dispose);
      expect(controller.move('files', target: 'main-chat', side: side), isTrue);
      final split = controller.root as DockSplit;
      final horizontal = side == DockSide.left || side == DockSide.right;
      final movedFirst = side == DockSide.left || side == DockSide.top;
      expect(split.axis, horizontal ? DockAxis.horizontal : DockAxis.vertical);
      final moved = movedFirst ? split.first : split.second;
      final original = movedFirst ? split.second : split.first;
      expect((moved as DockTabs).orderedPanelIds, ['files']);
      expect((original as DockTabs).orderedPanelIds, ['main-chat']);
      expect(controller.openPanelIds, {'main-chat', 'files'});
    });
  }

  test('close selects a neighbour and removes empty groups', () {
    final controller = DockController();
    addTearDown(controller.dispose);
    controller
      ..open('terminal')
      ..open('changes')
      ..reveal('terminal');
    expect(controller.close('terminal'), isTrue);
    expect(_group(controller.root, 'files').active, 'changes');
    expect(controller.close('changes'), isTrue);
    expect(controller.close('files'), isTrue);
    expect(controller.root, isA<DockTabs>());
    expect(controller.openPanelIds, {'main-chat'});
    expect(controller.close('missing'), isFalse);
  });

  test('resize uses stable paths and clamps both model ratios', () {
    final controller = DockController();
    addTearDown(controller.dispose);
    controller
      ..open('terminal')
      ..move('terminal', target: 'main-chat', side: DockSide.top);
    expect(controller.splitAtPath('0'), isA<DockSplit>());
    expect(controller.resize('0', 0.25), isTrue);
    expect(controller.splitAtPath('0')!.ratio, 0.25);
    expect(controller.resize('0', -2), isTrue);
    expect(controller.splitAtPath('0')!.ratio, 0.05);
    expect(controller.resize('', 4), isTrue);
    expect(controller.splitAtPath('')!.ratio, 0.95);
    expect(controller.resize('not-a-path', 0.5), isFalse);
    expect(controller.resize('', double.nan), isFalse);
  });

  test('maximize is temporary and restore preserves the layout', () {
    final controller = DockController();
    addTearDown(controller.dispose);
    expect(controller.maximize('missing'), isFalse);
    expect(controller.maximize('files'), isTrue);
    final saved = jsonEncode(controller.toJson());
    expect(controller.maximizedPanelId, 'files');
    expect(controller.restore(), isTrue);
    expect(controller.restore(), isFalse);
    expect(jsonEncode(controller.toJson()), saved);
    expect(jsonEncode(controller.toJson()), isNot(contains('maximized')));
  });

  test('preset round trip keeps groups, order, active tabs and ratios', () {
    final controller = DockController()
      ..open('terminal')
      ..move('files', target: 'main-chat')
      ..resize('', 0.31);
    addTearDown(controller.dispose);
    final restored = DockController.fromJson(jsonEncode(controller.toJson()));
    addTearDown(restored.dispose);
    expect(restored.toJson(), controller.toJson());
    expect(restored.maximizedPanelId, isNull);
  });

  test('JSON sanitizes duplicates, unknown IDs, bad active and ratios', () {
    final controller = DockController.fromJson({
      'version': 1,
      'root': {
        'type': 'split',
        'axis': 'vertical',
        'ratio': 8,
        'first': {
          'type': 'tabs',
          'groupId': 'same',
          'orderedPanelIds': ['main-chat', 'main-chat'],
          'active': 'missing',
        },
        'second': {
          'type': 'tabs',
          'groupId': 'same',
          'orderedPanelIds': ['files', 'main-chat', 'unknown', 'files'],
          'active': 'main-chat',
        },
      },
    });
    addTearDown(controller.dispose);
    expect(controller.openPanelIds, {'main-chat', 'files'});
    expect(controller.openPanelIds.length, 2);
    expect(_group(controller.root, 'main-chat').active, 'main-chat');
    expect(_group(controller.root, 'files').active, 'files');
    expect(
      _group(controller.root, 'main-chat').groupId,
      isNot(_group(controller.root, 'files').groupId),
    );
    expect((controller.root as DockSplit).ratio, 0.95);
  });

  test('bad presets and standalone bad nodes safely restore main layout', () {
    for (final bad in [
      null,
      '{bad',
      {'version': 99},
      {'version': 1},
    ]) {
      final controller = DockController.fromJson(bad);
      expect(controller.openPanelIds, {'main-chat', 'files'});
      expect(controller.root, isA<DockSplit>());
      controller.dispose();
    }
    final node = DockNode.fromJson({
      'type': 'tabs',
      'groupId': 'g',
      'orderedPanelIds': ['files'],
      'active': 'files',
    }) as DockTabs;
    expect(node.orderedPanelIds, ['main-chat', 'files']);
  });
}
