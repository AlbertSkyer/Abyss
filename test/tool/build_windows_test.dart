import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/build_windows.dart' show mergeBuildEnvironment;

void main() {
  test('Abyss installer packages its own independent browser host', () {
    final installer = File('tool/baocode.iss').readAsStringSync();
    expect(installer, contains('#define BinaryName "Abyss.exe"'));
    expect(installer, contains('#define UrlScheme "abyss"'));
    expect(installer, contains('#define BundleBrowser 1'));
    expect(installer, contains('#define BrowserHostName "dev.abyss.browser"'));
    expect(
      installer,
      contains('#define BrowserHostBinary "abyss-browser-host.exe"'),
    );
    expect(
      installer,
      contains('#define BrowserHostManifest "dev.abyss.browser.json"'),
    );
    expect(installer, contains('PrivilegesRequired=lowest'));
    expect(installer, contains('recursesubdirs createallsubdirs'));
    expect(installer, contains('Source: "{#BundleDir}\\{#BrowserHostBinary}"'));
    final builder = File('tool/build_windows.dart').readAsStringSync();
    expect(builder, contains("arguments.indexOf('--iscc')"));
    expect(builder, contains('isccOverride ?? _findIscc()'));
    final edition = File('browser_extension/abyss.json').readAsStringSync();
    expect(edition, contains('"host": "dev.abyss.browser"'));
    expect(
      edition,
      contains('"extensionId": "kecjiojfloffimkeghgongilhienkdlh"'),
    );
  });
  test('installer defaults retain concrete BaoCode request flags', () {
    final installer = File('tool/baocode.iss').readAsStringSync();
    expect(installer, contains('#define CliFlag "--baocode-cli"'));
    expect(installer, contains('#define AgentFlag "--baocode-agent"'));
    expect(installer, isNot(contains('#define CliFlag "{#CliFlag}"')));
    expect(installer, isNot(contains('#define AgentFlag "{#AgentFlag}"')));
  });

  test('browser registration is one edition leaf, never the other host', () {
    final installer = File('tool/baocode.iss').readAsStringSync();
    final registry = installer.substring(
      installer.indexOf('; The browsers\' native messaging host'),
      installer.indexOf('; Unticked: what an earlier install added goes.'),
    );
    final leaves = RegExp(
      r'Root: HKA; Subkey: "([^"\r\n]*NativeMessagingHosts\\[^"\r\n]+)";.*?',
      multiLine: true,
    ).allMatches(registry).map((match) => match.group(1)).toList();
    expect(leaves, hasLength(3));
    for (final browser in [r'Google\Chrome', 'Microsoft\\Edge', 'Chromium']) {
      final key = 'Software\\$browser\\NativeMessagingHosts\\';
      expect(registry, contains('Subkey: "$key{#BrowserHostName}"'));
      expect(registry, isNot(contains('Subkey: "${key}dev.baocode.browser"')));
      expect(registry, isNot(contains('Subkey: "${key}dev.abyss.browser"')));
    }
    expect(
      RegExp(r'NativeMessagingHosts";[\s\S]*?uninsdeletekeyifempty')
          .allMatches(registry),
      hasLength(3),
    );
    expect(registry, contains('ValueData: "{app}\\{#BrowserHostManifest}"'));
    expect(registry, isNot(contains('Software\\BaoCode')));
  });

  test('Abyss stop script syntax and exact-path process selection', () async {
    final script = _abyssBrowserHostStopScript();
    expect(script.codeUnits.every((unit) => unit < 128), isTrue);
    expect(script, contains(r'$env:ABYSS_BROWSER_HOST_TARGET'));
    expect(script, contains('[System.StringComparison]::OrdinalIgnoreCase'));
    expect(script, isNot(contains('taskkill')));
    final installer = File('tool/baocode.iss').readAsStringSync();
    expect(installer, contains("'{app}\\{#BrowserHostBinary}'"));
    expect(installer, contains('PrepareToInstall'));
    expect(installer, contains('CurUninstallStep = usUninstall'));
    expect(
      installer,
      contains("SetEnvironmentVariable('ABYSS_BROWSER_HOST_TARGET'"),
    );
    expect(installer, isNot(contains('/F /IM abyss-browser-host.exe')));
    expect(installer, isNot(contains('/F /IM {#ProductName}')));
    final temporary = await Directory.systemTemp.createTemp(
      'abyss-installer-stop-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final scriptFile = File('${temporary.path}\\stop.ps1')
      ..writeAsStringSync(script, encoding: ascii);
    final powershell =
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';
    final parse = await Process.run(
      powershell,
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'$errors = $null; [void][System.Management.Automation.Language.Parser]'
            r'::ParseFile($env:ABYSS_SCRIPT_FILE, [ref]$null, [ref]$errors); '
            r'if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; '
            r'exit 1 }',
      ],
      environment: {'ABYSS_SCRIPT_FILE': scriptFile.path},
    );
    expect(parse.stderr, isEmpty, reason: '${parse.stdout}');
    expect(parse.exitCode, 0);

    final installed = r'C:\Program Files\Abyss & quoted\abyss-browser-host.exe';
    final mock =
        '''
function Get-CimInstance {
  [CmdletBinding()]
  param([string]\$ClassName, [string]\$Filter)
  if (\$ClassName -ne 'Win32_Process') { throw 'Unexpected CIM class' }
  if (\$Filter -ne "Name = 'abyss-browser-host.exe'") {
    throw "Unexpected CIM filter: \$Filter"
  }
  @(
    [pscustomobject]@{ ProcessId = 101; ExecutablePath = '$installed' }
    [pscustomobject]@{ ProcessId = 102; ExecutablePath = \$env:ABYSS_BROWSER_HOST_TARGET.ToUpperInvariant() }
    [pscustomobject]@{ ProcessId = 103; ExecutablePath = 'D:\\elsewhere\\abyss-browser-host.exe' }
    [pscustomobject]@{ ProcessId = 104; ExecutablePath = 'C:\\Program Files\\BaoCode\\baocode-browser-host.exe' }
    [pscustomobject]@{ ProcessId = 105; ExecutablePath = \$null }
  )
}
\$global:stopped = @()
function Stop-Process {
  [CmdletBinding()]
  param([int]\$Id, [switch]\$Force)
  \$global:stopped += \$Id
}
& \$env:ABYSS_SCRIPT_FILE
"STOPPED:\$(\$global:stopped -join ',')"
''';
    final run = await Process.run(
      powershell,
      ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', mock],
      environment: {
        'ABYSS_BROWSER_HOST_TARGET': installed,
        'ABYSS_SCRIPT_FILE': scriptFile.path,
      },
    );
    expect(run.stderr, isEmpty, reason: '${run.stdout}');
    expect(run.stdout, contains('STOPPED:101,102'), reason: '${run.stdout}');
    expect(run.exitCode, 0);
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

/// Reconstructs the exact ASCII script embedded in the Abyss Inno [Code]
/// section. This tests generated script text, not an actual install/uninstall.
String _abyssBrowserHostStopScript() {
  final installer = File('tool/baocode.iss').readAsStringSync();
  final declaration = RegExp(
    r'const\s+BrowserHostStopScript\s*=\s*([\s\S]*?);\s*\r?\n\s*procedure EndBrowserHost;',
  ).firstMatch(installer);
  expect(declaration, isNotNull);
  final pieces = RegExp(r"'((?:''|[^'])*)'|#13#10|\{#BrowserHostBinary\}|\+")
      .allMatches(declaration!.group(1)!);
  final script = StringBuffer();
  for (final piece in pieces) {
    final token = piece.group(0)!;
    if (token == '+') continue;
    if (token == '#13#10') {
      script.write('\r\n');
    } else if (token == '{#BrowserHostBinary}') {
      script.write('abyss-browser-host.exe');
    } else {
      script.write(piece.group(1)!.replaceAll("''", "'"));
    }
  }
  return script.toString().replaceAll(
    '{#BrowserHostBinary}',
    'abyss-browser-host.exe',
  );
}
