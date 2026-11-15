import '../util/json.dart';

/// Where a subagent's model came from, in the order of precedence.
enum SubagentModelSource {
  /// `CLAUDE_CODE_SUBAGENT_MODEL` with `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`:
  /// over everything but a call's `inherit`.
  forced,

  /// The `model` the call named, short of `inherit`.
  requested,

  /// The model its agent definition names (`.claude/agents/*.md`).
  definition,

  /// The scalar model set for subagents (`CLAUDE_CODE_SUBAGENT_MODEL`).
  subagentDefault,

  /// `inherit`: the session's own model.
  inherit,

  /// The host's subagent pool, taken in turn.
  pool,

  /// Nothing above named one: the session's own model.
  session,
}

/// What a subagent runs on, and why: the model id its calls are made with,
/// the `model` its call asked for (if any), and the pool entry it came
/// from (if it did).
class SubagentModelAssignment {
  const SubagentModelAssignment({
    required this.model,
    required this.source,
    this.requested,
    this.poolModel,
    this.poolIndex,
  });

  /// The model id the agent's requests are made with.
  final String model;

  final SubagentModelSource source;

  /// The call's `model`, as it was given, if it gave one.
  final String? requested;

  /// The pool entry this was taken from, if any.
  final String? poolModel;

  /// Its place in the pool, if it came from one.
  final int? poolIndex;

  /// What a task's or call's result says of the assignment, beside
  /// `resolvedModel` (which it keeps for compatibility): the model the
  /// agent was assigned and where it was chosen from.
  Map<String, Object?> toJson() => {
    'assignedModel': model,
    'modelSource': source.name,
    if (requested != null) 'requestedModel': requested,
    if (poolModel != null) 'poolModel': poolModel,
    if (poolIndex != null) 'poolIndex': poolIndex,
  };
}

/// Decides the model a subagent runs on: the forced or explicit model, its
/// definition's, the scalar model set for subagents, else the host's pool
/// taken in turn (round-robin), else the session's own.
///
/// The pool is an ordered list of model ids or provider model refs
/// (`@<provider>/<model>`) the host has found configured and available;
/// this class takes them one after another, wrapping around, and only when
/// no higher precedence applies. A blank entry is left out. It holds no
/// state beyond the next place in the pool, so the same calls in the same
/// order assign the same models; calls that name a model do not use up a
/// place.
class SubagentModelSelector {
  SubagentModelSelector([Iterable<String> pool = const []])
    : pool = List.unmodifiable([for (final ref in pool) ?asText(ref)]);

  /// The ids the pool is made of, blanks left out, in their order.
  final List<String> pool;

  int _next = 0;

  /// The next pool model and its place, wrapping around; null when the
  /// pool is empty.
  ({String model, int index})? take() {
    if (pool.isEmpty) return null;
    final index = _next % pool.length;
    _next++;
    return (model: pool[index], index: index);
  }

  /// The model a subagent runs on:
  ///
  /// 1. [forced]: [configuredSubagent] over [asked] and [definitionModel]
  ///    (only a call's `inherit` stands), as the CLI has it.
  /// 2. [asked], unless it is `inherit`.
  /// 3. [definitionModel], unless it is `inherit`.
  /// 4. [configuredSubagent].
  /// 5. The next model of the [pool].
  /// 6. [sessionModel].
  ///
  /// [resolve] turns an alias (`opus`, `haiku`) into the model id it stands
  /// for; the session's catalog does. A pool ref is kept as it is by it.
  SubagentModelAssignment assign({
    required bool forced,
    required String sessionModel,
    String? asked,
    String? definitionModel,
    String? configuredSubagent,
    String Function(String alias)? resolve,
  }) {
    final askedModel = asText(asked);
    final definition = asText(definitionModel);
    final subagent = asText(configuredSubagent);
    String resolveAlias(String alias) => switch (resolve) {
      final resolve? => resolve(alias),
      null => alias,
    };

    SubagentModelAssignment named(String alias, SubagentModelSource source) =>
        SubagentModelAssignment(
          model: alias == 'inherit' ? sessionModel : resolveAlias(alias),
          source: alias == 'inherit' ? SubagentModelSource.inherit : source,
          requested: askedModel,
        );

    if (forced) {
      final alias = askedModel == 'inherit' ? 'inherit' : subagent;
      if (alias == null) {
        return SubagentModelAssignment(
          model: sessionModel,
          source: SubagentModelSource.forced,
          requested: askedModel,
        );
      }
      return named(alias, SubagentModelSource.forced);
    }
    if (askedModel != null) {
      return named(askedModel, SubagentModelSource.requested);
    }
    if (definition != null) {
      return named(definition, SubagentModelSource.definition);
    }
    if (subagent != null) {
      return named(subagent, SubagentModelSource.subagentDefault);
    }
    if (take() case final taken?) {
      return SubagentModelAssignment(
        // A provider model ref is kept as it is: it is no alias.
        model: taken.model.startsWith('@')
            ? taken.model
            : resolveAlias(taken.model),
        source: SubagentModelSource.pool,
        requested: askedModel,
        poolModel: taken.model,
        poolIndex: taken.index,
      );
    }
    return SubagentModelAssignment(
      model: sessionModel,
      source: SubagentModelSource.session,
      requested: askedModel,
    );
  }
}
