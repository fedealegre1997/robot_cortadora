// Auditor — AUD-25: claves duplicadas con escapes. Oráculo INDEPENDIENTE:
// tokenizador JSON escrito a mano (no usa jsonDecode ni el escáner del código)
// que decodifica las claves de primer nivel (\uXXXX en minúscula y mayúscula,
// \/, \", \\, \b \f \n \r \t, pares sustitutos). Se compara, para miles de
// objetos aleatorios, la decisión de ControlCommand.fromJsonLine con la del
// oráculo.

import 'dart:math' as math;

import 'package:cortadora_e7/core/control_command.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Oráculo: claves de primer nivel decodificadas, o null si el objeto no se
// pudo tokenizar (no debería pasar con texto generado).
// ---------------------------------------------------------------------------
class _Tok {
  _Tok(this.s);
  final String s;
  int i = 0;

  void ws() {
    while (i < s.length && ' \t\r\n'.contains(s[i])) {
      i++;
    }
  }

  String str() {
    assert(s[i] == '"');
    i++;
    final out = <int>[];
    while (s[i] != '"') {
      if (s[i] == '\\') {
        i++;
        switch (s[i]) {
          case '"':
            out.add(0x22);
          case '\\':
            out.add(0x5c);
          case '/':
            out.add(0x2f);
          case 'b':
            out.add(8);
          case 'f':
            out.add(12);
          case 'n':
            out.add(10);
          case 'r':
            out.add(13);
          case 't':
            out.add(9);
          case 'u':
            out.add(int.parse(s.substring(i + 1, i + 5), radix: 16));
            i += 4;
          default:
            throw StateError('escape inválido ${s[i]}');
        }
        i++;
      } else {
        out.add(s.codeUnitAt(i));
        i++;
      }
    }
    i++;
    return String.fromCharCodes(out);
  }

  void skipValue() {
    ws();
    final c = s[i];
    if (c == '"') {
      str();
    } else if (c == '{') {
      i++;
      ws();
      if (s[i] == '}') {
        i++;
        return;
      }
      while (true) {
        ws();
        str();
        ws();
        i++; // :
        skipValue();
        ws();
        if (s[i] == ',') {
          i++;
          continue;
        }
        i++; // }
        return;
      }
    } else if (c == '[') {
      i++;
      ws();
      if (s[i] == ']') {
        i++;
        return;
      }
      while (true) {
        skipValue();
        ws();
        if (s[i] == ',') {
          i++;
          continue;
        }
        i++; // ]
        return;
      }
    } else {
      while (i < s.length && !',}]'.contains(s[i]) && !' \t\r\n'.contains(s[i])) {
        i++;
      }
    }
  }

  List<String> topKeys() {
    ws();
    assert(s[i] == '{');
    i++;
    final keys = <String>[];
    ws();
    if (s[i] == '}') return keys;
    while (true) {
      ws();
      keys.add(str());
      ws();
      i++; // :
      skipValue();
      ws();
      if (s[i] == ',') {
        i++;
        continue;
      }
      return keys;
    }
  }
}

bool oracleHasDup(String text) {
  final keys = _Tok(text).topKeys();
  return keys.length != keys.toSet().length;
}

// ---------------------------------------------------------------------------
// Generador
// ---------------------------------------------------------------------------
const base = <String, String>{
  't': '"CMD"',
  'state': '1',
  'dir': '1',
  'speed': '50',
  'cutter': '0',
  'trimmer': '0',
  'seq': '12',
};

/// Claves "difíciles" para los extras.
const trickyKeys = ['', ' ', 'a b', 'ñ', 'é', '😀', 'a"b', r'a\b', 'a/b', 'T', 'Cutter', 'cutter ', 'a\nb', ' '];

String encodeKey(String k, math.Random r) {
  final b = StringBuffer('"');
  for (final cp in k.runes) {
    final units = String.fromCharCode(cp).codeUnits;
    final esc = r.nextInt(3) == 0;
    String u4(int u) {
      final h = u.toRadixString(16).padLeft(4, '0');
      return '\\u${r.nextBool() ? h : h.toUpperCase()}';
    }

    if (cp == 0x22) {
      b.write(r.nextBool() ? r'\"' : u4(cp));
    } else if (cp == 0x5c) {
      b.write(r.nextBool() ? r'\\' : u4(cp));
    } else if (cp == 0x2f) {
      b.write(switch (r.nextInt(3)) { 0 => '/', 1 => r'\/', _ => u4(cp) });
    } else if (cp < 0x20) {
      b.write(switch (cp) {
        10 => r'\n',
        13 => r'\r',
        9 => r'\t',
        8 => r'\b',
        12 => r'\f',
        _ => u4(cp),
      });
    } else if (esc) {
      for (final u in units) {
        b.write(u4(u)); // pares sustitutos: 😀
      }
    } else {
      b.writeCharCode(cp);
    }
  }
  return (b..write('"')).toString();
}

