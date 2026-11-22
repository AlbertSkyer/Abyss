import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/mock_claude_code_transport.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/workspace/dock_layout.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Catalog implements SessionCatalog {
  @override
  Future<List<ProjectRecord>> projects() async => [
    ProjectRecord(
      path: '/dock',
      sessions: [
        for (final id in ['a', 'b', 'c'])
          SessionRecord(
            id: id,
            title: id,
            cwd: '/dock',
            updatedAt: DateTime(2026),
          ),
      ],
    ),
  ];
  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => [];
  @override
  Future<void> delete(String id) async {}
}

final KernelDescriptor kernel = KernelDescriptor(
  id: 'claude-code',
  label: 'test',
  icon: Icons.chat,
  description: '',
  catalog: Catalog(),
  create: (context) =>
      ClaudeCodeKernel(kernel, context, start: MockClaudeCodeTransport.start),
);

void main() {
  group('Abyss dock persistence', skip: !AppEdition.isAbyss, () {
    test(
      'legacy tree migrates once and restores tool activity and focus',
      () async {
        final store = MemoryPreferenceStore({
          'chat': {
            'panes': ['a', 'b'],
            'cells': [0, 1, 0, 1],
            'tabs': [
              ['a', 'c'],
              ['b'],
            ],
            'under': [
              ['c'],
              [],
            ],
            'active': ['a', 'b'],
            'focused': 1,
          },
          'workbench': {
            'dock': {
              'version': 1,
              'root': {
                'type': 'split',
                'axis': 'vertical',
                'ratio': 0.7,
                'first': {
                  'type': 'tabs',
                  'groupId': 'old-main',
                  'orderedPanelIds': ['main-chat'],
                  'active': 'main-chat',
                },
                'second': {
                  'type': 'tabs',
                  'groupId': 'old-tools',
                  'orderedPanelIds': ['files', 'terminal'],
                  'active': 'terminal',
                },
              },
            },
          },
        });
        final workspace = Workspace(kernels: [kernel], preferences: store);
        await workspace.load();
        expect(workspace.openChats.map((t) => t.id).toSet(), {'a', 'b', 'c'});
        expect(workspace.grid.isEmpty, isTrue);
        expect(workspace.chatDock.controller.root, isA<DockSplit>());
        expect(
          (workspace.chatDock.controller.root as DockSplit).axis,
          DockAxis.vertical,
        );
        final a = workspace.threads.firstWhere((t) => t.id == 'a');
        final b = workspace.threads.firstWhere((t) => t.id == 'b');
        workspace.select(b);
        workspace.chatDock.move(b, target: 'files');
        workspace.chatDock.focusPanel('terminal');
        workspace.keepGridLines();
        final saved = workspace.chatDock.toJson();
        workspace.dispose();
        await pumpEventQueue();
        final restored = Workspace(kernels: [kernel], preferences: store);
        await restored.load();
        expect(restored.openChats.map((t) => t.id).toSet(), {'a', 'b', 'c'});
        expect(restored.chatDock.toJson()['layout'], saved['layout']);
        expect(restored.current?.id, b.id);
        expect(
          restored.isShown(restored.threads.firstWhere((t) => t.id == 'b')),
          isFalse,
        );
        expect(a.id, 'a');
        restored.dispose();
      },
    );

    test('new-chat slots keep independent drafts across restart', () async {
      final store = MemoryPreferenceStore({
        'chat': {
          'version': 2,
          'layout': {
            'version': 1,
            'root': {
              'type': 'tabs',
              'groupId': 'g',
              'orderedPanelIds': ['chat:one', 'chat:two'],
              'active': 'chat:two',
            },
          },
          'bindings': {
            'chat:one': {'new': '/dock', 'slot': 'one'},
            'chat:two': {'new': '/dock', 'slot': 'two'},
          },
          'selected': 'chat:two',
        },
      });
      final drafts = MemoryPreferenceStore();
      final workspace = Workspace(
        kernels: [kernel],
        preferences: store,
        drafts: drafts,
      );
      await workspace.load();
      final one = workspace.chatDock.threadFor('chat:one')!;
      final two = workspace.chatDock.threadFor('chat:two')!;
      expect(one, isNot(same(two)));
      one.session.draft.save(
        'ONE',
        const TextSelection.collapsed(offset: 3),
        const [],
      );
      two.session.draft.save(
        'TWO',
        const TextSelection.collapsed(offset: 3),
        const [],
      );
      workspace.keepGridLines();
      workspace.dispose();
      await pumpEventQueue();
      final restored = Workspace(
        kernels: [kernel],
        preferences: store,
        drafts: drafts,
      );
      await restored.load();
      expect(
        restored.chatDock.threadFor('chat:one')!.session.draft.content,
        'ONE',
      );
      expect(
        restored.chatDock.threadFor('chat:two')!.session.draft.content,
        'TWO',
      );
      restored.dispose();
    });

    test('a detached chat keeps its thread and redocks where it was', () async {
      final workspace = Workspace(
        kernels: [kernel],
        preferences: MemoryPreferenceStore(),
      );
      await workspace.load();
      final a = workspace.threads.firstWhere((t) => t.id == 'a');
      final b = workspace.threads.firstWhere((t) => t.id == 'b');
      workspace.openChatTab(a);
      workspace.openChatTab(b);
      final panel = workspace.chatDock.panelId(b);
      final group = workspace.chatDock.groupOf(b)!.groupId;
      final index = workspace.chatDock.tabsOf(b).indexOf(b);
      expect(workspace.detachChatTab(b), isTrue);
      expect(workspace.isChatDetached(b), isTrue);
      expect(workspace.openChats, isNot(contains(b)));
      expect(workspace.chatDock.threadFor(panel), isNull);
      expect(
        workspace.resolveFloatingThread(workspace.referenceOfThread(b), panel),
        same(b),
      );
      expect(workspace.redockChatTab(b, groupId: group, index: index), isTrue);
      expect(workspace.isChatDetached(b), isFalse);
      expect(workspace.chatDock.tabsOf(b), containsAllInOrder([a, b]));
      expect(identical(workspace.current, b), isTrue);
      workspace.dispose();
    });

    test('an unsent detached chat resolves to the same thread', () async {
      final workspace = Workspace(
        kernels: [kernel],
        preferences: MemoryPreferenceStore(),
      );
      await workspace.load();
      final source = workspace.threads.firstWhere((t) => t.id == 'a');
      final draft = workspace.create(project: source.project);
      expect(draft.id, isNull);
      final reference = workspace.referenceOfThread(draft);
      expect((reference as Map)['new'], source.project.path);
      final panel = workspace.chatDock.panelId(draft);
      expect(workspace.detachChatTab(draft), isTrue);
      expect(workspace.resolveFloatingThread(reference, panel), same(draft));
      expect(workspace.redockChatTab(draft), isTrue);
      expect(workspace.isChatDetached(draft), isFalse);
      workspace.dispose();
    });

    test(
      'a generic owner lookup can leave the live dock chat mounted',
      () async {
        final workspace = Workspace(
          kernels: [kernel],
          preferences: MemoryPreferenceStore(),
        );
        await workspace.load();
        final a = workspace.threads.firstWhere((t) => t.id == 'a');
        workspace.openChatTab(a);
        final panel = workspace.chatDock.panelId(a);
        expect(
          workspace.resolveFloatingThread(
            workspace.referenceOfThread(a),
            panel,
            detach: false,
          ),
          same(a),
        );
        expect(workspace.isChatDetached(a), isFalse);
        expect(workspace.openChats, contains(a));
        workspace.dispose();
      },
    );

    test('a restored window chat not in the dock is marked detached', () async {
      final workspace = Workspace(
        kernels: [kernel],
        preferences: MemoryPreferenceStore(),
      );
      await workspace.load();
      final b = workspace.threads.firstWhere((t) => t.id == 'b');
      expect(workspace.openChats, isNot(contains(b)));
      final panel = 'chat:restored-window';
      expect(
        workspace.resolveFloatingThread(workspace.referenceOfThread(b), panel),
        same(b),
      );
      expect(workspace.isChatDetached(b), isTrue);
      // Raw opens and restores cannot mount it while its window holds it.
      expect(workspace.chatDock.open(b), isFalse);
      expect(workspace.openChats, isNot(contains(b)));
      expect(workspace.redockChatTab(b), isTrue);
      expect(workspace.isChatDetached(b), isFalse);
      expect(workspace.openChats, contains(b));
      workspace.dispose();
    });

    test('archiving a detached chat releases its marker', () async {
      final workspace = Workspace(
        kernels: [kernel],
        preferences: MemoryPreferenceStore(),
      );
      await workspace.load();
      final b = workspace.threads.firstWhere((t) => t.id == 'b');
      workspace.openChatTab(b);
      expect(workspace.detachChatTab(b), isTrue);
      workspace.setArchived(b, true);
      expect(workspace.isChatDetached(b), isFalse);
      expect(workspace.redockChatTab(b), isFalse);
      workspace.dispose();
    });

    test('an unsent scratch window restores its draft text', () async {
      final store = MemoryPreferenceStore();
      final drafts = MemoryPreferenceStore();
      final workspace = Workspace(
        kernels: [kernel],
        preferences: store,
        drafts: drafts,
      );
      await workspace.load();
      final source = workspace.threads.firstWhere((t) => t.id == 'a');
      final scratch = await workspace.createEmptyScratch(source);
      scratch.session.draft.save(
        'SCRATCH',
        const TextSelection.collapsed(offset: 7),
        const [],
      );
      final reference = workspace.referenceOfScratch(scratch);
      expect((reference! as Map)['empty'], isTrue);
      workspace.dispose();
      await pumpEventQueue();
      final restored = Workspace(
        kernels: [kernel],
        preferences: store,
        drafts: drafts,
      );
      await restored.load();
      final again = restored.resolveFloatingScratch(reference, null);
      expect(again, isNotNull);
      expect(again!.session.draft.content, 'SCRATCH');
      expect(restored.isScratch(again), isTrue);
      expect(restored.isChatDetached(again), isTrue);
      expect(restored.redockChatTab(again), isTrue);
      expect(restored.isChatDetached(again), isFalse);
      restored.dispose();
    });
  });
}
