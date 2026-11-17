import 'dart:io';

import 'package:baocode/browser/browser_endpoint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Windows endpoint is created privately without administrator privileges',
    () async {
      final root = await Directory.systemTemp.createTemp('abyss-endpoint-acl-');
      addTearDown(() => root.delete(recursive: true));
      final directory = '${root.path}/private';
      await BrowserEndpoint.secureDirectory(directory);
      await BrowserEndpoint.secureDirectory(directory);
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'''
$acl=Get-Acl -LiteralPath $env:ABYSS_BROWSER_ENDPOINT
$user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if(-not $acl.AreAccessRulesProtected){exit 2}
foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
 if($rule.IdentityReference.Value -notin @($user,'S-1-5-18','S-1-5-32-544')){exit 3}
}
''',
        ],
        environment: {'ABYSS_BROWSER_ENDPOINT': directory},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final file = File('${root.path}/not-a-directory')
        ..writeAsStringSync('fixture');
      await expectLater(
        BrowserEndpoint.secureDirectory(file.path),
        throwsA(isA<FileSystemException>()),
      );
    },
    skip: !Platform.isWindows,
  );
}
