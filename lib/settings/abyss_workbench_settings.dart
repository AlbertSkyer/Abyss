import 'package:flutter/foundation.dart';

import '../platform/app_edition.dart';
import 'user_settings.dart';

/// Abyss-only workbench choices, kept in the edition's own settings.json.
///
/// BaoCode always shows subagent tasks in its sidebar. Abyss hides only those
/// rows by default: their sessions, histories, unread state and folding stay
/// untouched, and the conversation's own task views are unaffected.
abstract final class AbyssWorkbenchSettings {
  static const sidebarAgentTasksKey = 'abyss.sidebar.showAgentTasks';
  static const autoDispatchKey = 'abyss.agents.autoDispatch';
  static const autoDispatchConcurrencyKey =
      'abyss.agents.autoDispatchConcurrency';
  static const defaultAutoDispatchConcurrency = AppEdition.isAbyss ? 16 : 3;
  static const minAutoDispatchConcurrency = 1;
  static const maxAutoDispatchConcurrency = 16;

  /// On for Abyss unless explicitly disabled. Model choice is still limited
  /// to the allowed pool; this does not change dangerous-tool permissions.
  static bool parseAuto(Object? value) => AppEdition.isAbyss && value != false;

  /// Read by the kernel whenever a new or continued task is dispatched.
  /// Tests can replace this without attaching a settings file.
  static bool Function() automatic = () =>
      parseAuto(SettingsFiles.instance.settings[autoDispatchKey]);

  /// Only an integer in the supported range is a valid concurrency choice.
  static int parseAutoDispatchConcurrency(Object? value) {
    if (value is int &&
        value >= minAutoDispatchConcurrency &&
        value <= maxAutoDispatchConcurrency) {
      return value;
    }
    return defaultAutoDispatchConcurrency;
  }

  /// The current limit for automatically dispatched main-session tasks.
  /// Tests can replace this without attaching a settings file.
  static int Function() autoDispatchConcurrency = () =>
      parseAutoDispatchConcurrency(
        SettingsFiles.instance.settings[autoDispatchConcurrencyKey],
      );

  /// Set by [attach]; a notifier keeps this a display-only concern of the
  /// sidebar rather than adding workspace or session state.
  static final shown = ValueNotifier<bool>(!AppEdition.isAbyss);

  static UserSettings? _settings;

  static bool parse(Object? value) => !AppEdition.isAbyss || value == true;

  /// Follows the current settings file. Called by the general settings page
  /// and by the sidebar, so either entry point also works on its own in a
  /// window or test without the other.
  static void attach(UserSettings settings) {
    if (identical(_settings, settings)) return;
    _settings?.removeListener(_update);
    _settings = settings;
    settings.addListener(_update);
    _update();
  }

  static void _update() =>
      shown.value = parse(_settings?[sidebarAgentTasksKey]);

  static Object? setting(bool on) => on ? true : null;

  static Future<void> setShown(bool on) async {
    final settings = _settings ?? SettingsFiles.instance.settings;
    attach(settings);
    try {
      await settings.update(sidebarAgentTasksKey, setting(on));
    } catch (error) {
      // A settings file that does not parse is left as it is; its error is
      // already exposed by UserSettings for the settings window to show.
    }
  }
}
