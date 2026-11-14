// Auditor — tests 4, 5 y 6 a nivel controlador y enlaces (fake_async).
//   4: al soltar sale dir = 0.
//   5: pérdida de conexión / segundo plano → STOP.
//   6: con toolsEnabled=false es IMPOSIBLE que salga cutter/trimmer = 1.

import 'dart:math' as math;
import 'dart:ui' show AppLifecycleState;

import 'package:cortadora_e7/app/session_controller.dart';
import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/ble_robot_link.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:cortadora_e7/core/simulated_robot_link.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_helpers.dart';

const off = AppConfig(toolsEnabled: false);
const on = AppConfig(toolsEnabled: true);
const tick = Duration(milliseconds: 100);

void expectSafeStop(ControlCommand c, {String? reason}) {
  expect((c.state, c.dir, c.speed, c.cutter, c.trimmer),
      (RobotState.stop, Direction.none, 0, 0, 0),
      reason: reason);
}

(RecordingLink, SessionController) connected(FakeAsync async,
    {AppConfig config = off}) {
  final link = RecordingLink(clock: () => async.elapsed);
  final c = SessionController(link: link, config: config);
  link.setStatus(LinkStatus.connected);
  async.flushMicrotasks();
  return (link, c);
}

void main() {
  group('A4 soltar → dir 0', () {
    for (final d in [
      Direction.forward,
      Direction.backward,
      Direction.left,
      Direction.right,
    ]) {
      test('mantener ${d.name} 1 s y soltar: envío inmediato con dir 0 y todos los siguientes en 0',
          () {
        fakeAsync((async) {
          final (link, c) = connected(async);
          c.requestState(RobotState.manual);
          c.pressDirection(d);
          async.elapse(const Duration(seconds: 1));
          expect(link.sent.last.dir, d);
          final n = link.sent.length;
          final tRelease = async.elapsed;
          c.releaseDirection();
          expect(link.sent.length, n + 1, reason: 'envío inmediato');
          expect(link.sentAt.last, tRelease);
          expect(link.sent.last.dir, Direction.none);
          async.elapse(const Duration(seconds: 2));
          expect(link.sent.skip(n).map((e) => e.dir), everyElement(Direction.none));
          c.dispose();
        });
      });
    }

    test('pulso: mantener apretado NO extiende el giro (un solo pulseTurn = 300 ms)', () {
      fakeAsync((async) {
        final (link, c) = connected(async);
        c.requestState(RobotState.manual);
        c.setTurnMode(TurnMode.pulse);
        final t0 = async.elapsed;
        c.pulseTurn(Direction.left);
        async.elapse(const Duration(seconds: 2)); // "dedo apoyado" 2 s
        final withLeft = [
          for (var i = 0; i < link.sent.length; i++)
            if (link.sent[i].dir == Direction.left) link.sentAt[i] - t0
        ];
        expect(withLeft, isNotEmpty);
        // Empate de timers en t = 300 ms: el tick del heartbeat (creado antes)
        // corre antes que el fin del pulso y sale un último "izquierda"; en el
        // MISMO instante el fin del pulso manda dir 0. Ningún giro después.
        expect(withLeft.last, lessThanOrEqualTo(kTurnPulseDuration),
            reason: 'ningún envío con giro después del pulso');
        final firstNone = [
          for (var i = 0; i < link.sent.length; i++)
            if (link.sent[i].dir == Direction.none && link.sentAt[i] - t0 > Duration.zero)
              link.sentAt[i] - t0
        ].first;
        expect(firstNone, kTurnPulseDuration, reason: 'dir 0 sale justo al terminar el pulso');
        expect(link.sent.last.dir, Direction.none);
        c.dispose();
      });
    });

    test('STOP durante un pulso cancela el pulso (no reaparece el giro)', () {
      fakeAsync((async) {
        final (link, c) = connected(async);
        c.requestState(RobotState.manual);
        c.pulseTurn(Direction.right);
        c.stop();
        c.requestState(RobotState.manual);
        final n = link.sent.length;
        async.elapse(const Duration(seconds: 1));
        expect(link.sent.skip(n).map((e) => e.dir), everyElement(Direction.none));
        c.dispose();
      });
    });
  });

  group('A5 pérdida de conexión / segundo plano → STOP', () {
    test('SimulatedRobotLink real: simulateLinkLoss → controlador en STOP, sin heartbeat; '
        'al reconectar el PRIMER comando es STOP', () {
      fakeAsync((async) {
        final link = SimulatedRobotLink(on);
        final c = SessionController(link: link, config: on);
        c.connect();
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        c.requestState(RobotState.manual);
        c.setSpeed(90);
        c.setCutter(true);
        c.setTrimmer(true);
        c.pressDirection(Direction.forward);
        async.elapse(const Duration(milliseconds: 300));
        expect(link.lastReceivedCommand?.cutter, 1);

        link.simulateLinkLoss();
        async.flushMicrotasks();
        expect(c.isConnected, isFalse);
        expect(c.state, RobotState.stop);
        expect(c.dir, Direction.none);
        expect(c.cutter, isFalse);
        expect(c.trimmer, isFalse);
        expect(c.heartbeatActive, isFalse);
        // El "ESP" deja de ver dir/herramientas al instante (sin conexión).
        final pub = link.espPublishedCommand!;
        expect((pub.dir, pub.cutter, pub.trimmer), (Direction.none, 0, 0));

        final before = link.receivedCommandCount;
        async.elapse(const Duration(seconds: 2));
        expect(link.receivedCommandCount, before, reason: 'no envía sin enlace');

        c.connect();
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        async.elapse(tick);
        final after = link.receivedCommands.skip(
            link.receivedCommands.length - (link.receivedCommandCount - before));
        expect(after, isNotEmpty);
        expectSafeStop(after.first, reason: 'primer comando tras reconectar');
        after.forEach(expectSafeStop);
        c.disconnect();
        async.elapse(tick);
        c.dispose();
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('ventana entre la caída y el aviso asíncrono: no sale nada que no sea STOP', () {
      fakeAsync((async) {
        final (link, c) = connected(async, config: on);
        c.requestState(RobotState.manual);
        c.setCutter(true);
        c.pressDirection(Direction.forward);
        async.elapse(tick);
        // Caída: el estado del enlace cambia YA, el controlador se entera en
        // una microtarea. En el medio, el usuario aprieta cosas.
        link.setStatus(LinkStatus.disconnected);
        final n = link.sent.length;
        c.pressDirection(Direction.backward);
        c.releaseDirection();
        c.stop();
        async.flushMicrotasks();
        expect(link.sent.length, n, reason: 'el enlace caído no transmite');
        expect(c.state, RobotState.stop);
        c.dispose();
      });
    });

    for (final lc in AppLifecycleState.values.where((s) => s != AppLifecycleState.resumed)) {
      test('${lc.name}: STOP inmediato con herramientas y dirección pedidas', () {
        fakeAsync((async) {
          final (link, c) = connected(async, config: on);
          c.requestState(RobotState.manual);
          c.setCutter(true);
          c.setTrimmer(true);
          c.pressDirection(Direction.forward);
          async.elapse(const Duration(milliseconds: 50));
          final n = link.sent.length;
          final t = async.elapsed;
          c.handleLifecycleState(lc);
          expect(link.sent.length, n + 1);
          expect(link.sentAt.last, t, reason: 'sin esperar al tick');
          expectSafeStop(link.sent.last);
          // en segundo plano el heartbeat sigue mandando STOP (no MANUAL)
          async.elapse(const Duration(seconds: 3));
          link.sent.skip(n).forEach(expectSafeStop);
          c.handleLifecycleState(AppLifecycleState.resumed);
          async.elapse(const Duration(seconds: 1));
          link.sent.skip(n).forEach(expectSafeStop);
          c.dispose();
        });
      });
    }
  });

  group('A6 TOOLS_ENABLED=false: imposible mandar cutter/trimmer = 1', () {
    test('la compilación de test (sin --dart-define) tiene toolsEnabled = false', () {
      expect(AppConfig.fromEnvironment.toolsEnabled, isFalse);
      expect(const bool.fromEnvironment('TOOLS_ENABLED'), isFalse);
    });

    test('controlador: 20 000 acciones aleatorias (semilla fija) → nunca sale un 1', () {
      fakeAsync((async) {
        final (link, c) = connected(async);
        final rnd = math.Random(20261113);
        for (var i = 0; i < 20000; i++) {
          switch (rnd.nextInt(14)) {
            case 0:
              c.requestState(RobotState.values[rnd.nextInt(4)]);
            case 1:
              c.pressDirection(Direction.values[rnd.nextInt(5)]);
            case 2:
              c.releaseDirection();
            case 3:
              c.pulseTurn(rnd.nextBool() ? Direction.left : Direction.right);
            case 4:
              c.setSpeed(rnd.nextInt(101));
            case 5:
            case 6:
              c.setCutter(true);
            case 7:
            case 8:
              c.setTrimmer(true);
            case 9:
              c.stop();
            case 10:
              c.setTurnMode(TurnMode.values[rnd.nextInt(2)]);
            case 11:
              c.handleLifecycleState(
                  AppLifecycleState.values[rnd.nextInt(AppLifecycleState.values.length)]);
            case 12:
              link.setStatus(LinkStatus.disconnected);
              async.flushMicrotasks();
              link.setStatus(LinkStatus.connected);
            case 13:
              async.elapse(Duration(milliseconds: rnd.nextInt(250)));
          }
          expect(c.cutter, isFalse);
          expect(c.trimmer, isFalse);
        }
        async.elapse(const Duration(seconds: 1));
        expect(link.sent.length, greaterThan(1000));
        expect(link.sent.where((e) => e.cutter != 0 || e.trimmer != 0), isEmpty);
        for (final l in link.lines) {
          expect(l, contains('"cutter":0,"trimmer":0'));
        }
        c.dispose();
      });
    });

    test('SimulatedRobotLink(toolsEnabled=false): un comando con 1/1 llega al "ESP" en 0/0',
        () {
      fakeAsync((async) {
        final link = SimulatedRobotLink(off, connectDelay: Duration.zero);
        link.connect();
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        for (var s = 0; s < 4; s++) {
          for (var d = 0; d < 5; d++) {
            link.sendCommand(ControlCommand(
                state: RobotState.fromCode(s),
                dir: Direction.fromCode(d),
                speed: 100,
                cutter: 1,
                trimmer: 1,
                seq: s * 10 + d));
            async.flushMicrotasks();
            expect(link.lastTransmittedLine, contains('"cutter":0,"trimmer":0'));
            expect(link.lastReceivedCommand!.cutter, 0);
            expect(link.lastReceivedCommand!.trimmer, 0);
          }
        }
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('controlador con config ON pero enlace con config OFF: el enlace igual filtra '
        '(defensa en profundidad)', () {
      fakeAsync((async) {
        final link = SimulatedRobotLink(off, connectDelay: Duration.zero);
        final c = SessionController(link: link, config: on);
        c.connect();
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        c.requestState(RobotState.manual);
        c.setCutter(true);
        c.setTrimmer(true);
        expect(c.cutter, isTrue, reason: 'el controlador sí lo pide');
        async.elapse(const Duration(seconds: 1));
        expect(link.receivedCommands.map((e) => e.cutter), everyElement(0));
        expect(link.receivedCommands.map((e) => e.trimmer), everyElement(0));
        c.disconnect();
        async.elapse(tick);
        c.dispose();
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('BleRobotLink: sin radio no se puede llevar a "connected" en un test; '
        'sendCommand desconectado no transmite ni lanza', () async {
      // LIMITACIÓN (hallazgo AUD-05): el camino de envío BLE con conexión no
      // es ejercitable sin hardware. Su política se verifica estáticamente en
      // audit_static_test.dart.
      final link = BleRobotLink(off);
      await link.sendCommand(ControlCommand(
          state: RobotState.manual,
          dir: Direction.forward,
          speed: 100,
          cutter: 1,
          trimmer: 1,
          seq: 1));
      expect(link.status, LinkStatus.disconnected);
      await link.dispose();
    });

    test('ControlCommand por sí solo PERMITE cutter=1 (la barrera está en enlace + controlador)',
        () {
      // Caracterización: el constructor no conoce TOOLS_ENABLED. Cualquier
      // RobotLink nuevo DEBE aplicar applyToolsPolicy (contrato en robot_link.dart).
      final cmd = ControlCommand(
          state: RobotState.manual,
          dir: Direction.none,
          speed: 0,
          cutter: 1,
          trimmer: 1,
          seq: 0);
      expect(cmd.cutter, 1);
      expect(cmd.applyToolsPolicy(toolsEnabled: false).cutter, 0);
      expect(cmd.applyToolsPolicy(toolsEnabled: false).trimmer, 0);
    });
  });
}
