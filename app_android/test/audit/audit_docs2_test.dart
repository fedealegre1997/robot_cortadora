// Auditor — AUD-25/26/27/22/23: el ejemplo nuevo de §5.1 y las reglas únicas del
// protocolo, comprobados contra el código real y contra el texto del documento.

import 'dart:convert';
import 'dart:io';

import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/esp_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

String doc(String n) => File('../docs/$n').readAsStringSync();

void main() {
  final proto = doc('protocolo_ble_app_esp.md');
  final entrega = doc('entrega_companero_firmware.md');

  test('§5.1: el ejemplo del documento (…"seq":12,"cut\\u0074er":1}) se extrae del texto, jsonDecode '
      'lo ve como cutter = 1 y fromJsonLine lo RECHAZA (resultado que afirma el doc: ninguna respuesta)', () {
    final m = RegExp(r'`(\{"t":"CMD"[^`]*cut\\u0074er[^`]*\})`').firstMatch(proto);
    expect(m, isNotNull, reason: 'no se encontró el ejemplo en §5.1 / CMD-15b');
    final line = m!.group(1)!;
    expect(line, '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"cut\\u0074er":1}');
    expect((jsonDecode(line) as Map)['cutter'], 1, reason: 'por eso es peligroso: JSON lo lee como cutter = 1');
    expect(() => ControlCommand.fromJsonLine('$line\n'), throwsFormatException);
  });

  test('§5.1: "un CMD con cut\\u0074er escrita UNA sola vez es válido y se interpreta como cutter"', () {
    const ok = '{"t":"CMD","state":1,"dir":1,"speed":50,"cut\\u0074er":1,"trimmer":0,"seq":12}';
    final c = ControlCommand.fromJsonLine(ok);
    expect((c.cutter, c.seq), (1, 12));
    expect(proto, contains('escrita **una sola vez**'));
  });

  test('CMD-15b está en la tabla 6.1 y lo que dice es verdad', () {
    expect(proto, contains('| CMD-15b |'));
    expect(proto, contains('las claves se comparan **decodificadas**'));
    // CMD-15 y CMD-15b se rechazan; el anidado NO (como dice §5.1)
    expect(
        () => ControlCommand.fromJsonLine(
            '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"cutter":1}'),
        throwsFormatException);
    expect(
        ControlCommand.fromJsonLine(
                '{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"n":{"a":1,"a":2}}')
            .seq,
        12,
        reason: '§5.1: los duplicados anidados no se rechazan');
  });

  test('AUD-23(c): §1 menciona AREA y ESTOP; AUD-22: la ventana de emparejamiento tiene fila propia '
      'y la decide el compañero (en protocolo y en el paquete)', () {
    final l18 = proto.split('\n').firstWhere((l) => l.contains('No hay canal de retorno'));
    expect(l18, contains('`AREA`'));
    expect(l18, contains('`ESTOP`'));
    expect(proto, contains('| Ventana de emparejamiento con botón físico | **RECOMENDACIÓN fuerte; la decisión es del compañero de firmware**'));
    expect(entrega, contains('RECOMENDACIÓN FUERTE, pero la decisión es tuya'));
    expect(entrega, contains('cuya decisión es del compañero'));
    // ya no figura como pregunta abierta de la usuaria
    expect(proto.contains('Ventana de emparejamiento física, cifrado de NVS'), isFalse,
        reason: 'la última fila de 11.1 no debe volver a agrupar la ventana entre los abiertos');
  });

  test('AUD-27: §5.7 y PCLR-3 dicen lo mismo (claves desconocidas se procesan; mal formado o sin \\n, no)', () {
    expect(proto, contains('Un PCLR con claves desconocidas se procesa igual (PCLR-3)'));
    expect(proto, contains('| PCLR-3 |'));
    expect(proto.contains('o con otra clave: sin respuesta'), isFalse);
  });

  test('AUD-26: UNA regla en 8.1, 8.2 y ST-9; "comando nuevo y válido" ya no aparece como condición suelta', () {
    expect(proto, contains('**Regla única (la de ST-9):**'));
    expect(proto, contains('Aplica la **regla única de 8.1 (la de ST-9):**'));
    expect(proto, contains('| ST-9 |'));
    // ST-9 y 8.2 coinciden: AUTO solo tras un state:0 válido
    expect(proto, contains('solo vuelve a aceptar AUTO (`state:2/3`) después de recibir un comando válido con `state:0`'));
    expect(proto, contains('AUTO (`state:2/3`) solo se acepta después de un comando válido con `state:0` en esa conexión'));
    // MANUAL sigue abierto
    expect(proto, contains('pregunta abierta 9'));
    expect(proto, contains('9. **PREGUNTA abierta (usuaria y compañero): ¿el STOP retenido también aplica a MANUAL?'));
    // frases viejas desaparecieron
    expect(proto.contains('hasta recibir un comando **nuevo y válido** de la app'), isFalse);
    expect(proto.contains('aunque sea `state:2`, recién entonces cambia'), isFalse);
  });

  test('el decodificador de la app sigue ignorando AREA y ESTOP (pendientes de la segunda APK, como dicen los docs)', () {
    for (final l in ['{"t":"AREA","id":7}\n', '{"t":"ESTOP","why":"T"}\n']) {
      expect(EspProtocol.decodeEspLine(l), isNull);
    }
  });
}
