import 'dart:io';

import 'package:path/path.dart' as p;

/// Product identity which differs between parallel editions. Package names
/// and Flutter method-channel protocols deliberately do not: those remain
/// BaoCode's in every edition. Filesystem, registry, window and native request
/// identities must always be edition-specific.
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
  static const nativeCliFlag = isAbyss ? '--abyss-cli' : '--baocode-cli';
  static const nativeAgentFlag = isAbyss ? '--abyss-agent' : '--baocode-agent';
  static const nativeLinkFlag = isAbyss ? '--abyss-link' : '--baocode-link';

  /// Abyss never consumes BaoCode's signed update feed.
  static const hasUpdateFeed = !isAbyss;
  static bool get hasBrowserExtension => !isAbyss || Platform.isWindows;
  static const browserHost = isAbyss
      ? 'dev.abyss.browser'
      : 'dev.baocode.browser';
  static const browserExtensionId = isAbyss
      ? 'kecjiojfloffimkeghgongilhienkdlh'
      : 'jfjagocghaaheooicmdnhcholmgdkngk';
  static const browserPrefix = isAbyss ? 'abyss-browser' : 'baocode-browser';
  static const browserHostExecutable = isAbyss
      ? 'abyss-browser-host'
      : 'baocode-browser-host';

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
