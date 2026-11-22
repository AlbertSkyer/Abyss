import 'dart:async';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_claude.dart';
import '../remote/remote_location.dart';
import '../remote/remote_services.dart';
import '../chat/composer/composer_files.dart';
import '../chat/composer/file_drop.dart';
import '../chat/side_panel/file_link.dart' show FileLineRange;
import '../chat/side_panel/file_open.dart' show FileOpenRequest;
import '../ide/ide_dialog.dart';
import '../ide/ide_quick_input.dart';
import '../ide/ide_workspace.dart';
import '../l10n/l10n.dart';
import '../platform/app_edition.dart';
import '../platform/local_paths.dart'
    if (dart.library.io) '../platform/local_paths_io.dart'
    as local;
import '../theme/codicons.dart';
import '../workspace/main_window.dart';
import '../workspace/preference_store.dart';
import '../workspace/quit_confirmation.dart';
import '../workspace/window_controls.dart';
import '../workspace/workspace.dart';
import 'code_args.dart';
import 'window_frame.dart';
import 'window_host.dart';
import 'window_settings.dart';

/// The kinds of window: the chat's, the app's main one (there is one);
/// the IDE's, one per folder (or none: its welcome); an agent's, its
/// conversation alone (Explorer's Open with BaoCode, a new one each time);
/// a file panel's, the files of a project its owner picked; and the stash's
/// panel (see lib/stash/), none of the app's windows to the system: not
/// listed, never in front of the others as they are.
enum AppWindowKind { chat, ide, agent, panel, stash }

/// What a panel shows: one of the main window's dock tabs, moved out into
/// a window of its own, or the files of a project (a legacy independent
/// file panel, which has no [PanelSpec.tabId]).
enum PanelKind {
  files,
  changes,
  terminal,
  usage,
  plan,
  agents,
  ports,
  team,
  scratch,
  chat,
}

/// A panel: a window of its own, opened by [ownerId] (an agent's session,
/// whose id keeps it across runs) on [projectPath]'s [kind]. Its [id] is
/// stable: opening a panel with an id that is already open shows that one.
///
/// A panel moved out of the dock keeps its [tabId] (the dock panel's id),
/// and where it was ([dockGroup], [dockIndex]), so it can return there.
/// Its [ownerReference] is kept only in memory (or in the JSON when it is
/// JSON-safe): a draft conversation whose session has no id yet, which the
/// main workbench resolves when the panel is opened again (see
/// [AppWindows.prepareDockPanelRestore]).
class PanelSpec {
  const PanelSpec({
    required this.id,
    required this.ownerId,
    required this.projectPath,
    this.kind = PanelKind.files,
    this.tabId,
    this.ownerReference,
    this.dockGroup,
    this.dockIndex,
    this.state = const {},
    this.frame,
    this.tabs = const [],
    this.activeFile,
    this.readOnly = false,
    this.pinned = false,
  });

  final String id;

  /// The owner's session id; empty for an unsent draft, which
  /// [ownerReference] names instead.
  final String ownerId;
  final String projectPath;
  final PanelKind kind;

  /// The dock tab it was moved from; null for a legacy independent file
  /// panel (one opened as a copy, with no tab to return to).
  final String? tabId;

  /// The owner while its session has no id (an unsent draft): the live
  /// object this run, or a JSON-safe token another run can resolve. Not
  /// kept when it is not JSON-safe.
  final Object? ownerReference;

  /// Where it was in the dock: the group it was moved from and its place
  /// there (kept to return it).
  final String? dockGroup;
  final int? dockIndex;

  /// The tab's own state (a scratch's text, a page's place): JSON values
  /// only, kept for the next launch.
  final Map<String, Object?> state;

  /// Legacy file windows keep their original project until explicitly unlocked.
  bool get filesLocked => state['filesLocked'] != false;

  /// Where it was, as it last reported (kept for the next launch).
  final WindowFrame? frame;

  /// The files its side panel shows (a request may hold what only its
  /// session has, as a diff: those are not kept).
  final List<FileOpenRequest> tabs;

  /// The file in front among [tabs], by its path.
  final String? activeFile;

  /// Whether it shows its files not to edit: a panel duplicated from
  /// another, so that the same file has one editor.
  final bool readOnly;

  /// Whether the system keeps this window above other windows.
  final bool pinned;

  static const Object _unset = Object();

  PanelSpec copyWith({
    String? ownerId,
    String? projectPath,
    WindowFrame? frame,
    List<FileOpenRequest>? tabs,
    Object? activeFile = _unset,
    bool? readOnly,
    bool? pinned,
    String? tabId,
    Object? ownerReference = _unset,
    String? dockGroup,
    int? dockIndex,
    Map<String, Object?>? state,
  }) => PanelSpec(
    id: id,
    ownerId: ownerId ?? this.ownerId,
    projectPath: projectPath ?? this.projectPath,
    kind: kind,
    tabId: tabId ?? this.tabId,
    ownerReference: identical(ownerReference, _unset)
        ? this.ownerReference
        : ownerReference,
    dockGroup: dockGroup ?? this.dockGroup,
    dockIndex: dockIndex ?? this.dockIndex,
    state: state ?? this.state,
    frame: frame ?? this.frame,
    tabs: tabs ?? this.tabs,
    activeFile: identical(activeFile, _unset)
        ? this.activeFile
        : activeFile as String?,
    readOnly: readOnly ?? this.readOnly,
    pinned: pinned ?? this.pinned,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'ownerId': ownerId,
    'projectPath': projectPath,
    'kind': kind.name,
    'tabId': ?tabId,
    if (ownerReference != null && _jsonSafe(ownerReference))
      'ownerReference': ownerReference,
    'dockGroup': ?dockGroup,
    'dockIndex': ?dockIndex,
    if (state.isNotEmpty) 'state': state,
    'tabs': [for (final request in tabs) ?_requestToJson(request)],
    'activeFile': activeFile,
    'readOnly': readOnly,
    'pinned': pinned,
    'frame': ?frame?.toJson(),
  };

  /// Whether [value] can be written as JSON as it is (a moved panel's
  /// owner reference is dropped when it cannot).
  static bool _jsonSafe(Object? value) => switch (value) {
    null || bool() || num() || String() => true,
    final List list => list.every(_jsonSafe),
    final Map map => map.entries.every(
      (entry) => entry.key is String && _jsonSafe(entry.value),
    ),
    _ => false,
  };

