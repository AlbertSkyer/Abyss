import 'package:baocode/ide/ide_menu.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/claude_code/claude_path_setting.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:baocode/settings/pages/general_page.dart';
import 'package:baocode/settings/pages/settings_dropdown.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('${AppEdition.name} local core policy', () {
    late bool cliInstalled;

    setUp(() {
      cliInstalled = false;
      ClaudeCore.cliInstalled = () => cliInstalled;
    });

    tearDown(() => ClaudeCore.cliInstalled = () => false);

    test('missing CLI and a saved built-in choice follow the edition', () {
      for (final setting in [null, 'builtin', 'cli', 'nonsense', true]) {
        expect(
          ClaudeCore.parse(setting),
          AppEdition.isAbyss || setting == 'cli'
              ? ClaudeCore.cli
              : ClaudeCore.builtin,
          reason: 'setting: $setting',
        );
      }
      expect(
        ClaudeCore.fallback,
        AppEdition.isAbyss ? ClaudeCore.cli : ClaudeCore.builtin,
      );

      cliInstalled = true;
      expect(ClaudeCore.fallback, ClaudeCore.cli);
      expect(ClaudeCore.parse(null), ClaudeCore.cli);
      expect(ClaudeCore.parse('nonsense'), ClaudeCore.cli);
      expect(
        ClaudeCore.parse('builtin'),
        AppEdition.isAbyss ? ClaudeCore.cli : ClaudeCore.builtin,
      );
    });

    testWidgets('settings show only cores the edition actually offers', (
      tester,
    ) async {
      final settings = _MemoryUserSettings({
        ClaudeCore.settingKey: ClaudeCore.builtin.name,
      });
      addTearDown(settings.dispose);
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: GeneralSettingsPage(
              settings: settings,
              claudeStatus: () async => const LocalClaudeMissing(),
            ),
          ),
        ),
      );
      await tester.pump();

      final dropdowns = tester
          .widgetList<SettingsDropdown>(find.byType(SettingsDropdown))
          .toList();
      final core = dropdowns.singleWhere(
        (dropdown) => dropdown.entries().any(
          (entry) => entry is IdeMenuAction && entry.label == 'Claude Code CLI',
        ),
      );
      final entries = core.entries().whereType<IdeMenuAction>().toList();
      expect(core.current, AppEdition.isAbyss ? 'Claude Code CLI' : 'Built-in');
      expect(
        entries.map((entry) => entry.label),
        AppEdition.isAbyss
            ? ['Claude Code CLI']
            : ['Claude Code CLI', 'Built-in'],
      );
      expect(
        entries.singleWhere((entry) => entry.isChecked).label,
        core.current,
      );

      final description = AppEdition.isAbyss
          ? 'Abyss local sessions always use the external Claude Code CLI'
          : 'Built-in: comes with Abyss';
      expect(find.textContaining(description), findsOneWidget);
      expect(find.textContaining('None found yet'), findsOneWidget);

      // Choosing the sole Abyss entry really writes `cli`; it is not a
      // built-in selection merely relabelled as the CLI.
      for (final entry in entries) {
        entry.onSelected?.call();
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      expect(
        settings[ClaudeCore.settingKey],
        AppEdition.isAbyss ? 'cli' : 'builtin',
      );
    });
  });
}

class _MemoryUserSettings extends UserSettings {
  _MemoryUserSettings(this.values) : super('memory-settings.json');

  @override
  Map<String, Object?> values;

  @override
  Object? operator [](String key) => values[key];

  @override
  Future<void> update(String key, Object? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    notifyListeners();
  }
}
