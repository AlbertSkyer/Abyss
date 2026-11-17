import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/claude_code/claude_edition.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/claude_code/claude_onboarding.dart';
import 'package:baocode/models/secret_store_io.dart';
import 'package:baocode/kernel/claude_code/claude_storage_io.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/window/code_args.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Windows provider secrets use only the Abyss data directory', () {
    final previousDataDirectory = DataDirectory.current;
    addTearDown(() => DataDirectory.current = previousDataDirectory);
    final root = Directory.systemTemp.createTempSync('abyss-secret-root-');
    addTearDown(() => root.deleteSync(recursive: true));
    DataDirectory.current = DataDirectory(p.join(root.path, 'abyss'));
    final store = systemSecretStore();
    expect(store, isA<DpapiSecretStore>());
    expect(
      (store as DpapiSecretStore).directory,
      p.join(root.path, 'abyss', 'secrets'),
    );
    expect(root.listSync(), isEmpty);
  }, skip: !Platform.isWindows);

  test(
    'onboarding writes only Abyss config and preserves foreign state',
    () async {
      final previousDataDirectory = DataDirectory.current;
      addTearDown(() => DataDirectory.current = previousDataDirectory);
      final root = Directory.systemTemp.createTempSync(
        'abyss-onboarding-root-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final own = p.join(root.path, 'abyss');
      final home = p.join(root.path, 'home');
      final foreign = p.join(root.path, 'foreign');
      DataDirectory.current = DataDirectory(own);
      const sentinel = '{"hasCompletedOnboarding":false,"marker":"foreign"}';
      final foreignFiles = [
        File(p.join(home, '.claude.json')),
        File(p.join(foreign, '.claude.json')),
      ];
      for (final file in foreignFiles) {
        file
          ..createSync(recursive: true)
          ..writeAsStringSync(sentinel);
      }
      final environment = {
        'HOME': home,
        'USERPROFILE': home,
        'CLAUDE_CONFIG_DIR': foreign,
        'BAOCODE_CLAUDE_DATA_PATH': foreign,
      };
      expect(await prepareClaudeOnboarding(environment: environment), isTrue);
      expect(
        jsonDecode(
          File(p.join(own, 'claude', '.claude.json')).readAsStringSync(),
        ),
        {'hasCompletedOnboarding': true},
      );
      expect(await prepareClaudeOnboarding(environment: environment), isFalse);
      for (final file in foreignFiles) {
        expect(file.readAsStringSync(), sentinel);
      }
      expect(Directory(p.join(own, 'claude')).listSync(), hasLength(1));
    },
  );

  test('Abyss uses only its own data, pointer and native identities', () {
    expect(AppEdition.isAbyss, isTrue);
    expect(AppEdition.name, 'Abyss');
    expect(AppEdition.dataFolder, 'abyss');
    expect(AppEdition.environmentVariable, 'ABYSS_DATA_DIR');
    expect(AppEdition.pointerFolder, '.abyss');
    expect(AppEdition.windowsRegistryRoot, r'Software\Abyss');
    expect(AppEdition.windowsContextMenu, 'Abyss');
    expect(AppEdition.urlScheme, 'abyss');
    expect(AppEdition.nativeCliFlag, '--abyss-cli');
    expect(AppEdition.nativeAgentFlag, '--abyss-agent');
    expect(AppEdition.nativeLinkFlag, '--abyss-link');
    expect(CodeArgs.windowsRequestFlag, '--abyss-cli');
    expect(CodeArgs.windowsAgentFlag, '--abyss-agent');
    expect(CodeArgs.windowsLinkFlag, '--abyss-link');
    expect(CodeArgs.requestFileSuffix, '.abyss-cli');
    expect(AppEdition.hasUpdateFeed, isFalse);
    expect(AppEdition.hasBrowserExtension, Platform.isWindows);
    expect(AppEdition.browserHost, 'dev.abyss.browser');
    expect(AppEdition.browserExtensionId, 'kecjiojfloffimkeghgongilhienkdlh');
  });

  test('BaoCode environment and pointer cannot redirect Abyss', () {
    final home = Directory.systemTemp
        .createTempSync('abyss-edition-pointer-test-')
        .path;
    addTearDown(() => Directory(home).deleteSync(recursive: true));
    File(p.join(home, '.baocode', 'config-dir.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"dataDir":"${home.replaceAll(r'\', r'\\')}\\foreign"}',
      );
    Directory(p.join(home, 'foreign')).createSync();
    Directory(p.join(home, 'own')).createSync();

    final environment = <String, String>{
      'APPDATA': p.join(home, 'Roaming'),
      'USERPROFILE': home,
      'HOME': home,
      'BAOCODE_DATA_DIR': p.join(home, 'foreign'),
      'ABYSS_DATA_DIR': p.join(home, 'own'),
    };
    final own = resolveDataDirectory(environment: environment, home: home);
    expect(own.path, p.join(home, 'own'));
    expect(own.pointerFile, p.join(home, '.abyss', 'config-dir.json'));
    expect(own.source, DataDirectorySource.environment);

    environment.remove('ABYSS_DATA_DIR');
    final independent = resolveDataDirectory(
      environment: environment,
      home: home,
    );
    expect(independent.path, p.join(home, 'Roaming', 'abyss'));
    expect(independent.pointerFile, p.join(home, '.abyss', 'config-dir.json'));
    expect(independent.path, isNot(contains('baocode')));
  });

  test(
    'Abyss CLI launch and catalog share an independent config root',
    () async {
      final root = Directory.systemTemp.createTempSync('abyss-cli-isolation-');
      addTearDown(() => root.deleteSync(recursive: true));
      addTearDown(() => ClaudeEnvironment.use(null));
      final previousDataDirectory = DataDirectory.current;
      addTearDown(() => DataDirectory.current = previousDataDirectory);
      DataDirectory.current = DataDirectory(root.path);
      final environment = <String, String>{
        'HOME': p.join(root.path, 'home'),
        'USERPROFILE': p.join(root.path, 'home'),
        'BAOCODE_CLAUDE_DATA_PATH': p.join(root.path, 'home', '.claude'),
        'CLAUDE_CONFIG_DIR': p.join(root.path, 'home', '.claude'),
      };
      ClaudeEnvironment.use(environment);
      final config = p.join(root.path, 'claude');
      expect(await ClaudeEnvironment.configDir(), config);
      expect(config, isNot(contains('.claude')));
      expect(
        LocalClaudeIdentity.runtimeDir(root.path),
        p.join(root.path, 'claude-runtime'),
      );
      final state = ClaudeEnvironment.stateDirectory(environment);
      expect(state['CLAUDE_CONFIG_DIR'], config);
      expect(state['ABYSS_CLAUDE_DATA_PATH'], config);
      expect(state.containsKey('BAOCODE_CLAUDE_DATA_PATH'), isFalse);

      final cwd = p.join(root.path, 'project');
      Directory(cwd).createSync();
      final session =
          File(p.join(config, 'projects', '-project', 'session.jsonl'))
            ..createSync(recursive: true)
            ..writeAsStringSync(
              '${jsonEncode({
                'type': 'user',
                'uuid': 'aaaaaaaa-1111-4111-8111-111111111111',
                'cwd': cwd,
                'message': {'role': 'user', 'content': 'Abyss own session'},
              })}\n',
            );
      final projects = await const ClaudeStorage().projects();
      expect(
        p.normalize(projects.single.sessions.single.path!),
        p.normalize(session.path),
      );
    },
  );
}
