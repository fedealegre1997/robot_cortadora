import 'dart:convert';

import 'package:cortadora_e7/core/esp_protocol.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:flutter_test/flutter_test.dart';

const square = [(0, 0), (0, 100), (100, 100), (100, 0)];

void main() {
  group('POLY / PCLR (App → ESP, formato fijado por la Directiva)', () {
    test('encodePolygon: formato exacto', () {
      expect(EspProtocol.encodePolygon(5, [(1, 2), (3, 4), (-5, -6)]),
          '{"t":"POLY","id":5,"p":[[1,2],[3,4],[-5,-6]]}\n');
    });

    test('encodeClear', () {
      expect(EspProtocol.encodeClear(), '{"t":"PCLR"}\n');
    });

    test('integridad: vértices 3–10', () {
      List<(int, int)> n(int k) => List.generate(k, (i) => (i, i));
      expect(EspProtocol.polygonIntegrityError(1, n(2)), PerrCode.vertexCount);
      expect(EspProtocol.polygonIntegrityError(1, n(3)), isNull);
      expect(EspProtocol.polygonIntegrityError(1, n(10)), isNull);
      expect(EspProtocol.polygonIntegrityError(1, n(11)), PerrCode.vertexCount);
      expect(EspProtocol.polygonIntegrityError(1, []), PerrCode.vertexCount);
    });

    test('integridad: int32', () {
      const mx = EspProtocol.int32Max, mn = EspProtocol.int32Min;
      expect(EspProtocol.polygonIntegrityError(1, [(mn, mx), (0, 0), (1, 1)]), isNull);
      expect(EspProtocol.polygonIntegrityError(1, [(mx + 1, 0), (0, 0), (1, 1)]),
          PerrCode.range);
      expect(EspProtocol.polygonIntegrityError(1, [(0, mn - 1), (0, 0), (1, 1)]),
          PerrCode.range);
    });

    test('integridad: id 1–65535 (PROPUESTA)', () {
      expect(EspProtocol.polygonIntegrityError(0, square), PerrCode.id);
      expect(EspProtocol.polygonIntegrityError(1, square), isNull);
      expect(EspProtocol.polygonIntegrityError(65535, square), isNull);
      expect(EspProtocol.polygonIntegrityError(65536, square), PerrCode.id);
    });

    test('NO valida geometría: un polígono que se cruza es válido para el ESP', () {
      const bowtie = [(0, 0), (100, 100), (0, 100), (100, 0)];
      expect(EspProtocol.polygonIntegrityError(1, bowtie), isNull);
    });

    test('parsePolygonLine: ida y vuelta', () {
      final r = EspProtocol.parsePolygonLine(EspProtocol.encodePolygon(9, square));
      expect(r.isValid, isTrue);
      expect(r.id, 9);
      expect(r.points, square);
    });

    test('parsePolygonLine: errores de formato', () {
      for (final l in [
        'basura',
        '{"t":"PCLR"}',
        '{"t":"POLY","p":[[0,0],[1,1],[2,2]]}',
        '{"t":"POLY","id":"1","p":[[0,0],[1,1],[2,2]]}',
        '{"t":"POLY","id":1}',
        '{"t":"POLY","id":1,"p":[[0,0],[1,1],[2]]}',
        '{"t":"POLY","id":1,"p":[[0,0],[1,1],[2,2.5]]}',
      ]) {
        expect(EspProtocol.parsePolygonLine(l).error, PerrCode.format, reason: l);
      }
      // si el id se pudo leer, viaja en el PERR
      expect(EspProtocol.parsePolygonLine('{"t":"POLY","id":4,"p":7}').id, 4);
    });

    test('parsePolygonLine: línea demasiado larga → LEN', () {
      final long = '{"t":"POLY","id":1,"p":[${List.filled(200, '[0,0]').join(',')}]}';
      expect(EspProtocol.parsePolygonLine(long).error, PerrCode.length);
    });
  });

  group('ESP → App (POK fijado; PERR/ACK/GPS PROPUESTOS)', () {
    test('POK', () {
      final m = EspProtocol.decodeEspLine('{"t":"POK","id":7}\n');
      expect(m, isA<PolygonAccepted>().having((p) => p.id, 'id', 7));
    });

    test('PERR con id y sin id', () {
      expect(EspProtocol.encodePerr(id: 7, code: PerrCode.vertexCount),
          '{"t":"PERR","id":7,"e":"NVERT"}\n');
      expect(EspProtocol.encodePerr(code: PerrCode.format), '{"t":"PERR","e":"FMT"}\n');
      final a = EspProtocol.decodeEspLine('{"t":"PERR","id":7,"e":"NVERT"}') as PolygonRejected;
      expect(a.id, 7);
      expect(a.reason, 'NVERT');
      final b = EspProtocol.decodeEspLine('{"t":"PERR","e":"FMT"}') as PolygonRejected;
      expect(b.id, isNull);
      expect(b.reason, 'FMT');
    });

    test('ACK', () {
      expect(EspProtocol.encodeAck(65535), '{"t":"ACK","seq":65535}\n');
      expect((EspProtocol.decodeEspLine('{"t":"ACK","seq":12}') as CommandAck).seq, 12);
      expect(EspProtocol.decodeEspLine('{"t":"ACK","seq":65536}'), isNull);
      expect(EspProtocol.decodeEspLine('{"t":"ACK"}'), isNull);
    });

    test('GPS con fix: 1e-7° → grados, simulated=false', () {
      final line = EspProtocol.encodeGps(
          fix: 1, latE7: -123456789, lonE7: 456789012, sats: 9, hdop: 0.8);
      expect(line,
          '{"t":"GPS","fix":1,"lat":-123456789,"lon":456789012,"sats":9,"hdop":0.8}\n');
      final g = EspProtocol.decodeEspLine(line) as GpsFix;
      expect(g.lat, closeTo(-12.3456789, 1e-9));
      expect(g.lon, closeTo(45.6789012, 1e-9));
      expect(g.fixQuality, 1);
      expect(g.satellites, 9);
      expect(g.hdop, 0.8);
      expect(g.simulated, isFalse);
    });

    test('GPS sin fix y sin datos (-1)', () {
      final line = EspProtocol.encodeGps(fix: 0);
      expect(line, '{"t":"GPS","fix":0,"sats":-1,"hdop":-1}\n');
      final g = EspProtocol.decodeEspLine(line) as GpsFix;
      expect(g.lat, isNull);
      expect(g.lon, isNull);
      expect(g.satellites, isNull);
      expect(g.hdop, isNull);
    });

    test('fuera de rango → null (AUD-04)', () {
      for (final l in [
        '{"t":"POK","id":0}',
        '{"t":"POK","id":65536}',
        '{"t":"POK","id":-5}',
        '{"t":"PERR","id":0,"e":"FMT"}',
        '{"t":"PERR","id":70000,"e":"NVERT"}',
        '{"t":"PERR","id":2147483648,"e":"ID"}', // eco fuera de int32
        '{"t":"GPS","fix":-1}',
        '{"t":"GPS","fix":1,"lat":900000001,"lon":0}',
        '{"t":"GPS","fix":1,"lat":-900000001,"lon":0}',
        '{"t":"GPS","fix":1,"lat":0,"lon":1800000001}',
        '{"t":"GPS","fix":1,"lat":0,"lon":-1800000001}',
        '{"t":"GPS","fix":1,"lat":0,"lon":0,"sats":-2}',
        '{"t":"GPS","fix":1,"lat":0,"lon":0,"hdop":-0.5}',
      ]) {
        expect(EspProtocol.decodeEspLine(l), isNull, reason: l);
      }
    });

    test('bordes válidos se aceptan', () {
      expect((EspProtocol.decodeEspLine('{"t":"POK","id":1}') as PolygonAccepted).id, 1);
      expect((EspProtocol.decodeEspLine('{"t":"POK","id":65535}') as PolygonAccepted).id,
          65535);
      final g = EspProtocol.decodeEspLine(
          '{"t":"GPS","fix":1,"lat":-900000000,"lon":1800000000,"sats":-1,"hdop":-1}') as GpsFix;
      expect((g.lat, g.lon, g.satellites, g.hdop), (-90.0, 180.0, null, null));
    });

    test('PERR "ID" lleva el eco del id inválido (int32) y se acepta', () {
      for (final id in [0, -1, 65536, EspProtocol.int32Min]) {
        final r = EspProtocol.decodeEspLine(EspProtocol.encodePerr(id: id, code: PerrCode.id))
            as PolygonRejected;
        expect((r.id, r.reason), (id, PerrCode.id));
      }
    });

    test('lado ESP: el id se valida primero; el eco solo si cabe en int32', () {
      final a = EspProtocol.parsePolygonLine('{"t":"POLY","id":0,"p":7}');
      expect((a.id, a.error), (0, PerrCode.id));
      final b = EspProtocol.parsePolygonLine('{"t":"POLY","id":99999999999,"p":[]}');
      expect((b.id, b.error), (null, PerrCode.id));
      // todo PERR que arma el ESP de referencia es aceptado por la app
      for (final l in [
        'x',
        '{"t":"POLY","id":0,"p":7}',
        '{"t":"POLY","id":99999999999,"p":[]}',
        '{"t":"POLY","id":3,"p":[[0,0]]}',
        '{"t":"POLY","id":3,"p":[[2147483648,0],[0,0],[1,1]]}',
      ]) {
        final r = EspProtocol.parsePolygonLine(l);
        final m = EspProtocol.decodeEspLine(EspProtocol.encodePerr(id: r.id, code: r.error!));
        expect(m, isA<PolygonRejected>(), reason: l);
      }
    });

    test('líneas inválidas o desconocidas → null (nunca lanza)', () {
      for (final l in ['', 'x', '[]', '{"t":"ZZZ"}', '{"t":"POK"}', '{"t":"POK","id":"1"}',
          '{"t":"GPS"}', '{"t":"GPS","fix":1,"lat":1.5,"lon":2}']) {
        expect(EspProtocol.decodeEspLine(l), isNull, reason: l);
      }
    });
  });

  group('LineAssembler', () {
    test('reensambla fragmentos y separa varias líneas', () {
      final a = LineAssembler();
      expect(a.add(utf8.encode('{"t":"PO')), isEmpty);
      expect(a.add(utf8.encode('K","id":1}\n{"t":"ACK"')), ['{"t":"POK","id":1}']);
      expect(a.add(utf8.encode(',"seq":2}\n')), ['{"t":"ACK","seq":2}']);
    });

    test('descarta una línea que supera el máximo y se recupera', () {
      final a = LineAssembler(maxLineLength: 10);
      expect(a.add(utf8.encode('0123456789ABCDEF')), isEmpty);
      expect(a.add(utf8.encode('XYZ\nok\n')), ['ok']);
    });
  });

  group('tamaños para el análisis de MTU', () {
    test('POLY de 10 vértices: peor int32 y peor coordenada geográfica', () {
      const mn = EspProtocol.int32Min;
      final worstInt32 = EspProtocol.encodePolygon(65535, List.filled(10, (mn, mn)));
      expect(utf8.encode(worstInt32).length, 290);
      final worstGeo = EspProtocol.encodePolygon(
          65535, List.filled(10, (-900000000, -1800000000)));
      expect(utf8.encode(worstGeo).length, 280);
      expect(utf8.encode(worstInt32).length, lessThanOrEqualTo(EspProtocol.maxLineLength));
    });

    test('mensajes ESP → App en el peor caso', () {
      expect(utf8.encode(EspProtocol.encodeAck(65535)).length, 24);
      expect(utf8.encode(EspProtocol.encodePok(65535)).length, 23);
      final gps = EspProtocol.encodeGps(
          fix: 2, latE7: -900000000, lonE7: -1800000000, sats: 12, hdop: 99.9);
      expect(utf8.encode(gps).length, 77);
    });
  });
}
