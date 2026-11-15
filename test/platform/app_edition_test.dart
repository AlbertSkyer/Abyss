import 'dart:io';

import 'package:baocode/kernel/claude_code/claude_edition.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default edition keeps BaoCode identity and data paths', () {
    expect(AppEdition.isAbyss, isFalse);
    expect(AppEdition.name, 'BaoCode');
    expect(AppEdition.dataFolder, 'baocode');
    expect(AppEdition.environmentVariable, 'BAOCODE_DATA_DIR');
    expect(AppEdition.pointerFolder, '.baocode');
    expect(AppEdition.windowsRegistryRoot, r'Software\BaoCode');
    expect(AppEdition.urlScheme, 'baocode');
    expect(AppEdition.nativeCliFlag, '--baocode-cli');
    expect(AppEdition.nativeAgentFlag, '--baocode-agent');
    expect(AppEdition.nativeLinkFlag, '--baocode-link');

    final environment = <String, String>{
      if (Platform.isWindows)
        'APPDATA': r'C:\Users\me\AppData\Roaming'
      else
        'HOME': '/home/me',
    };
    final result = resolveDataDirectory(
      environment: environment,
      home: '/home/me',
    );
    expect(result.defaultPath, contains('baocode'));
    expect(result.pointerFile, contains('.baocode'));
    expect(
      LocalClaudeIdentity.configDir({
        'HOME': '/home/me',
        'CLAUDE_CONFIG_DIR': '/home/me/foreign',
      }),
      '/home/me/foreign',
    );
  });
}
