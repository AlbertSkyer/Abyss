import 'dart:async';

import 'session.dart';

/// Puts a subagent's start to the host for leave, one at a time.
///
/// A turn may have several Agent/Task calls under way at once, and the
/// host shows one question at a time: each waits for the one before it to
/// be answered, in the order the calls were made. The model each runs on
/// is chosen before its turn, so the queue does not change which pool
/// model a call takes.
class AgentApprovals {
  AgentApprovals(this.session);

  final AgentSession session;

  /// The last request made: the next waits for it.
  Future<void> _last = Future.value();

  /// Asks the host for leave to start an agent, with [request] (see
  /// AgentTool): its answer, `{behavior, model, message}`. Given up when
  /// the session is closed or the turn stopped.
  Future<Map<String, Object?>> ask(Map<String, Object?> request) =>
      _ask('can_use_agent', request);

  /// An explicit retry is a second, user-initiated decision, not an agent
  /// looping on a failure. It goes through the same serial approval queue
  /// and carries the same model choices, with a new tool-call id.
  Future<Map<String, Object?>> retry(Map<String, Object?> request) =>
      _ask('retry_agent', request);

  Future<Map<String, Object?>> _ask(
    String subtype,
    Map<String, Object?> request,
  ) async {
    final previous = _last;
    final release = Completer<void>();
    _last = release.future;
    await previous;
    try {
      return await session.hostRequest(subtype, request);
    } finally {
      release.complete();
    }
  }
}
