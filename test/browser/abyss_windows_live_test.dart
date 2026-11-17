// Explicit opt-in: uses an artificial page, temporary browser profile and only
// Abyss's HKCU native-host leaf. Never reads a user's browser profile.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/browser/browser_tools.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';

import '../kernel_test.dart' show FakeCli;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final browserPath = Platform.environment['ABYSS_BROWSER_LIVE'];
  final hostPath = Platform.environment['ABYSS_BROWSER_HOST'];
  final extensionPath = Platform.environment['ABYSS_BROWSER_EXTENSION'];
  test(
    'Windows independent extension connects and controls only its shared tabs',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'abyss-browser-live-',
      );
      final profile = Directory(p.join(temporary.path, 'profile'))
        ..createSync();
      final endpoint = p.join(temporary.path, 'Abyss-browser-bridge');
      final manifest = File(p.join(temporary.path, 'dev.abyss.browser.json'))
        ..writeAsStringSync(
          jsonEncode({
            'name': BrowserBridge.hostName,
            'description': 'Abyss test',
            'path': p.absolute(hostPath!),
            'type': 'stdio',
            'allowed_origins': [
              'chrome-extension://${AppEdition.browserExtensionId}/',
            ],
          }),
        );
      final registry = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'''
$ErrorActionPreference='Stop'
$keys=@('Software\Google\Chrome\NativeMessagingHosts\dev.abyss.browser','Software\Microsoft\Edge\NativeMessagingHosts\dev.abyss.browser')
$saved=@()
foreach($key in $keys){
 $item=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($key)
 if($null -ne $item){$saved+=@{key=$key;exists=$true;value=$item.GetValue('');kind=[int]$item.GetValueKind('')};$item.Dispose()}
 else{$saved+=@{key=$key;exists=$false}}
}
$saved | ConvertTo-Json -Compress
foreach($key in $keys){$item=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($key);$item.SetValue('',$env:ABYSS_TEST_MANIFEST);$item.Dispose()}
''',
        ],
        environment: {'ABYSS_TEST_MANIFEST': manifest.path},
      );
      expect(registry.exitCode, 0, reason: '${registry.stderr}');
      final backup = registry.stdout.toString().trim();
      final backupFile = File(p.join(temporary.path, 'registry-backup.json'))
        ..writeAsStringSync(backup);
      final bridge = BrowserBridge.instance;
      BrowserBridge.socketFolder = endpoint;
      Process? browser;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<title>Abyss live fixture</title><input id="q" placeholder="Search"><button onclick="document.title=\'clicked \'+q.value">Go</button><p>ABYSS_LOCAL_FIXTURE</p><script>console.log("fixture console");fetch("/ping");</script>',
        );
        await request.response.close();
      });
      try {
        await bridge.start();
        expect(File(BrowserBridge.portPath).existsSync(), isTrue);
        BrowserTools.register();
        browser = await Process.start(
          browserPath!,
          [
            '--user-data-dir=${profile.path}',
            '--load-extension=${p.absolute(extensionPath!)}',
            '--remote-debugging-port=0',
            '--no-first-run',
            '--no-default-browser-check',
            '--window-size=1100,850',
            'chrome://extensions/',
          ],
          environment: {'TEMP': temporary.path, 'TMP': temporary.path},
          includeParentEnvironment: true,
        );
        // Only diagnostics from a self-created profile, not browser user data.
        print(
          'ABYSS_LIVE_BROWSER_PID=${browser.pid} PROFILE=${profile.path} EXTENSION=${p.absolute(extensionPath)} REGISTRY_BACKUP=${backupFile.path}',
        );
        unawaited(browser.stdout.drain<void>());
        unawaited(browser.stderr.drain<void>());
        final deadline = DateTime.now().add(const Duration(minutes: 8));
        while (bridge.browsers.isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(
          bridge.browsers,
          isNotEmpty,
          reason: 'Load the unpacked extension through the temporary browser developer page if its command-line load is unsupported.',
        );
        final connection = bridge.browsers.first;
        final tab = await connection.request('tabs.create', {
          'url': 'http://127.0.0.1:${server.port}/',
          'active': true,
        }) as Map;
        final tabId = tab['tabId'] ?? tab['id'];
        expect(tabId, isA<int>());
        final tabs = await connection.request('tabs.list') as List;
        expect(tabs.any((tab) => (tab as Map)['tabId'] == tabId), isTrue);
        expect(
          tabs.any(
            (tab) => '${(tab as Map)['url']}'.startsWith('chrome://extensions'),
          ),
          isFalse,
        );
        final result = await connection.request('cdp', {
          'tabId': tabId,
          'method': 'Runtime.evaluate',
          'params': {
            'expression': 'document.querySelector("#q").value="Abyss";document.querySelector("button").click();document.title',
            'returnByValue': true,
          },
        }) as Map;
        expect(jsonEncode(result), contains('clicked Abyss'));
        final expression = await connection.request('cdp', {
          'tabId': tabId,
          'method': 'Runtime.evaluate',
          'params': {
            'expression': 'document.body.innerText',
            'returnByValue': true,
          },
        });
        expect(jsonEncode(expression), contains('ABYSS_LOCAL_FIXTURE'));
        final shot = await connection.request('cdp', {
          'tabId': tabId,
          'method': 'Page.captureScreenshot',
          'params': {},
        }) as Map;
        final encoded = shot['data'] as String;
        final screenshot = File(
          p.absolute(
            'build/abyss-browser-${p.basenameWithoutExtension(browserPath)}-live.png',
          ),
        );
        screenshot.writeAsBytesSync(base64Decode(encoded));
        final sdk = await ClaudeSdkTools.handle({
          'id': 1,
          'method': 'tools/list',
        }, const ClaudeSdkCall(cwd: '/fixture'));
        expect(jsonEncode(sdk), contains('browser_tabs'));
        final called = await ClaudeSdkTools.handle({
          'id': 2,
          'method': 'tools/call',
          'params': {'name': 'browser_tabs', 'arguments': {}},
        }, const ClaudeSdkCall(cwd: '/fixture'));
        expect(jsonEncode(called), contains('clicked Abyss'));
        final cli = FakeCli();
        ClaudeLaunch? launch;
        final kernel = ClaudeCodeKernel(
          MockKernels.claudeCode,
          const KernelContext(cwd: '/fixture'),
          start: (value) async {
            launch = value;
            return cli;
          },
          providerEnvironment: (_, _) async => const {},
        );
        kernel.prepare();
        await pumpEventQueue(times: 30);
        expect(launch!.sdkServers, contains(ClaudeSdkTools.server));
        cli.push({
          'type': 'control_request',
          'request_id': 'browser-live',
          'request': {
            'subtype': 'mcp_message',
            'server_name': ClaudeSdkTools.server,
            'message': {
              'id': 3,
              'method': 'tools/call',
              'params': {'name': 'browser_tabs', 'arguments': {}},
            },
          },
        });
        final responseDeadline = DateTime.now().add(
          const Duration(seconds: 10),
        );
        while (!cli.written.any(
              (message) =>
                  message['type'] == 'control_response' &&
                  (message['response'] as Map)['request_id'] == 'browser-live',
            ) &&
            DateTime.now().isBefore(responseDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        final replies = cli.written.where(
          (message) =>
              message['type'] == 'control_response' &&
              (message['response'] as Map)['request_id'] == 'browser-live',
        );
        expect(jsonEncode(replies.toList()), contains('clicked Abyss'));
        kernel.dispose();
        await kernel.stopped;
        print(
          'ABYSS_LIVE_PASS browser=${connection.browser} screenshot=${screenshot.path} tab=$tabId',
        );
      } finally {
        await bridge.stop();
        BrowserTools.unregister();
        BrowserBridge.socketFolder = null;
        await server.close(force: true);
        if (browser != null) {
          await Process.run('taskkill.exe', [
            '/PID',
            '${browser.pid}',
            '/T',
            '/F',
          ]);
        }
        final restored = await Process.run(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r'''
$ErrorActionPreference='Stop'
$saved=Get-Content -LiteralPath $env:ABYSS_TEST_BACKUP -Raw | ConvertFrom-Json
foreach($old in $saved){
 if($old.exists){$item=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($old.key);$item.SetValue('', $old.value, [Microsoft.Win32.RegistryValueKind]$old.kind);$item.Dispose()}
 else{[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($old.key,$false)}
}
''',
          ],
          environment: {'ABYSS_TEST_BACKUP': backupFile.path},
        );
        expect(restored.exitCode, 0, reason: '${restored.stderr}');
      }
    },
    skip:
        !Platform.isWindows ||
        !AppEdition.isAbyss ||
        browserPath == null ||
        hostPath == null ||
        extensionPath == null,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
