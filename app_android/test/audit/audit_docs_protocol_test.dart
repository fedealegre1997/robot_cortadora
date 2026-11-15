// Auditor — revisión de DOCUMENTOS: cada ejemplo de docs/protocolo_ble_app_esp.md
// se genera/decodifica con el código REAL de lib/core (ControlCommand,
// EspProtocol, SimulatedRobotLink, BleConfig) y se comparan tamaños, rangos y
// constantes. Un ejemplo que el código real rechaza, o un tamaño mal
// calculado, queda ROJO (es hallazgo; no se afloja el test).
//
// Los documentos se leen con rutas relativas a app_android/ (flutter test corre
// desde ahí). Solo lectura.

import 'dart:convert';
import 'dart:io';

import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/ble_robot_link.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/esp_protocol.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:cortadora_e7/core/simulated_robot_link.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

String doc(String name) => File('../docs/$name').readAsStringSync();
int bytes(String s) => utf8.encode(s).length;

const square = [(0, 0), (0, 1000), (1000, 1000), (1000, 0)];

void main() {
  final proto = doc('protocolo_ble_app_esp.md');
  final entrega = doc('entrega_companero_firmware.md');
  final e7 = doc('e7_app_android.md');

  group('UUID y constantes', () {
    test('los tres UUID son EXACTAMENTE los decididos, en la fila correcta, y no hay otros', () {
      const svc = 'd4d28957-613f-4007-8a1d-1deab4080779';
      const cmd = '5a38f5bc-797e-4e23-97e6-efc129c921d5';
      const ntf = '9d803301-5ae6-4c4a-ab5a-8f783c540282';
      final re = RegExp(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}');
      for (final d in [proto, entrega, e7]) {
        for (final m in re.allMatches(d)) {
          expect([svc, cmd, ntf], contains(m.group(0)!.toLowerCase()));
        }
      }
      expect(RegExp(r'\| Servicio \| `' + svc + r'` \|').hasMatch(proto), isTrue);
      expect(RegExp(r'\| Característica de comando \(app → ESP\) \| `' + cmd + r'` \|').hasMatch(proto), isTrue);
      expect(RegExp(r'\| Característica de notificaciones \(ESP → app\) \| `' + ntf + r'` \|').hasMatch(proto), isTrue);
    });

    test('constantes del documento = constantes del código', () {
      expect(AppConfig.heartbeatPeriod, const Duration(milliseconds: 100));
      expect(AppConfig.espCommandTimeout, const Duration(milliseconds: 300));
      expect(EspProtocol.maxLineLength, 512);
      expect(BleConfig.requestedMtu, 517);
      expect((EspProtocol.minVertices, EspProtocol.maxVertices), (3, 10));
      expect((EspProtocol.polygonIdMin, EspProtocol.polygonIdMax), (1, 65535));
      expect(PerrCode.all.toSet(), {'FMT', 'NVERT', 'RANGE', 'ID', 'LEN'});
      for (final c in PerrCode.all) {
        expect(proto, contains('`$c`'), reason: 'código PERR $c en el doc');
      }
      expect(ControlCommand.jsonType, 'CMD');
    });

    test('el doc dice que los UUID siguen en null en BleConfig: es verdad', () {
      expect(proto, contains('siguen en `null` (PENDIENTE)'));
      expect(BleConfig.serviceUuid, isNull);
      expect(BleConfig.rxCharacteristicUuid, isNull);
      expect(BleConfig.txCharacteristicUuid, isNull);
      expect(BleConfig.isConfigured, isFalse);
    });
  });

  group('300 ms escrito igual en todos lados', () {
    test('ningún documento dice que 300 ms o "desde 300" corta; los que lo precisan dicen más de 300 / 300 vale', () {
      final bad = RegExp(r'(≥|>=|desde|a partir de|al menos|o más)\s*300\s*ms|300\s*ms\s*o\s*más', caseSensitive: false);
      for (final e in {'protocolo': proto, 'entrega': entrega, 'e7': e7}.entries) {
        for (final (i, line) in e.value.split('\n').indexed) {
          expect(bad.hasMatch(line), isFalse, reason: '${e.key}:${i + 1}: $line');
        }
      }
      // Cada documento nuevo afirma el borde (300 vale / 301 corta).
      for (final d in [proto, entrega]) {
        expect(d, contains('300 vale'));
        expect(d, contains('301'));
      }
      expect(e7, contains('más de 300 ms'));
    });
  });

  group('tamaños en bytes (con el \\n) — ejemplos del documento vs código', () {
    ControlCommand cmd(int s, int d, int v, int c, int t, int q) => ControlCommand(
        state: RobotState.fromCode(s), dir: Direction.fromCode(d), speed: v, cutter: c, trimmer: t, seq: q);

    test('CMD: 71 (mínimo), 73 (ejemplo), 77 (peor caso)', () {
      expect(bytes(cmd(0, 0, 0, 0, 0, 0).toJsonLine()), 71);
      expect(bytes(cmd(1, 1, 50, 0, 0, 12).toJsonLine()), 73);
      expect(bytes(cmd(3, 4, 100, 1, 1, 65535).toJsonLine()), 77);
      // y es de verdad el máximo
      var max = 0;
      for (final s in [0, 3]) {
        for (final d in [0, 4]) {
          for (final v in [0, 9, 10, 100]) {
            for (final q in [0, 9, 10, 99, 100, 9999, 10000, 65535]) {
              max = [max, bytes(cmd(s, d, v, 1, 1, q).toJsonLine())].reduce((a, b) => a > b ? a : b);
            }
          }
        }
      }
      expect(max, 77);
    });

    test('ACK 21 (ejemplo) / 24 (peor); POK 19 / 23; PCLR 13', () {
      expect(bytes(EspProtocol.encodeAck(12)), 21);
      expect(bytes(EspProtocol.encodeAck(65535)), 24);
      expect(bytes(EspProtocol.encodePok(7)), 19);
      expect(bytes(EspProtocol.encodePok(65535)), 23);
      expect(bytes(EspProtocol.encodeClear()), 13);
    });

    test('GPS 40 (sin fix) / 73 (ejemplo) / 77 (peor caso)', () {
      expect(bytes(EspProtocol.encodeGps(fix: 0)), 40);
      expect(bytes(EspProtocol.encodeGps(fix: 1, latE7: -123456789, lonE7: 456789012, sats: 9, hdop: 0.8)), 73);
      expect(bytes(EspProtocol.encodeGps(fix: 2, latE7: -900000000, lonE7: -1800000000, sats: 12, hdop: 99.9)), 77);
    });

    test('POLY 62 (4 vértices, id 7) / 290 (peor int32) / 280 (geográfico extremo)', () {
      expect(bytes(EspProtocol.encodePolygon(7, square)), 62);
      const mn = EspProtocol.int32Min;
      expect(bytes(EspProtocol.encodePolygon(65535, List.filled(10, (mn, mn)))), 290);
      expect(bytes(EspProtocol.encodePolygon(65535, List.filled(10, (-900000000, -1800000000)))), 280);
    });

    test('PERR 23 (sin id) / 32 (ejemplo NVERT id 5) / 42 (peor caso)', () {
      expect(bytes(EspProtocol.encodePerr(code: 'FMT')), 23);
      expect(bytes(EspProtocol.encodePerr(id: 5, code: 'NVERT')), 32);
      var max = 0;
      for (final id in [null, 0, 65535, -2147483648, 2147483647]) {
        for (final c in PerrCode.all) {
          max = [max, bytes(EspProtocol.encodePerr(id: id, code: c))].reduce((a, b) => a > b ? a : b);
        }
      }
      expect(max, 42);
    });

    test('AREA (5.8) y ESTOP (5.9): tamaños CALCULADOS con jsonEncode (sin pegar constantes) y presentes en el doc', () {
      // No existe encoder en lib/core (la app solo ignora AREA/ESTOP): se arma
      // la línea con el mismo codec que usan POK/ACK/GPS.
      String area(int id) => '${jsonEncode({'t': 'AREA', 'id': id})}\n';
      String estop(String why) => '${jsonEncode({'t': 'ESTOP', 'why': why})}\n';
      final sizes = [area(0), area(7), area(65535)].map(bytes).toList();
      // Derivación independiente: POK ("POK" = 3 letras) mide 19 B con id de 1 dígito;
      // "AREA" tiene 1 letra más que "POK"... y la clave del campo de tipo es la misma.
      final pokOneDigit = bytes(EspProtocol.encodePok(7));
      expect(sizes[1], pokOneDigit + ('AREA'.length - 'POK'.length));
      expect(sizes[0], sizes[1], reason: 'id 0 y id 7 tienen un dígito');
      expect(sizes[2], sizes[1] + 4, reason: 'id 65535 = 4 dígitos más');
      // y lo que dice el documento coincide con lo calculado
      expect(proto, contains('Tamaño: ${sizes[0]} B (`{"t":"AREA","id":0}` + `\\n`), ${sizes[1]} B'));
      expect(proto, contains('**${sizes[2]} B** (peor caso, `id` 65535)'));
      expect(proto, contains('`{"t":"AREA","id":0}\\n` (${sizes[0]} B)'));
      expect(proto, contains('`{"t":"AREA","id":7}\\n` (${sizes[1]} B)'));
      // ESTOP
      expect(estop('T'), '{"t":"ESTOP","why":"T"}\n');
      expect(bytes(estop('T')), 24, reason: 'el doc dice 24 B');
      expect(proto, contains('Tamaño: **${bytes(estop('T'))} B** (con `\\n`)'));
      expect(entrega, contains('`{"t":"ESTOP","why":"T"}`, ${bytes(estop('T'))} B'));
      expect(entrega, contains('${sizes[0]}–${sizes[2]} B'));
      // la app hoy ignora ambos (tipo desconocido), como dice el doc
      for (final l in [area(0), area(65535), estop('T')]) {
        expect(EspProtocol.decodeEspLine(l), isNull, reason: l);
      }
      // ESTOP cabe en cualquier MTU ≥ 27
      expect(bytes(estop('T')) + 3, lessThanOrEqualTo(27));
    });
  });
  group('CMD (6.1): cada fila contra ControlCommand.fromJsonLine', () {
    const base = '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12}';
    test('CMD-1/2/3/4/18 válidos', () {
      final c1 = ControlCommand.fromJsonLine('$base\n');
      expect((c1.state.code, c1.dir.code, c1.speed, c1.cutter, c1.trimmer, c1.seq), (1, 1, 50, 0, 0, 12));
      expect(c1.toJsonLine(), '$base\n');
      expect(ControlCommand.fromJsonLine('{"t":"CMD","state":0,"dir":0,"speed":0,"cutter":0,"trimmer":0,"seq":0}').seq, 0);
      final c3 = ControlCommand.fromJsonLine('{"t":"CMD","state":3,"dir":4,"speed":100,"cutter":1,"trimmer":1,"seq":65535}');
      expect((c3.state, c3.dir, c3.speed, c3.cutter, c3.trimmer, c3.seq),
          (RobotState.autoPause, Direction.right, 100, 1, 1, 65535));
      expect(ControlCommand.fromJsonLine(base.replaceFirst('"seq":12', '"seq":0')).seq, 0);
      expect(ControlCommand.fromJsonLine('$base\r\n').seq, 12, reason: 'CMD-18: \\r antes del \\n');
    });

    test('CMD-6…14, 16, 17, 19: el parser de referencia los rechaza', () {
      final invalid = {
        'CMD-6': base.replaceFirst('"state":1', '"state":4'),
        'CMD-7': base.replaceFirst('"dir":1', '"dir":5'),
        'CMD-8': base.replaceFirst('"speed":50', '"speed":101'),
        'CMD-9': base.replaceFirst('"speed":50', '"speed":-1'),
        'CMD-10': base.replaceFirst('"cutter":0', '"cutter":2'),
        'CMD-11': base.replaceFirst('"trimmer":0', '"trimmer":-1'),
        'CMD-12': base.replaceFirst('"seq":12', '"seq":65536'),
        'CMD-13a': base.replaceFirst('"speed":50', '"speed":50.5'),
        'CMD-13b': base.replaceFirst('"speed":50', '"speed":"50"'),
        'CMD-14': base.replaceFirst(',"trimmer":0', ''),
        'CMD-16': base.replaceFirst('"CMD"', '"cmd"'),
        'CMD-17': 'esto no es json',
        'CMD-19': '{"t":"ZZZ"}',
      };
      invalid.forEach((k, v) {
        expect(() => ControlCommand.fromJsonLine(v), throwsFormatException, reason: k);
      });
    });

    test('CMD-15 (clave duplicada "cutter":1 al final): el documento exige DESCARTAR la línea', () {
      const dup = '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"cutter":1}';
      expect(() => ControlCommand.fromJsonLine(dup), throwsFormatException,
          reason: 'el parser de referencia (usado por el ESP simulado) acepta el duplicado y deja cutter=1');
    });
  });

  group('ACK / GPS / POK / PERR (6.2): lo que la app debe aceptar o descartar', () {
    test('ACK-1/2', () {
      expect((EspProtocol.decodeEspLine('{"t":"ACK","seq":0}\n') as CommandAck).seq, 0);
      expect((EspProtocol.decodeEspLine('{"t":"ACK","seq":65535}\n') as CommandAck).seq, 65535);
      for (final l in ['{"t":"ACK","seq":65536}', '{"t":"ACK","seq":-1}', '{"t":"ACK","seq":1.0}']) {
        expect(EspProtocol.decodeEspLine(l), isNull, reason: l);
      }
    });

    test('GPS-1/2/3/4', () {
      final g1 = EspProtocol.decodeEspLine(
          '{"t":"GPS","fix":1,"lat":-123456789,"lon":456789012,"sats":9,"hdop":0.8}\n') as GpsFix;
      expect(g1.lat, closeTo(-12.3456789, 1e-9));
      expect(g1.lon, closeTo(45.6789012, 1e-9));
      final g2 = EspProtocol.decodeEspLine('{"t":"GPS","fix":0,"sats":-1,"hdop":-1}\n') as GpsFix;
      expect((g2.lat, g2.lon, g2.satellites, g2.hdop), (null, null, null, null));
      expect(
          EspProtocol.decodeEspLine(
              '{"t":"GPS","fix":2,"lat":-900000000,"lon":1800000000,"sats":12,"hdop":99.9}\n'),
          isA<GpsFix>());
      for (final l in [
        '{"t":"GPS","fix":1,"lat":900000001,"lon":0,"sats":1,"hdop":1}',
        '{"t":"GPS","fix":-1,"lat":0,"lon":0,"sats":1,"hdop":1}',
        '{"t":"GPS","fix":1,"lat":0,"lon":0,"sats":-2,"hdop":1}',
        '{"t":"GPS","fix":1,"lat":0,"lon":0,"sats":1,"hdop":-0.5}',
      ]) {
        expect(EspProtocol.decodeEspLine(l), isNull, reason: l);
      }
    });

    test('POK / PERR / AREA: ejemplos y la app ignora AREA hoy (como dice el doc)', () {
      expect((EspProtocol.decodeEspLine('{"t":"POK","id":7}\n') as PolygonAccepted).id, 7);
      final p = EspProtocol.decodeEspLine('{"t":"PERR","id":-1,"e":"ID"}\n') as PolygonRejected;
      expect((p.id, p.reason), (-1, 'ID'));
      expect(EspProtocol.decodeEspLine('{"t":"PERR","e":"FMT"}\n'), isA<PolygonRejected>());
      for (final l in ['{"t":"AREA","id":0}\n', '{"t":"AREA","id":7}\n']) {
        expect(EspProtocol.decodeEspLine(l), isNull, reason: 'AREA aún no se decodifica: $l');
      }
    });
  });

  group('POLY (6.3): cada fila contra EspProtocol.parsePolygonLine', () {
    String poly(int id, List<(int, int)> p) => EspProtocol.encodePolygon(id, p);
    PolygonParseResult parse(String l) => EspProtocol.parsePolygonLine(l);

    test('POLY-1 formato exacto y validez; POLY-2/3/4/5/6 válidos', () {
      expect(poly(7, square), '{"t":"POLY","id":7,"p":[[0,0],[0,1000],[1000,1000],[1000,0]]}\n');
      expect(parse(poly(7, square)).isValid, isTrue);
      expect(parse(poly(1, [(0, 0), (0, 1000), (1000, 0)])).isValid, isTrue);
      expect(parse(poly(65535, List.generate(10, (i) => (i, i)))).isValid, isTrue);
      expect(parse(poly(65535, List.filled(10, (EspProtocol.int32Min, EspProtocol.int32Min)))).isValid, isTrue);
      expect(parse(poly(3, [(EspProtocol.int32Max, EspProtocol.int32Min), (0, 0), (1, 1)])).isValid, isTrue);
      expect(parse(poly(1, [(0, 0), (1000, 1000), (0, 1000), (1000, 0)])).isValid, isTrue,
          reason: 'POLY-6: autointersección válida para el ESP');
    });

    test('POLY-8…20 y 22: código y id del PERR exactos', () {
      final cases = <String, (String, int?, String)>{
        'POLY-8': (poly(5, [(0, 0), (1, 1)]), 5, 'NVERT'),
        'POLY-9': (poly(5, List.generate(11, (i) => (i, i))), 5, 'NVERT'),
        'POLY-10': ('{"t":"POLY","id":5,"p":[]}', 5, 'NVERT'),
        'POLY-11': (poly(5, [(2147483648, 0), (0, 0), (1, 1)]), 5, 'RANGE'),
        'POLY-12': (poly(5, [(0, -2147483649), (0, 0), (1, 1)]), 5, 'RANGE'),
        'POLY-13': (poly(0, square), 0, 'ID'),
        'POLY-14': (poly(65536, square), 65536, 'ID'),
        'POLY-15': (poly(-1, square), -1, 'ID'),
        'POLY-17': ('{"t":"POLY","p":[[0,0],[1,1],[2,2]]}', null, 'FMT'),
        'POLY-18': ('{"t":"POLY","id":"7","p":[[0,0],[1,1],[2,2]]}', null, 'FMT'),
        'POLY-19': ('{"t":"POLY","id":4,"p":7}', 4, 'FMT'),
        'POLY-20a': ('{"t":"POLY","id":4,"p":[[0],[1,1],[2,2]]}', 4, 'FMT'),
        'POLY-20b': ('{"t":"POLY","id":4,"p":[[0,0.5],[1,1],[2,2]]}', 4, 'FMT'),
      };
      cases.forEach((k, v) {
        final r = parse(v.$1);
        expect((r.id, r.error), (v.$2, v.$3), reason: k);
        // y el PERR que emitiría el ESP es el de la tabla
        final wire = EspProtocol.encodePerr(id: r.id, code: r.error!);
        expect(EspProtocol.decodeEspLine(wire), isA<PolygonRejected>(), reason: '$k: la app acepta su PERR');
      });
    });

    test('POLY-21: línea > 512 B que empieza con {"t":"POLY" → LEN sin id', () {
      final long = '{"t":"POLY","id":1,"p":[${List.filled(200, '[0,0]').join(',')}]}\n';
      expect(bytes(long), greaterThan(512));
      final r = parse(long);
      expect((r.id, r.error), (null, 'LEN'));
      expect(EspProtocol.encodePerr(code: 'LEN'), '{"t":"PERR","e":"LEN"}\n');
    });

    test('POLY-16 (id 99999999999, no cabe en int32): el doc dice PERR SIN id; con el ESP simulado de '
        'referencia la app recibe ese PERR', () {
      fakeAsync((async) {
        final link = SimulatedRobotLink(const AppConfig(toolsEnabled: false), connectDelay: Duration.zero);
        final msgs = <RobotMessage>[];
        link.messages.listen(msgs.add);
        link.connect();
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        link.sendPolygon(99999999999, square);
        async.flushMicrotasks();
        final rej = msgs.whereType<PolygonRejected>().toList();
        expect(rej, hasLength(1), reason: 'el simulador emite PERR con el id sin recortar y la app lo descarta (fuera de int32)');
        expect((rej.single.id, rej.single.reason), (null, 'ID'));
        link.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('REQUISITOS 14/11/26 contra el ESP simulado de referencia (caracterización)', () {
    test('el ESP simulado de referencia NO fuerza state a STOP en el corte (el doc 8.1/ST-2 sí lo exige): '
        'divergencia registrada', () {
      fakeAsync((async) {
        const cfg = AppConfig(toolsEnabled: true);
        final link = SimulatedRobotLink(cfg, connectDelay: Duration.zero);
        link.connect();
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        link.sendCommand(ControlCommand(
            state: RobotState.autoRun, dir: Direction.forward, speed: 50, cutter: 0, trimmer: 0, seq: 5));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 301));
        final pub = link.espPublishedCommand!;
        expect((pub.dir, pub.cutter, pub.trimmer), (Direction.none, 0, 0));
        // El documento (ST-2) pide state = STOP (0). El simulador conserva AUTO_RUN:
        expect(pub.state, RobotState.autoRun);
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('el polígono vigente del ESP simulado se conserva al desconectar (AR-3) y PCLR lo borra', () {
      fakeAsync((async) {
        final link = SimulatedRobotLink(const AppConfig(toolsEnabled: false), connectDelay: Duration.zero);
        link.connect();
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        link.sendPolygon(7, square);
        async.flushMicrotasks();
        expect(link.espPolygonId, 7);
        link.simulateLinkLoss();
        async.flushMicrotasks();
        expect(link.espPolygonId, 7);
        link.connect();
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        link.sendPolygon(9, [(0, 0), (1, 1)]); // inválido: no cambia el vigente
        async.flushMicrotasks();
        expect(link.espPolygonId, 7);
        link.clearPolygon();
        async.flushMicrotasks();
        expect(link.espPolygonId, 0);
        link.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