  /// Null for an entry that is not a panel (an owner or id gone, or a
  /// file of another version's). An entry with no owner id is one of an
  /// unsent draft, whose [ownerReference] names its owner instead.
  static PanelSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final projectPath = json['projectPath'];
    if (id is! String || id.isEmpty) return null;
    if (projectPath is! String) return null;
    final owner = json['ownerId'];
    final ownerReference = json['ownerReference'];
    final ownerId = owner is String ? owner : '';
    final activeFile = json['activeFile'];
    final tabId = json['tabId'];
    final dockGroup = json['dockGroup'];
    final dockIndex = json['dockIndex'];
    final tab = tabId is String && tabId.isNotEmpty ? tabId : null;
    // No owner id and no reference names no owner at all, unless it is a
    // moved tab (whose owner the workbench resolves at restore).
    if (ownerId.isEmpty && ownerReference == null && tab == null) {
      return null;
    }
    final kind = PanelKind.values.asNameMap()[json['kind'] ?? 'files'];
    if (kind == null ||
        (tab != null &&
            (kind == PanelKind.chat
                ? !tab.startsWith('chat:')
                : tab != kind.name))) {
      return null;
    }
    return PanelSpec(
      id: id,
      ownerId: ownerId,
      projectPath: projectPath,
      kind: kind,
      tabId: tab,
      ownerReference: ownerReference,
      dockGroup: dockGroup is String && dockGroup.isNotEmpty ? dockGroup : null,
      dockIndex: dockIndex is int ? dockIndex : null,
      state: _stateFromJson(json['state']),
      frame: WindowFrame.fromJson(json['frame']),
      tabs: [
        if (json['tabs'] case final List<Object?> tabs)
          for (final request in tabs) ?_requestFromJson(request),
      ],
      activeFile: activeFile is String ? activeFile : null,
      readOnly: json['readOnly'] == true,
      pinned: json['pinned'] == true,
    );
  }

  static Map<String, Object?> _stateFromJson(Object? json) {
    if (json is! Map) return const {};
    return {
      for (final entry in json.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  /// [request] as the plain file it shows (its path, lines and flags); null
  /// for one carrying what only its session has (a diff, the text before or
  /// after a change, the agent's change pending), which is not kept.
  static Map<String, Object?>? _requestToJson(FileOpenRequest request) {
    if (request.diff ||
        request.plan ||
        request.agentChange ||
        request.change != null ||
        request.original != null ||
        request.modified != null) {
      return null;
    }
    return {
      'path': request.path,
      if (request.range case final range?)
        'range': {
          'start': range.start,
          'end': range.end,
          'column': ?range.column,
        },
      if (request.local) 'local': true,
      if (request.readOnly) 'readOnly': true,
    };
  }

  static FileOpenRequest? _requestFromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    if (path is! String || path.isEmpty) return null;
    return FileOpenRequest(
      path,
      range: _rangeFromJson(json['range']),
      local: json['local'] == true,
      readOnly: json['readOnly'] == true,
    );
  }

  static FileLineRange? _rangeFromJson(Object? json) {
    if (json is! Map) return null;
    final start = json['start'];
    if (start is! int || start < 1) return null;
    final end = json['end'];
    final column = json['column'];
    return FileLineRange(
      start,
      end is int ? end : null,
      column is int ? column : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PanelSpec &&
      other.id == id &&
      other.ownerId == ownerId &&
      other.projectPath == projectPath &&
      other.kind == kind &&
      other.tabId == tabId &&
      other.ownerReference == ownerReference &&
      other.dockGroup == dockGroup &&
      other.dockIndex == dockIndex &&
      mapEquals(other.state, state) &&
      other.frame == frame &&
      listEquals(other.tabs, tabs) &&
      other.activeFile == activeFile &&
      other.readOnly == readOnly &&
      other.pinned == pinned;

  @override
  int get hashCode => Object.hash(
    id,
    ownerId,
    projectPath,
    kind,
    tabId,
    ownerReference,
    dockGroup,
    dockIndex,
    Object.hashAllUnordered(
      state.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
    frame,
    Object.hashAll(tabs),
    activeFile,
    readOnly,
    pinned,
  );

  @override
  String toString() =>
      'PanelSpec($id, $kind${tabId == null ? '' : ' $tabId'}, $ownerId, '
      '$projectPath)';
}

/// What a window's workbench does for [AppWindows]: it is the one to open
/// files in it, show an agent there, and answer for what it has unsaved.
abstract interface class WindowDelegate {
  /// Where the window's dialogs show; null once it is gone.
  BuildContext? get windowContext;

  /// The IDE's workspace the window shows (that of its folder); none in the
  /// chat's window.
  IdeWorkspace? get ideSpace;

  /// Opens [files] in editors, each at its line and column.
  Future<void> openFiles(List<CodeTarget> files);

  /// Shows [thread]: as the tab of the IDE's chat, or in the chat's panes.
  void showAgent(AgentThread thread);

  /// The IDE's [folder] (its welcome, for none) in this window: what the
  /// chat's window does without windows of the IDE's own.
  void showIdeFolder(String? folder);

  /// Its documents not saved, their editors' last keys in.
  Future<List<IdeDocument>> unsavedDocuments();

  /// Saves [documents] (an untitled one asks where); whether all were.
  Future<bool> saveDocuments(List<IdeDocument> documents);

  /// Whether its terminals run: a shell alive, or ([childProcesses]) one
  /// running a command.
  bool terminalsRunning({required bool childProcesses});

  /// Shows [pick] over the window (Switch Window…).
  void showQuickPick(IdeQuickPick pick);

  /// Runs [command] (of the File menu, the IDE's) in the window.
  void runCommand(String command);
}

/// What a file panel's workbench does for [AppWindows], beside what every
/// window's does ([WindowDelegate]): answer for the files it would lose as
/// the panel closes, and take what the panel showed when it docks.
abstract interface class FilePanelDelegate {
  /// Whether the panel may close, its unsaved files saved or let go;
  /// false keeps it open. Asks once (the close is not asked about twice).
  Future<bool> confirmFilePanelClose();

  /// Takes back [panel]'s tabs and the file in front, as the panel's
  /// window closes to dock in its owner's.
  void acceptDockedFiles(PanelSpec panel);
}

/// One of the app's windows.
class AppWindow {
  AppWindow._(
    this.kind,
    this.viewId,
    this._folder, {
    this.frame,
    this._thread,
    PanelSpec? panel,
  }) : _panel = panel; // ignore: prefer_initializing_formals

  final AppWindowKind kind;

  /// Its view, which the engine draws it in.
  final int viewId;

  bool get isChat => kind == AppWindowKind.chat;
  bool get isIde => kind == AppWindowKind.ide;
  bool get isAgent => kind == AppWindowKind.agent;
  bool get isPanel => kind == AppWindowKind.panel;
  bool get isStash => kind == AppWindowKind.stash;

  /// What a panel shows; null for the other windows. Kept up to date as
  /// the panel's workbench shows other files (see [AppWindows.keepFilePanel]).
  PanelSpec? get panel => _panel;
  PanelSpec? _panel;

  /// The agent an agent's window shows (another picked in its sidebar
  /// takes its place: see [AppWindows.showInWindow]).
  AgentThread? get thread => _thread;
  AgentThread? _thread;

  /// The folder an IDE window shows; null for its welcome (and the chat's).
  String? get folder => _folder;
  String? _folder;

  /// Changes with its folder: what the window shows is built anew.
  int get generation => _generation;
  int _generation = 0;

  /// Where it is, as it last reported.
  WindowFrame? frame;

  /// Whether it has unsaved files.
  bool get edited => _edited;
  bool _edited = false;

  /// Whether it shows: the chat's may be closed, which hides it.
  bool get shown => _shown;
  bool _shown = true;

  WindowDelegate? get delegate => _delegate;
  WindowDelegate? _delegate;
  Completer<WindowDelegate> _ready = Completer();

  /// Its workbench, once built.
  Future<WindowDelegate?> get ready {
    if (_delegate case final delegate?) return SynchronousFuture(delegate);
    return _ready.future
        .then<WindowDelegate?>((d) => d)
        .timeout(const Duration(seconds: 10), onTimeout: () => null);
  }

  /// The workbench built in it takes it over.
  void attach(WindowDelegate delegate) {
    _delegate = delegate;
    if (!_ready.isCompleted) _ready.complete(delegate);
  }

  /// It is gone (its folder replaced, the window closed).
  void detach(WindowDelegate delegate) {
    if (!identical(_delegate, delegate)) return;
    _delegate = null;
    if (_ready.isCompleted) _ready = Completer();
  }

  void _setFolder(String? folder) {
    _folder = folder;
    _generation++;
    _edited = false;
  }

  /// Its name, as menus list it.
  String label(AppLocalizations l10n) => switch ((kind, _folder)) {
    (AppWindowKind.chat, _) => l10n.windowChatTitle,
    (AppWindowKind.agent, _) => thread!.localizedTitle(l10n),
    (AppWindowKind.panel, _) =>
      panel == null ? l10n.windowWelcomeTitle : _panelName(panel!, l10n),
    (AppWindowKind.stash, _) => 'Stash',
    (_, final folder?) => _folderName(folder),
    (_, null) => l10n.windowWelcomeTitle,
  };

  /// A panel's name: what it shows, and its project's, told from the IDE's
  /// window of it.
  static String _panelName(PanelSpec panel, AppLocalizations l10n) {
    final folder = panel.projectPath;
    final name = switch (panel.kind) {
      PanelKind.files => l10n.sidePanelFiles,
      PanelKind.changes => l10n.sidePanelChanges,
      PanelKind.terminal => l10n.sidePanelTerminal,
      PanelKind.usage => l10n.sidePanelUsage,
      PanelKind.plan => l10n.sidePanelPlan,
      PanelKind.agents => l10n.sidePanelAgents,
      PanelKind.ports => l10n.sidePanelPorts,
      PanelKind.team => l10n.dockTeam,
      PanelKind.scratch => l10n.dockScratch,
      PanelKind.chat => switch (panel.state['title']) {
        final String title when title.isNotEmpty => title,
        _ => l10n.windowChatTitle,
      },
    };
    return folder.isEmpty ? name : '$name — ${_folderName(folder)}';
  }

  /// The title the system shows: `folder — BaoCode`.
  String title(AppLocalizations l10n) => '${label(l10n)} — ${AppEdition.name}';

  /// The folder's name; a remote one's with its host, as VS Code shows
  /// one (`app [SSH: dev]`, `app [WSL: Ubuntu]`).
  static String _folderName(String folder) {
    if (RemoteLocation.hostOf(folder) case final host?) {
      return '${RemoteLocation.nameOf(folder)} '
          '[${RemoteLocation.reachedBy(host)}: ${RemoteLocation.hostName(host)}]';
    }
    final name = p.basename(folder);
    return name.isEmpty ? folder : name;
  }

  @override
  String toString() =>
      'AppWindow(${kind.name} $viewId'
      '${_folder == null ? '' : ' $_folder'}'
      '${panel == null ? '' : ' ${panel!.id}'})';
}

/// One window kept between runs: an IDE's folder (null: its welcome) and
/// where it was, or the chat's place among them.
class _KeptWindow {
  const _KeptWindow({this.folder, this.frame, this.chat = false});

  final String? folder;
  final WindowFrame? frame;
  final bool chat;

  Map<String, Object?> toJson() =>
      chat ? {'chat': true} : {'folder': folder, 'frame': ?frame?.toJson()};

  static _KeptWindow? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['chat'] == true) return const _KeptWindow(chat: true);
    return _KeptWindow(
      folder: json['folder'] as String?,
      frame: WindowFrame.fromJson(json['frame']),
    );
  }
}

/// The app's windows, VS Code's way: the chat's, its main one, and one per
/// folder the IDE opens (or none), in one engine, each a view of it. The
/// agents, their sessions, the settings, the theme and the language are
/// the same in all; each window has its own navigator, dialogs and focus.
///
/// Where the system cannot open more windows (the web, a host without the
/// `baocode/windows` channel), or `window.ideWindows` says so, the IDE
/// shows in the main window, as it did before: [multi] is false and the
/// IDE's entries go to its workbench. The setting changed, the IDE moves
/// at once (see [settingsChanged]).
class AppWindows extends ChangeNotifier implements WindowHostEvents {
  AppWindows({
    required this.host,
    required this.workspace,
    required this._l10n,
    this._store,
    WindowSettings Function()? settings,
    MainWindow Function()? mainWindow,
    this._updateSetting,
    Future<bool> Function(String path)? isDirectory,
    Future<String?> Function(String path)? takeFile,
    Future<bool> Function(String path)? exists,
    bool Function()? hasTray,
    Future<AppExitResponse> Function()? quit,
    Future<void> Function()? nextFrame,
    bool? quitsWithLastWindow,
    bool Function(String ownerId)? panelOwnerExists,
    this.prepareDockPanelRestore,
    this.undoDockPanelRestore,
  }) : _settings = settings ?? (() => const WindowSettings()),
       _mainWindow = mainWindow ?? (() => MainWindow.fallback),
       _isDirectory = isDirectory ?? _folderThere,
       _takeFile = takeFile ?? local.takeFile,
       _exists = exists ?? local.exists,
       _hasTray = hasTray ?? (() => false),
       _panelOwnerOverride = panelOwnerExists,
       _quitOverride = quit,
       _nextFrame = nextFrame ?? (() => WidgetsBinding.instance.endOfFrame),
       _quitsWithLastWindow =
           quitsWithLastWindow ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    chat = AppWindow._(AppWindowKind.chat, host.mainViewId, null);
    _mru.add(chat);
  }

  /// `windows.json` in the data folder's state/, beside state.json.
  /// Version 2 keeps the file panels as well; a version 1 file (none kept
  /// then) reads the same, with no panel. Version 3 keeps a moved dock
  /// tab's [PanelSpec.tabId], its dock place and its state, and an unsent
  /// draft's owner reference where JSON can hold it.
  static const fileName = 'windows.json';
  static const _version = 3;

  /// Resolves a moved dock tab being opened again, before its window is
  /// made: the main workbench establishes the owner (an unsent draft among
  /// them) and takes the tab out of the main view; false leaves the panel
  /// closed. When none is given, a panel is restored only if its owner is
  /// (as before).
  bool Function(PanelSpec)? prepareDockPanelRestore;

  /// Puts a moved dock tab whose window could not be made back where it
  /// came from. When none is given, the main workbench's
  /// [FilePanelDelegate.acceptDockedFiles] takes it back.
  void Function(PanelSpec)? undoDockPanelRestore;

  final WindowHost host;
  final Workspace workspace;
  final AppLocalizations Function() _l10n;
  final PreferenceStore? _store;
  final WindowSettings Function() _settings;
  final MainWindow Function() _mainWindow;

  /// Writes a setting to settings.json (a switch of `window.ideWindows`
  /// cancelled is written back).
  final void Function(String key, Object? value)? _updateSetting;

  /// Whether [folder] is there to open again: a remote one is taken to be
  /// (its host is not asked before the window shows).
  static Future<bool> _folderThere(String folder) =>
      RemoteLocation.isRemote(folder)
      ? Future.value(true)
      : local.isDirectory(folder);

  /// [folder] for the system to show as the window's file (its proxy
  /// icon): none for a remote one.
  static String? _localOnly(String? folder) =>
      folder != null && RemoteLocation.isRemote(folder) ? null : folder;

  final Future<bool> Function(String path) _isDirectory;
  final Future<String?> Function(String path) _takeFile;
  final Future<bool> Function(String path) _exists;
  final bool Function() _hasTray;
  final Future<AppExitResponse> Function()? _quitOverride;

  /// Whether a file panel's owner is still there (a test's answer, else the
  /// workspace's threads).
  final bool Function(String ownerId)? _panelOwnerOverride;

  bool _panelOwnerExists(String ownerId) =>
      (_panelOwnerOverride ?? _threadExists)(ownerId);

  /// Whether an agent of the workspace keeps [ownerId]'s session.
  bool _threadExists(String ownerId) =>
      workspace.threads.any((thread) => thread.id == ownerId);

  Future<AppExitResponse> _quit() => (_quitOverride ?? _exit)();

  /// The quit under way: the windows' closing all ask once (the taskbar's
  /// Close all windows closes each, and the last of them quits).
  Future<AppExitResponse>? _exiting;

  /// Quits the app, asked first (see main.dart's onExitRequested). On
  /// Windows the engine's way (exitApplication) ends the message loop with
  /// the windows still up, and the app hangs taking Flutter down outside
  /// it: the app is asked here, its IDE windows closed (see
  /// [closeForQuit]), and its main window closed in the loop (see
  /// app_windows.h' kQuitMessage).
  Future<AppExitResponse> _exit() {
    final binding = ServicesBinding.instance;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return binding.exitApplication(AppExitType.cancelable);
    }
    return _exiting ??= () async {
      try {
        final response = await binding.handleRequestAppExit();
        if (response == AppExitResponse.exit) {
          await closeForQuit();
          await host.quit();
        }
        return response;
      } finally {
        _exiting = null;
      }
    }();
  }

  /// Whether the app is going: what is kept for the next launch stays as
  /// it was before (see [closeForQuit]).
  bool _quitting = false;

  /// The IDE's windows (and the agents') closed as the app goes
  /// (Windows'), as [requestClose] closes one: their widgets first, then
  /// their views. Left to the main window's going, a view the engine still
  /// draws goes in the middle of it, and the engine, waiting for it to be
  /// let go of, hangs the app. They are kept for the next launch as they
  /// were.
  @visibleForTesting
  Future<void> closeForQuit() async {
    if (_ide.isEmpty && _agents.isEmpty && _panels.isEmpty) return;
    _quitting = true;
    final closing = [..._ide, ..._agents, ..._panels];
    _ide.clear();
    _agents.clear();
    _panels.clear();
    notifyListeners();
    await _nextFrame();
    for (final window in closing) {
      WindowControls.stopListening(window.viewId);
      FileDrops.stopListening(window.viewId);
      await host.close(window.viewId);
    }
  }

  final Future<void> Function() _nextFrame;

  /// Windows': the app quits as its last window closes (the tray aside).
  /// macOS' stays, the Dock's icon opening the chat's window again.
  final bool _quitsWithLastWindow;

  /// The chat's window: the main one, always there (hidden when closed).
  late final AppWindow chat;

  /// Whether the system opens the app's windows for it: the chat's is
  /// then one of them, which the app closes, hides and brings in front.
  bool get started => _started;
  bool _started = false;

  /// Whether the IDE opens windows of its own (`window.ideWindows`); else
  /// it shows in the main one.
  bool get multi => _started && _separate;
  bool _separate = true;

  /// All of them, the one in front first.
  List<AppWindow> get windows => List.unmodifiable(_mru);
  final List<AppWindow> _mru = [];

  /// The IDE's, in the order they opened (as menus list them).
  List<AppWindow> get ideWindows => List.unmodifiable(_ide);
  final List<AppWindow> _ide = [];

  /// The agents', in the order they opened.
  List<AppWindow> get agentWindows => List.unmodifiable(_agents);
  final List<AppWindow> _agents = [];

  /// The file panels, in the order they opened.
  List<AppWindow> get panelWindows => List.unmodifiable(_panels);
  final List<AppWindow> _panels = [];

  /// The panel with [id] (its stable one), if it is open.
  AppWindow? panelFor(String id) =>
      _panels.where((window) => window.panel?.id == id).firstOrNull;

  /// The panel a dock tab moved out, [tabId], if it is open.
  AppWindow? windowForTab(String tabId) =>
      _panels.where((window) => window.panel?.tabId == tabId).firstOrNull;

  AppWindow? windowOf(int viewId) =>
      _mru.where((window) => window.viewId == viewId).firstOrNull;

  /// The IDE's window of [folder], if one is open.
  AppWindow? windowFor(String folder) {
    final key = _key(folder);
    return _ide
        .where((w) => w.folder != null && _key(w.folder!) == key)
        .firstOrNull;
  }

  /// The window in front: the keyboard's, where dialogs about the app ask.
  AppWindow get active =>
      _mru.where((window) => window.shown).firstOrNull ?? chat;

  /// The IDE's window last in front.
  AppWindow? get recentIde => _mru.where((window) => window.isIde).firstOrNull;

  static String _key(String path) => p.canonicalize(path);

  /// The window of [folder] that has [path] in it (the deepest folder).
  AppWindow? _containing(String path) {
    AppWindow? best;
    for (final window in _ide) {
      final folder = window.folder;
      if (folder == null) continue;
      if (!p.equals(folder, path) && !p.isWithin(folder, path)) continue;
      if (best == null || best.folder!.length < folder.length) best = window;
    }
    return best;
  }

  // --- Start -----------------------------------------------------------------

  /// Asks the system whether windows can be opened; from then on the IDE's
  /// entries (Open in Fast Ide, the sidebar's…) open them.
  Future<bool> start() async {
    _started = await host.start(this);
    _separate = _settings().ideWindows == IdeWindows.separate;
    if (multi) {
      workspace.ideWindows = _routeIde;
      _syncWorkspace();
    }
    return _started;
  }

  ({List<_KeptWindow> windows, bool chatShown})? _launch;

  /// The file panels to open again, read with the windows ([restore] opens
  /// them once the workspace has its threads: a panel whose owner is gone
  /// is left out).
  List<PanelSpec>? _panelLaunch;

  /// Whether the chat's window shows at launch, decided before the app
  /// shows (see [prepareLaunch]).
  bool get chatShownAtLaunch => _launch?.chatShown ?? true;

  /// Reads what to open at launch, before the first frame: whether the
  /// chat's window shows (the system knows it before the app runs: told
  /// here for the next launch, and for this one where it is not too
  /// late) and which IDE windows open again ([restore] opens them).
  ///
  /// The app opens to the chat or to the IDE, never both:
  /// `workbench.mainWindow` says which, by default where it was left (the
  /// window in front at the last quit). To the chat, its window alone; to
  /// the IDE, the IDE's windows `window.restoreWindows` says (or an empty
  /// one), the chat's hidden. The IDE's folder that showed in the main
  /// window (the first run with windows, or `window.ideWindows` changed
  /// meanwhile) opens in a window of its own.
  ///
  /// With the IDE in the main window, only it shows; the IDE's window last
  /// in front, if any were left, gives it its folder.
  ///
  /// Started for a [request] (Explorer's Open with BaoCode or Fast Ide, the
  /// `code` command), it opens to that alone, at once, in a window of its
  /// own: the agent's (see [openAgent]), else what the request opens;
  /// nothing of the last run, the chat's window hidden.
  Future<void> prepareLaunch({
    LaunchRequest request = LaunchRequest.none,
  }) async {
    if (!_started) return;
    if (request == LaunchRequest.agent ||
        (_separate && request == LaunchRequest.ide)) {
      _wasInIde = request == LaunchRequest.ide;
      _panelLaunch = null;
      _launch = (windows: const [_KeptWindow(chat: true)], chatShown: false);
      chat._shown = false;
      _syncWorkspace();
      // Read for this launch as well: after Dart starts, on Windows.
      await host.setMainShownAtLaunch(false);
      _mainShownNext = false;
      return;
    }
    final kept = await _store?.read() ?? const <String, Object?>{};
    // File panels use the native host independently of the IDE-window setting.
    final panels = [
      if (kept['panels'] case final List<Object?> entries)
        for (final json in entries) ?PanelSpec.fromJson(json),
    ];
    _panelLaunch = panels;
    if (!_separate) return _prepareMainOnly(kept);
    final old = workspace.takeSingleWindowIde();
    final versioned = kept['version'] != null;
    final ide = switch (_mainWindow()) {
      MainWindow.chat => false,
      MainWindow.ide => true,
      MainWindow.last =>
        versioned
            ? (kept['leftIn'] ??
                      (kept['chatShown'] == false ? 'ide' : 'chat')) ==
                  'ide'
            : old.shown,
    };
    final windows = <_KeptWindow>[];
    if (ide) {
      if (versioned) {
        final restore = _settings().restoreWindows;
        for (final json in kept['windows'] as List<Object?>? ?? const []) {
          final window = _KeptWindow.fromJson(json);
          if (window == null || window.chat) continue;
          final folder = window.folder;
          final keep = switch (restore) {
            RestoreWindows.all => true,
            RestoreWindows.folders => folder != null,
            RestoreWindows.one => windows.isEmpty,
            RestoreWindows.none => false,
          };
          if (!keep) continue;
          // A folder gone (deleted, a drive unplugged) is not opened.
          if (folder != null && !await _isDirectory(folder)) continue;
          windows.add(window);
        }
      }
      if (old.folder case final folder?
          when (old.shown || !versioned) &&
              !windows.any((w) => w.folder == folder) &&
              await _isDirectory(folder)) {
        windows.insert(0, _KeptWindow(folder: folder));
      }
      // Never no window at all.
      if (windows.isEmpty) windows.add(const _KeptWindow());
    }
    windows.add(const _KeptWindow(chat: true));
    final chatShown = !ide;
    _wasInIde = ide;
    _launch = (windows: windows, chatShown: chatShown);
    chat._shown = chatShown;
    _syncWorkspace();
    await host.setMainShownAtLaunch(chatShown);
    _mainShownNext = chatShown;
  }

  Future<void> _prepareMainOnly(Map<String, Object?> kept) async {
    // The IDE is in the main window, but file panels still open separately.
    final front = [
      for (final json in kept['windows'] as List<Object?>? ?? const [])
        ?_KeptWindow.fromJson(json),
    ].where((w) => !w.chat && w.folder != null).firstOrNull;
    if (front?.folder case final folder?
        when workspace.ideFolder == null && await _isDirectory(folder)) {
      workspace.openIdeFolder(folder);
    }
    _launch = (windows: const [_KeptWindow(chat: true)], chatShown: true);
    await host.setMainShownAtLaunch(true);
    _mainShownNext = true;
  }

  /// Opens the windows [prepareLaunch] read, back to front, each where it
  /// was (moved back onto a screen, if that one is gone); the one in front
  /// at the last quit is again.
  Future<void> restore() async {
    final launch = _launch;
    if (launch == null || !_started) return;
    _launch = null;
    await _serial(() async {
      if (!launch.chatShown) await host.hide(chat.viewId);
      final screens = await host.screens();
      for (final kept in launch.windows.reversed) {
        if (kept.chat) {
          if (launch.chatShown) _focus(chat);
          continue;
        }
        await _create(kept.folder, frame: kept.frame?.fit(screens));
      }
      final front = _mru.where((w) => w.shown).firstOrNull;
      if (front != null) _focus(front);
    });
    await _restorePanels();
    _save();
  }

  /// Opens again the file panels [prepareLaunch] read, once the workspace
  /// has what it keeps (their owners among it): a panel whose owner is
  /// gone, or whose id is open already, is left out. Back to front, so the
  /// first of them is in front; where it was, moved back onto a screen if
  /// that one is gone.
  Future<void> _restorePanels() async {
    final kept = _panelLaunch;
    if (kept == null || !_started) return;
    if (kept.isEmpty) {
      _panelLaunch = null;
      return;
    }
    // A session kept in the workspace's projects: not before it has read
    // them (a first run, the files read while the windows open).
    if (workspace.loading) {
      await workspace.loaded.timeout(
        const Duration(seconds: 10),
        onTimeout: () {},
      );
    }
    try {
      await _serial(() async {
        final screens = await host.screens();
        final restored = <AppWindow>[];
        for (final spec in kept.reversed) {
          if (panelFor(spec.id) != null) continue;
          if (spec.tabId case final tabId? when windowForTab(tabId) != null) {
            continue;
          }
          // One window failing is not the rest's: it is left out, and the
          // ones after it still open.
          var prepared = false;
          try {
            // A tab moved out of the dock (files among them), or a draft
            // whose owner only its reference names, is the main
            // workbench's to resolve: it vacates the main view before the
            // window opens.
            final prepare = prepareDockPanelRestore;
            final moved = spec.tabId != null || spec.ownerReference != null;
            prepared = moved && prepare != null;
            if (prepared) {
              if (!prepare(spec)) {
                prepared = false;
                continue;
              }
            } else if (!_panelOwnerExists(spec.ownerId)) {
              continue;
            }
            final frame = spec.frame?.fit(screens);
            final window = await _createPanel(
              frame == null ? spec : spec.copyWith(frame: frame),
              show: false,
            );
            if (window != null) {
              restored.add(window);
            } else if (prepared) {
              // The window could not be made: the tab goes back where it
              // came from, rather than being lost.
              await _undoDockRestore(spec);
            }
          } catch (error, stack) {
            debugPrint('restore panel ${spec.id}: $error\n$stack');
            // Prepared and not made: the tab goes back rather than away.
            if (prepared && panelFor(spec.id) == null) {
              try {
                await _undoDockRestore(spec);
              } catch (undoError) {
                debugPrint('restore panel ${spec.id} undo: $undoError');
              }
            }
          }
        }
        // Native secondary windows are hidden until focused. Show every
        // restored view back to front, not only the last one we created.
        for (final window in restored) {
          _toFront(window);
          await host.focus(window.viewId);
        }
      });
    } finally {
      // Even one window failing: the rest is written as it is from then on.
      _panelLaunch = null;
    }
  }

  // --- Opening ---------------------------------------------------------------

  /// One opening at a time: a second waits for the window the first opens.
  Future<void> _queue = Future.value();

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// The Workspace's IDE entries (Open in Fast Ide, the sidebar's, a
  /// changed file clicked): [folder]'s window, [thread] its chat's tab.
  void _routeIde(String? folder, AgentThread? thread) =>
      unawaited(showFolder(folder, thread: thread));

  /// The IDE's window of [folder], opened if it is not, in front; with
  /// [thread] the tab of its chat and [files] in editors. Without a
  /// folder, the IDE's window last in front (an empty one, if there is
  /// none, or with [newWindow]).
  Future<AppWindow?> showFolder(
    String? folder, {
    AgentThread? thread,
    List<CodeTarget> files = const [],
    bool newWindow = false,
  }) {
    if (!multi) return _showInMain(folder, thread: thread, files: files);
    return _serial(() async {
      var window = folder == null
          ? (newWindow ? null : recentIde)
          : windowFor(folder);
      // A new window for files shows once they are open in it, not its
      // welcome page first.
      var hidden = false;
      if (window == null) {
        hidden = files.isNotEmpty;
        window = await _create(folder, show: !hidden);
      } else {
        _focus(window);
        if (folder != null) workspace.noteIdeFolder(folder);
      }
      if (window == null) return null;
      if (thread != null || files.isNotEmpty) {
        final delegate = await window.ready;
        if (thread != null) delegate?.showAgent(thread);
        if (files.isNotEmpty) {
          final opening = delegate?.openFiles(files) ?? Future<void>.value();
          if (hidden) {
            // Not kept from sight long by a slow file.
            await opening
                .timeout(_filesWait, onTimeout: () {})
                .catchError((Object _) {});
            await _nextFrame();
            _focus(window);
          }
          await opening;
        }
      }
      return window;
    });
  }

  /// Without windows of its own, the IDE shows in the main one (in front,
  /// shown again if it was closed).
  Future<AppWindow?> _showInMain(
    String? folder, {
    AgentThread? thread,
    List<CodeTarget> files = const [],
  }) async {
    if (_started) _focus(chat);
    final delegate = await chat.ready;
    if (delegate == null) return null;
    if (thread != null) {
      workspace.openInIde(thread);
    } else {
      delegate.showIdeFolder(folder);
    }
    if (files.isNotEmpty) await delegate.openFiles(files);
    return chat;
  }

  /// New Window: an empty one. With the IDE in the main window, its empty
  /// window there (the folder it had stays among the recent).
  Future<AppWindow?> newWindow() {
    if (!multi) {
      workspace.closeIdeFolder();
      return _showInMain(null);
    }
    return showFolder(null, newWindow: true);
  }

  /// How long a new window waits for the files it opens before it shows
  /// (see [showFolder]).
  static const _filesWait = Duration(seconds: 1);

  /// Opens a window of the IDE's for [folder] (its welcome, for none): at
  /// the size `window.newWindowDimensions` says, shown once it is drawn
  /// (with [show] false, when the caller focuses it).
  Future<AppWindow?> _create(
    String? folder, {
    WindowFrame? frame,
    bool show = true,
  }) async {
    if (folder != null) workspace.noteIdeFolder(folder);
    final l10n = _l10n();
    final window = AppWindow._(AppWindowKind.ide, -1, folder);
    final viewId = await host.create(
      frame: frame ?? await _newFrame(),
      title: window.title(l10n),
    );
    if (viewId == null) return null;
    if (await host.waitForView(viewId) == null) {
      await host.close(viewId);
      return null;
    }
    final created = AppWindow._(
      AppWindowKind.ide,
      viewId,
      folder,
      frame: frame,
    );
    _ide.add(created);
    _mru.insert(0, created);
    _changed();
    // Shown once it has something to show.
    await _nextFrame();
    if (show) _focus(created);
    unawaited(
      host.setTitle(viewId, created.title(l10n), path: _localOnly(folder)),
    );
    return created;
  }

  /// Where a new window goes: `default`, where the system puts one;
  /// `inherit`, the size of the one in front, below and right of it;
  /// `maximized` and `fullscreen` so.
  Future<WindowFrame?> _newFrame() async {
    final dimensions = _settings().newWindowDimensions;
    if (dimensions == NewWindowDimensions.defaultSize) return null;
    final front = active;
    final frame = await host.frame(front.viewId) ?? front.frame;
    if (frame == null) return null;
    final screens = await host.screens();
    return switch (dimensions) {
      NewWindowDimensions.inherit => frame.cascade(screens),
      NewWindowDimensions.maximized => frame.copyWith(
        maximized: true,
        fullscreen: false,
      ),
      NewWindowDimensions.fullscreen => frame.copyWith(fullscreen: true),
      NewWindowDimensions.defaultSize => null,
    };
  }

  /// [window] in front, the keyboard's.
  void focus(AppWindow window) {
    if (!_started) return;
    _focus(window);
    _save();
  }

  void _focus(AppWindow window) {
    _toFront(window);
    unawaited(host.focus(window.viewId));
  }

  void _toFront(AppWindow window) {
    final wasShown = window.shown;
    window._shown = true;
    WindowControls.activeViewId = window.viewId;
    if (identical(_mru.firstOrNull, window) && wasShown) return;
    _mru
      ..remove(window)
      ..insert(0, window);
    _changed();
  }

  /// Shows the chat's window again (Show Chat Window; the Dock's icon).
  void showChat() {
    if (!_started) return;
    focus(chat);
  }

  /// Opens [files]: each in the window whose folder has it, else in [from]
  /// (where they were dropped), else the IDE's window last in front, else a
  /// new one; with [newWindow], all in a new one, with [reuse], in the one
  /// last in front.
  Future<void> openFiles(
    List<CodeTarget> files, {
    bool newWindow = false,
    bool reuse = false,
    AppWindow? from,
  }) async {
    if (files.isEmpty) return;
    if (!multi) {
      await _showInMain(null, files: files);
      return;
    }
    if (newWindow) {
      await showFolder(null, files: files, newWindow: true);
      return;
    }
    final groups = <AppWindow?, List<CodeTarget>>{};
    for (final file in files) {
      final window = reuse
          ? recentIde
          : _containing(file.path) ?? from ?? recentIde;
      (groups[window] ??= []).add(file);
    }
    for (final MapEntry(key: window, value: targets) in groups.entries) {
      if (window == null) {
        await showFolder(null, files: targets, newWindow: true);
        continue;
      }
      await _serial(() async {
        if (window.folder == null &&
            !_ide.contains(window) &&
            !_panels.contains(window)) {
          return;
        }
        _focus(window);
        for (final target in targets) {
          workspace.addRecentFile(target.path);
        }
        final delegate = await window.ready;
        await delegate?.openFiles(targets);
      });
    }
  }

  /// What the `code` command asks (see [CodeArgs]).
  Future<void> handleCode(CodeArgs args) async {
    if (args.opensNothing) {
      // The app started for it (an older script's request) shows its own
      // window, not none.
      if (_started && !_mru.any((window) => window.shown)) showChat();
      return;
    }
    final folders = <CodeTarget>[], files = <CodeTarget>[];
    for (final path in args.paths) {
      final target = await _located(path);
      (await _isDirectory(target.path) ? folders : files).add(target);
    }
    await _openCode(args, folders, files);
  }

  /// What the `code` command asks in a terminal of [host]'s (see
  /// ServerCli): its arguments read from [cwd] there, [stat] telling its
  /// files (`file`, `directory`, null for none) from its folders. What went
  /// wrong, for the command to print, or null; the windows open after.
  Future<String?> handleRemoteCode(
    String host,
    String cwd,
    List<String> arguments, {
    required Future<String?> Function(String path) stat,
  }) async {
    final args = CodeArgs.parse(arguments, cwd: cwd);
    if (args.opensNothing) {
      return "BaoCode's code command only opens files and folders.";
    }
    Future<String?> typeOf(String path) =>
        stat(path).then((type) => type, onError: (Object _) => null);
    final folders = <CodeTarget>[], files = <CodeTarget>[];
    for (var target in args.paths) {
      var type = await typeOf(target.path);
      // `a.vue:58:11` without `-g`, as below.
      final at = type == null ? target.atLine : null;
      if (at != null) {
        if (await typeOf(at.path) case final there?) {
          (target, type) = (at, there);
        }
      }
      final location = CodeTarget(
        RemoteLocation.of(host, target.path),
        line: target.line,
        column: target.column,
      );
      (type == 'directory' ? folders : files).add(location);
    }
    unawaited(
      _openCode(
        args,
        folders,
        files,
      ).catchError((Object error) => debugPrint('code: $error')),
    );
    return null;
  }

  /// Opens [folders] and [files] as [args] asks (see [handleCode]).
  Future<void> _openCode(
    CodeArgs args,
    List<CodeTarget> folders,
    List<CodeTarget> files,
  ) async {
    if (folders.isEmpty && files.isEmpty) {
      if (!multi) {
        await _showInMain(null);
        return;
      }
      await showFolder(null, newWindow: args.newWindow);
      return;
    }
    for (final folder in folders) {
      final reuse = args.reuseWindow ? recentIde : null;
      if (reuse != null && windowFor(folder.path) == null) {
        await replaceFolder(reuse, folder.path);
      } else {
        await showFolder(folder.path);
      }
    }
    await openFiles(
      files,
      newWindow: args.newWindow && folders.isEmpty,
      reuse: args.reuseWindow,
    );
  }

  /// [target], or the file it names at a line: `a.vue:58:11` given without
  /// `-g` (as tools that start an editor they do not know give it) is
  /// a.vue at line 58, column 11, unless there is a file of that name.
  Future<CodeTarget> _located(CodeTarget target) async {
    final at = target.atLine;
    if (at == null || RemoteLocation.isRemote(target.path)) return target;
    if (await _exists(target.path) || !await _exists(at.path)) return target;
    return at;
  }

  /// What the system asks to open: a request of the `code` command (on
  /// Windows, its arguments; on macOS, the file its script left), Open
  /// with BaoCode's ([openAgent]), or paths (Finder's Open With, the Dock's
  /// icon, the File menu's Open Recent), as `code` would open them.
  Future<void> openRequested(List<String> paths) async {
    if (paths.firstOrNull == CodeArgs.agentRequestMarker) {
      await openAgent(paths.sublist(1));
      return;
    }
    if (CodeArgs.isRequest(paths)) {
      await handleCode(CodeArgs.fromRequest(paths));
      return;
    }
    final plain = <String>[];
    for (final path in paths) {
      if (!path.endsWith(CodeArgs.requestFileSuffix)) {
        plain.add(path);
        continue;
      }
      final request = await _takeFile(path);
      if (request != null) await handleCode(CodeArgs.fromRequestFile(request));
    }
    if (plain.isEmpty) return;
    await handleCode(
      CodeArgs(paths: [for (final path in plain) CodeTarget(path)]),
    );
  }

  /// How wide an agent's window opens (see [openAgent]): the
  /// conversation alone.
  static const agentWidth = 520.0;

  /// Explorer's Open with BaoCode: a new agent, ready to type to, in a new
  /// window of its own each time ([agentWidth] wide; without windows, in
  /// the chat's). A folder is its project (opened as one if it was not); a
  /// file goes in the composer as if pasted, the agent in the project it is
  /// in, else in its folder.
  Future<AgentThread?> openAgent(List<String> paths) async {
    String? folder;
    final files = <ComposerFile>[];
    for (final path in paths) {
      final directory = await _isDirectory(path);
      if (directory && folder == null) {
        folder = path;
      } else {
        files.add(ComposerFile(path, directory: directory));
      }
    }
    if (folder == null && files.isEmpty) return null;
    folder ??= _projectOf(files.first.path) ?? p.dirname(files.first.path);
    if (!_started) {
      final thread = await workspace.openFolder(folder);
      thread.session.draft.insertFiles(files);
      workspace.layout = WorkspaceLayout.chat;
      (await chat.ready)?.showAgent(thread);
      return thread;
    }
    final thread = workspace.newWindowAgent(folder);
    thread.session.draft.insertFiles(files);
    final window = await _serial(() => _createAgent(thread));
    if (window == null) workspace.closeWindowAgent(thread);
    return window == null ? null : thread;
  }

  /// Opens a window of [thread]'s own, [agentWidth] wide.
  Future<AppWindow?> _createAgent(AgentThread thread) async {
    final l10n = _l10n();
    final pending = AppWindow._(AppWindowKind.agent, -1, null, thread: thread);
    final viewId = await host.create(
      title: pending.title(l10n),
      width: agentWidth,
    );
    if (viewId == null) return null;
    if (await host.waitForView(viewId) == null) {
      await host.close(viewId);
      return null;
    }
    final created = AppWindow._(
      AppWindowKind.agent,
      viewId,
      null,
      thread: thread,
    );
    _agents.add(created);
    _mru.insert(0, created);
    _titles[created] = pending.title(l10n);
    _watchAgents();
    _changed();
    // Shown once it has something to show.
    await _nextFrame();
    _focus(created);
    return created;
  }

  /// The agents' windows' titles, as last set: an agent titled after its
  /// first message (or renamed), its window's title follows.
  final Map<AppWindow, String> _titles = {};
  bool _watching = false;

  void _watchAgents() {
    if (_watching) return;
    _watching = true;
    workspace.addListener(_agentsChanged);
  }

  void _agentsChanged() {
    if (!_started) return;
    final l10n = _l10n();
    var retitled = false;
    for (final window in [..._agents]) {
      // Deleted (or dropped) meanwhile: its window goes.
      if (!workspace.threads.contains(window.thread)) {
        unawaited(_remove(window));
        continue;
      }
      final title = window.title(l10n);
      if (_titles[window] == title) continue;
      _titles[window] = title;
      unawaited(host.setTitle(window.viewId, title));
      retitled = true;
    }
    _titles.removeWhere((window, _) => !_agents.contains(window));
    if (retitled) _syncMenus();
  }

  @override
  void dispose() {
    if (_watching) workspace.removeListener(_agentsChanged);
    super.dispose();
  }

  /// The project [path] is in (the deepest), if any.
  String? _projectOf(String path) {
    String? best;
    for (final project in workspace.projects) {
      if (!p.isWithin(project.path, path)) continue;
      if (best == null || best.length < project.path.length) {
        best = project.path;
      }
    }
    return best;
  }

  /// Files dragged from Finder or Explorer onto [viewId]'s window, where no
  /// part of it took them: a folder opens its window, files as the `code`
  /// command opens them (in the window they were dropped on, unless one
  /// has their folder).
  bool dropped(int viewId, List<ComposerFile> files) {
    if (files.isEmpty) return false;
    final window = windowOf(viewId);
    unawaited(() async {
      for (final folder in files.where((file) => file.directory)) {
        await showFolder(folder.path);
      }
      await openFiles([
        for (final file in files)
          if (!file.directory) CodeTarget(file.path),
      ], from: window != null && window.isIde ? window : null);
    }());
    return true;
  }

  /// Open Folder… in [window]: [folder] in its place (its unsaved files
  /// asked about first); a window that has it already comes in front.
  /// None: Close Folder, its welcome.
  Future<void> replaceFolder(AppWindow window, String? folder) async {
    if (!multi || !window.isIde) {
      await showFolder(folder);
      return;
    }
    if (folder != null) {
      if (windowFor(folder) case final open?) {
        if (!identical(open, window)) focus(open);
        return;
      }
    }
    if (folder == null && window.folder == null) return;
    if (!await _confirmUnsaved([window])) return;
    if (folder != null) workspace.noteIdeFolder(folder);
    if (window.delegate case final delegate?) window.detach(delegate);
    window._setFolder(folder);
    _focus(window);
    unawaited(
      host.setTitle(
        window.viewId,
        window.title(_l10n()),
        path: _localOnly(folder),
      ),
    );
    unawaited(host.setEdited(window.viewId, false));
    _changed();
    _save();
  }

  // --- Closing and quitting ----------------------------------------------------

  final Set<AppWindow> _closing = {};

  /// Closes [window] as its close button, Close Window or ⌘W do
  /// ([byKeyboard] for a shortcut), asking first as the settings say: the
  /// chat's hides; an agent's goes (the agent goes on, in the sidebar); an
  /// IDE's asks about its unsaved files and its running terminals, and
  /// goes with its editors, terminals and language servers. Whether it
  /// closed.
  Future<bool> requestClose(AppWindow window, {bool byKeyboard = false}) async {
    if (!_started) return false;
    if (window.isChat) {
      await _hideChat();
      return true;
    }
    if (window.isAgent) {
      if (!_agents.contains(window)) return false;
      await _remove(window);
      return true;
    }
    if (window.isPanel) {
      // A moved conversation's window closed returns it to the dock; the
      // others close as before (see [dockPanel] to dock one back).
      return _closePanel(
        window,
        dockBack: window.panel?.kind == PanelKind.chat,
      );
    }
    if (!_ide.contains(window) || !_closing.add(window)) return false;
    try {
      final settings = _settings();
      final delegate = window.delegate;
      final context = delegate?.windowContext;
      if (context != null && context.mounted) {
        if (settings.confirmBeforeClose.asks(byKeyboard: byKeyboard)) {
          _focus(window);
          final l10n = context.l10n;
          final choice = await showIdeDialog(
            context,
            message: l10n.windowConfirmClose,
            buttons: [l10n.cmdCloseWindow],
            type: IdeDialogType.question,
          );
          if (choice != 0) return false;
        }
        if (!await _confirmUnsaved([window])) return false;
        final confirm = settings.terminalConfirmOnExit;
        if (confirm != TerminalConfirmOnExit.never &&
            delegate!.terminalsRunning(
              childProcesses:
                  confirm == TerminalConfirmOnExit.hasChildProcesses,
            ) &&
            context.mounted) {
          _focus(window);
          final l10n = context.l10n;
          final choice = await showIdeDialog(
            context,
            message: l10n.windowTerminateTerminals,
            buttons: [l10n.windowTerminate],
          );
          if (choice != 0) return false;
        }
      }
      await _remove(window);
      return true;
    } finally {
      _closing.remove(window);
    }
  }

  Future<void> _remove(AppWindow window) async {
    // Out of full screen first, still drawn (see WindowHost.leaveFullScreen);
    // then back to the window it covered.
    final wasFullScreen = await host.leaveFullScreen(window.viewId);
    _ide.remove(window);
    _agents.remove(window);
    _panels.remove(window);
    _mru.remove(window);
    _changed();
    // Its view's widgets go first, then the view.
    await _nextFrame();
    WindowControls.stopListening(window.viewId);
    FileDrops.stopListening(window.viewId);
    await host.close(window.viewId);
    if (window.thread case final thread?) workspace.closeWindowAgent(thread);
    _save();
    if (_mru.firstWhereOrNull((w) => w.shown) case final front?) {
      WindowControls.activeViewId = front.viewId;
      if (wasFullScreen) unawaited(host.focus(front.viewId));
    }
    await _quitIfNoneShows();
  }

  Future<void> _hideChat() async {
    chat._shown = false;
    _mru
      ..remove(chat)
      ..add(chat);
    _changed();
    await host.leaveFullScreen(chat.viewId);
    await host.hide(chat.viewId);
    _save();
    final front = active;
    if (front.shown) {
      WindowControls.activeViewId = front.viewId;
      if (!front.isChat) unawaited(host.focus(front.viewId));
    }
    await _quitIfNoneShows();
  }

  /// On Windows, the app goes with its last window, unless the tray keeps
  /// it; quitting cancelled, the chat's window shows again.
  Future<void> _quitIfNoneShows() async {
    if (!_quitsWithLastWindow || _hasTray()) return;
    if (_mru.any((w) => w.shown)) return;
    if (await _quit() == AppExitResponse.cancel) showChat();
  }

  /// Saves, or not, the unsaved files of [windows], asked once for all of
  /// them in the window in front; whether to go on (not cancelled, all
  /// saved that were to be).
  Future<bool> _confirmUnsaved(List<AppWindow> windows) async {
    final unsaved = <(WindowDelegate, List<IdeDocument>)>[];
    for (final window in windows) {
      final delegate = window.delegate;
      if (delegate == null) continue;
      final documents = await delegate.unsavedDocuments();
      if (documents.isNotEmpty) unsaved.add((delegate, documents));
    }
    if (unsaved.isEmpty) return true;
    final asker = windows.length == 1 ? windows.single : active;
    final context = (asker.delegate ?? unsaved.first.$1).windowContext;
    if (context == null || !context.mounted) return true;
    if (_started) _focus(asker);
    final l10n = context.l10n;
    final documents = [for (final (_, docs) in unsaved) ...docs];
    final choice = await showIdeDialog(
      context,
      message: documents.length == 1
          ? l10n.wbConfirmSave(documents.single.name)
          : l10n.windowSaveChanges(documents.length),
      detail: documents.length == 1
          ? l10n.explorerChangesLost
          : [
              for (final doc in documents) doc.name,
              '',
              l10n.explorerChangesLost,
            ].join('\n'),
      buttons: [
        documents.length == 1 ? l10n.commonSave : l10n.windowSaveAll,
        l10n.commonDontSave,
      ],
    );
    switch (choice) {
      case 0:
        for (final (delegate, docs) in unsaved) {
          if (!await delegate.saveDocuments(docs)) return false;
        }
        return true;
      case 1:
        return true;
      default:
        return false;
    }
  }

  /// Before the app quits (⌘Q, the tray's Quit, logging out): the unsaved
  /// files of all windows asked about at once, then (as before windows)
  /// whether to quit with agents or terminals at work; asked in the window
  /// in front, shown for it (the app may be in the tray). With nothing at
  /// work, the Quit (the tray's, the last window's close button) is enough.
  Future<bool> confirmQuit() async {
    // A panel's own workbench answers for its files, and is not asked about
    // them again here.
    final guarded = [
      for (final panel in _panels)
        if (panel.delegate case final FilePanelDelegate guard) (panel, guard),
    ];
    final windows = [
      ..._ide,
      chat,
      for (final panel in _panels)
        if (panel.delegate is! FilePanelDelegate) panel,
    ];
    if (!await _confirmUnsaved(windows)) return false;
    for (final (_, guard) in guarded) {
      if (!await guard.confirmFilePanelClose()) return false;
    }
    final working =
        workspace.threads.any(
          (thread) =>
              !thread.archived &&
              // A bot's answering is not the user's work to lose.
              !workspace.isAppFolder(thread.project.path) &&
              (thread.status == ThreadStatus.running ||
                  thread.status == ThreadStatus.needsInput),
        ) ||
        windows.any(
          (window) =>
              window.delegate?.terminalsRunning(childProcesses: true) ?? false,
        );
    // What runs on remote hosts ends with their servers.
    final remote = RemoteClaudeTransport.running + RemotePtyAdapter.open;
    if (!working && remote == 0) return true;
    final asker = active.delegate?.windowContext != null ? active : chat;
    final context = asker.delegate?.windowContext;
    if (context == null || !context.mounted) return true;
    if (_started) _focus(asker);
    return QuitConfirmation.confirm(context, remote: remote);
  }

  // --- The system's events -----------------------------------------------------

  @override
  void windowCloseRequested(int viewId) {
    if (_stash?.viewId == viewId) {
      stashCloseRequested?.call();
      return;
    }
    if (windowOf(viewId) case final window?) {
      unawaited(requestClose(window));
    }
  }

  @override
  void windowFocused(int viewId) {
    if (defaultTargetPlatform == TargetPlatform.windows) _reattachTextInput();
    final window = windowOf(viewId);
    if (window == null) return;
    final wasShown = window.shown;
    _toFront(window);
    if (!wasShown) _syncWorkspace();
    _save();
  }

  /// Back in front on Windows (Alt+Tab), the text field that had the
  /// keyboard has its input connection anew: the old one no longer gets
  /// what is typed until the field is clicked.
  void _reattachTextInput() {
    final node = primaryFocus;
    if (node?.context?.findAncestorWidgetOfExactType<EditableText>() == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Moved on meanwhile (a click elsewhere): left as it is.
      if (!identical(primaryFocus, node) || node == null) return;
      node.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
      // After the focus moved (it does in a microtask): asked back at once,
      // it would not have moved at all.
      unawaited(
        Future<void>(() {
          if (node.context != null && !node.hasPrimaryFocus) {
            node.requestFocus();
          }
        }),
      );
    });
  }

  @override
  void windowFrameChanged(int viewId, WindowFrame frame) {
    final window = windowOf(viewId);
    if (window == null || window.frame == frame) return;
    window.frame = frame;
    _save();
  }

  @override
  void newWindowRequested() => unawaited(newWindow());

  /// The tray's Quit. Chosen again while the app asks whether to quit, it
  /// quits: the window asked in may show nothing to answer in.
  @override
  void quitRequested() {
    if (QuitConfirmation.asking) {
      QuitConfirmation.quitAnyway();
      return;
    }
    unawaited(_quit());
  }

  /// The app's icon clicked with none of its windows shown: the IDE's
  /// window last in front (a new one, if none is open) when the app opens
  /// to the IDE, else the chat's.
  @override
  void reopenRequested() {
    if (multi && _mainWindow() == MainWindow.ide) {
      if (recentIde case final window?) {
        focus(window);
      } else {
        unawaited(newWindow());
      }
      return;
    }
    showChat();
  }

  // --- The IDE's windows, or none -------------------------------------------

  /// The setting asked for last that was declined (unsaved files kept the
  /// IDE where it was): not asked again until it changes.
  bool? _declined;
  bool _switching = false;

  /// settings.json changed: what shows at the next launch, and the IDE
  /// moved to windows of its own or into the main window, as
  /// `window.ideWindows` now says.
  void settingsChanged() {
    syncMainShownAtLaunch();
    if (!_started || _switching) return;
    final separate = _settings().ideWindows == IdeWindows.separate;
    if (separate == _separate) {
      _declined = null;
      return;
    }
    if (separate == _declined) return;
    _switching = true;
    unawaited(
      (separate ? _toSeparate() : _toMainWindow()).whenComplete(
        () => _switching = false,
      ),
    );
  }

  /// The main window's IDE moves to a window of its own (if it showed), its
  /// unsaved files asked about first: the main window's editors,
  /// terminals and language servers go.
  Future<void> _toSeparate() async {
    if (!await _confirmUnsaved([chat])) return _decline(true);
    _separate = true;
    final old = workspace.takeSingleWindowIde();
    workspace.ideWindows = _routeIde;
    _changed();
    _save();
    if (old.shown) await showFolder(old.folder);
  }

  /// The IDE's windows close (their unsaved files asked about first); the
  /// main window shows the folder of the one last in front, as the IDE if
  /// one was in front.
  Future<void> _toMainWindow() async {
    final windows = List.of(_ide);
    if (!await _confirmUnsaved(windows)) return _decline(false);
    final front = recentIde;
    final ideInFront = front != null && identical(active, front);
    for (final window in windows) {
      await host.leaveFullScreen(window.viewId);
    }
    if (ideInFront || !chat.shown) _focus(chat);
    // Their views' widgets go first, then the views; then the main window
    // takes the IDE.
    _ide.removeWhere(windows.contains);
    _mru.removeWhere(windows.contains);
    _changed();
    await _nextFrame();
    for (final window in windows) {
      WindowControls.stopListening(window.viewId);
      FileDrops.stopListening(window.viewId);
      await host.close(window.viewId);
    }
    _separate = false;
    workspace.ideWindows = null;
    if (front?.folder case final folder?) workspace.openIdeFolder(folder);
    if (ideInFront) workspace.layout = WorkspaceLayout.ide;
    _changed();
    _save();
  }

  /// Unsaved files kept the IDE where it is: the setting is written back.
  void _decline(bool separate) {
    _declined = separate;
    _updateSetting?.call(
      WindowSettings.ideWindowsKey,
      _separate ? IdeWindows.separate.name : null,
    );
  }

  // --- Agents ------------------------------------------------------------------

  /// An agent a notification (or the tray's menu) picked: in its own
  /// window, if it has one; in the IDE's window it is a tab of, that tab
  /// shown; else in the chat's window.
  void showAgent(AgentThread thread) {
    if (_agents.firstWhereOrNull((w) => w.thread == thread) case final own?) {
      focus(own);
      return;
    }
    // A conversation moved out to a window of its own comes in front there,
    // rather than a second copy opened in the main window.
    if (_panels.firstWhereOrNull(
          (w) =>
              w.panel?.kind == PanelKind.chat &&
              _panelShowsThread(w.panel!, thread),
        )
        case final detached?) {
      focus(detached);
      return;
    }
    if (!multi) {
      if (_started) _focus(chat);
      chat.delegate?.showAgent(thread);
      return;
    }
    final folder = thread.project.path;
    final window = windowFor(folder);
    if (window != null && workspace.ideChats(folder).contains(thread)) {
      workspace.openIdeChat(folder, thread);
      _focus(window);
      unawaited(window.ready.then((delegate) => delegate?.showAgent(thread)));
      return;
    }
    _focus(chat);
    unawaited(chat.ready.then((delegate) => delegate?.showAgent(thread)));
  }

  /// [window], an agent's, shows [thread] in place of its own: one picked
  /// (or made) in its sidebar, as the chat's window would. The agent it had
  /// goes if nothing was sent to it, as with its window closed.
  /// Whether [spec], a chat panel's, shows [thread]: by its tab id, its
  /// owner's id, or the id it kept in its state.
  static bool _panelShowsThread(PanelSpec spec, AgentThread thread) {
    final id = thread.id;
    if (id == null || id.isEmpty) return false;
    return spec.tabId == id ||
        spec.ownerId == id ||
        spec.state['threadId'] == id;
  }

  void showInWindow(AppWindow window, AgentThread thread) {
    final old = window.thread;
    if (!window.isAgent || identical(old, thread)) return;
    window._thread = thread;
    _agentsChanged();
    _changed();
    if (old != null) workspace.closeWindowAgent(old);
  }

  // --- The file panels ---------------------------------------------------------

  /// A panel's stable id: of its owner and what it shows, unless the caller
  /// gives one.
  static String panelId(
    String ownerId,
    String projectPath, {
    PanelKind kind = PanelKind.files,
  }) => '${kind.name}:$ownerId:$projectPath';

  /// Opens [ownerId]'s panel of [kind] on [projectPath] (with [files] in
  /// editors and [tabs] in its side panel, [activeFile] in front): its
  /// window, shown in front; the panel with [id], or the one moved from
  /// [tabId], if it is open already (its files opened, where it was). A
  /// panel duplicated from another is [readOnly], its files shown not to
  /// edit. A moved dock tab keeps [dockGroup], [dockIndex] and [state];
  /// [ownerReference] names an owner whose session has no id yet. [commit],
  /// after the window's view is there and before its workbench mounts, may
  /// still refuse it (false closes the window, nothing moved into it). Null
  /// where the system opens no window of its own, or the window could not
  /// be made.
  Future<AppWindow?> openFilePanel(
    String ownerId, {
    required String projectPath,
    String? id,
    PanelKind kind = PanelKind.files,
    String? tabId,
    Object? ownerReference,
    String? dockGroup,
    int? dockIndex,
    Map<String, Object?> state = const {},
    WindowFrame? frame,
    List<CodeTarget> files = const [],
    List<FileOpenRequest> tabs = const [],
    String? activeFile,
    bool readOnly = false,
    bool Function()? commit,
  }) {
    if (!_started) return Future.value(null);
    final spec = PanelSpec(
      id: id ?? panelId(ownerId, projectPath, kind: kind),
      ownerId: ownerId,
      projectPath: projectPath,
      kind: kind,
      tabId: tabId,
      ownerReference: ownerReference,
      dockGroup: dockGroup,
      dockIndex: dockIndex,
      state: state,
      frame: frame,
      tabs: tabs,
      activeFile: activeFile,
      readOnly: readOnly,
    );
    return _serial(() async {
      if (panelFor(spec.id) case final open?) {
        _focus(open);
        if (files.isNotEmpty) {
          final delegate = await open.ready;
          await delegate?.openFiles(files);
        }
        _save();
        return open;
      }
      if (spec.tabId case final tabId? when windowForTab(tabId) != null) {
        final open = windowForTab(tabId)!;
        _focus(open);
        if (files.isNotEmpty) {
          final delegate = await open.ready;
          await delegate?.openFiles(files);
        }
        _save();
        return open;
      }
      final created = await _createPanel(spec, files: files, commit: commit);
      if (created != null) _save();
      return created;
    });
  }

  /// The files [window], a panel's, shows, the file in front and whether
  /// they stay open: kept for the next launch, without rebuilding it.
  void keepFilePanel(
    AppWindow window, {
    required List<FileOpenRequest> files,
    required String? activeFile,
    required bool pinned,
  }) {
    final spec = window.panel;
    if (spec == null) return;
    window._panel = spec.copyWith(
      tabs: files,
      activeFile: activeFile,
      pinned: pinned,
    );
    _save();
  }

  /// The state [window], a panel's, keeps for the next launch (a
  /// scratch's text, a page's place): JSON values only.
  void keepPanelState(
    AppWindow window,
    Map<String, Object?> state, {
    bool? pinned,
    String? ownerId,
    String? projectPath,
    Object? ownerReference = PanelSpec._unset,
  }) {
    final spec = window.panel;
    if (spec == null) return;
    window._panel = spec.copyWith(
      state: state,
      pinned: pinned,
      ownerId: ownerId,
      projectPath: projectPath,
      ownerReference: ownerReference,
    );
    if (projectPath != null && projectPath != spec.projectPath) {
      unawaited(
        host.setTitle(
          window.viewId,
          window.title(_l10n()),
          path: _localOnly(projectPath),
        ),
      );
      _syncMenus();
    }
    _save();
  }

  Future<AppWindow?> _createPanel(
    PanelSpec spec, {
    bool show = true,
    List<CodeTarget> files = const [],
    bool Function()? commit,
  }) async {
    final l10n = _l10n();
    final pending = AppWindow._(
      AppWindowKind.panel,
      -1,
      null,
      panel: spec,
      frame: spec.frame,
    );
    final viewId = await host.create(
      frame: spec.frame,
      title: pending.title(l10n),
    );
    if (viewId == null) return null;
    if (await host.waitForView(viewId) == null) {
      await host.close(viewId);
      return null;
    }
    // The caller's last word once the view is there, before the panel is
    // listed and its workbench mounts (a staged transfer that found its
    // source changed closes it here; nothing was moved into it).
    if (commit != null) {
      try {
        if (!commit()) {
          await host.close(viewId);
          return null;
        }
        // Unmount the source view before another view claims its editor,
        // composer, approval dialog or terminal host.
        await _nextFrame();
      } catch (_) {
        await host.close(viewId);
        rethrow;
      }
    }
    final created = AppWindow._(
      AppWindowKind.panel,
      viewId,
      null,
      frame: spec.frame,
      panel: spec,
    );
    _panels.add(created);
    _mru.insert(0, created);
    _changed();
    // Shown once it has something to show.
    await _nextFrame();
    if (show) _focus(created);
    unawaited(
      host.setTitle(
        viewId,
        created.title(l10n),
        path: _localOnly(spec.projectPath),
      ),
    );
    if (files.isNotEmpty) {
      final delegate = await created.ready;
      await delegate?.openFiles(files);
    }
    return created;
  }

  /// Closes the panel with [id] (as its close button does: its unsaved
  /// files asked about first); whether it closed. With [returnChat], its
  /// tab goes back to the main workbench (as [dockPanel]); without it the
  /// panel closes and its tab is not taken back (a staged transfer that
  /// found the window could not be kept closes it so).
  Future<bool> closeFilePanel(String id, {bool returnChat = false}) async {
    final panel = panelFor(id);
    if (panel == null) return false;
    return _closePanel(panel, dockBack: returnChat);
  }

  /// Returns the panel with [id] to the main dock after checking for
  /// unsaved changes, whatever [PanelKind] it shows: the main workbench
  /// takes its tab back (see [FilePanelDelegate.acceptDockedFiles]) and the
  /// chat's window comes in front. Null if it is not open, or was kept.
  Future<AppWindow?> dockPanel(String id) async {
    final panel = panelFor(id);
    if (panel == null) return null;
    // A conversation's panel redocks as its window closes (see
    // [requestClose]); docked here too, it would come back twice.
    final closed = panel.panel?.kind == PanelKind.chat
        ? await requestClose(panel)
        : await _closePanel(panel, dockBack: true);
    if (!closed) return null;
    _focus(chat);
    return chat;
  }

  /// The files panel's dock-back, as [dockPanel] (kept name).
  Future<AppWindow?> dockFilePanel(String id) => dockPanel(id);

  /// Called once a panel's window has closed, with what it showed: the
  /// workbench lets a place in the dock free and drops what it cached of
  /// the panel's owner. Not called for a panel the window could not close.
  void Function(PanelSpec)? onDockPanelClosed;

  /// Closes [window], a panel's, once (its guard the same as
  /// [requestClose]'s): its workbench answers for its unsaved files, then
  /// with [dockBack] its tab goes back to the main workbench
  /// ([FilePanelDelegate.acceptDockedFiles]); without it the panel closes
  /// as before.
  Future<bool> _closePanel(AppWindow window, {required bool dockBack}) async {
    if (!_panels.contains(window) || !_closing.add(window)) return false;
    try {
      // Its workbench answers for its unsaved files once (a panel built
      // before this knew of none).
      final delegate = window.delegate;
      final mayClose = delegate is FilePanelDelegate
          ? await (delegate as FilePanelDelegate).confirmFilePanelClose()
          : await _confirmUnsaved([window]);
      if (!mayClose) return false;
      final spec = window.panel;
      if (dockBack && spec == null) return false;
      // Closing the only window shown would quit the app (Windows): the
      // chat's shows again, as the window to use.
      final lastShown = !_mru.any(
        (other) => other.shown && !identical(other, window),
      );
      if (lastShown) _focus(chat);
      await _remove(window);
      try {
        if (dockBack) {
          workspace.layout = WorkspaceLayout.chat;
          final main = await chat.ready;
          if (main is FilePanelDelegate) {
            (main as FilePanelDelegate).acceptDockedFiles(spec!);
          }
        }
      } finally {
        if (spec != null) onDockPanelClosed?.call(spec);
      }
      return true;
    } finally {
      _closing.remove(window);
    }
  }

  /// A moved dock tab whose window could not be made goes back to the main
  /// workbench, so that it is not lost.
  Future<void> _undoDockRestore(PanelSpec spec) async {
    if (undoDockPanelRestore case final undo?) {
      undo(spec);
      return;
    }
    final main = await chat.ready;
    if (main is FilePanelDelegate) {
      (main as FilePanelDelegate).acceptDockedFiles(spec);
    }
  }

  // --- The stash's panel ------------------------------------------------------

  /// The stash's panel, once made ([startStash]).
  AppWindow? get stash => _stash;
  AppWindow? _stash;

  /// Whether it shows.
  bool get stashShown => _stashShown;
  bool _stashShown = false;

  /// The panel's own close (Alt+F4 on Windows): its owner hides it, what
  /// it has written kept first.
  VoidCallback? stashCloseRequested;

  /// Makes the stash's panel, hidden, for it to show at once when asked
  /// (see [showStash]); null where the system has none.
  Future<AppWindow?> startStash() async {
    if (!_started) return null;
    if (_stash case final stash?) return stash;
    final viewId = await host.createStash();
    if (viewId == null) return null;
    if (await host.waitForView(viewId) == null) return null;
    final window = _stash = AppWindow._(AppWindowKind.stash, viewId, null);
    window._shown = false;
    notifyListeners();
    return window;
  }

  /// Shows the stash's panel, the keyboard's (the app in front stays so).
  Future<void> showStash() async {
    final stash = _stash ?? await startStash();
    if (stash == null) return;
    _stashShown = stash._shown = true;
    WindowControls.activeViewId = stash.viewId;
    await host.showStash();
  }

  /// Hides the stash's panel.
  Future<void> hideStash() async {
    final stash = _stash;
    if (stash == null || !_stashShown) return;
    _stashShown = stash._shown = false;
    if (_mru.firstWhereOrNull((w) => w.shown) case final front?) {
      WindowControls.activeViewId = front.viewId;
    }
    await host.hideStash();
  }

  // --- Titles and menus --------------------------------------------------------

  /// [window] has unsaved files, or no longer: the dot in its close button
  /// (macOS), and in the menus' lists.
  void setEdited(AppWindow window, bool edited) {
    if (window._edited == edited) return;
    window._edited = edited;
    if (!_started) return;
    unawaited(host.setEdited(window.viewId, edited));
    _syncMenus();
  }

  /// The titles and menus again, in the app's language (it changed).
  void relabel() {
    if (!_started) return;
    final l10n = _l10n();
    for (final window in _mru) {
      unawaited(
        host.setTitle(
          window.viewId,
          window.title(l10n),
          path: _localOnly(
            window.isPanel ? window.panel!.projectPath : window.folder,
          ),
        ),
      );
    }
    _menus = null;
    _syncMenus();
  }

  /// Switch Window…: the windows (the chat's among them, shown or not),
  /// the one in front last first, picked over [from].
  void switchWindow(AppWindow from) {
    final delegate = from.delegate;
    if (delegate == null || !multi) return;
    final l10n = _l10n();
    final items = [
      for (final window in [
        ..._mru.where((w) => w.shown),
        ..._mru.where((w) => !w.shown),
      ])
        IdeQuickPickItem(
          label: window.label(l10n),
          description: [
            if (identical(window, from)) l10n.windowCurrent,
            ?window.folder,
          ].join('  '),
          icon: Icon(
            window.isChat
                ? Codicons.commentDiscussion
                : window.isAgent
                ? Codicons.comment
                : window.isPanel
                ? Codicons.files
                : window.folder == null
                ? Codicons.emptyWindow
                : Codicons.folder,
          ),
          onAccept: () => focus(window),
        ),
    ];
    delegate.showQuickPick(
      IdeQuickPick(
        items: items,
        placeholder: l10n.windowSwitchPlaceholder,
        matchOnDescription: true,
        sortByLabel: false,
        activeItems: [items.length > 1 ? items[1] : items.first],
        onDidAccept: (item) => item?.onAccept?.call(),
      ),
    );
  }

  List<WindowMenuEntry>? _menus;

  void _syncMenus() {
    if (!_started) return;
    final l10n = _l10n();
    final menus = [
      for (final window in [chat, ..._ide, ..._agents, ..._panels])
        WindowMenuEntry(
          viewId: window.viewId,
          title: window.label(l10n),
          edited: window.edited,
        ),
    ];
    if (listEquals(menus, _menus)) return;
    _menus = menus;
    unawaited(
      host.setWindowList(
        menus,
        labels: {
          'newWindow': l10n.cmdNewWindow,
          'showChat': l10n.cmdShowChatWindow,
          'cycle': l10n.windowCycle,
          'windows': l10n.windowMenuWindows,
        },
      ),
    );
  }

  // --- Keeping them ------------------------------------------------------------

  /// What the workspace counts as shown: the chat's panes while its window
  /// shows, the tabs of the IDE's windows, and the agents' windows'.
  void _syncWorkspace() {
    workspace.showAgentWindows([for (final window in _agents) ?window.thread]);
    if (!multi) return;
    workspace.showWindows(
      folders: [for (final window in _ide) ?window.folder],
      chat: chat.shown,
    );
  }

  void _changed() {
    _syncWorkspace();
    _syncMenus();
    notifyListeners();
  }

  bool? _mainShownNext;
  Future<void> _writing = Future.value();

  /// Keeps the windows for the next launch (`windows.json`), the one in
  /// front first, and tells the system whether the chat's shows then.
  void _save() {
    // Not while what to open again is being read and opened: it would be
    // written over with the windows opened so far.
    if (!_started || _launch != null || _panelLaunch != null || _quitting) {
      return;
    }
    final store = _store;
    final data = <String, Object?>{
      'version': _version,
      'windows': [
        // An agent's window is not opened again; the panels are kept
        // apart, by their stable ids and owners.
        for (final window in _mru.where((w) => !w.isAgent && !w.isPanel))
          (window.isChat
                  ? const _KeptWindow(chat: true)
                  : _KeptWindow(folder: window.folder, frame: window.frame))
              .toJson(),
      ],
      if (_panels.isNotEmpty)
        'panels': [
          for (final window in _panels)
            window.panel!.copyWith(frame: window.frame).toJson(),
        ],
      'chatShown': chat.shown,
      'leftIn': _leftInIde ? 'ide' : 'chat',
    };
    if (store != null) {
      _writing = _writing
          .then((_) => store.write(data))
          .catchError((Object error) => debugPrint('windows.json: $error'));
    }
    syncMainShownAtLaunch();
  }

  /// Whether the app is left in the IDE: an IDE's window in front of
  /// those that show (the agents' aside). With none showing (the last
  /// closed, as on Windows it quits the app), where it was before.
  bool get _leftInIde {
    if (_mru.firstWhereOrNull((w) => w.shown && !w.isAgent && !w.isPanel)
        case final front?) {
      _wasInIde = front.isIde;
    }
    return _wasInIde;
  }

  bool _wasInIde = false;

  /// Whether the chat's window shows at the next launch, as the system is
  /// to know before the app runs: also when `workbench.mainWindow` changes.
  /// Always, with the IDE in it.
  void syncMainShownAtLaunch() {
    if (!_started) return;
    final shown =
        !_separate ||
        switch (_mainWindow()) {
          MainWindow.chat => true,
          MainWindow.ide => false,
          MainWindow.last => !_leftInIde,
        };
    if (shown == _mainShownNext) return;
    _mainShownNext = shown;
    unawaited(host.setMainShownAtLaunch(shown));
  }

  /// Waits for what is being written.
  @visibleForTesting
  Future<void> get saved => _writing;
}

extension<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) => where(test).firstOrNull;
}