String value(math.Random r, int depth) {
  switch (r.nextInt(depth > 2 ? 4 : 7)) {
    case 0:
      return '${r.nextInt(100) - 50}';
    case 1:
      return [r'"{\"cutter\":1}"', '"a:b,c"', r'"\\"', '"["', '"}"', r'"\""', '""'][r.nextInt(7)];
    case 2:
      return ['true', 'false', 'null'][r.nextInt(3)];
    case 3:
      return '-1.5e3';
    case 4: // anidado con las MISMAS claves del contrato, repetidas
      return '{"cutter":1,"cutter":0,"t":"X","t":"Y","${r.nextBool() ? "cut\\u0074er" : "cutter"}":2}';
    case 5:
      return '[${List.generate(r.nextInt(3), (_) => value(r, depth + 1)).join(", ")}]';
    default:
      return '{"k": ${value(r, depth + 1)}, "k": 1}';
  }
}

String ws(math.Random r) => ['', ' ', '\n', '\t', ' \r\n '][r.nextInt(5)];

void main() {
  test('el oráculo (tokenizador propio) concuerda con jsonDecode en las claves y detecta los duplicados', () {
    expect(oracleHasDup('{"cutter":0,"cut\\u0074er":1}'), isTrue);
    expect(oracleHasDup('{"cutter":0,"CUT\\u0054ER":1}'), isFalse, reason: '\\u0054 = "T": "cuTter" ≠ "cutter"');
    expect(oracleHasDup('{"a":{"x":1,"x":2},"b":[{"x":1},{"x":1}]}'), isFalse);
    expect(oracleHasDup('{"":1,"":2}'), isTrue);
    expect(oracleHasDup('{"a/b":1,"a\\/b":2}'), isTrue);
    expect(oracleHasDup('{"😀":1,"\\uD83D\\uDE00":2}'), isTrue);
    expect(oracleHasDup('{"\\u00f1":1,"\\u00F1":2}'), isTrue);
  });

  group('casos dirigidos pedidos por el coordinador', () {
    String cmd(List<String> extra) =>
        '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12${extra.map((e) => ',$e').join()}}';

    void rejects(String l, [String why = '']) =>
        expect(() => ControlCommand.fromJsonLine(l), throwsFormatException, reason: '$why $l');
    void accepts(String l, [String why = '']) =>
        expect(ControlCommand.fromJsonLine(l).seq, 12, reason: '$why $l');

    test('escapes en minúscula y mayúscula, claves escapadas por completo, el ejemplo del documento', () {
      rejects(cmd(['"cut\\u0074er":1']), 'el ejemplo del documento');
      rejects(cmd(['"cut\\u0074er":1', '"cut\\u0074er":0']), 'dos escapadas entre sí');
      rejects(cmd(['"tri\\u006dmer":1']), 'hex en minúscula');
      rejects(cmd(['"tri\\u006Dmer":1']), 'hex en mayúscula');
      rejects(cmd(['"tri\\u006dmer":1', '"tri\\u006Dmer":1']), 'minúscula vs mayúscula entre sí');
      rejects(cmd(['"\\u0063\\u0075\\u0074\\u0074\\u0065\\u0072":1']), 'clave escapada por completo');
      rejects(cmd(['"\\u0073\\u0065\\u0071":99']), 'seq escapada');
      rejects('{"\\u0074":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"t":"CMD"}', 'la clave t');
      accepts(cmd(['"cut\\u0054er":1']), '\\u0054 es "T": otra clave, NO duplica');
      accepts(cmd(['"cut\\u0074er_":1']));
    });

    test('barra, comillas, barra invertida, pares sustitutos, vacía, con espacios', () {
      rejects(cmd(['"a\\/b":1', '"a/b":2']));
      rejects(cmd(['"a\\"b":1', '"a\\u0022b":2']));
      rejects(cmd(['"a\\\\b":1', '"a\\u005cb":2']));
      rejects(cmd(['"\\uD83D\\uDE00":1', '"\\ud83d\\ude00":2']));
      rejects(cmd(['"😀":1', '"\\uD83D\\uDE00":2']), 'literal vs par sustituto escapado');
      rejects(cmd(['"":1', '"":2']), 'clave vacía');
      rejects(cmd(['"a b":1', '"a\\u0020b":2']));
      accepts(cmd(['"a b":1', '"a  b":2']), 'espacios distintos');
      accepts(cmd(['"":1', '" ":2']));
    });

    test('valores string con { : " y objetos anidados con las mismas claves: NO se rechazan', () {
      accepts(cmd(['"s":"{\\"cutter\\":1,\\"cutter\\":1}"']));
      accepts(cmd(['"s":"a\\\\"', '"u":1']));
      accepts(cmd(['"s":"\\""']));
      accepts(cmd(['"n":{"cutter":1,"cutter":2,"t":"x","t":"y"}']));
      accepts(cmd(['"n":[{"cut\\u0074er":1,"cutter":1}]']));
      accepts(cmd(['"n":{"k":{"cutter":1,"cut\\u0074er":2}}']));
    });

    test('JSON inválido, truncado y {}: FormatException, sin colgarse', () {
      for (final bad in ['{', '{"a"', '{"a":', '{"cut\\u0074er":1,', '{"t":"CMD","cutter":0,"cut\\u0074er"', '{}', '{ }', '[{"a":1}]', '{"a":1,"a":2']) {
        rejects(bad);
      }
    });
  });
  group('propiedad aleatoria contra el oráculo independiente', () {
    String build(math.Random r, {required bool forceDup}) {
      final members = <(String, String)>[];
      for (final e in base.entries) {
        members.add((r.nextInt(3) == 0 ? encodeKey(e.key, r) : '"${e.key}"', e.value));
      }
      final extras = {...trickyKeys.where((_) => r.nextInt(3) == 0), if (r.nextBool()) 'x', if (r.nextBool()) 'y'};
      for (final k in extras) {
        members.add((encodeKey(k, r), value(r, 0)));
      }
      if (forceDup) {
        // repetir una clave existente (del contrato o extra) con otra codificación
        final pool = [...base.keys, ...extras];
        final k = pool[r.nextInt(pool.length)];
        members.add((encodeKey(k, r), k == 't' ? '"CMD"' : '1'));
      }
      members.shuffle(r);
      return '${ws(r)}{${members.map((m) => '${ws(r)}${m.$1}${ws(r)}:${ws(r)}${m.$2}').join(',')}${ws(r)}}${ws(r)}';
    }

    test('6000 objetos (50 % con duplicado forzado, claves difíciles, escapes mixtos): la decisión de '
        'fromJsonLine == la del oráculo', () {
      final r = math.Random(20261116);
      var rej = 0, acc = 0;
      final mismatches = <String>[];
      for (var i = 0; i < 6000; i++) {
        final text = build(r, forceDup: i.isEven);
        final dup = oracleHasDup(text);
        ControlCommand? parsed;
        try {
          parsed = ControlCommand.fromJsonLine(text);
        } on FormatException {
          parsed = null;
        }
        if (dup == (parsed != null)) {
          mismatches.add('oráculo dup=$dup, fromJsonLine ${parsed != null ? "ACEPTÓ" : "rechazó"}: $text');
        }
        if (parsed == null) {
          rej++;
        } else {
          acc++;
          expect((parsed.cutter, parsed.trimmer, parsed.seq), (0, 0, 12), reason: text);
        }
      }
      // ignore: avoid_print
      print('AUD-25 propiedad: aceptados=$acc rechazados=$rej discrepancias=${mismatches.length}');
      expect(acc, greaterThan(1500));
      expect(rej, greaterThan(1500));
      expect(mismatches, isEmpty, reason: mismatches.take(3).join('\n'));
    });

    test('3000 con duplicado por escape (primera o segunda aparición): se rechazan TODOS; '
        '3000 sin duplicado: se aceptan TODOS', () {
      final r = math.Random(31337);
      for (var i = 0; i < 3000; i++) {
        final dup = build(r, forceDup: true);
        if (oracleHasDup(dup)) {
          expect(() => ControlCommand.fromJsonLine(dup), throwsFormatException, reason: dup);
        }
        final ok = build(r, forceDup: false);
        if (!oracleHasDup(ok)) {
          expect(ControlCommand.fromJsonLine(ok).seq, 12, reason: ok);
        }
      }
    });
  });
}
