// Auditor — tests 7 y 8 + borde de 300 ms.
//   7: el simulador responde POK/PERR bien y no confirma nada que no corresponda.
//   8: ningún campo se sale de rango (constructor, JSON generado, parsers).
//   300 ms: borde EXACTO del contrato ("más de 300 ms" corta).

import 'dart:convert';

import 'package:cortadora_e7/app/session_controller.dart';
import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/esp_protocol.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:cortadora_e7/core/simulated_robot_link.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_helpers.dart';

const off = AppConfig(toolsEnabled: false);
const on = AppConfig(toolsEnabled: true);
const square = [(0, 0), (0, 100), (100, 100), (100, 0)];

ControlCommand full(int seq) => ControlCommand(
    state: RobotState.manual,
    dir: Direction.forward,
    speed: 100,
    cutter: 1,
    trimmer: 1,
    seq: seq);

/// Simulador conectado + mensajes capturados.
(SimulatedRobotLink, List<RobotMessage>) sim(FakeAsync async, AppConfig cfg) {
  final link = SimulatedRobotLink(cfg, connectDelay: Duration.zero);
  final msgs = <RobotMessage>[];
  link.messages.listen(msgs.add);
  link.connect();
  async.elapse(Duration.zero);
  async.flushMicrotasks();
  expect(link.status, LinkStatus.connected);
  return (link, msgs);
}

