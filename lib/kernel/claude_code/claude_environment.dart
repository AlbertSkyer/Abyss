import 'package:bao_remote/local.dart' as shared;

import 'claude_edition.dart';

abstract final class ClaudeEnvironment {
  static String get dataPathVariable => LocalClaudeIdentity.dataPathVariable;
  static const essentialTrafficVariable =
      shared.ClaudeEnvironment.essentialTrafficVariable;
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
