import 'package:bao_remote/local.dart' as shared;
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'claude_edition.dart';

abstract final class ClaudeEnvironment {
  static String get dataPathVariable => LocalClaudeIdentity.dataPathVariable;
  static const essentialTrafficVariable =
      shared.ClaudeEnvironment.essentialTrafficVariable;
  @visibleForTesting
  // Forward the shared test seam without changing production shell discovery.
  // ignore: invalid_use_of_visible_for_testing_member
  static String? get shellOverride => shared.ClaudeEnvironment.shellOverride;
  @visibleForTesting
  static set shellOverride(String? shell) =>
      // ignore: invalid_use_of_visible_for_testing_member
      shared.ClaudeEnvironment.shellOverride = shell;
  static Future<Map<String, String>> of() => shared.ClaudeEnvironment.of();
  static void use(Map<String, String>? environment) =>
      shared.ClaudeEnvironment.use(environment);
  static Future<String> configDir() async =>
      LocalClaudeIdentity.configDir(await of());
  static Map<String, String> stateDirectory(Map<String, String> environment) =>
      LocalClaudeIdentity.stateDirectory(
        environment,
        LocalClaudeIdentity.configDir(environment),
      );
}
