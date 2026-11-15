import 'package:bao_remote/local.dart' show AppPaths;
import 'package:path/path.dart' as p;

import '../../platform/app_edition.dart';
import '../../platform/data_dir.dart';

/// Local Claude Code identity. Remote hosts keep their own CLI setup and
/// BaoCode keeps its established ~/.claude behavior.
abstract final class LocalClaudeIdentity {
  static String get dataPathVariable => AppEdition.isAbyss
      ? 'ABYSS_CLAUDE_DATA_PATH'
      : 'BAOCODE_CLAUDE_DATA_PATH';

  /// One root for process launch, session/history catalog and customizations.
  /// Abyss does not inherit BaoCode's sessions, tasks or credentials.
  static String configDir(Map<String, String> environment) {
    if (AppEdition.isAbyss) {
      // Only this product's explicit override may redirect its CLI state.
      // A generic or BaoCode variable from the parent environment must not
      // reconnect Abyss to another product's sessions or credentials.
      if (environment[dataPathVariable] case final dir? when dir.isNotEmpty) {
        return dir;
      }
      return p.join(DataDirectory.current.path, 'claude');
    }
    for (final name in [dataPathVariable, 'CLAUDE_CONFIG_DIR']) {
      if (environment[name] case final dir? when dir.isNotEmpty) return dir;
    }
    final home = AppPaths.home(environment);
    return home.isEmpty ? '' : p.join(home, '.claude');
  }

  static Map<String, String> stateDirectory(
    Map<String, String> environment,
    String configDir,
  ) => {'CLAUDE_CONFIG_DIR': configDir, dataPathVariable: configDir};

  /// The downloaded executable is not its user configuration.
  static String runtimeDir(String dataDirectory) =>
      p.join(dataDirectory, AppEdition.isAbyss ? 'claude-runtime' : 'claude');
}
