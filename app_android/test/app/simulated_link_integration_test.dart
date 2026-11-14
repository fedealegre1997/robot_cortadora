// Integración del SessionController con el SimulatedRobotLink real del core
// (el enlace por defecto de la APK, ver lib/app/link_factory.dart).

import 'dart:ui' show AppLifecycleState;

import 'package:cortadora_e7/app/link_factory.dart';
import 'package:cortadora_e7/app/session_controller.dart';
import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:cortadora_e7/core/simulated_robot_link.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('el enlace por defecto es el robot simulado', () {
    final link = createDefaultLink(const AppConfig(toolsEnabled: false));
    expect(link, isA<SimulatedRobotLink>());
    expect(link.isSimulated, isTrue);
  });

  test('con el simulador: 10 Hz, STOP al conectar y herramientas en 0', () {
    fakeAsync((async) {
      const config = AppConfig(toolsEnabled: false);
      final link = SimulatedRobotLink(config);
      final c = SessionController(link: link, config: config);

      c.connect();
      async.elapse(const Duration(seconds: 1));
      expect(c.linkStatus, LinkStatus.connected);
      expect(link.receivedCommandCount, greaterThan(0));
      expect(link.lastReceivedCommand?.state, RobotState.stop);

      c.requestState(RobotState.manual);
      c.setCutter(true);
      c.pressDirection(Direction.forward);
      final before = link.receivedCommandCount;
      async.elapse(const Duration(seconds: 2));
      expect(link.receivedCommandCount - before, 20);
      expect(link.lastReceivedCommand?.dir, Direction.forward);
      expect(link.receivedCommands.map((e) => e.cutter), everyElement(0));

      // El GPS del simulador llega rotulado como simulado.
      expect(c.lastGps?.simulated, isTrue);

      c.handleLifecycleState(AppLifecycleState.paused);
      async.flushMicrotasks();
      expect(link.lastReceivedCommand?.state, RobotState.stop);
      expect(link.lastReceivedCommand?.dir, Direction.none);

      c.disconnect();
      async.elapse(const Duration(milliseconds: 100));
      expect(c.linkStatus, LinkStatus.disconnected);
      expect(c.heartbeatActive, isFalse);
      c.dispose();
      link.dispose();
      async.flushMicrotasks();
    });
  });
}
