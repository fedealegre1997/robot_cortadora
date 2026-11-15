// Auditor — AUD-20: claves duplicadas en ControlCommand.fromJsonLine.
// Seguridad: {"cutter":0,...,"cutter":1} no puede colar cutter = 1.
//
// jsonDecode DECODIFICA las claves (escapes \uXXXX incluidos) y se queda con la
// ÚLTIMA; por eso "cutter" y "cutter" son LA MISMA clave. El oráculo de
// estos tests usa el significado real de JSON: decodifica cada clave de primer
// nivel y compara decodificadas.

import 'dart:convert';
import 'dart:math' as math;

import 'package:cortadora_e7/core/control_command.dart';
import 'package:flutter_test/flutter_test.dart';

const baseMembers = <String, String>{
  't': '"CMD"',
  'state': '1',
  'dir': '1',
  'speed': '50',
  'cutter': '0',
  'trimmer': '0',
  'seq': '12',
};

String obj(List<(String, String)> members, {String sep = ',', String pre = '', String post = ''}) =>
    '$pre{${members.map((m) => '${m.$1}:${m.$2}').join(sep)}}$post';

String q(String k) => '"$k"';

/// Clave escrita con \uXXXX en algunas posiciones (misma clave para JSON).
String escaped(String k, math.Random r, {double p = 0.5}) {
  final b = StringBuffer('"');
  var any = false;
  for (final u in k.codeUnits) {
    if (r.nextDouble() < p) {
      final hex = u.toRadixString(16).padLeft(4, '0');
      b.write('\\u${r.nextBool() ? hex : hex.toUpperCase()}');
      any = true;
    } else {
      b.writeCharCode(u);
    }
  }
  if (!any && k.isNotEmpty) {
    // garantizar al menos un escape
    final u = k.codeUnitAt(0);
    return '"\\u${u.toRadixString(16).padLeft(4, '0')}${k.substring(1)}"';
  }
  return (b..write('"')).toString();
}

/// Oráculo independiente: claves de primer nivel DECODIFICADAS; hay duplicado
/// si dos claves decodificadas coinciden. Se parte de la lista que YO armé.
bool hasDupByMeaning(List<String> rawKeys) {
  final seen = <String>{};
  for (final k in rawKeys) {
    final decoded = jsonDecode(k) as String;
    if (!seen.add(decoded)) return true;
  }
  return false;
}

String randomValue(math.Random r, int depth) {
  switch (r.nextInt(depth > 2 ? 4 : 7)) {
    case 0:
      return '${r.nextInt(1000) - 500}';
    case 1:
      return jsonEncode(['a', 'b,c', '{x:1}', 'k":1', 'q\\"cutter\\":1', r'back\\', '[', '}', ':,'][r.nextInt(9)]);
    case 2:
      return r.nextBool() ? 'true' : 'null';
    case 3:
      return '${r.nextDouble()}';
    case 4: // objeto anidado, A PROPÓSITO con claves duplicadas adentro
      return '{"a":${r.nextInt(5)},"a":${r.nextInt(5)},"cutter":1,"cutter":0}';
    case 5:
      return '[${List.generate(r.nextInt(3), (_) => randomValue(r, depth + 1)).join(',')}]';
    default:
      return '{"k":${randomValue(r, depth + 1)}}';
  }
}

String ws(math.Random r) => ['', ' ', '\n', '\t', ' \r\n '][r.nextInt(5)];