void main() {
  group('borde de 300 ms del corte del ESP (contrato: "más de 300 ms")', () {
    test('comando con 300 ms EXACTOS de antigüedad: el ESP NO corta', () {
      fakeAsync((async) {
        final (link, _) = sim(async, on);
        link.sendCommand(full(1));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 300));
        final pub = link.espPublishedCommand!;
        expect((pub.dir, pub.cutter, pub.trimmer), (Direction.forward, 1, 1),
            reason: 'a 300 ms justos el contrato todavía NO corta (corta con > 300 ms)');
      });
    });

    test('comando con 301 ms de antigüedad: el ESP SÍ corta (dir, cutter, trimmer = 0)', () {
      fakeAsync((async) {
        final (link, _) = sim(async, on);
        link.sendCommand(full(1));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 301));
        final pub = link.espPublishedCommand!;
        expect((pub.dir, pub.cutter, pub.trimmer), (Direction.none, 0, 0));
        // state, speed y seq se conservan (el contrato solo fuerza dir/cutter/trimmer)
        expect((pub.state, pub.speed, pub.seq), (RobotState.manual, 100, 1));
      });
    });

    test('299 ms: no corta', () {
      fakeAsync((async) {
        final (link, _) = sim(async, on);
        link.sendCommand(full(1));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 299));
        expect(link.espPublishedCommand, full(1));
      });
    });
  });

  group('A7 simulador: POK / PERR y nada más', () {
    test('polígono válido (3 y 10 vértices, int32 extremos) → exactamente un POK con su id',
        () {
      fakeAsync((async) {
        final (link, msgs) = sim(async, off);
        msgs.clear();
        const mn = EspProtocol.int32Min, mx = EspProtocol.int32Max;
        final cases = <(int, List<(int, int)>)>[
          (1, [(0, 0), (1, 1), (2, 0)]),
          (65535, List.generate(10, (i) => (i.isEven ? mn : mx, i.isEven ? mx : mn))),
          (7, square),
        ];
        for (final (id, p) in cases) {
          msgs.clear();
          link.sendPolygon(id, p);
          async.flushMicrotasks();
          final areaMsgs =
              msgs.where((m) => m is PolygonAccepted || m is PolygonRejected).toList();
          expect(areaMsgs, hasLength(1), reason: 'id $id');
          expect((areaMsgs.single as PolygonAccepted).id, id);
          expect(link.espPolygonId, id);
          // El POLY transmitido tiene el formato FIJO del contrato.
          final line = link.lastTransmittedLine!;
          final j = jsonDecode(line) as Map<String, dynamic>;
          expect(j.keys.toList(), ['t', 'id', 'p']);
          expect(j['t'], 'POLY');
          expect((j['p'] as List).length, p.length);
          expect(line.endsWith('\n'), isTrue);
        }
      });
    });

    test('inválidos → PERR con el id y el código; nunca POK; el área vigente no cambia', () {
      fakeAsync((async) {
        final (link, msgs) = sim(async, off);
        link.sendPolygon(9, square);
        async.flushMicrotasks();
        expect(link.espPolygonId, 9);
        msgs.clear();
        final bad = <(int, List<(int, int)>, String)>[
          (10, [], PerrCode.vertexCount),
          (11, [(0, 0)], PerrCode.vertexCount),
          (12, [(0, 0), (1, 1)], PerrCode.vertexCount),
          (13, List.generate(11, (i) => (i, i)), PerrCode.vertexCount),
          (14, [(EspProtocol.int32Max + 1, 0), (0, 0), (1, 1)], PerrCode.range),
          (15, [(0, EspProtocol.int32Min - 1), (0, 0), (1, 1)], PerrCode.range),
          (0, square, PerrCode.id),
          (65536, square, PerrCode.id),
          (-1, square, PerrCode.id),
        ];
        for (final (id, p, _) in bad) {
          link.sendPolygon(id, p);
        }
        async.flushMicrotasks();
        expect(msgs.whereType<PolygonAccepted>(), isEmpty);
        final rej = msgs.whereType<PolygonRejected>().toList();
        expect(rej.map((r) => (r.id, r.reason)).toList(),
            [for (final (id, _, code) in bad) (id, code)]);
        expect(link.espPolygonId, 9, reason: 'doble buffer: el vigente no cambia');
      });
    });

    test('sin conexión: ni POK, ni PERR, ni ACK (no confirma lo que no recibió)', () {
      fakeAsync((async) {
        final link = SimulatedRobotLink(off);
        final msgs = <RobotMessage>[];
        link.messages.listen(msgs.add);
        link.sendPolygon(1, square);
        link.sendPolygon(2, const []);
        link.clearPolygon();
        link.sendCommand(full(1));
        async.elapse(const Duration(seconds: 2));
        expect(msgs, isEmpty);
        expect(link.espPolygonId, 0);
      });
    });

    test('durante una sesión real con el controlador solo llegan ACK, GPS, POK, PERR — '
        'y ninguno cambia lo pedido', () {
      fakeAsync((async) {
        final link = SimulatedRobotLink(off);
        final c = SessionController(link: link, config: off);
        final msgs = <RobotMessage>[];
        link.messages.listen(msgs.add);
        c.connect();
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
        c.requestState(RobotState.autoRun);
        link.sendPolygon(3, square); // aceptado
        link.sendPolygon(4, const [(0, 0)]); // rechazado
        async.elapse(const Duration(seconds: 3));
        expect(msgs.whereType<PolygonAccepted>().single.id, 3);
        expect(msgs.whereType<PolygonRejected>().single.id, 4);
        for (final m in msgs) {
          expect(m is CommandAck || m is GpsFix || m is PolygonAccepted || m is PolygonRejected,
              isTrue);
        }
        // Un POK no "confirma" el modo: lo pedido sigue igual, nada más.
        expect(c.state, RobotState.autoRun);
        expect(c.lastAreaResponse, isA<PolygonRejected>());
        // El GPS del simulador viene rotulado como simulado y sin calidad inventada.
        final gps = msgs.whereType<GpsFix>().toList();
        expect(gps, isNotEmpty);
        for (final g in gps) {
          expect(g.simulated, isTrue);
          expect(g.satellites, isNull);
          expect(g.hdop, isNull);
        }
        // Cada ACK corresponde a un comando realmente recibido.
        final acks = msgs.whereType<CommandAck>().map((a) => a.seq).toList();
        expect(acks.length, link.receivedCommandCount);
        c.disconnect();
        async.elapse(const Duration(milliseconds: 100));
        c.dispose();
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('PCLR: borra el vigente y NO responde nada', () {
      fakeAsync((async) {
        final (link, msgs) = sim(async, off);
        link.sendPolygon(5, square);
        async.flushMicrotasks();
        msgs.clear();
        link.clearPolygon();
        async.flushMicrotasks();
        expect(msgs.where((m) => m is! GpsFix), isEmpty);
        expect(link.espPolygonId, 0);
        expect(link.lastTransmittedLine, '{"t":"PCLR"}\n');
      });
    });
  });

  group('A8 rangos', () {
    test('constructor: bordes válidos y uno afuera de cada lado, en cada campo', () {
      ControlCommand mk({int speed = 0, int cutter = 0, int trimmer = 0, int seq = 0}) =>
          ControlCommand(
              state: RobotState.stop,
              dir: Direction.none,
              speed: speed,
              cutter: cutter,
              trimmer: trimmer,
              seq: seq);
      for (final v in [0, 100]) {
        expect(mk(speed: v).speed, v);
      }
      for (final v in [-1, 101, -2147483648, 9007199254740991]) {
        expect(() => mk(speed: v), throwsArgumentError, reason: 'speed $v');
      }
      for (final v in [-1, 2]) {
        expect(() => mk(cutter: v), throwsArgumentError);
        expect(() => mk(trimmer: v), throwsArgumentError);
      }
      for (final v in [0, 65535]) {
        expect(mk(seq: v).seq, v);
      }
      for (final v in [-1, 65536]) {
        expect(() => mk(seq: v), throwsArgumentError);
      }
      expect(() => RobotState.fromCode(4), throwsArgumentError);
      expect(() => Direction.fromCode(5), throwsArgumentError);
    });

    test('JSON generado: TODAS las combinaciones de bordes pasan el oráculo independiente', () {
      var n = 0;
      for (final s in RobotState.values) {
        for (final d in Direction.values) {
          for (final sp in [0, 1, 99, 100]) {
            for (final cu in [0, 1]) {
              for (final tr in [0, 1]) {
                for (final q in [0, 1, 65534, 65535]) {
                  final line = ControlCommand(
                          state: s, dir: d, speed: sp, cutter: cu, trimmer: tr, seq: q)
                      .toJsonLine();
                  expect(auditCommandLine(line), isNull, reason: line);
                  expect(utf8.encode(line).length, lessThanOrEqualTo(77));
                  n++;
                }
              }
            }
          }
        }
      }
      expect(n, 4 * 5 * 4 * 2 * 2 * 4);
    });

    test('JSON del controlador en una sesión larga: todo pasa el oráculo', () {
      fakeAsync((async) {
        final link = RecordingLink();
        final c = SessionController(link: link, config: on, seqCounter: SeqCounter(65000));
        link.setStatus(LinkStatus.connected);
        async.flushMicrotasks();
        for (var i = 0; i < 2000; i++) {
          c.requestState(RobotState.values[i % 4]);
          c.setSpeed(i % 101);
          c.pressDirection(Direction.values[i % 5]);
          c.setCutter(i.isEven);
          async.elapse(const Duration(milliseconds: 37));
        }
        expect(link.lines.length, greaterThan(700));
        for (final l in link.lines) {
          expect(auditCommandLine(l), isNull, reason: l);
        }
        c.dispose();
      });
    });

    test('parser de CMD: rechaza tipos y rangos inválidos (bool, double, exponente, '
        'enteros enormes, null, negativos)', () {
      const ok = '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12}';
      final bad = [
        ok.replaceFirst('"cutter":0', '"cutter":true'),
        ok.replaceFirst('"cutter":0', '"cutter":null'),
        ok.replaceFirst('"speed":50', '"speed":5e1'),
        ok.replaceFirst('"speed":50', '"speed":50.0'),
        ok.replaceFirst('"seq":12', '"seq":99999999999999999999'),
        ok.replaceFirst('"seq":12', '"seq":-1'),
        ok.replaceFirst('"state":1', '"state":-1'),
        ok.replaceFirst('"dir":1', '"dir":-1'),
        ok.replaceFirst('"t":"CMD",', ''),
        ok.replaceFirst('"CMD"', '"cmd"'),
        '$ok garbage',
        '',
        'null',
      ];
      for (final b in bad) {
        expect(() => ControlCommand.fromJsonLine(b), throwsFormatException, reason: b);
      }
    });

    test('(caracterización) parser de CMD: claves extra se aceptan y clave duplicada = gana la última',
        () {
      const dup =
          '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"cutter":1}';
      expect(ControlCommand.fromJsonLine(dup).cutter, 1);
      const extra =
          '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"x":9}';
      expect(ControlCommand.fromJsonLine(extra).seq, 12);
    });

    test('decodeEspLine: valores fuera de rango del contrato/propuesta se descartan', () {
      // POK/PERR id fuera de 1–65535 (propuesta del propio Agente 1), lat/lon
      // fuera de ±90°/±180° (1e-7°), fix negativo.
      final bad = [
        '{"t":"POK","id":0}',
        '{"t":"POK","id":-5}',
        '{"t":"POK","id":70000}',
        '{"t":"PERR","id":-1,"e":"FMT"}',
        '{"t":"GPS","fix":1,"lat":900000001,"lon":0}',
        '{"t":"GPS","fix":1,"lat":0,"lon":-1800000001}',
        '{"t":"GPS","fix":1,"lat":99999999999,"lon":0}',
        '{"t":"GPS","fix":-3,"lat":0,"lon":0}',
      ];
      final accepted = [
        for (final l in bad)
          if (EspProtocol.decodeEspLine(l) != null) l
      ];
      expect(accepted, isEmpty, reason: 'aceptadas: $accepted');
    });

    test('decodeEspLine: ACK fuera de 0–65535 se descarta (bordes)', () {
      expect((EspProtocol.decodeEspLine('{"t":"ACK","seq":0}') as CommandAck).seq, 0);
      expect((EspProtocol.decodeEspLine('{"t":"ACK","seq":65535}') as CommandAck).seq, 65535);
      expect(EspProtocol.decodeEspLine('{"t":"ACK","seq":-1}'), isNull);
      expect(EspProtocol.decodeEspLine('{"t":"ACK","seq":65536}'), isNull);
      expect(EspProtocol.decodeEspLine('{"t":"ACK","seq":1.0}'), isNull);
    });

    test('controlador: setSpeed fuera de rango lanza y no cambia; los botones ±10 no salen de 0–100',
        () {
      final link = RecordingLink();
      final c = SessionController(link: link, config: off);
      for (final v in [-1, 101, 1000]) {
        expect(() => c.setSpeed(v), throwsRangeError);
      }
      expect(c.selectedSpeed, kDefaultSpeedPercent);
      expect(c.outgoingSpeed, 0, reason: 'en STOP viaja speed 0');
      c.dispose();
    });
  });
}
