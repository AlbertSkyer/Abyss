import 'dart:convert';

import 'package:baocode/workspace/chat_dock.dart';
import 'package:baocode/workspace/chat_grid.dart';
import 'package:baocode/workspace/dock_layout.dart';
import 'package:flutter_test/flutter_test.dart';

ChatDock<String> dock({
  List<String>? drafts,
  Map<String, String>? references,
}) => ChatDock<String>(
  referenceOf: (thread) => references?[thread] ?? thread,
  resolveReference: (reference, panel) {
    if (reference is String && reference.startsWith('missing')) return null;
    return reference is String
        ? reference
        : (reference as Map)['new'] as String?;
  },
  hasDraft: (thread) => drafts?.contains(thread) ?? false,
);

Map<String, Object?> layout(Iterable<DockTabs> groups) => {
  'version': 1,
  'root': {
    'type': 'tabs',
    'groupId': 'main',
    'orderedPanelIds': [
      'main-chat',
      for (final g in groups) ...g.orderedPanelIds,
    ],
    'active': 'main-chat',
  },
};

void main() {
  group('stable bindings and session operations', () {
    test('new references have stable tokens and drafts are pinned', () {
      final references = <String, String>{};
      final chats = ChatDock<String>(
        referenceOf: (thread) =>
            references[thread] ?? {'new': '/project', 'slot': thread},
        resolveReference: (reference, panel) =>
            reference is String ? reference : '${(reference as Map)['slot']}',
      );
      expect(chats.open('/one', preview: true), isTrue);
      final panel = chats.panelId('/one');
      expect(panel, 'chat:new:%2Fproject-slot-%2Fone');
      references['/one'] = 'session-1';
      expect(chats.panelId('/one'), panel);
      expect(chats.toJson()['bindings'], {panel: 'session-1'});
      expect(chats.open('/one'), isTrue);
      expect(chats.openChats, ['/one']);
      expect(chats.isPreview('/one'), isFalse);
    });

    test('one preview per group, explicit tabs never evicted', () {
      final chats = dock(drafts: ['draft']);
      chats.open('fixed');
      chats.open('preview-1', preview: true);
      chats.open('preview-2', preview: true);
      expect(chats.openChats, ['fixed', 'preview-2']);
      expect(chats.visibleChats, ['preview-2']);
      expect(chats.isPreview('preview-2'), isTrue);
      expect(chats.open('draft', preview: true), isTrue);
      expect(chats.openChats.toSet(), {'fixed', 'preview-2', 'draft'});
      expect(chats.isPreview('draft'), isFalse);
      expect(chats.pin('preview-2'), isTrue);
      chats.open('preview-3', preview: true);
      expect(chats.openChats.toSet(), {
        'fixed',
        'preview-2',
        'draft',
        'preview-3',
      });
    });

    test('activate, close, tabs, focus and neighbor follow the dock tree', () {
      final chats = dock();
      chats.open('left');
      chats.open('covered');
      chats.open('right', target: 'left', side: DockSide.right);
      chats.open('right-tab', target: 'right');
      expect(chats.tabsOf('right-tab'), ['right', 'right-tab']);
      expect(chats.visibleChats.toSet(), {'covered', 'right-tab'});
      chats.activate('left');
      chats.activate('right');
      expect(chats.selected, 'right');
      expect(chats.neighbor('right', DockSide.left), 'left');
      expect(chats.neighbor('left', DockSide.right), 'right');
      expect(chats.focusGroup(chats.groupOf('left')!.groupId), isTrue);
      expect(chats.focusedGroup, chats.groupOf('left'));
      chats.activate('right');
      chats.close('right-tab');
      expect(chats.selected, 'right');
      chats.close('right');
      expect(chats.openChats.toSet(), {'left', 'covered'});
      chats.activate('left');
      chats.close('covered');
      expect(chats.selected, 'left');
      chats.close('left');
      expect(chats.openChats, isEmpty);
      expect(chats.controller.root, isA<DockTabs>());
      expect((chats.controller.root as DockTabs).orderedPanelIds, isEmpty);
    });

    test('move, root move, reorder and callbacks', () {
      var notifications = 0;
      final chats = dock()..open('a');
      chats.controller.addListener(() => notifications++);
      chats.open('b', target: 'a');
      expect(
        chats.reorder('a', group: chats.groupOf('b')!.groupId, before: null),
        isTrue,
      );
      expect(chats.tabsOf('a'), ['b', 'a']);
      expect(chats.move('a', target: 'b', side: DockSide.bottom), isTrue);
      expect(chats.neighbor('a', DockSide.top), 'b');
      expect(
        chats.move('a', target: 'b', root: true, side: DockSide.right),
        isTrue,
      );
      expect(chats.controller.root, isA<DockSplit>());
      expect(chats.move('a', target: 'does-not-exist'), isFalse);
      expect(notifications, greaterThan(0));
    });
  });

  group('version 2 persistence', () {
    test('round trip keeps references, previews, selection and tools', () {
      final chats = dock();
      chats.open('one');
      chats.open('two', preview: true);
      chats.controller.open('files');
      final saved = jsonDecode(jsonEncode(chats.toJson()));
      final restored = dock();
      expect(restored.restore(saved), isTrue);
      expect(restored.openChats, ['one', 'two']);
      expect(restored.selected, 'two');
      expect(restored.isPreview('two'), isTrue);
      expect(restored.controller.openPanelIds, contains('files'));
      expect(restored.toJson()['layout'], saved['layout']);
    });

    test('bad bindings are skipped but valid sessions and tools survive', () {
      final chats = dock();
      final saved = chats.toJson();
      saved['bindings'] = {
        'chat:valid': 'valid',
        'chat:bad': 'missing-one',
        'chat:also-bad': 42,
      };
      saved['layout'] = {
        'version': 1,
        'root': {
          'type': 'split',
          'axis': 'horizontal',
          'ratio': 0.4,
          'first': {
            'type': 'tabs',
            'groupId': 'chat',
            'orderedPanelIds': ['chat:valid', 'chat:bad'],
            'active': 'chat:bad',
          },
          'second': {
            'type': 'tabs',
            'groupId': 'tools',
            'orderedPanelIds': ['files', 'not-registered'],
            'active': 'files',
          },
        },
      };
      saved['selected'] = 'chat:bad';
      expect(chats.restore(saved), isTrue);
      expect(chats.openChats, ['valid']);
      expect(chats.selected, 'valid');
      expect(chats.controller.openPanelIds, {'chat:valid', 'files'});
    });

    test('empty tree round trip does not recreate a conversation', () {
      final chats = dock()..open('last');
      chats.close('last');
      final saved = chats.toJson();
      final restored = dock();
      expect(restored.restore(saved), isTrue);
      expect(restored.openChats, isEmpty);
      expect(restored.controller.isEmpty, isTrue);
    });

    test('direct closing an unselected chat preserves the tool target', () {
      final chats = dock()
        ..open('a')
        ..open('b');
      chats.controller.open('files');
      chats.focusPanel('files');
      chats.controller.close(chats.panelId('a'));
      expect(chats.selected, 'b');
      expect(chats.visibleChats, isEmpty);
    });

    test('malformed restore is atomic', () {
      final chats = dock()..open('keep');
      final before = chats.toJson();
      expect(chats.restore('{broken'), isFalse);
      expect(chats.restore({'version': 2, 'bindings': {}}), isFalse);
      expect(chats.toJson(), before);
    });
  });

  group('legacy migration and presets', () {
    test('migrates grid tabs, ratios and old dock tools without main-chat', () {
      final chats = dock();
      final grid = ChatGrid<String>()
        ..restore(['a', 'b', 'a', 'c'])
        ..restoreTabs('a', ['hidden', 'a'], ['hidden'])
        ..columnRatios = [0.31, 0.31];
      final oldDock = {
        'version': 1,
        'root': {
          'type': 'tabs',
          'groupId': 'old',
          'orderedPanelIds': ['main-chat', 'files'],
          'active': 'main-chat',
        },
      };
      expect(chats.migrateLegacy(oldDock, grid), isTrue);
      expect(chats.openChats.toSet(), {'a', 'b', 'c', 'hidden'});
      expect(chats.controller.openPanelIds, contains('files'));
      expect(chats.controller.openPanelIds, isNot(contains('main-chat')));
      expect(chats.tabsOf('a').toSet(), {'a', 'hidden'});
      expect(chats.controller.root, isA<DockSplit>());
      expect((chats.controller.root as DockSplit).ratio, 0.68);
      final chatRoot = (chats.controller.root as DockSplit).first;
      expect(chatRoot, isA<DockSplit>());
      expect((chatRoot as DockSplit).ratio, closeTo(0.31, 0.001));
    });

    test('empty legacy grid retains tools and can be empty safely', () {
      final chats = dock();
      chats.migrateLegacy(null, ChatGrid<String>());
      expect(chats.openChats, isEmpty);
      chats.migrateLegacy({
        'version': 1,
        'root': {
          'type': 'tabs',
          'groupId': 'g',
          'orderedPanelIds': ['main-chat', 'files'],
          'active': 'main-chat',
        },
      }, ChatGrid<String>());
      expect(chats.controller.openPanelIds, {'files'});
    });

    test('applying multiple main-chat slots retains every open chat', () {
      final chats = dock();
      for (final name in ['a', 'b', 'c', 'd']) {
        chats.open(name);
      }
      final old = chats.openChats.toSet();
      final preset = {
        'version': 1,
        'root': {
          'type': 'split',
          'axis': 'horizontal',
          'ratio': 0.5,
          'first': {
            'type': 'tabs',
            'groupId': 'left',
            'orderedPanelIds': ['main-chat', 'files'],
            'active': 'main-chat',
          },
          'second': {
            'type': 'tabs',
            'groupId': 'right',
            'orderedPanelIds': ['main-chat'],
            'active': 'main-chat',
          },
        },
      };
      expect(chats.applyPreset(preset), isTrue);
      expect(chats.openChats.toSet(), old);
      expect(chats.controller.openPanelIds, contains('files'));
      expect(chats.controller.openPanelIds, isNot(contains('main-chat')));
      expect(chats.visibleChats.length, 1);
      expect(chats.tabsOf('a').toSet(), old);
    });

    test('preset snapshot has slots but no session bindings', () {
      final chats = dock();
      chats.open('secret-session');
      chats.open('other', target: 'secret-session', side: DockSide.right);
      final snapshot = chats.presetJson();
      final encoded = jsonEncode(snapshot);
      expect(encoded, contains('main-chat'));
      expect(encoded, isNot(contains('secret-session')));
      expect(encoded, isNot(contains('bindings')));
      expect(chats.applyPreset(snapshot), isTrue);
      expect(chats.openChats.toSet(), {'secret-session', 'other'});
    });
  });

  group('detached chats', () {
    test('detach keeps the tab out and redock restores its group index', () {
      final chats = dock();
      chats.open('a');
      chats.open('b', target: 'a');
      chats.open('c', target: 'b');
      final panel = chats.panelId('b');
      expect(chats.detach('b'), isTrue);
      expect(chats.isDetached('b'), isTrue);
      expect(chats.openChats, ['a', 'c']);
      expect(chats.visibleChats, isNot(contains('b')));
      expect(chats.open('b'), isFalse);
      expect(chats.activate('b'), isFalse);
      expect(jsonEncode(chats.toJson()), isNot(contains(panel)));
      expect(chats.redock('b'), isTrue);
      expect(chats.isDetached('b'), isFalse);
      expect(chats.openChats.toSet(), {'a', 'b', 'c'});
      expect(chats.tabsOf('a'), ['a', 'b', 'c']);
      expect(chats.selected, 'b');
      expect(chats.panelId('b'), panel);
    });

    test('an unsent detached chat keeps its reference token', () {
      final chats = ChatDock<String>(
        referenceOf: (thread) => {'new': '/project', 'slot': thread},
        resolveReference: (reference, panel) => reference is String
            ? reference
            : (reference as Map)['slot'] as String,
      );
      chats.open('one');
      final panel = chats.panelId('one');
      chats.detach('one');
      expect(chats.redock('one'), isTrue);
      expect(chats.panelId('one'), panel);
      expect(chats.toJson()['bindings'], {
        panel: {'new': '/project', 'slot': 'one'},
      });
    });

    test('restore never mounts a detached chat a second time', () {
      final chats = dock();
      chats.open('one');
      chats.open('two');
      final saved = jsonDecode(jsonEncode(chats.toJson()));
      expect(chats.detach('one'), isTrue);
      expect(chats.restore(saved), isTrue);
      expect(chats.isDetached('one'), isTrue);
      expect(chats.openChats, ['two']);
    });

    test('a released detached chat is not mounted by restoring it', () {
      final chats = dock();
      chats.open('one');
      final saved = jsonDecode(jsonEncode(chats.toJson()));
      chats.detach('one');
      chats.releaseDetached('one');
      expect(chats.isDetached('one'), isFalse);
      expect(chats.openChats, isEmpty);
      // Not detached any more: it can come back normally.
      expect(chats.restore(saved), isTrue);
      expect(chats.openChats, ['one']);
    });
  });

  group('blocked tool panels', () {
    test('a blocked tool leaves the tree and cannot be mounted raw', () {
      final chats = dock();
      chats.open('chat');
      chats.controller.open('files');
      final placement = chats.controller.panelPlacement('files')!;
      expect(chats.controller.blockPanel('files'), isTrue);
      expect(chats.controller.isPanelBlocked('files'), isTrue);
      expect(chats.controller.openPanelIds, isNot(contains('files')));
      expect(chats.controller.open('files'), isFalse);
      expect(chats.controller.reveal('files'), isFalse);
      expect(
        chats.controller.move('files', target: chats.panelId('chat')),
        isFalse,
      );
      expect(
        chats.controller.insertPanel('files', groupId: placement.groupId),
        isFalse,
      );
      final chatPanel = chats.panelId('chat');
      expect(
        chats.controller.replaceRoot(
          DockTabs(
            groupId: placement.groupId,
            orderedPanelIds: [chatPanel, 'files'],
            active: chatPanel,
          ),
        ),
        isTrue,
      );
      expect(chats.controller.openPanelIds, {chatPanel});
      expect(
        chats.controller.unblockPanel(
          'files',
          groupId: placement.groupId,
          index: placement.index,
        ),
        isTrue,
      );
      expect(chats.controller.isPanelBlocked('files'), isFalse);
      expect(chats.controller.openPanelIds, contains('files'));
      expect(chats.controller.panelPlacement('files'), (
        groupId: placement.groupId,
        index: placement.index,
      ));
    });

    test('loadJson and stale dock-close cannot reopen a floating tool', () {
      final chats = dock();
      chats.open('chat');
      final panel = chats.panelId('chat');
      chats.controller.open('files');
      chats.controller.blockPanel('files');
      chats.controller.loadJson({
        'version': 1,
        'root': {
          'type': 'tabs',
          'groupId': 'restored',
          'orderedPanelIds': [panel, 'files'],
          'active': 'files',
        },
      });
      expect(chats.controller.openPanelIds, isNot(contains('files')));
      expect(chats.controller.close('files'), isFalse);
      expect(chats.controller.removePanel('files'), isFalse);
      expect(chats.controller.isPanelBlocked('files'), isTrue);
    });
  });
}
