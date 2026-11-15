import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/build_windows.dart' show mergeBuildEnvironment;

void main() {
  test('installer defaults retain concrete BaoCode request flags', () {
    final installer = File('tool/baocode.iss').readAsStringSync();
    expect(installer, contains('#define CliFlag "--baocode-cli"'));
    expect(installer, contains('#define AgentFlag "--baocode-agent"'));
    expect(installer, isNot(contains('#define CliFlag "{#CliFlag}"')));
    expect(installer, isNot(contains('#define AgentFlag "{#AgentFlag}"')));
  });

  test(
    'child inherits environment and replaces Windows keys ignoring case',
    () {
      final environment = mergeBuildEnvironment(
        {'AppData': r'C:\Users\me\AppData\Roaming', 'Path': r'C:\Tools'},
        {'APPDATA': r'D:\Abyss\build-config'},
      );
      expect(environment, {
        'Path': r'C:\Tools',
        'APPDATA': r'D:\Abyss\build-config',
      });
      expect(
        environment.keys.where((key) => key.toLowerCase() == 'appdata'),
        hasLength(1),
      );
    },
  );

  test('empty override inherits the complete environment', () {
    final environment = mergeBuildEnvironment({'Path': r'C:\Tools'}, {});
    expect(environment, {'Path': r'C:\Tools'});
  });
}
