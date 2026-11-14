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
