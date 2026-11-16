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

  test('generic empty layout opens dynamic chat panels without main chat', () {
    final controller = DockController(
      availablePanelIds: const ['tools'],
      requiredPanelId: null,
    );
    addTearDown(controller.dispose);
    final empty = controller.root as DockTabs;
    expect(empty.orderedPanelIds, isEmpty);
    expect(empty.active, '');
    expect(empty.copyWith(orderedPanelIds: const []).active, '');
    expect(controller.isEmpty, isTrue);
    expect(controller.focusedGroup, isNull);
    expect(controller.openPanelIds, isEmpty);
    expect(controller.availablePanelIds, {'tools'});
    expect(controller.open('tools'), isTrue);
    expect(controller.close('tools'), isTrue);
    expect(controller.isEmpty, isTrue);
    expect(controller.toJson()['version'], dockLayoutVersion);

    expect(controller.registerPanel('chat:one'), isTrue);
    expect(controller.registerPanel('chat:one'), isFalse);
    controller.registerPanels(const ['chat:two', 'chat:two', '']);
    expect(controller.openPanelIds, isEmpty);
    expect(controller.open('chat:one'), isTrue);
    expect(controller.open('chat:two'), isTrue);
    expect(_group(controller.root, 'chat:one').orderedPanelIds, [
      'chat:one',
      'chat:two',
    ]);
    expect(controller.availablePanelIds.contains('main-chat'), isFalse);
    expect(controller.close('chat:one'), isTrue);
    expect(controller.close('chat:two'), isTrue);
    expect(controller.isEmpty, isTrue);
  });

  test(
    'unregister closes only that dynamic panel and preserves required ID',
    () {
      final controller =
          DockController(
              availablePanelIds: const ['chat:one', 'chat:two'],
              requiredPanelId: null,
            )
            ..open('chat:one')
            ..open('chat:two');
      addTearDown(controller.dispose);
      expect(controller.unregisterPanel('chat:one'), isTrue);
      expect(controller.openPanelIds, {'chat:two'});
      expect(controller.availablePanelIds, {'chat:two'});
      expect(controller.open('chat:one'), isFalse);
      expect(controller.unregisterPanel('chat:one'), isFalse);
      expect(controller.unregisterPanel('chat:two'), isTrue);
      expect(controller.isEmpty, isTrue);

      final required = DockController(
        availablePanelIds: const ['other'],
        requiredPanelId: 'required',
      );
      addTearDown(required.dispose);
      expect(required.openPanelIds, {'required'});
      expect(required.close('required'), isFalse);
      expect(required.unregisterPanel('required'), isFalse);
      required.open('other');
      expect(required.close('other'), isTrue);
      expect(required.openPanelIds, {'required'});
      expect(required.removePanel('required'), isTrue);
      expect(required.isEmpty, isTrue);
    },
  );

  test('replaceRoot is atomic and empty split branches collapse', () {
    final controller = DockController(
      availablePanelIds: const ['one', 'two'],
      requiredPanelId: null,
    );
    addTearDown(controller.dispose);
    final replacement = DockSplit(
      axis: DockAxis.vertical,
      ratio: 0.4,
      first: DockTabs(
        groupId: 'g1',
        orderedPanelIds: const ['one', 'one'],
        active: 'one',
      ),
      second: DockTabs(
        groupId: 'g2',
        orderedPanelIds: const ['two'],
        active: 'two',
      ),
    );
    expect(controller.replaceRoot(replacement), isTrue);
    expect(controller.openPanelIds, {'one', 'two'});
    expect(controller.availablePanelIds, {'one', 'two'});
    expect(controller.focusedGroup!.groupId, 'g2');
    expect(controller.focusGroup('g1'), isTrue);
    controller.open('two');
    expect(controller.openPanelIds, {'one', 'two'});

    final before = controller.toJson();
    expect(
      controller.replaceRoot(
        DockTabs(
          groupId: 'invalid',
          orderedPanelIds: const ['one', 'not-registered'],
          active: 'one',
        ),
      ),
      isFalse,
    );
    expect(controller.toJson(), before);
    expect(controller.availablePanelIds.contains('not-registered'), isFalse);
    expect(controller.focusGroup('missing'), isFalse);

    final collapsed = DockController(
      availablePanelIds: const ['one'],
      requiredPanelId: null,
      root: DockSplit(
        axis: DockAxis.horizontal,
        ratio: 0.5,
        first: DockTabs(
          groupId: 'empty',
          orderedPanelIds: const [],
          active: '',
        ),
        second: DockTabs(
          groupId: 'one-group',
          orderedPanelIds: const ['one'],
          active: 'one',
        ),
      ),
    );
    addTearDown(collapsed.dispose);
    expect(collapsed.root, isA<DockTabs>());
    expect((collapsed.root as DockTabs).groupId, 'one-group');
  });

  test(
    'dynamic JSON restores IDs, preserves empty state and de-duplicates',
    () {
      final restored = DockController.fromJson(
        {
          'version': 1,
          'root': {
            'type': 'split',
            'axis': 'horizontal',
            'ratio': 0.5,
            'first': {
              'type': 'tabs',
              'groupId': 'chats',
              'orderedPanelIds': ['chat:one', 'chat:one', 'chat:two'],
              'active': 'chat:two',
            },
            'second': {
              'type': 'tabs',
              'groupId': 'other',
              'orderedPanelIds': ['chat:one', 'tools'],
              'active': 'tools',
            },
          },
        },
        availablePanelIds: const ['tools'],
        requiredPanelId: null,
      );
      addTearDown(restored.dispose);
      expect(restored.openPanelIds, {'chat:one', 'chat:two', 'tools'});
      expect(restored.availablePanelIds, restored.openPanelIds);
      expect(restored.availablePanelIds.contains('main-chat'), isFalse);
      expect(_group(restored.root, 'chat:one').active, 'chat:two');
      expect(_group(restored.root, 'tools').orderedPanelIds, ['tools']);
      expect(restored.toJson()['version'], 1);

      final empty =
          DockController.fromJson(
            restored.toJson(),
            availablePanelIds: const ['tools'],
            requiredPanelId: null,
          )..loadJson({
            'version': 1,
            'root': {
              'type': 'tabs',
              'groupId': 'empty',
              'orderedPanelIds': const [],
              'active': '',
            },
          });
      addTearDown(empty.dispose);
      expect(empty.isEmpty, isTrue);
      expect(empty.openPanelIds, isEmpty);
      expect(empty.availablePanelIds, restored.availablePanelIds);
      empty.open('chat:one');
      expect(empty.openPanelIds, {'chat:one'});
    },
  );

  for (final side in DockSide.values) {
    test('${side.name} root move docks at the complete tree edge', () {
      final controller =
          DockController(
              availablePanelIds: const ['one', 'two', 'three'],
              requiredPanelId: null,
            )
            ..open('one')
            ..open('two');
      addTearDown(controller.dispose);
      controller.open('three');
      controller.move('three', target: 'one', side: DockSide.bottom);
      expect(controller.root, isA<DockSplit>());
      final oldRoot = controller.root;
      expect(controller.moveToRoot('three', side: side), isTrue);
      final root = controller.root as DockSplit;
      expect(
        root.axis,
        side == DockSide.left || side == DockSide.right
            ? DockAxis.horizontal
            : DockAxis.vertical,
      );
      final movedFirst = side == DockSide.left || side == DockSide.top;
      final moved = movedFirst ? root.first : root.second;
      final remainder = movedFirst ? root.second : root.first;
      expect((moved as DockTabs).orderedPanelIds, ['three']);
      expect(remainder, isNot(same(oldRoot)));
      expect(controller.openPanelIds, {'one', 'two', 'three'});
      expect(controller.focusedGroup!.orderedPanelIds, ['three']);
    });
  }

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