void main() {
  group('casos dirigidos', () {
    String line(List<(String, String)> extra, {String pre = '', String post = ''}) => obj([
          for (final e in baseMembers.entries) (q(e.key), e.value),
          ...extra,
        ], pre: pre, post: post);

    test('duplicadas de primer nivel (cualquier clave, posición y valor) se rechazan', () {
      for (final k in baseMembers.keys) {
        for (final v in ['0', '1', '2', '"x"', 'null', '[1]', '{"a":1}']) {
          expect(() => ControlCommand.fromJsonLine(line([(q(k), v)])), throwsFormatException,
              reason: 'dup $k=$v al final');
          expect(
              () => ControlCommand.fromJsonLine(obj([(q(k), v), for (final e in baseMembers.entries) (q(e.key), e.value)])),
              throwsFormatException,
              reason: 'dup $k=$v al principio');
        }
      }
      expect(() => ControlCommand.fromJsonLine(line([('"x"', '1'), ('"x"', '1')])), throwsFormatException,
          reason: 'clave desconocida repetida con el mismo valor');
    });

    test('NO son duplicadas: anidadas, dentro de strings, claves distintas por mayúsculas, espacios y saltos', () {
      expect(ControlCommand.fromJsonLine(line([('"n"', '{"a":1,"a":2}')])).cutter, 0);
      expect(ControlCommand.fromJsonLine(line([('"n"', '[{"cutter":1},{"cutter":2}]')])).cutter, 0);
      expect(ControlCommand.fromJsonLine(line([('"s"', r'"\"cutter\":1,\"cutter\":1"')])).cutter, 0);
      expect(ControlCommand.fromJsonLine(line([('"s"', r'"termina con barra \\"'), ('"u"', '1')])).seq, 12);
      expect(ControlCommand.fromJsonLine(line([('"s"', '"{[:,"')])).seq, 12);
      expect(ControlCommand.fromJsonLine(line([('"Cutter"', '1')])).cutter, 0, reason: 'mayúsculas = otra clave');
      expect(ControlCommand.fromJsonLine('{ "t" :\n "CMD" ,\t"state":1,"dir":1,"speed":50 ,"cutter":0,'
              '"trimmer":0,"seq":12 \r\n}\n')
          .seq, 12);
    });

    test('JSON inválido, objeto vacío y no-objeto: se rechazan (FormatException) y no se cuelgan', () {
      for (final bad in ['', '{', '}', '{}', '[]', '"x"', '{"t":"CMD",', '{"t":"CMD","t"', '{"a":"b', 'null']) {
        expect(() => ControlCommand.fromJsonLine(bad), throwsFormatException, reason: bad);
      }
    });

    test('clave duplicada escrita con escape \\u: "cutter" y "cut\\u0074er" son la MISMA clave para JSON', () {
      // jsonDecode da cutter = 1 (gana la última). El parser tiene que rechazarla.
      const esc = '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"cut\\u0074er":1}';
      expect((jsonDecode(esc) as Map)['cutter'], 1, reason: 'precondición: así lo ve jsonDecode');
      expect(() => ControlCommand.fromJsonLine(esc), throwsFormatException,
          reason: 'BYPASS: la línea se acepta con cutter = 1');
    });

    test('escape de la primera aparición y de ambas', () {
      for (final l in [
        '{"\\u0074":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"t":"CMD"}',
        '{"t":"CMD","state":1,"dir":1,"speed":50,"\\u0063utter":0,"trimmer":0,"seq":12,"cutter":1}',
        '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"\\u0063utter":1,"cut\\u0074er":1}',
        '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"tri\\u006dmer":1}',
        '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"se\\u0071":99}',
      ]) {
        expect(() => ControlCommand.fromJsonLine(l), throwsFormatException, reason: l);
      }
    });

    test('escape SIN duplicado se acepta (una sola clave escrita con \\u)', () {
      const ok = '{"t":"CMD","state":1,"dir":1,"speed":50,"\\u0063utter":0,"trimmer":0,"seq":12}';
      expect(ControlCommand.fromJsonLine(ok).seq, 12);
    });
  });

  group('propiedad (semilla fija): objetos aleatorios', () {
    test('SIN duplicados (por significado de JSON): siempre se acepta y conserva los campos', () {
      final r = math.Random(20261115);
      for (var i = 0; i < 3000; i++) {
        final members = <(String, String)>[
          for (final e in baseMembers.entries)
            (r.nextInt(4) == 0 ? escaped(e.key, r) : q(e.key), e.value),
        ];
        // extras con claves únicas (algunas con nombres engañosos), valores con duplicados ANIDADOS
        final extras = ['x', 'y', 'Cutter', 'cutter ', 'cutte', 'a,b', 'k":1'].where((_) => r.nextBool());
        for (final k in extras) {
          members.add((jsonEncode(k), randomValue(r, 0)));
        }
        members.shuffle(r);
        final text = obj(members, sep: '${ws(r)},${ws(r)}', pre: ws(r), post: '${ws(r)}\n');
        final keys = members.map((m) => m.$1).toList();
        expect(hasDupByMeaning(keys), isFalse, reason: 'generador: $text');
        final c = ControlCommand.fromJsonLine(text);
        expect((c.state.code, c.dir.code, c.speed, c.cutter, c.trimmer, c.seq), (1, 1, 50, 0, 0, 12),
            reason: text);
      }
    });

    test('CON duplicados escritos IGUAL (texto crudo): siempre se rechaza', () {
      final r = math.Random(7);
      for (var i = 0; i < 3000; i++) {
        final members = <(String, String)>[
          for (final e in baseMembers.entries) (q(e.key), e.value),
        ];
        final k = (r.nextBool() ? baseMembers.keys.toList() : ['x', 'y', 'z'])[r.nextInt(3)];
        members.add((q(k), randomValue(r, 0)));
        if (!baseMembers.containsKey(k)) members.add((q(k), randomValue(r, 0))); // desconocida: 2 veces
        members.shuffle(r);
        final text = obj(members, sep: '${ws(r)},${ws(r)}', pre: ws(r));
        expect(() => ControlCommand.fromJsonLine(text), throwsFormatException, reason: text);
      }
    });

    test('CON duplicados donde alguna aparición lleva escape \\uXXXX: siempre se rechaza (el JSON es el mismo)', () {
      final r = math.Random(99);
      var accepted = <String>[];
      for (var i = 0; i < 3000; i++) {
        final members = <(String, String)>[
          for (final e in baseMembers.entries) (q(e.key), e.value),
        ];
        final k = baseMembers.keys.toList()[r.nextInt(baseMembers.length)];
        members.add((escaped(k, r), k == 't' ? '"CMD"' : '${r.nextInt(2)}'));
        members.shuffle(r);
        final text = obj(members);
        expect(hasDupByMeaning(members.map((m) => m.$1).toList()), isTrue, reason: 'generador: $text');
        try {
          ControlCommand.fromJsonLine(text);
          accepted.add(text);
        } on FormatException {
          // rechazada: lo correcto
        }
      }
      expect(accepted, isEmpty,
          reason: '${accepted.length} líneas con clave duplicada por escape fueron ACEPTADAS; '
              'ejemplo: ${accepted.isEmpty ? '' : accepted.first}');
    });
  });

  group('regresión: nada más cambió', () {
    test('toJsonLine: formato byte a byte y ida y vuelta de todo el rango de bordes', () {
      for (final s in RobotState.values) {
        for (final d in Direction.values) {
          for (final sp in [0, 1, 50, 99, 100]) {
            for (final seq in [0, 1, 65534, 65535]) {
              final c = ControlCommand(
                  state: s, dir: d, speed: sp, cutter: sp % 2, trimmer: (sp ~/ 2) % 2, seq: seq);
              final line = c.toJsonLine();
              expect(
                  line,
                  '{"t":"CMD","state":${s.code},"dir":${d.code},"speed":$sp,"cutter":${sp % 2},'
                  '"trimmer":${(sp ~/ 2) % 2},"seq":$seq}\n');
              expect(ControlCommand.fromJsonLine(line), c);
            }
          }
        }
      }
    });
  });
}
