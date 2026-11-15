// Tests del SessionController con fake_async y un RobotLink falso propio
// (ver fakes.dart: no dependen de que lib/core esté implementado).

import 'dart:ui' show AppLifecycleState;

import 'package:cortadora_e7/app/session_controller.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const tick = Duration(milliseconds: 100);

/// Arma link + controlador conectado dentro de fake_async.
(FakeRobotLink, SessionController) setUpConnected(
  FakeAsync async, {
  bool toolsEnabled = false,
  int seqStart = 0,
}) {
  final link = FakeRobotLink(clock: () => async.elapsed);
  final c = makeController(link, toolsEnabled: toolsEnabled, seqStart: seqStart);
  link.setStatus(LinkStatus.connected);
  async.flushMicrotasks();
  return (link, c);
}

void expectSafeStop(ControlCommand cmd) {
  expect(cmd.state, RobotState.stop);
  expect(cmd.dir, Direction.none);
  expect(cmd.speed, 0);
  expect(cmd.cutter, 0);
  expect(cmd.trimmer, 0);
}

void main() {
  group('heartbeat', () {
    test('envía ~10 comandos por segundo aunque no se apriete nada', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        async.elapse(const Duration(seconds: 1));
        // 1 STOP inmediato al conectar (t = 0) + 10 ticks del heartbeat.
        expect(link.sent, hasLength(11));
        expect(link.sentAt,
            [Duration.zero, for (var i = 1; i <= 10; i++) tick * i]);
        for (final cmd in link.sent) {
          expect(cmd.dir, Direction.none);
        }
        expect(c.heartbeatActive, isTrue);
        c.dispose();
      });
    });

    test('es continuo y no se duplica con cambios de UI', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        // 10 s de uso intenso de la UI intercalado con el tiempo.
        for (var i = 0; i < 100; i++) {
          switch (i % 10) {
            case 0:
              c.requestState(RobotState.manual);
            case 1:
              c.pressDirection(Direction.forward);
            case 3:
              c.releaseDirection();
            case 4:
              c.setSpeed(i % 101);
            case 5:
              c.setTurnMode(TurnMode.pulse);
            case 6:
              c.pulseTurn(Direction.left);
            case 7:
              c.setTurnMode(TurnMode.hold);
            case 8:
              c.requestState(RobotState.autoPause);
          }
          async.elapse(tick);
        }
        // Nunca hay un hueco de más de 100 ms entre envíos.
        var prev = Duration.zero;
        for (final t in link.sentAt) {
          expect(t - prev, lessThanOrEqualTo(tick));
          prev = t;
        }
        expect(async.elapsed - prev, lessThanOrEqualTo(tick));

        // Sin interacción, la tasa vuelve a ser exactamente 10/s (un solo timer).
        final before = link.sent.length;
        async.elapse(const Duration(seconds: 2));
        expect(link.sent.length - before, 20);
        c.dispose();
      });
    });

    test('seq incrementa en 1 por envío y da la vuelta en 65535', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async, seqStart: 65530);
        async.elapse(const Duration(seconds: 1));
        expect(link.sent.map((e) => e.seq).toList(),
            [65530, 65531, 65532, 65533, 65534, 65535, 0, 1, 2, 3, 4]);
        expect(c.lastSentSeq, 4);
        expect(c.sentCount, 11);
        c.dispose();
      });
    });

    test('no envía sin conexión; arranca al conectar y para al desconectar', () {
      fakeAsync((async) {
        final link = FakeRobotLink(clock: () => async.elapsed);
        final c = makeController(link);
        async.elapse(const Duration(seconds: 1));
        expect(link.sent, isEmpty);
        expect(c.heartbeatActive, isFalse);

        link.setStatus(LinkStatus.connecting);
        async.elapse(const Duration(seconds: 1));
        expect(link.sent, isEmpty);

        link.setStatus(LinkStatus.connected);
        expect(link.sent, hasLength(1)); // STOP inmediato, sin esperar el tick
        async.elapse(const Duration(milliseconds: 500));
        expect(link.sent, hasLength(6));

        link.setStatus(LinkStatus.disconnected);
        expect(c.heartbeatActive, isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(link.sent, hasLength(6));
        expect(async.pendingTimers, isEmpty);
        c.dispose();
      });
    });

    test('dispose cancela el heartbeat', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        expect(link.sent, hasLength(1)); // solo el STOP inicial
        c.dispose();
        async.elapse(const Duration(seconds: 1));
        expect(link.sent, hasLength(1));
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('dirección', () {
    test('mantener adelante → dir 1 en cada tick; soltar → dir 0 inmediato',
        () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        expect(link.sent, hasLength(1)); // STOP inicial, dir 0
        expect(link.sent.first.state, RobotState.stop);
        c.requestState(RobotState.manual);
        c.setSpeed(40);
        c.pressDirection(Direction.forward);
        async.elapse(const Duration(milliseconds: 500));
        expect(link.sent.skip(1).map((e) => e.dir),
            everyElement(Direction.forward));
        expect(link.sent.last.state, RobotState.manual);
        expect(link.sent.last.speed, 40);

        final n = link.sent.length;
        c.releaseDirection();
        // Envío inmediato al soltar, sin esperar el tick.
        expect(link.sent, hasLength(n + 1));
        expect(link.sent.last.dir, Direction.none);
        async.elapse(const Duration(milliseconds: 500));
        expect(link.sent.skip(n).map((e) => e.dir),
            everyElement(Direction.none));
        c.dispose();
      });
    });

    test('fuera de MANUAL, dir = 0 siempre', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        for (final s in [
          RobotState.stop,
          RobotState.autoRun,
          RobotState.autoPause,
        ]) {
          c.requestState(s);
          c.pressDirection(Direction.forward);
          c.pulseTurn(Direction.left);
          expect(c.dir, Direction.none);
          async.elapse(const Duration(milliseconds: 300));
        }
        expect(link.sent, isNotEmpty);
        expect(link.sent.map((e) => e.dir), everyElement(Direction.none));

        // Pasar de MANUAL (con adelante apretado) a AUTO_RUN baja dir.
        c.requestState(RobotState.manual);
        c.pressDirection(Direction.forward);
        async.elapse(tick);
        expect(link.sent.last.dir, Direction.forward);
        c.requestState(RobotState.autoRun);
        expect(link.sent.last.dir, Direction.none);
        expect(link.sent.last.state, RobotState.autoRun);
        async.elapse(const Duration(milliseconds: 500));
        expect(link.sent.last.dir, Direction.none);
        c.dispose();
      });
    });

    test('giro en modo mantener: izquierda mientras se mantiene, 0 al soltar',
        () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        c.requestState(RobotState.manual);
        expect(c.turnMode, TurnMode.hold);
        final start = link.sent.length;
        c.pressDirection(Direction.left);
        async.elapse(const Duration(seconds: 1));
        final held = link.sent.skip(start).toList();
        expect(held, hasLength(10));
        expect(held.map((e) => e.dir), everyElement(Direction.left));
        c.releaseDirection();
        expect(link.sent.last.dir, Direction.none);
        async.elapse(const Duration(milliseconds: 300));
        expect(link.sent.last.dir, Direction.none);
        c.dispose();
      });
    });

    test('giro en modo pulso: dir de giro un tiempo corto y vuelve a 0', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        c.requestState(RobotState.manual);
        c.setTurnMode(TurnMode.pulse);
        final start = link.sent.length;
        c.pulseTurn(Direction.right);
        expect(c.dir, Direction.right);
        async.elapse(kTurnPulseDuration - const Duration(milliseconds: 1));
        expect(c.dir, Direction.right);
        final during = link.sent.skip(start).toList();
        expect(during, isNotEmpty);
        expect(during.map((e) => e.dir), everyElement(Direction.right));

        async.elapse(const Duration(milliseconds: 1));
        expect(c.dir, Direction.none);
        expect(link.sent.last.dir, Direction.none);
        final afterPulse = link.sent.length;
        async.elapse(const Duration(seconds: 1));
        expect(link.sent.skip(afterPulse).map((e) => e.dir),
            everyElement(Direction.none));
        c.dispose();
      });
    });

    test('cambiar el modo de giro no deja un giro colgado', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        c.requestState(RobotState.manual);
        c.pressDirection(Direction.left);
        c.setTurnMode(TurnMode.pulse);
        expect(c.dir, Direction.none);
        expect(link.sent.last.dir, Direction.none);
        c.dispose();
      });
    });

    test('el pulso solo admite izquierda/derecha', () {
      fakeAsync((async) {
        final (_, c) = setUpConnected(async);
        c.requestState(RobotState.manual);
        expect(() => c.pulseTurn(Direction.forward), throwsArgumentError);
        c.dispose();
      });
    });
  });

  group('STOP', () {
    test('STOP pone todo en seguro y envía de inmediato', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async, toolsEnabled: true);
        c.requestState(RobotState.manual);
        c.setSpeed(80);
        c.setCutter(true);
        c.setTrimmer(true);
        c.pressDirection(Direction.forward);
        async.elapse(tick);
        expect(link.sent.last.cutter, 1);
        expect(link.sent.last.trimmer, 1);

        final n = link.sent.length;
        c.stop();
        expect(link.sent, hasLength(n + 1)); // inmediato, sin esperar tick
        expectSafeStop(link.sent.last);
        expect(c.state, RobotState.stop);
        expect(c.cutter, isFalse);
        expect(c.trimmer, isFalse);

        // El heartbeat sigue mandando STOP.
        async.elapse(const Duration(seconds: 1));
        expect(link.sent, hasLength(n + 11));
        link.sent.skip(n).forEach(expectSafeStop);
        // La velocidad elegida se conserva para la próxima vez.
        expect(c.selectedSpeed, 80);
        c.dispose();
      });
    });

    test('requestState(STOP) equivale a STOP', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        c.requestState(RobotState.manual);
        c.pressDirection(Direction.backward);
        c.requestState(RobotState.stop);
        expectSafeStop(link.sent.last);
        c.dispose();
      });
    });

    test('desconectar envía STOP antes de cortar', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        c.requestState(RobotState.manual);
        c.pressDirection(Direction.forward);
        c.disconnect();
        async.flushMicrotasks();
        expectSafeStop(link.sent.last);
        expect(link.status, LinkStatus.disconnected);
        c.dispose();
      });
    });
  });

  group('pérdida de conexión', () {
    test('lo pedido pasa a STOP y al reconectar arranca en STOP', () {
      fakeAsync((async) {
        final (link, c) =
            setUpConnected(async, toolsEnabled: true);
        c.requestState(RobotState.manual);
        c.setCutter(true);
        c.pressDirection(Direction.forward);
        async.elapse(tick);
        expect(link.sent.last.state, RobotState.manual);

        link.setStatus(LinkStatus.disconnected);
        expect(c.state, RobotState.stop);
        expect(c.dir, Direction.none);
        expect(c.cutter, isFalse);
        expect(c.heartbeatActive, isFalse);

        final n = link.sent.length;
        link.setStatus(LinkStatus.connecting);
        link.setStatus(LinkStatus.connected);
        async.elapse(const Duration(seconds: 1));
        final after = link.sent.skip(n).toList();
        expect(after, hasLength(11)); // STOP inmediato + 10 ticks
        after.forEach(expectSafeStop);
        c.dispose();
      });
    });

    test('STOP inmediato al conectar: primer envío, mismo instante, completo',
        () {
      for (final tools in [false, true]) {
        fakeAsync((async) {
          final link = FakeRobotLink(clock: () => async.elapsed);
          final c = makeController(link, toolsEnabled: tools, seqStart: 65535);
          async.elapse(const Duration(milliseconds: 250));
          link.setStatus(LinkStatus.connecting);
          // Lo pedido durante "connecting" no se transmite.
          c.requestState(RobotState.manual);
          c.pressDirection(Direction.forward);
          c.setCutter(true);
          async.elapse(const Duration(milliseconds: 50));
          expect(link.sent, isEmpty);

          final t0 = async.elapsed;
          link.setStatus(LinkStatus.connected);
          // Sin flush ni elapse: el STOP ya salió, antes de cualquier tick.
          expect(link.sent, hasLength(1), reason: 'tools=$tools');
          expect(link.sentAt.single, t0);
          expectSafeStop(link.sent.single);
          expect(link.sent.single.seq, 65535);
          expect(c.state, RobotState.stop);

          // El siguiente (heartbeat) llega a +100 ms, seq contiguo, sin
          // un segundo STOP duplicado en el mismo instante.
          async.elapse(const Duration(milliseconds: 99));
          expect(link.sent, hasLength(1));
          async.elapse(const Duration(milliseconds: 1));
          expect(link.sent, hasLength(2));
          expect(link.sentAt[1] - t0, tick);
          expect(link.sent.map((e) => e.seq).toList(), [65535, 0]);
          async.elapse(const Duration(seconds: 1));
          expect(link.sent, hasLength(12));
          for (var i = 1; i < link.sentAt.length; i++) {
            expect(link.sentAt[i] - link.sentAt[i - 1], tick);
          }
          link.sent.forEach(expectSafeStop);
          c.dispose();
        });
      }
    });

    test('STOP inmediato en CADA reconexión tras una caída', () {
      for (final tools in [false, true]) {
        fakeAsync((async) {
          final link = FakeRobotLink(clock: () => async.elapsed);
          final c = makeController(link, toolsEnabled: tools);
          for (var i = 0; i < 5; i++) {
            final n = link.sent.length;
            link.setStatus(LinkStatus.connected);
            expect(link.sent.length, n + 1, reason: 'conexión $i tools=$tools');
            expect(link.sentAt.last, async.elapsed);
            expectSafeStop(link.sent.last);

            // El usuario pide de todo, y después cae el enlace.
            c.requestState(RobotState.manual);
            c.setSpeed(80);
            c.setCutter(true);
            c.setTrimmer(true);
            c.pressDirection(Direction.forward);
            async.elapse(const Duration(milliseconds: 350));
            expect(link.sent.last.state, RobotState.manual);
            link.setStatus(LinkStatus.disconnected);
            async.elapse(const Duration(milliseconds: 500));
            // Caída: no se envía nada más hasta reconectar.
            final m = link.sent.length;
            async.elapse(const Duration(seconds: 1));
            expect(link.sent.length, m);
            expect(async.pendingTimers, isEmpty);
          }
          c.dispose();
        });
      }
    });

    test('nace ya conectado: también envía STOP de inmediato', () {
      fakeAsync((async) {
        final link = FakeRobotLink(clock: () => async.elapsed);
        link.setStatus(LinkStatus.connected);
        final c = makeController(link);
        expect(link.sent, hasLength(1));
        expectSafeStop(link.sent.single);
        c.dispose();
      });
    });

    test('pasar a "connecting" también cuenta como pérdida', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        c.requestState(RobotState.manual);
        link.setStatus(LinkStatus.connecting);
        expect(c.state, RobotState.stop);
        expect(c.heartbeatActive, isFalse);
        c.dispose();
      });
    });

    test('sin conexión no se pueden pedir estados ni dirección', () {
      fakeAsync((async) {
        final link = FakeRobotLink();
        final c = makeController(link);
        c.requestState(RobotState.manual);
        c.pressDirection(Direction.forward);
        expect(c.state, RobotState.stop);
        expect(c.dir, Direction.none);
        c.dispose();
      });
    });
  });

  group('ciclo de vida', () {
    for (final lifecycle in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      test('${lifecycle.name} → STOP con envío inmediato', () {
        fakeAsync((async) {
          final (link, c) = setUpConnected(async);
          c.requestState(RobotState.manual);
          c.pressDirection(Direction.forward);
          async.elapse(tick);
          final n = link.sent.length;
          c.handleLifecycleState(lifecycle);
          expect(link.sent, hasLength(n + 1));
          expectSafeStop(link.sent.last);

          // Al volver queda en STOP (no retoma MANUAL ni adelante).
          c.handleLifecycleState(AppLifecycleState.resumed);
          expect(c.state, RobotState.stop);
          async.elapse(const Duration(milliseconds: 500));
          link.sent.skip(n).forEach(expectSafeStop);
          c.dispose();
        });
      });
    }

    test('resumed no cambia nada', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        c.requestState(RobotState.manual);
        final n = link.sent.length;
        c.handleLifecycleState(AppLifecycleState.resumed);
        expect(c.state, RobotState.manual);
        expect(link.sent, hasLength(n));
        c.dispose();
      });
    });
  });

  group('herramientas', () {
    test('toolsEnabled = false → nunca se envía cutter/trimmer = 1', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        for (final s in [
          RobotState.manual,
          RobotState.autoRun,
          RobotState.autoPause,
        ]) {
          c.requestState(s);
          c.setCutter(true);
          c.setTrimmer(true);
          expect(c.cutter, isFalse);
          expect(c.trimmer, isFalse);
          async.elapse(const Duration(milliseconds: 500));
        }
        c.stop();
        c.handleLifecycleState(AppLifecycleState.paused);
        expect(link.sent.length, greaterThan(15));
        expect(link.sent.map((e) => e.cutter), everyElement(0));
        expect(link.sent.map((e) => e.trimmer), everyElement(0));
        c.dispose();
      });
    });

    test('toolsEnabled = true → se pueden pedir, pero no en STOP', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async, toolsEnabled: true);
        c.setCutter(true); // en STOP: se ignora
        expect(c.cutter, isFalse);
        c.requestState(RobotState.manual);
        c.setCutter(true);
        c.setTrimmer(true);
        async.elapse(tick);
        expect(link.sent.last.cutter, 1);
        expect(link.sent.last.trimmer, 1);
        c.setTrimmer(false);
        async.elapse(tick);
        expect(link.sent.last.cutter, 1);
        expect(link.sent.last.trimmer, 0);
        c.dispose();
      });
    });
  });

  group('otros', () {
    test('velocidad fuera de 0–100 lanza error y no cambia', () {
      fakeAsync((async) {
        final (_, c) = setUpConnected(async);
        c.setSpeed(55);
        expect(() => c.setSpeed(101), throwsRangeError);
        expect(() => c.setSpeed(-1), throwsRangeError);
        expect(c.selectedSpeed, 55);
        c.dispose();
      });
    });

    test('guarda GPS, ACK y respuesta de área sin tocar lo pedido', () {
      fakeAsync((async) {
        final (link, c) = setUpConnected(async);
        c.requestState(RobotState.manual);
        link.emit(const GpsFix(lat: -25.3, lon: -57.6, simulated: true));
        link.emit(const CommandAck(42));
        link.emit(const PolygonRejected(reason: 'sin área'));
        expect(c.lastGps?.simulated, isTrue);
        expect(c.lastAckSeq, 42);
        expect(c.lastAreaResponse, isA<PolygonRejected>());
        expect(c.state, RobotState.manual);
        c.dispose();
      });
    });

    test('frecuencia nominal del heartbeat = 10 Hz', () {
      final c = makeController(FakeRobotLink());
      expect(c.heartbeatHz, 10);
      c.dispose();
    });
  });
}
