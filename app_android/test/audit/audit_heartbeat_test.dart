// Auditor — tests 1 y 3: heartbeat a 10 Hz que no se detiene, y seq con
// vuelta 65535 → 0. Deterministas (fake_async). Se usa el enlace SIMULADO
// REAL del core (streams asíncronos), no el fake del Agente 2.

import 'package:cortadora_e7/app/session_controller.dart';
import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:cortadora_e7/core/simulated_robot_link.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_helpers.dart';

const off = AppConfig(toolsEnabled: false);
const tick = Duration(milliseconds: 100);

void main() {
  group('A1 heartbeat 10 Hz (fake_async)', () {
    // REGLA NUEVA (Paso 1, aprobada por el usuario): al pasar a `connected` el
    // controlador envía un STOP inmediato (t = 0) y recién después corre el
    // heartbeat. Invariantes que NO se aflojan: tick cada 100 ms exactos
    // (medido desde el primer tick, no desde el STOP), un solo heartbeat,
    // dir 0 y STOP en todos los envíos.
    test('10 minutos conectado sin tocar nada: STOP inmediato + 6000 ticks cada 100 ms exactos, dir 0',
        () {
      fakeAsync((async) {
        final link = RecordingLink(clock: () => async.elapsed);
        final c = SessionController(link: link, config: off);
        link.setStatus(LinkStatus.connected);
        async.flushMicrotasks(); // stream asíncrono, como los enlaces reales
        final t0 = async.elapsed;
        async.elapse(const Duration(minutes: 10));
        expect(link.sent.length, 6001, reason: '1 STOP inmediato + 6000 ticks');
        expect(link.sentAt.first - t0, Duration.zero, reason: 'el STOP sale en t = 0');
        for (var i = 1; i < link.sentAt.length; i++) {
          expect(link.sentAt[i] - t0, tick * i, reason: 'tick $i');
          expect(link.sentAt[i] - link.sentAt[i - 1], tick, reason: 'hueco antes del tick $i');
        }
        expect(link.sent.map((e) => e.dir), everyElement(Direction.none));
        expect(link.sent.map((e) => e.state), everyElement(RobotState.stop));
        expect(c.heartbeatActive, isTrue);
        c.dispose();
      });
    });

    test('con el SimulatedRobotLink real: conecta, 10 Hz sostenido, ESP siempre "fresco"',
        () {
      fakeAsync((async) {
        final link = SimulatedRobotLink(off);
        final c = SessionController(link: link, config: off);
        c.connect();
        async.elapse(const Duration(milliseconds: 500)); // connectDelay
        async.flushMicrotasks();
        expect(c.isConnected, isTrue);
        c.requestState(RobotState.manual);
        c.pressDirection(Direction.forward);
        final before = link.receivedCommandCount;
        // 60 s: debe recibir 600 comandos y el ESP nunca debe cortar por edad.
        for (var i = 0; i < 600; i++) {
          async.elapse(tick);
          expect(link.espPublishedCommand?.dir, Direction.forward,
              reason: 'el ESP simulado cortó en el tick $i');
        }
        expect(link.receivedCommandCount - before, 600);
        c.disconnect();
        async.elapse(tick);
        c.dispose();
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('ráfaga de acciones de UI (1000 por segundo) no crea timers extra ni frena el ritmo',
        () {
      fakeAsync((async) {
        final link = RecordingLink(clock: () => async.elapsed);
        final c = SessionController(link: link, config: off);
        link.setStatus(LinkStatus.connected);
        async.flushMicrotasks();
        c.requestState(RobotState.manual);
        final timersBefore = async.periodicTimerCount;
        expect(timersBefore, 1, reason: 'debe haber UN solo timer periódico');
        for (var ms = 0; ms < 5000; ms++) {
          switch (ms % 7) {
            case 0:
              c.pressDirection(Direction.forward);
            case 1:
              c.setSpeed(ms % 101);
            case 2:
              c.releaseDirection();
            case 3:
              c.requestState(RobotState.manual);
            case 4:
              c.setTurnMode(ms.isEven ? TurnMode.pulse : TurnMode.hold);
            case 5:
              c.setCutter(true);
          }
          async.elapse(const Duration(milliseconds: 1));
          expect(async.periodicTimerCount, 1);
        }
        // Envíos del heartbeat (los extra son envíos inmediatos de soltar/STOP):
        // entre dos envíos nunca pasan más de 100 ms.
        var prev = Duration.zero;
        for (final t in link.sentAt) {
          expect(t - prev, lessThanOrEqualTo(tick));
          prev = t;
        }
        c.dispose();
        expect(async.periodicTimerCount, 0);
      });
    });

    test('reconexión repetida (50 veces) nunca deja dos heartbeats', () {
      fakeAsync((async) {
        final link = RecordingLink(clock: () => async.elapsed);
        final c = SessionController(link: link, config: off);
        for (var i = 0; i < 50; i++) {
          link.setStatus(LinkStatus.connecting);
          link.setStatus(LinkStatus.connected);
          async.flushMicrotasks();
          expect(async.periodicTimerCount, 1);
          async.elapse(const Duration(milliseconds: 250));
          link.setStatus(LinkStatus.disconnected);
          async.flushMicrotasks();
          expect(async.periodicTimerCount, 0);
        }
        // 50 conexiones × (1 STOP inmediato + 2 ticks en 250 ms) = 150 envíos,
        // con los ticks a 100 ms exactos DESDE el primer tick de cada conexión
        // (nunca un tick extra ni un tick adelantado por el STOP).
        expect(link.sent.length, 150);
        for (var k = 0; k < 50; k++) {
          final base = link.sentAt[k * 3];
          expect(link.sentAt[k * 3 + 1] - base, tick, reason: 'conexión $k: primer tick');
          expect(link.sentAt[k * 3 + 2] - base, tick * 2, reason: 'conexión $k: segundo tick');
          expect(link.sent[k * 3].state, RobotState.stop, reason: 'conexión $k: 1.º es STOP');
        }
        c.dispose();
      });
    });
  });

  group('A3 seq', () {
    test('incrementa de a 1 y da la vuelta 65535 → 0 (comando, JSON y ACK del simulador)',
        () {
      fakeAsync((async) {
        final link = SimulatedRobotLink(off);
        final acks = <int>[];
        link.messages.listen((m) {
          if (m is CommandAck) acks.add(m.seq);
        });
        final c = SessionController(
            link: link, config: off, seqCounter: SeqCounter(65533));
        c.connect();
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 600));
        final seqs = link.receivedCommands.map((e) => e.seq).toList();
        // Regla nueva: el STOP inmediato al conectar consume el primer seq
        // (65533); después, 6 ticks en 600 ms.
        expect(seqs, [65533, 65534, 65535, 0, 1, 2, 3]);
        expect(link.receivedCommands.first.state, RobotState.stop);
        expect(acks, seqs);
        expect(link.lastTransmittedLine, contains('"seq":3}'));
        c.disconnect();
        async.elapse(tick);
        c.dispose();
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('recorre 2 vueltas completas (131072 envíos) sin saltos ni repetidos', () {
      fakeAsync((async) {
        final link = RecordingLink();
        final c = SessionController(link: link, config: off);
        link.setStatus(LinkStatus.connected);
        async.flushMicrotasks();
        async.elapse(tick * 131072);
        // 1 STOP inmediato + 131072 ticks: la secuencia 0,1,2,… no tiene saltos
        // ni repetidos a través de DOS vueltas completas (65535 → 0).
        expect(link.sent.length, 131073);
        for (var i = 0; i < link.sent.length; i++) {
          expect(link.sent[i].seq, i % 65536);
        }
        c.dispose();
      });
    });

    test('los envíos inmediatos (soltar, STOP) también consumen seq sin repetir', () {
      fakeAsync((async) {
        final link = RecordingLink();
        final c = SessionController(
            link: link, config: off, seqCounter: SeqCounter(65534));
        link.setStatus(LinkStatus.connected);
        async.flushMicrotasks();
        c.requestState(RobotState.manual);
        c.pressDirection(Direction.forward);
        c.releaseDirection(); // inmediato
        c.stop(); // inmediato
        async.elapse(tick);
        // 65534 = STOP inmediato al conectar; 65535 = releaseDirection;
        // 0 = stop(); 1 = el tick de elapse(tick). Sin saltos ni repetidos.
        expect(link.sent.map((e) => e.seq).toList(), [65534, 65535, 0, 1]);
        expect(link.sent.first.state, RobotState.stop);
        c.dispose();
      });
    });
  });
}
