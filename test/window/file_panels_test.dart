import 'dart:ui' show AppExitResponse, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/side_panel/file_link.dart' show FileLineRange;
import 'package:baocode/chat/side_panel/file_open.dart' show FileOpenRequest;
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/window/app_windows.dart';
import 'package:baocode/window/code_args.dart';
import 'package:baocode/window/window_frame.dart';
import 'package:baocode/window/window_settings.dart';
import 'package:baocode/workspace/main_window.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';

import 'fake_window_host.dart';

/// The app's windows over a fake system, the file panels' owners whatever
/// [owners] says (a workspace's thread would have to be opened otherwise).
class _Harness {
  _Harness(
    WidgetTester tester, {
    Map<String, Object?>? kept,
    Set<String>? owners,
    bool quitsWithLastWindow = false,
    IdeWindows ideWindows = IdeWindows.separate,
    bool Function(PanelSpec)? prepare,
    void Function(PanelSpec)? undo,
    FakeWindowHost? host,
  }) : host = host ?? FakeWindowHost(tester.view),
       store = MemoryPreferenceStore(kept),
       workspace = Workspace.mock(),
       owners = owners ?? {'owner-1'} {
    windows = AppWindows(
      host: this.host,
      workspace: workspace,
      l10n: () => englishLocalizations,
      store: store,
      settings: () => WindowSettings(ideWindows: ideWindows),
      mainWindow: () => MainWindow.chat,
      isDirectory: (path) async => true,
      nextFrame: () async {},
      quit: () async {
        quits++;
        return AppExitResponse.cancel;
      },
      quitsWithLastWindow: quitsWithLastWindow,
      panelOwnerExists: (ownerId) => this.owners.contains(ownerId),
      prepareDockPanelRestore: prepare,
      undoDockPanelRestore: undo,
    );
    windows.chat.attach(chatDelegate);
    // Each window's workbench comes with it.
    windows.addListener(() {
      for (final window in [...windows.ideWindows, ...windows.panelWindows]) {
        if (window.delegate == null) {
          final delegate = FakeDelegate(log: this.host.log);
          delegates[window.viewId] = delegate;
          mountedSpecs[window.viewId] = window.panel;
          window.attach(delegate);
        }
      }
    });
  }

  final FakeWindowHost host;
  final MemoryPreferenceStore store;
  final Workspace workspace;
  final Set<String> owners;
  late final AppWindows windows;
  late final FakeDelegate chatDelegate = FakeDelegate();
  final Map<int, FakeDelegate> delegates = {};

  /// The spec each window had as its workbench was attached.
  final Map<int, PanelSpec?> mountedSpecs = {};

  /// How many times the app was asked to quit.
  int quits = 0;

  Future<void> start() => windows.start();

  AppWindow panel(String id) =>
      windows.panelWindows.firstWhere((window) => window.panel!.id == id);

  FakeDelegate delegateOf(AppWindow window) => delegates[window.viewId]!;
}

/// A panel's workbench that answers for its files, noting what it was
/// asked and what it took back.
class _GuardDelegate extends FakeDelegate implements FilePanelDelegate {
  _GuardDelegate({this.allow = true});

  bool allow;
  int asked = 0;
  final List<PanelSpec> docked = [];

  @override
  Future<bool> confirmFilePanelClose() async {
    asked++;
    return allow;
  }

  @override
  void acceptDockedFiles(PanelSpec panel) => docked.add(panel);
}

/// The system, failing to make a window whose title has [title] in it.
class _FailingHost extends FakeWindowHost {
  _FailingHost(super.implicit, {required this.title});

  final String title;

  @override
  Future<int?> create({
    WindowFrame? frame,
    required String title,
    double? width,
  }) async {
    if (title.contains(this.title)) return null;
    return super.create(frame: frame, title: title, width: width);
  }
}

PanelSpec _spec(
  String id, {
  String owner = 'owner-1',
  String project = '/w/a',
  List<FileOpenRequest> tabs = const [],
  String? activeFile,
  bool readOnly = false,
  bool pinned = false,
}) => PanelSpec(
  id: id,
  ownerId: owner,
  projectPath: project,
  tabs: tabs,
  activeFile: activeFile,
  readOnly: readOnly,
  pinned: pinned,
);

