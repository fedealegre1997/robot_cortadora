import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/esp_protocol.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:cortadora_e7/core/simulated_robot_link.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const toolsOff = AppConfig(toolsEnabled: false);
const toolsOn = AppConfig(toolsEnabled: true);
const square = [(0, 0), (0, 100), (100, 100), (100, 0)];

ControlCommand fullCmd(int seq) => ControlCommand(
      state: RobotState.manual,
      dir: Direction.forward,
      speed: 100,
      cutter: 1,
      trimmer: 1,
      seq: seq,
    );

/// Crea el simulador conectado dentro de fakeAsync y junta lo que emite.
class Harness {
  final SimulatedRobotLink link;
  final List<RobotMessage> msgs = [];
  final List<LinkStatus> statuses = [];

  Harness(FakeAsync async, AppConfig config, {bool connect = true})
      : link = SimulatedRobotLink(config,
            connectDelay: const Duration(milliseconds: 50),
            gpsPeriod: const Duration(seconds: 1)) {
    link.messages.listen(msgs.add);
    link.statusStream.listen(statuses.add);
    if (connect) {
      link.connect();
      async.elapse(const Duration(milliseconds: 50));
    }
  }

  List<T> of<T>() => msgs.whereType<T>().toList();
}

void main() {
  test('es simulado y arranca desconectado', () {
    final l = SimulatedRobotLink(toolsOff);
    expect(l.isSimulated, isTrue);
    expect(l.status, LinkStatus.disconnected);
  });

  test('connect: connecting → connected tras la demora; disconnect → disconnected', () {
    fakeAsync((async) {
      final h = Harness(async, toolsOff, connect: false);
      h.link.connect();
      async.flushMicrotasks();
      expect(h.link.status, LinkStatus.connecting);
      async.elapse(const Duration(milliseconds: 49));
      expect(h.link.status, LinkStatus.connecting);
      async.elapse(const Duration(milliseconds: 1));
      expect(h.link.status, LinkStatus.connected);
      h.link.disconnect();
      async.flushMicrotasks();
      expect(h.link.status, LinkStatus.disconnected);
      expect(h.statuses,
          [LinkStatus.connecting, LinkStatus.connected, LinkStatus.disconnected]);
    });
  });

  test('disconnect durante connecting cancela la conexión', () {
    fakeAsync((async) {
      final h = Harness(async, toolsOff, connect: false);
      h.link.connect();
      async.elapse(const Duration(milliseconds: 10));
      h.link.disconnect();
      async.elapse(const Duration(seconds: 5));
      expect(h.link.status, LinkStatus.disconnected);
      expect(h.of<GpsFix>(), isEmpty);
    });
  });

  group('sendCommand', () {
    test('sin conexión no envía nada ni hay ACK', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOn, connect: false);
        h.link.sendCommand(fullCmd(1));
        async.elapse(const Duration(seconds: 1));
        expect(h.link.receivedCommandCount, 0);
        expect(h.link.lastReceivedCommand, isNull);
        expect(h.link.lastTransmittedLine, isNull);
        expect(h.of<CommandAck>(), isEmpty);
      });
    });

    test('toolsEnabled=false: el ESP nunca recibe cutter/trimmer = 1', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOff);
        for (var i = 0; i < 50; i++) {
          h.link.sendCommand(fullCmd(i));
          async.elapse(AppConfig.heartbeatPeriod);
        }
        expect(h.link.receivedCommandCount, 50);
        for (final c in h.link.receivedCommands) {
          expect(c.cutter, 0);
          expect(c.trimmer, 0);
          expect(c.speed, 100); // el resto no se toca
          expect(c.dir, Direction.forward);
        }
        expect(h.link.lastTransmittedLine, contains('"cutter":0,"trimmer":0'));
      });
    });

    test('toolsEnabled=true: los pedidos de herramientas pasan', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOn);
        h.link.sendCommand(fullCmd(3));
        async.flushMicrotasks();
        expect(h.link.lastReceivedCommand, fullCmd(3));
      });
    });

    test('ACK de recepción con el seq de cada comando', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOff);
        for (final s in [65534, 65535, 0, 1]) {
          h.link.sendCommand(ControlCommand.safeStop(s));
        }
        async.flushMicrotasks();
        expect(h.of<CommandAck>().map((a) => a.seq), [65534, 65535, 0, 1]);
      });
    });

    test('solo emite GPS y ACK: nada que confirme ejecución ni estado', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOn);
        for (var i = 0; i < 30; i++) {
          h.link.sendCommand(fullCmd(i));
          async.elapse(AppConfig.heartbeatPeriod);
        }
        for (final m in h.msgs) {
          expect(m is CommandAck || m is GpsFix, isTrue, reason: '$m');
        }
      });
    });

    test('historial acotado a historyLimit', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOff);
        final seq = SeqCounter();
        for (var i = 0; i < SimulatedRobotLink.historyLimit + 25; i++) {
          h.link.sendCommand(ControlCommand.safeStop(seq.next()));
        }
        async.flushMicrotasks();
        expect(h.link.receivedCommands.length, SimulatedRobotLink.historyLimit);
        expect(h.link.receivedCommandCount, SimulatedRobotLink.historyLimit + 25);
        expect(h.link.receivedCommands.first.seq, 25);
      });
    });
  });

  group('GPS de prueba', () {
    test('~1 Hz mientras está conectado, marcado simulated y ficticio', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOff);
        async.elapse(const Duration(seconds: 3));
        final fixes = h.of<GpsFix>();
        expect(fixes.length, 4); // uno al conectar + 3 periódicos
        for (final g in fixes) {
          expect(g.simulated, isTrue);
          expect(g.lat, SimulatedRobotLink.fakeLat);
          expect(g.lon, SimulatedRobotLink.fakeLon);
        }
      });
    });

    test('se detiene al desconectar', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOff);
        h.link.disconnect();
        async.flushMicrotasks();
        final n = h.of<GpsFix>().length;
        async.elapse(const Duration(seconds: 5));
        expect(h.of<GpsFix>().length, n);
      });
    });
  });

  group('polígono', () {
    test('válido → POK(id) y pasa a vigente', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOff);
        h.link.sendPolygon(42, square);
        async.flushMicrotasks();
        expect(h.of<PolygonAccepted>().single.id, 42);
        expect(h.link.espPolygonId, 42);
        expect(h.link.lastTransmittedLine,
            '{"t":"POLY","id":42,"p":[[0,0],[0,100],[100,100],[100,0]]}\n');
      });
    });

    test('inválido → PERR con código; el área vigente no cambia', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOff);
        h.link.sendPolygon(1, square);
        h.link.sendPolygon(2, square.sublist(0, 2)); // 2 vértices
        h.link.sendPolygon(3, List.generate(11, (i) => (i, i))); // 11 vértices
        h.link.sendPolygon(4, [(EspProtocol.int32Max + 1, 0), (0, 0), (1, 1)]);
        h.link.sendPolygon(0, square); // id inválido
        async.flushMicrotasks();
        final rej = h.of<PolygonRejected>();
        expect(rej.map((r) => (r.id, r.reason)), [
          (2, PerrCode.vertexCount),
          (3, PerrCode.vertexCount),
          (4, PerrCode.range),
          (0, PerrCode.id),
        ]);
        expect(h.link.espPolygonId, 1);
      });
    });

    test('sin conexión no envía ni responde', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOff, connect: false);
        h.link.sendPolygon(1, square);
        h.link.clearPolygon();
        async.flushMicrotasks();
        expect(h.msgs, isEmpty);
        expect(h.link.lastTransmittedLine, isNull);
      });
    });

    test('PCLR borra el área y no genera respuesta (el contrato no la define)', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOff);
        h.link.sendPolygon(5, square);
        async.flushMicrotasks();
        final before = h.msgs.where((m) => m is! GpsFix).length;
        h.link.clearPolygon();
        async.flushMicrotasks();
        expect(h.link.espPolygonId, 0);
        expect(h.link.lastTransmittedLine, '{"t":"PCLR"}\n');
        expect(h.msgs.where((m) => m is! GpsFix).length, before);
      });
    });
  });

  group('pérdida de conexión y seguridad del ESP', () {
    test('simulateLinkLoss: disconnected, deja de enviar y el ESP fuerza 0', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOn);
        h.link.sendCommand(fullCmd(1));
        async.flushMicrotasks();
        expect(h.link.espPublishedCommand, fullCmd(1));

        h.link.simulateLinkLoss();
        async.flushMicrotasks();
        expect(h.link.status, LinkStatus.disconnected);
        expect(h.statuses.last, LinkStatus.disconnected);

        h.link.sendCommand(fullCmd(2));
        async.flushMicrotasks();
        expect(h.link.receivedCommandCount, 1);
        final pub = h.link.espPublishedCommand!;
        expect(pub.dir, Direction.none);
        expect(pub.cutter, 0);
        expect(pub.trimmer, 0);
        expect(pub.seq, 1);
      });
    });

    test('borde del contrato: 300 ms exactos NO corta; más de 300 ms (301) corta', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOn);
        expect(h.link.espPublishedCommand, isNull); // nunca llegó comando
        h.link.sendCommand(fullCmd(1));
        async.elapse(const Duration(milliseconds: 300));
        expect(h.link.espPublishedCommand, fullCmd(1), reason: '300 ms justos: vigente');
        async.elapse(const Duration(milliseconds: 1));
        final pub = h.link.espPublishedCommand!;
        expect((pub.dir, pub.cutter, pub.trimmer), (Direction.none, 0, 0));
        expect((pub.state, pub.speed, pub.seq), (RobotState.manual, 100, 1));
        // a 10 Hz nunca vence
        for (var i = 2; i < 20; i++) {
          h.link.sendCommand(fullCmd(i));
          async.elapse(AppConfig.heartbeatPeriod);
          expect(h.link.espPublishedCommand, fullCmd(i));
        }
      });
    });

    test('AUD-11: la antigüedad se evalúa al consultar (reloj inyectado, µs), '
        'sin depender del timer', () {
      fakeAsync((async) {
        final link = SimulatedRobotLink(toolsOn,
            connectDelay: Duration.zero, monotonicClock: () => async.elapsed);
        link.connect();
        async.elapse(Duration.zero);
        expect(link.status, LinkStatus.connected);
        link.sendCommand(fullCmd(1));
        async.elapse(AppConfig.espCommandTimeout);
        expect(link.espPublishedCommand, fullCmd(1), reason: '300 ms justos: vigente');
        // 300 ms + 1 µs: el timer de respaldo (301 ms) todavía no disparó, pero
        // la consulta ya ve la antigüedad > 300 ms y corta.
        async.elapse(const Duration(microseconds: 1));
        expect(link.espPublishedCommand!.dir, Direction.none);
        expect(link.espPublishedCommand!.cutter, 0);
      });
    });

    test('AUD-11: el timer de respaldo es de 301 ms enteros (la VM trunca a ms)', () {
      expect(SimulatedRobotLink.espStaleTimerDelay, const Duration(milliseconds: 301));
      expect(SimulatedRobotLink.espStaleTimerDelay.inMicroseconds % 1000, 0);
    });

    test('reloj real por defecto: un comando recién recibido está vigente', () async {
      final link = SimulatedRobotLink(toolsOn, connectDelay: Duration.zero);
      await link.connect();
      await link.sendCommand(fullCmd(1));
      expect(link.espPublishedCommand, fullCmd(1));
      await link.dispose();
    });

    test('tras una pérdida y reconexión, el comando viejo ya no es vigente', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOn);
        h.link.sendCommand(fullCmd(1));
        async.flushMicrotasks();
        h.link.simulateLinkLoss();
        h.link.connect();
        async.elapse(const Duration(milliseconds: 50));
        expect(h.link.status, LinkStatus.connected);
        expect(h.link.espPublishedCommand!.dir, Direction.none);
      });
    });

  test('se puede reconectar después de una pérdida', () {
      fakeAsync((async) {
        final h = Harness(async, toolsOff);
        h.link.simulateLinkLoss();
        h.link.connect();
        async.elapse(const Duration(milliseconds: 50));
        expect(h.link.status, LinkStatus.connected);
      });
    });
  });

  test('dispose cierra los streams y deja de enviar', () {
    fakeAsync((async) {
      final h = Harness(async, toolsOff);
      var done = 0;
      h.link.messages.listen(null, onDone: () => done++);
      h.link.statusStream.listen(null, onDone: () => done++);
      h.link.dispose();
      async.flushMicrotasks();
      expect(done, 2);
      h.link.sendCommand(ControlCommand.safeStop(1));
      h.link.connect();
      async.elapse(const Duration(seconds: 2));
      expect(h.link.status, LinkStatus.disconnected);
      expect(h.link.receivedCommandCount, 0);
    });
  });
}
