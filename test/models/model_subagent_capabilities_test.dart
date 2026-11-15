import 'dart:io';

import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const alpha = ModelProvider(
    id: 'a',
    name: 'Alpha',
    models: [ProviderModel(id: 'one')],
  );

  test(
    'trims and dedupes caller-defined tags without changing the pool',
    () async {
      final providers = ModelProviders.memory(providers: const [alpha]);
      await providers.setSubagentPool(['@a/one']);
      await providers.setSubagentCapabilities(' @a/one ', [
        ' research ',
        '',
        'research',
        'long context',
      ]);

      expect(providers.subagentCapabilities('@a/one'), [
        'research',
        'long context',
      ]);
      expect(providers.subagentPool, ['@a/one']);
      expect(providers.subagentCapabilities('@missing/model'), isEmpty);
      expect(
        () => providers.subagentCapabilities('@a/one').clear(),
        throwsUnsupportedError,
      );

      await providers.setSubagentCapabilities('@other/model', ['review']);
      expect(providers.subagentPool, ['@a/one']);
      await providers.setSubagentCapabilities('@a/one', []);
      expect(providers.subagentCapabilities('@a/one'), isEmpty);
      expect(providers.subagentCapabilities('@other/model'), ['review']);
    },
  );

  test('rejects bad refs and unreasonable tag input', () async {
    final providers = ModelProviders.memory(providers: const [alpha]);
    expect(
      () => providers.setSubagentCapabilities('plain', ['research']),
      throwsArgumentError,
    );
    expect(
      () => providers.setSubagentCapabilities('@a/one', ['x' * 65]),
      throwsArgumentError,
    );
    expect(
      () => providers.setSubagentCapabilities('@a/one', [
        for (var index = 0; index < 17; index++) 'tag-$index',
      ]),
      throwsArgumentError,
    );
    expect(providers.subagentCapabilities('@a/one'), isEmpty);
  });

  test(
    'persists by ref in settings and tolerates hand-edited values',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subagent-capabilities',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final settings = UserSettings(p.join(directory.path, 'settings.json'));
      addTearDown(settings.dispose);
      await settings.load();
      final providers = ModelProviders.settings(
        settings,
        secrets: MemorySecretStore(),
      );
      await providers.setSubagentCapabilities('@a/one', [
        ' research ',
        'review',
      ]);
      await settings.update(ModelProviders.subagentCapabilitiesKey, {
        '@a/one': [' research ', 'review', 'research', 42],
        'bad-ref': ['ignored'],
        '@b/two': 'ignored',
        '@c/three': ['', null, ' kept '],
      });

      final again = UserSettings(settings.path);
      addTearDown(again.dispose);
      await again.load();
      final restored = ModelProviders.settings(
        again,
        secrets: MemorySecretStore(),
      );
      expect(restored.subagentCapabilities('@a/one'), ['research', 'review']);
      expect(restored.subagentCapabilities('bad-ref'), isEmpty);
      expect(restored.subagentCapabilities('@b/two'), isEmpty);
      expect(restored.subagentCapabilities('@c/three'), ['kept']);

      await restored.setSubagentCapabilities('@c/three', []);
      expect(again[ModelProviders.subagentCapabilitiesKey], {
        '@a/one': ['research', 'review'],
      });
      await restored.setSubagentCapabilities('@a/one', []);
      expect(again[ModelProviders.subagentCapabilitiesKey], isNull);
    },
  );
}