Future<String> _readBefore() async => 'before';

void main() {
  test('a panel spec keeps its plain files, with their lines and flags, and '
      'leaves out those only the session has', () {
    final spec = _spec(
      'files-1',
      tabs: [
        const FileOpenRequest(
          '/w/a/lib/main.dart',
          range: FileLineRange(3, 9, 5),
        ),
        const FileOpenRequest('/w/a/notes.txt', local: true, readOnly: true),
        const FileOpenRequest('/w/a/x.dart', diff: true),
        FileOpenRequest('/w/a/y.dart', original: _readBefore),
      ],
      activeFile: '/w/a/lib/main.dart',
      readOnly: true,
      pinned: true,
    );

    final json = spec.toJson();
    expect(json['tabs'], [
      {
        'path': '/w/a/lib/main.dart',
        'range': {'start': 3, 'end': 9, 'column': 5},
      },
      {'path': '/w/a/notes.txt', 'local': true, 'readOnly': true},
    ]);
    expect(json['activeFile'], '/w/a/lib/main.dart');
    expect(json['readOnly'], isTrue);
    expect(json['pinned'], isTrue);

    final back = PanelSpec.fromJson(json)!;
    expect(back.tabs, hasLength(2));
    expect(back.tabs.first.path, '/w/a/lib/main.dart');
    expect(back.tabs.first.range, const FileLineRange(3, 9, 5));
    expect(back.tabs.last.local, isTrue);
    expect(back.tabs.last.readOnly, isTrue);
    expect(back.activeFile, '/w/a/lib/main.dart');
    expect(back.readOnly, isTrue);
    expect(back.pinned, isTrue);
  });

  testWidgets('a file panel: its window, in front, among the windows and '
      'the menu, its files opened there', (tester) async {
    final harness = _Harness(tester);
    await harness.start();
    final panel = await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'files-1',
      files: [const CodeTarget('/w/a/lib/main.dart')],
    );

    expect(panel, isNotNull);
    expect(panel!.kind, AppWindowKind.panel);
    expect(panel.isPanel, isTrue);
    expect(panel.panel!.id, 'files-1');
    expect(panel.panel!.ownerId, 'owner-1');
    expect(panel.panel!.projectPath, '/w/a');
    expect(panel.panel!.kind, PanelKind.files);
    expect(harness.windows.panelWindows, [panel]);
    expect(harness.windows.windows.first, panel);
    expect(harness.windows.panelFor('files-1'), same(panel));
    expect(harness.host.created.single.title, 'Files — a — ${AppEdition.name}');
    expect(harness.delegateOf(panel).opened, [
      [const CodeTarget('/w/a/lib/main.dart')],
    ]);
    expect(
      harness.host.menu.map((entry) => entry.title),
      contains('Files — a'),
    );
    expect(harness.host.focused, panel.viewId);
  });

  testWidgets('an id opened already: the same panel, in front, not another '
      'window', (tester) async {
    final harness = _Harness(tester);
    await harness.start();
    final first = await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'files-1',
    );
    await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/b',
      id: 'files-2',
    );
    harness.host.log.clear();

    final again = await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'files-1',
      files: [const CodeTarget('/w/a/x.dart')],
    );

    expect(again, same(first));
    expect(harness.windows.panelWindows, hasLength(2));
    expect(harness.host.created, hasLength(2));
    expect(harness.windows.windows.first, first);
    expect(harness.delegateOf(first!).opened, [
      [const CodeTarget('/w/a/x.dart')],
    ]);
  });

  testWidgets('closing a panel: its view closed, out of the windows and the '
      'menu', (tester) async {
    final harness = _Harness(tester);
    await harness.start();
    final panel = (await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'files-1',
    ))!;
    final viewId = panel.viewId;

    expect(await harness.windows.closeFilePanel('files-1'), isTrue);

    expect(harness.windows.panelWindows, isEmpty);
    expect(harness.windows.panelFor('files-1'), isNull);
    expect(harness.windows.windows, isNot(contains(panel)));
    expect(harness.host.log, contains('close $viewId'));
    expect(
      harness.host.menu.map((entry) => entry.title),
      isNot(contains('Files — a — ${AppEdition.name}')),
    );
    expect(await harness.windows.closeFilePanel('files-1'), isFalse);
  });

  testWidgets('docking a panel: it closes, its files go to the chat where '
      'its owner is gone, and the chat comes in front', (tester) async {
    final harness = _Harness(tester, owners: {});
    await harness.start();
    final panel = (await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'files-1',
      tabs: [const FileOpenRequest('/w/a/a.dart', range: FileLineRange(2))],
      activeFile: '/w/a/a.dart',
    ))!;
    final viewId = panel.viewId;
    final chat = _GuardDelegate();
    harness.windows.chat.attach(chat);
    harness.host.log.clear();

    expect(
      await harness.windows.dockFilePanel('files-1'),
      same(harness.windows.chat),
    );
    expect(harness.windows.panelWindows, isEmpty);
    expect(harness.host.log, contains('close $viewId'));
    expect(chat.docked, hasLength(1));
    expect(chat.docked.single.tabs.single.path, '/w/a/a.dart');
    expect(chat.docked.single.activeFile, '/w/a/a.dart');
    expect(harness.host.focused, harness.windows.chat.viewId);
    expect(await harness.windows.dockFilePanel('files-1'), isNull);
  });

  testWidgets('closing a panel asks its workbench once, which may keep it '
      'open', (tester) async {
    final harness = _Harness(tester);
    await harness.start();
    final panel = (await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'files-1',
    ))!;
    final guard = _GuardDelegate(allow: false);
    panel.attach(guard);

    expect(await harness.windows.requestClose(panel), isFalse);
    expect(guard.asked, 1);
    expect(harness.windows.panelWindows, contains(panel));

    guard.allow = true;
    expect(await harness.windows.requestClose(panel), isTrue);
    expect(guard.asked, 2);
    expect(harness.windows.panelWindows, isEmpty);
  });

  testWidgets('the last panel closed does not quit the app: the chat shows '
      'again', (tester) async {
    final harness = _Harness(tester, quitsWithLastWindow: true);
    await harness.start();
    final panel = (await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'files-1',
    ))!;
    // The chat hidden: the panel is what shows.
    await harness.windows.requestClose(harness.windows.chat);
    expect(harness.windows.chat.shown, isFalse);
    expect(harness.quits, 0);

    final guard = _GuardDelegate();
    panel.attach(guard);
    expect(await harness.windows.requestClose(panel), isTrue);

    expect(harness.windows.panelWindows, isEmpty);
    expect(harness.windows.chat.shown, isTrue);
    expect(harness.quits, 0);
    expect(harness.host.focused, harness.windows.chat.viewId);
  });

  testWidgets('quitting asks the panels\' workbenches too, once each', (
    tester,
  ) async {
    final harness = _Harness(tester);
    await harness.start();
    final panel = (await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'files-1',
    ))!;
    final guard = _GuardDelegate(allow: false);
    panel.attach(guard);

    expect(await harness.windows.confirmQuit(), isFalse);
    expect(guard.asked, 1);

    guard.allow = true;
    expect(await harness.windows.confirmQuit(), isTrue);
    expect(guard.asked, 2);
  });

  testWidgets('a panel opened with its files: the spec its workbench mounts '
      'with has them, and a duplicate is read-only', (tester) async {
    final harness = _Harness(tester);
    await harness.start();
    final panel = (await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'files-1',
      tabs: [const FileOpenRequest('/w/a/a.dart')],
      activeFile: '/w/a/a.dart',
      readOnly: true,
    ))!;

    final mounted = harness.mountedSpecs[panel.viewId]!;
    expect(mounted.tabs.single.path, '/w/a/a.dart');
    expect(mounted.activeFile, '/w/a/a.dart');
    expect(mounted.readOnly, isTrue);
    expect(panel.panel!.readOnly, isTrue);
  });

  testWidgets('keeping a panel\'s files: the spec and the kept JSON, no '
      'window rebuilt', (tester) async {
    final harness = _Harness(tester);
    await harness.start();
    final panel = (await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'files-1',
    ))!;
    final views = harness.host.created.length;

    harness.windows.keepFilePanel(
      panel,
      files: [const FileOpenRequest('/w/a/b.dart', range: FileLineRange(4))],
      activeFile: '/w/a/b.dart',
      pinned: true,
    );
    await harness.windows.saved;

    expect(harness.host.created, hasLength(views));
    expect(panel.panel!.tabs.single.path, '/w/a/b.dart');
    expect(panel.panel!.activeFile, '/w/a/b.dart');
    expect(panel.panel!.pinned, isTrue);
    final kept = (harness.store.preferences['panels'] as List).single as Map;
    expect(kept['tabs'], [
      {
        'path': '/w/a/b.dart',
        'range': {'start': 4, 'end': 4},
      },
    ]);
    expect(kept['activeFile'], '/w/a/b.dart');
    expect(kept['pinned'], isTrue);
  });

  testWidgets('kept for the next launch: version 3, its panel with its '
      'stable id, owner, frame and files', (tester) async {
    final harness = _Harness(tester);
    await harness.start();
    final panel = (await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'files-1',
      tabs: [const FileOpenRequest('/w/a/a.dart')],
      activeFile: '/w/a/a.dart',
    ))!;
    harness.host.events!.windowFrameChanged(
      panel.viewId,
      const WindowFrame(Rect.fromLTWH(20, 30, 400, 500)),
    );
    await harness.windows.saved;

    final kept = harness.store.preferences;
    expect(kept['version'], 3);
    expect(kept['panels'], [
      {
        'id': 'files-1',
        'ownerId': 'owner-1',
        'projectPath': '/w/a',
        'kind': 'files',
        'tabs': [
          {'path': '/w/a/a.dart'},
        ],
        'activeFile': '/w/a/a.dart',
        'readOnly': false,
        'pinned': false,
        'frame': {'x': 20.0, 'y': 30.0, 'width': 400.0, 'height': 500.0},
      },
    ]);
  });

  testWidgets('restored after the workspace: a panel whose owner is there, '
      'not one whose owner is gone; its files as kept', (tester) async {
    final kept = {
      'version': 2,
      'windows': [
        {'chat': true},
      ],
      'panels': [
        _spec(
          'files-1',
          tabs: [
            const FileOpenRequest('/w/a/a.dart', range: FileLineRange(2, 4, 1)),
          ],
          activeFile: '/w/a/a.dart',
          pinned: true,
        ).toJson(),
        _spec('files-2', owner: 'owner-gone').toJson(),
        _spec('files-3').toJson(),
      ],
      'chatShown': true,
    };
    final harness = _Harness(
      tester,
      kept: kept,
      owners: {'owner-1'},
      ideWindows: IdeWindows.mainWindow,
    );
    await harness.start();
    await harness.windows.prepareLaunch();
    await harness.windows.restore();

    expect(harness.windows.panelWindows, hasLength(2));
    final panel = harness.windows.panelFor('files-1')!;
    final other = harness.windows.panelFor('files-3')!;
    expect(
      harness.host.log,
      containsAllInOrder(['focus ${other.viewId}', 'focus ${panel.viewId}']),
    );
    expect(panel, isNotNull);
    expect(harness.windows.panelFor('files-2'), isNull);
    expect(panel.panel!.ownerId, 'owner-1');
    expect(panel.panel!.tabs.single.path, '/w/a/a.dart');
    expect(panel.panel!.tabs.single.range, const FileLineRange(2, 4, 1));
    expect(panel.panel!.activeFile, '/w/a/a.dart');
    expect(panel.panel!.pinned, isTrue);
    expect(harness.windows.windows.first.isPanel, isTrue);
  });

  testWidgets('a version 1 file (no panels) reads as before, and is written '
      'as version 3', (tester) async {
    final kept = {
      'version': 1,
      'windows': [
        {'folder': '/w/a'},
        {'chat': true},
      ],
      'chatShown': false,
      'leftIn': 'ide',
    };
    final harness = _Harness(tester, kept: kept);
    await harness.start();
    await harness.windows.prepareLaunch();
    await harness.windows.restore();

    expect(harness.windows.panelWindows, isEmpty);
    await harness.windows.saved;
    expect(harness.store.preferences['version'], 3);
  });

  test('a moved dock tab keeps its tab id, dock place and state, and an '
      'unsent owner its reference only while JSON can hold it', () {
    final thread = Object();
    final spec = PanelSpec(
      id: 'panel-1',
      ownerId: '',
      ownerReference: thread,
      projectPath: '/w/a',
      kind: PanelKind.scratch,
      tabId: 'scratch',
      dockGroup: 'group-2',
      dockIndex: 3,
      state: {'text': 'hello', 'line': 2},
    );
    final json = spec.toJson();
    expect(json['tabId'], 'scratch');
    expect(json['dockGroup'], 'group-2');
    expect(json['dockIndex'], 3);
    expect(json['state'], {'text': 'hello', 'line': 2});
    // A live object is not JSON: only its in-memory spec has it.
    expect(json.containsKey('ownerReference'), isFalse);

    final back = PanelSpec.fromJson(json)!;
    expect(back.tabId, 'scratch');
    expect(back.ownerId, '');
    expect(back.dockGroup, 'group-2');
    expect(back.dockIndex, 3);
    expect(back.state, {'text': 'hello', 'line': 2});
    expect(back.ownerReference, isNull);

    // A JSON-safe token is kept, and names the owner a later run resolves.
    final tokenized = spec.copyWith(ownerReference: 'draft-7').toJson();
    expect(tokenized['ownerReference'], 'draft-7');
    expect(PanelSpec.fromJson(tokenized)!.ownerReference, 'draft-7');
    expect(PanelSpec.fromJson({...tokenized, 'kind': 'unknown'}), isNull);
    expect(PanelSpec.fromJson({...tokenized, 'tabId': 'terminal'}), isNull);
  });

  testWidgets('a moved tab opened again shows its own window, by its tab '
      'id, not a second one', (tester) async {
    final harness = _Harness(tester);
    await harness.start();
    final first = (await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'panel-1',
      kind: PanelKind.files,
      tabId: 'files',
    ))!;

    final again = await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'panel-2',
      kind: PanelKind.files,
      tabId: 'files',
    );

    expect(again, same(first));
    expect(harness.windows.panelWindows, [first]);
    expect(harness.windows.windowForTab('files'), same(first));
    expect(harness.windows.windowForTab('other'), isNull);
    expect(harness.host.created, hasLength(1));
  });

  testWidgets('closing a moved tab without docking: its tab is not taken '
      'back; closing with returnChat takes it back', (tester) async {
    final harness = _Harness(tester);
    await harness.start();
    final chat = _GuardDelegate();
    harness.windows.chat.attach(chat);

    final one = (await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'panel-1',
      tabId: 'files',
      kind: PanelKind.files,
    ))!;
    expect(await harness.windows.closeFilePanel('panel-1'), isTrue);
    expect(chat.docked, isEmpty);
    expect(harness.windows.panelWindows, isNot(contains(one)));

    await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'panel-2',
      tabId: 'changes',
      kind: PanelKind.changes,
    );
    expect(
      await harness.windows.closeFilePanel('panel-2', returnChat: true),
      isTrue,
    );
    expect(chat.docked, hasLength(1));
    expect(chat.docked.single.tabId, 'changes');
    expect(chat.docked.single.kind, PanelKind.changes);
  });

  testWidgets('a conversation\'s panel: its native close returns it to the '
      'dock, once', (tester) async {
    final harness = _Harness(tester);
    await harness.start();
    final chat = _GuardDelegate();
    harness.windows.chat.attach(chat);
    final panel = (await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'chat-panel',
      kind: PanelKind.chat,
      tabId: 'chat:1',
    ))!;

    expect(
      await harness.windows.dockPanel('chat-panel'),
      same(harness.windows.chat),
    );

    expect(harness.windows.panelWindows, isEmpty);
    expect(chat.docked, hasLength(1));
    expect(chat.docked.single.tabId, 'chat:1');
    expect(harness.windows.panelFor('chat-panel'), isNull);
    expect(panel.panel!.kind, PanelKind.chat);
  });

  testWidgets('a panel closed tells the workbench, once', (tester) async {
    final harness = _Harness(tester);
    await harness.start();
    final closed = <PanelSpec>[];
    harness.windows.onDockPanelClosed = closed.add;
    await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'panel-1',
      kind: PanelKind.ports,
    );

    expect(await harness.windows.closeFilePanel('panel-1'), isTrue);
    expect(closed.map((spec) => spec.id), ['panel-1']);
  });

  testWidgets('restoring a moved tab: its owner resolved before the window '
      'opens; a refusal leaves it out', (tester) async {
    final kept = {
      'version': 3,
      'windows': [
        {'chat': true},
      ],
      'panels': [
        PanelSpec(
          id: 'panel-1',
          ownerId: 'owner-1',
          projectPath: '/w/a',
          kind: PanelKind.usage,
          tabId: 'usage',
          dockGroup: 'g1',
          dockIndex: 1,
          state: {'page': 'today'},
        ).toJson(),
        PanelSpec(
          id: 'panel-2',
          ownerId: 'owner-1',
          projectPath: '/w/a',
          kind: PanelKind.plan,
          tabId: 'plan',
        ).toJson(),
      ],
      'chatShown': true,
    };
    final prepared = <PanelSpec>[];
    final harness = _Harness(
      tester,
      kept: kept,
      ideWindows: IdeWindows.mainWindow,
      prepare: (spec) {
        prepared.add(spec);
        // The plan's owner cannot be resolved: it stays out.
        return spec.tabId != 'plan';
      },
    );
    await harness.start();
    await harness.windows.prepareLaunch();
    await harness.windows.restore();

    expect(prepared.map((spec) => spec.tabId), containsAll(['usage', 'plan']));
    final restored = harness.windows.panelFor('panel-1')!;
    expect(restored.panel!.tabId, 'usage');
    expect(restored.panel!.dockGroup, 'g1');
    expect(restored.panel!.dockIndex, 1);
    expect(restored.panel!.state, {'page': 'today'});
    expect(harness.windows.panelFor('panel-2'), isNull);
  });

  testWidgets('a moved tab whose window cannot be made goes back to the '
      'workbench rather than away', (tester) async {
    final host = _FailingHost(tester.view, title: 'Usage');
    final undone = <PanelSpec>[];
    final kept = {
      'version': 3,
      'windows': [
        {'chat': true},
      ],
      'panels': [
        PanelSpec(
          id: 'panel-1',
          ownerId: 'owner-1',
          projectPath: '/w/a',
          kind: PanelKind.usage,
          tabId: 'usage',
        ).toJson(),
      ],
      'chatShown': true,
    };
    final harness = _Harness(
      tester,
      kept: kept,
      ideWindows: IdeWindows.mainWindow,
      host: host,
      prepare: (spec) => true,
      undo: undone.add,
    );
    await harness.start();
    await harness.windows.prepareLaunch();
    await harness.windows.restore();

    expect(harness.windows.panelWindows, isEmpty);
    expect(undone.map((spec) => spec.tabId), ['usage']);
  });

  testWidgets('quitting closes the panels first, their views let go before '
      'the app goes', (tester) async {
    final harness = _Harness(tester);
    await harness.start();
    final panel = (await harness.windows.openFilePanel(
      'owner-1',
      projectPath: '/w/a',
      id: 'files-1',
    ))!;
    harness.host.log.clear();

    await harness.windows.closeForQuit();

    expect(harness.windows.panelWindows, isEmpty);
    expect(harness.windows.panelFor('files-1'), isNull);
    expect(harness.host.log, contains('close ${panel.viewId}'));
  });
}
