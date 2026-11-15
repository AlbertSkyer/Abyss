import 'dart:convert';
import 'dart:io';

import 'package:baocode/kernel/claude_code/claude_edition.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/claude_code/claude_storage_io.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/window/code_args.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
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
    expect(AppEdition.hasBrowserExtension, isFalse);
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
