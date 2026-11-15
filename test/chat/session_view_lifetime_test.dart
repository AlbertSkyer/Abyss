import 'dart:async';

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/platform/app_edition.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Kernel implements AgentKernel {
  _Kernel(this.descriptor);

  @override
  final KernelDescriptor descriptor;
  final _events = StreamController<KernelEvent>.broadcast();
  var prepares = 0;
  var releases = 0;
  var sends = 0;
  var disposed = false;

  @override
  String? get sessionId => 'view-lifetime';
  @override
  KernelHealth get health => KernelHealth.ready;
  @override
  Stream<KernelEvent> get events => _events.stream;
  @override
  Future<void> get stopped => _events.done;
  @override
  void prepare() => prepares++;
  @override
  void release() => releases++;
  @override
  void send(KernelTurn turn) => sends++;
  @override
  void answer(String requestId, InteractionAnswer answer) {}
  @override
  void cancel() {}
  @override
  void restart() {}
  @override
  void dispose() {
    disposed = true;
    _events.close();
  }
}

void main() {
  test(
    'display detach follows edition lifetime without sending a turn',
    () async {
      late _Kernel kernel;
      late final KernelDescriptor descriptor;
      descriptor = KernelDescriptor(
        id: 'view-test',
        label: 'View test',
        icon: Icons.chat,
        description: '',
        create: (_) => kernel = _Kernel(descriptor),
      );
      final session = ChatSession(
        kernel: descriptor,
        kernels: [descriptor],
        historyCount: 0,
        openReview: (_, {session}) async => null,
      );
      expect(kernel.prepares, 0);
      session.attach();
      session.detach();
      await pumpEventQueue();
      expect(kernel.releases, AppEdition.isAbyss ? 0 : 1);
      session.attach();
      session.detach();
      await pumpEventQueue();
      expect(kernel.releases, AppEdition.isAbyss ? 0 : 2);
      expect(kernel.sends, 0);
      expect(kernel.disposed, isFalse);
      session.dispose();
      expect(kernel.disposed, isTrue);
    },
  );
}
