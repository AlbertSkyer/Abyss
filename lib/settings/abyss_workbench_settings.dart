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
