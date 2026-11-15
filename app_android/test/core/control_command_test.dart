import 'dart:convert';

import 'package:cortadora_e7/core/control_command.dart';
import 'package:flutter_test/flutter_test.dart';

ControlCommand cmd({
  RobotState state = RobotState.manual,
  Direction dir = Direction.forward,
  int speed = 50,
  int cutter = 0,
  int trimmer = 0,
  int seq = 0,
}) =>
    ControlCommand(
      state: state,
      dir: dir,
      speed: speed,
      cutter: cutter,
      trimmer: trimmer,
      seq: seq,
    );

void main() {
  group('rangos del constructor', () {
    test('acepta los bordes válidos', () {
      expect(() => cmd(speed: 0), returnsNormally);
      expect(() => cmd(speed: 100), returnsNormally);
      expect(() => cmd(cutter: 0, trimmer: 0), returnsNormally);
      expect(() => cmd(cutter: 1, trimmer: 1), returnsNormally);
      expect(() => cmd(seq: 0), returnsNormally);
      expect(() => cmd(seq: 65535), returnsNormally);
    });

    test('speed fuera de 0–100 lanza ArgumentError (no recorta)', () {
      expect(() => cmd(speed: -1), throwsArgumentError);
      expect(() => cmd(speed: 101), throwsArgumentError);
    });

    test('cutter fuera de 0/1 lanza ArgumentError', () {
      expect(() => cmd(cutter: -1), throwsArgumentError);
      expect(() => cmd(cutter: 2), throwsArgumentError);
    });

    test('trimmer fuera de 0/1 lanza ArgumentError', () {
      expect(() => cmd(trimmer: -1), throwsArgumentError);
      expect(() => cmd(trimmer: 2), throwsArgumentError);
    });

    test('seq fuera de 0–65535 lanza ArgumentError', () {
      expect(() => cmd(seq: -1), throwsArgumentError);
      expect(() => cmd(seq: 65536), throwsArgumentError);
    });

    test('copyWith también valida', () {
      expect(() => cmd().copyWith(speed: 101), throwsArgumentError);
    });

    test('state y dir: códigos del contrato', () {
      expect(RobotState.values.map((s) => s.code), [0, 1, 2, 3]);
      expect(Direction.values.map((d) => d.code), [0, 1, 2, 3, 4]);
      expect(RobotState.fromCode(3), RobotState.autoPause);
      expect(Direction.fromCode(4), Direction.right);
      expect(() => RobotState.fromCode(4), throwsArgumentError);
      expect(() => RobotState.fromCode(-1), throwsArgumentError);
      expect(() => Direction.fromCode(5), throwsArgumentError);
      expect(() => Direction.fromCode(-1), throwsArgumentError);
    });
  });

  group('safeStop / withToolsOff / política', () {
    test('safeStop: todo en 0 y STOP', () {
      final c = ControlCommand.safeStop(7);
      expect(c, cmd(state: RobotState.stop, dir: Direction.none, speed: 0, seq: 7));
    });

    test('withToolsOff fuerza cutter y trimmer a 0 y conserva el resto', () {
      final c = cmd(cutter: 1, trimmer: 1, speed: 80, seq: 9).withToolsOff();
      expect(c.cutter, 0);
      expect(c.trimmer, 0);
      expect(c.speed, 80);
      expect(c.seq, 9);
      expect(c.dir, Direction.forward);
    });

    test('applyToolsPolicy', () {
      final c = cmd(cutter: 1, trimmer: 1);
      expect(c.applyToolsPolicy(toolsEnabled: true), c);
      expect(c.applyToolsPolicy(toolsEnabled: false), c.withToolsOff());
    });
  });

  group('igualdad y toString', () {
    test('== y hashCode por valor', () {
      expect(cmd(seq: 3), cmd(seq: 3));
      expect(cmd(seq: 3).hashCode, cmd(seq: 3).hashCode);
      expect(cmd(seq: 3), isNot(cmd(seq: 4)));
      expect(cmd(cutter: 1), isNot(cmd(cutter: 0)));
    });

    test('toString incluye todos los campos', () {
      final s = cmd(seq: 12).toString();
      for (final f in ['state', 'dir', 'speed', 'cutter', 'trimmer', 'seq']) {
        expect(s, contains(f));
      }
    });
  });

  group('JSON (esquema PROPUESTO)', () {
    test('línea exacta, terminada en \\n, sin espacios', () {
      final line = cmd(seq: 12).toJsonLine();
      expect(line,
          '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12}\n');
      expect('\n'.allMatches(line).length, 1);
      expect(line.contains(' '), isFalse);
    });

    test('peor caso: 77 bytes (no cabe en 20 bytes de ATT por defecto)', () {
      final worst = cmd(
        state: RobotState.autoPause,
        dir: Direction.right,
        speed: 100,
        cutter: 1,
        trimmer: 1,
        seq: 65535,
      ).toJsonLine();
      expect(utf8.encode(worst).length, 77);
      expect(utf8.encode(worst).length, greaterThan(20));
    });

    test('ida y vuelta para todas las combinaciones de state/dir', () {
      for (final s in RobotState.values) {
        for (final d in Direction.values) {
          final c = cmd(state: s, dir: d, speed: 33, cutter: 1, trimmer: 0, seq: 65535);
          expect(ControlCommand.fromJsonLine(c.toJsonLine()), c);
        }
      }
    });

    test('parser estricto: rechaza formato y rangos inválidos', () {
      const ok = '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12}';
      expect(ControlCommand.fromJsonLine(ok).seq, 12);
      final bad = [
        'no es json',
        '[1,2,3]',
        ok.replaceFirst('"CMD"', '"POLY"'),
        ok.replaceFirst('"speed":50,', ''),
        ok.replaceFirst('"speed":50', '"speed":50.5'),
        ok.replaceFirst('"speed":50', '"speed":"50"'),
        ok.replaceFirst('"speed":50', '"speed":101'),
        ok.replaceFirst('"state":1', '"state":4'),
        ok.replaceFirst('"dir":1', '"dir":5'),
        ok.replaceFirst('"cutter":0', '"cutter":2'),
        ok.replaceFirst('"trimmer":0', '"trimmer":-1'),
        ok.replaceFirst('"seq":12', '"seq":65536'),
      ];
      for (final b in bad) {
        expect(() => ControlCommand.fromJsonLine(b), throwsFormatException, reason: b);
      }
    });
  });

  group('clave duplicada (AUD-20)', () {
    const base = '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12';

    test('una clave de primer nivel repetida se rechaza, venga donde venga', () {
      for (final dup in [
        '$base,"cutter":1}', // al final: ganaría el 1
        '{"cutter":1,${base.substring(1)}}', // al principio
        '$base,"trimmer":1}',
        '$base,"seq":13}',
        '$base,"t":"CMD"}', // aunque el valor sea igual
        '$base,"x":1,"x":2}', // clave desconocida repetida
      ]) {
        expect(() => ControlCommand.fromJsonLine(dup), throwsFormatException, reason: dup);
      }
    });

    test('AUD-25: duplicados disfrazados con escapes (se comparan las claves DECODIFICADAS)', () {
      // Cada caso decodifica a una clave que ya está en el objeto.
      for (final dup in [
        '$base,"cut\\u0074er":1}', // t = t
        '$base,"\\u0063utter":1}', // c = c, al inicio
        '$base,"\\u0063\\u0075\\u0074\\u0074\\u0065\\u0072":1}', // toda la clave escapada
        '{"cut\\u0074er":1,${base.substring(1)}}', // el escapado primero
        '$base,"se\\u0071":13}', // q = q
        '$base,"tr\\u0069mmer":1}', // i = i
        '$base,"\\u0073tate":2}', // s = s
        '$base,"cutt\\u0065r":1}', // hex en minúscula
        '$base,"cutt\\u0045r":1}'.replaceFirst('\\u0045', '\\u0065'),
        '$base,"\\u0054":"CMD"}'.replaceFirst('\\u0054', '\\u0074'), // la clave "t"
      ]) {
        expect(() => ControlCommand.fromJsonLine(dup), throwsFormatException, reason: dup);
      }
      // Mayúsculas en el escape (T = T, C = C) decodifican a OTRA letra:
      // "Tter" no es "tter"; no es duplicado ("cuTter" = "cuTter", clave nueva).
      expect(ControlCommand.fromJsonLine('$base,"cu\\u0054ter":1}').cutter, 0);
      // Pero hex en mayúscula del MISMO carácter sí cuenta: J y J son la misma J.
      expect(() => ControlCommand.fromJsonLine('$base,"\\u004A":1,"\\u004a":2}'),
          throwsFormatException);
    });

    test('AUD-25: \\/ , \\" y pares sustitutos en las claves', () {
      // "t\/" no es "t": son claves distintas; no hay duplicado.
      expect(ControlCommand.fromJsonLine('$base,"x\\/y":1}').seq, 12);
      // x/y repetida con y sin escape: es DUPLICADO ("x\/y" == "x/y").
      expect(() => ControlCommand.fromJsonLine('$base,"x/y":1,"x\\/y":2}'), throwsFormatException);
      // comilla escapada dentro de la clave: no corta la clave ni la duplica.
      expect(ControlCommand.fromJsonLine('$base,"a\\"b":1,"a\\"c":2}').seq, 12);
      expect(() => ControlCommand.fromJsonLine('$base,"a\\"b":1,"a\\u0022b":2}'), throwsFormatException);
      // barra invertida escapada al final de la clave
      expect(ControlCommand.fromJsonLine('$base,"k\\\\":1,"k":2}').seq, 12);
      // par sustituto (😀 = 😀) escrito de dos formas
      expect(() => ControlCommand.fromJsonLine('$base,"😀":1,"\\ud83d\\ude00":2}'), throwsFormatException);
      expect(ControlCommand.fromJsonLine('$base,"😀":1,"😁":2}').seq, 12);
    });

    test('lo que NO es duplicado se acepta: claves desconocidas, anidadas y con espacios', () {
      expect(ControlCommand.fromJsonLine('$base,"x":9}').seq, 12);
      expect(ControlCommand.fromJsonLine('$base,"a":{"k":1,"k":2}}').seq, 12,
          reason: 'solo cuentan las claves de primer nivel');
      expect(ControlCommand.fromJsonLine('$base,"s":"a,\\"cutter\\":1"}\r\n').seq, 12,
          reason: 'lo que está dentro de una cadena no es una clave');
      expect(ControlCommand.fromJsonLine('{ "t" : "CMD" , "state":1,"dir":1,"speed":50,'
              '"cutter":0,"trimmer":0,"seq":12 }')
          .seq, 12);
    });

    test('el JSON propio nunca se rechaza (ida y vuelta intacta)', () {
      for (var q = 0; q < 300; q += 7) {
        final c = ControlCommand(
            state: RobotState.values[q % 4],
            dir: Direction.values[q % 5],
            speed: q % 101,
            cutter: q % 2,
            trimmer: (q ~/ 2) % 2,
            seq: q * 200);
        expect(ControlCommand.fromJsonLine(c.toJsonLine()), c);
      }
    });
  });

  group('SeqCounter', () {
    test('arranca en 0 e incrementa', () {
      final s = SeqCounter();
      expect([s.next(), s.next(), s.next()], [0, 1, 2]);
    });

    test('da la vuelta 65535 → 0', () {
      final s = SeqCounter(65534);
      expect([s.next(), s.next(), s.next(), s.next()], [65534, 65535, 0, 1]);
    });

    test('recorre los 65536 valores y vuelve a 0', () {
      final s = SeqCounter();
      for (var i = 0; i <= 65535; i++) {
        expect(s.next(), i);
      }
      expect(s.next(), 0);
    });

    test('start fuera de rango lanza ArgumentError', () {
      expect(() => SeqCounter(-1), throwsArgumentError);
      expect(() => SeqCounter(65536), throwsArgumentError);
    });
  });
}
