import 'dart:io';

import 'package:path/path.dart' as p;

/// Product identity which differs between parallel editions. Package names,
/// Flutter channels, command-line flags and remote protocols deliberately do
/// not: they remain BaoCode's in every edition.
abstract final class AppEdition {
  static const name = String.fromEnvironment(
    'APP_EDITION',
    defaultValue: 'BaoCode',
  );
  static const isAbyss = name == 'Abyss';
  static const dataFolder = isAbyss ? 'abyss' : 'baocode';
  static const environmentVariable = isAbyss
      ? 'ABYSS_DATA_DIR'
      : 'BAOCODE_DATA_DIR';
  static const pointerFolder = isAbyss ? '.abyss' : '.baocode';
  static const windowsRegistryRoot = isAbyss
      ? r'Software\Abyss'
      : r'Software\BaoCode';
  static const windowsContextMenu = isAbyss ? 'Abyss' : 'BaoCode';
  static const urlScheme = isAbyss ? 'abyss' : 'baocode';

  /// Abyss has neither a signed update feed nor an extension of its own yet.
  /// Do not silently take BaoCode's, whose installer and browser host would
  /// replace or connect a different product.
  static const hasUpdateFeed = !isAbyss;
  static const hasBrowserExtension = !isAbyss;

  static String defaultDataPath(Map<String, String> environment) {
    var home = environment['HOME'] ?? '';
    if (Platform.isWindows) home = environment['USERPROFILE'] ?? home;
    if (home.isEmpty) {
      home = environment['HOME'] ?? environment['USERPROFILE'] ?? '';
    }
    if (Platform.isWindows) {
      final appData = environment['APPDATA'] ?? '';
      return p.join(appData.isEmpty ? home : appData, dataFolder);
    }
    return Platform.isMacOS
        ? p.join(home, 'Library', 'Application Support', dataFolder)
        : p.join(home, '.config', dataFolder);
  }
}
