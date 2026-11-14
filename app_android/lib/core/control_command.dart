// CONTRATO COMPARTIDO entre agentes (definido por el coordinador).
// Dueño de la implementación: Agente 1. Firmas públicas fijas (ver robot_link.dart).
//
// Campos EXACTOS de la Directiva §3.1 / docs/e7_app_android.md §4 (índices 16–21
// de /sensores en el ESP). No agregar ni renombrar campos del contrato.

import 'dart:convert';

/// `state`: 0 STOP, 1 MANUAL, 2 AUTO_RUN, 3 AUTO_PAUSE.
enum RobotState {
  stop(0),
  manual(1),
  autoRun(2),
  autoPause(3);

  final int code;
  const RobotState(this.code);

  /// Inverso de [code]. Lanza [ArgumentError] si el código no existe.
  static RobotState fromCode(int code) {
    for (final s in values) {
      if (s.code == code) return s;
    }
    throw ArgumentError.value(code, 'state', 'debe ser 0–3');
  }
}

/// `dir`: 0 nada, 1 adelante, 2 atrás, 3 izquierda, 4 derecha.
enum Direction {
  none(0),
  forward(1),
  backward(2),
  left(3),
  right(4);

  final int code;
  const Direction(this.code);

  /// Inverso de [code]. Lanza [ArgumentError] si el código no existe.
  static Direction fromCode(int code) {
    for (final d in values) {
      if (d.code == code) return d;
    }
    throw ArgumentError.value(code, 'dir', 'debe ser 0–4');
  }
}

/// Comando de control manual (App → ESP, 10 Hz mientras haya conexión).
/// Inmutable. Constructor validado: un valor fuera de rango lanza
/// [ArgumentError] (nunca se recorta en silencio).
class ControlCommand {
  /// Rangos del contrato (Directiva §3.1).
  static const int speedMin = 0;
  static const int speedMax = 100;
  static const int seqMin = 0;
  static const int seqMax = 65535;

  /// Valor del campo `t` del comando. PROPUESTA (docs §4), no congelado con
  /// el firmware.
  static const String jsonType = 'CMD';

  final RobotState state;
  final Direction dir;

  /// 0–100 (%).
  final int speed;

  /// 0 / 1 — pedido de cortadora.
  final int cutter;

  /// 0 / 1 — pedido de bordeadora.
  final int trimmer;

  /// 0–65535, da la vuelta (ver SeqCounter).
  final int seq;

  ControlCommand({
    required this.state,
    required this.dir,
    required this.speed,
    required this.cutter,
    required this.trimmer,
    required this.seq,
  }) {
    _checkRange(speed, speedMin, speedMax, 'speed');
    _checkRange(cutter, 0, 1, 'cutter');
    _checkRange(trimmer, 0, 1, 'trimmer');
    _checkRange(seq, seqMin, seqMax, 'seq');
  }

  static void _checkRange(int value, int min, int max, String name) {
    if (value < min || value > max) {
      throw ArgumentError.value(value, name, 'fuera de rango ($min–$max)');
    }
  }

  /// Comando de STOP seguro: state STOP, dir 0, speed 0, herramientas 0.
  factory ControlCommand.safeStop(int seq) => ControlCommand(
        state: RobotState.stop,
        dir: Direction.none,
        speed: 0,
        cutter: 0,
        trimmer: 0,
        seq: seq,
      );

  /// Copia con los campos indicados reemplazados (validada igual que el
  /// constructor).
  ControlCommand copyWith({
    RobotState? state,
    Direction? dir,
    int? speed,
    int? cutter,
    int? trimmer,
    int? seq,
  }) =>
      ControlCommand(
        state: state ?? this.state,
        dir: dir ?? this.dir,
        speed: speed ?? this.speed,
        cutter: cutter ?? this.cutter,
        trimmer: trimmer ?? this.trimmer,
        seq: seq ?? this.seq,
      );

  /// Copia con las herramientas forzadas a 0.
  ControlCommand withToolsOff() =>
      (cutter == 0 && trimmer == 0) ? this : copyWith(cutter: 0, trimmer: 0);

  /// Política de herramientas que aplican AMBOS enlaces antes de transmitir
  /// (defensa en profundidad): si `toolsEnabled` es false, cutter/trimmer = 0.
  ControlCommand applyToolsPolicy({required bool toolsEnabled}) =>
      toolsEnabled ? this : withToolsOff();

  /// Mapa en el orden fijo del esquema propuesto.
  Map<String, Object> toJsonMap() => <String, Object>{
        't': jsonType,
        'state': state.code,
        'dir': dir.code,
        'speed': speed,
        'cutter': cutter,
        'trimmer': trimmer,
        'seq': seq,
      };

  /// JSON de una línea (esquema PROPUESTO por el Agente 1, ver docs §4).
  ///
  /// Ejemplo: `{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12}`
  /// seguido de `\n`. Sin espacios, claves en orden fijo, todo enteros.
  String toJsonLine() => '${jsonEncode(toJsonMap())}\n';

  /// Parser inverso estricto (referencia del lado ESP y tests).
  ///
  /// Acepta la línea con o sin `\n` final. Lanza [FormatException] si el JSON
  /// no es un objeto, si `t` no es `"CMD"`, si falta un campo, si un campo no
  /// es entero o si un valor está fuera de rango.
  factory ControlCommand.fromJsonLine(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line.trimRight());
    } on FormatException catch (e) {
      throw FormatException('CMD: JSON inválido (${e.message})', line);
    }
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('CMD: se esperaba un objeto JSON', line);
    }
    final map = decoded;
    if (map['t'] != jsonType) {
      throw FormatException('CMD: "t" debe ser "$jsonType"', line);
    }
    int field(String key) {
      final v = map[key];
      if (v is! int) {
        throw FormatException('CMD: "$key" falta o no es entero', line);
      }
      return v;
    }

    try {
      return ControlCommand(
        state: RobotState.fromCode(field('state')),
        dir: Direction.fromCode(field('dir')),
        speed: field('speed'),
        cutter: field('cutter'),
        trimmer: field('trimmer'),
        seq: field('seq'),
      );
    } on ArgumentError catch (e) {
      throw FormatException('CMD: ${e.name} ${e.message} (${e.invalidValue})', line);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ControlCommand &&
      other.state == state &&
      other.dir == dir &&
      other.speed == speed &&
      other.cutter == cutter &&
      other.trimmer == trimmer &&
      other.seq == seq;

  @override
  int get hashCode => Object.hash(state, dir, speed, cutter, trimmer, seq);

  @override
  String toString() => 'ControlCommand(state: ${state.name}, dir: ${dir.name}, '
      'speed: $speed, cutter: $cutter, trimmer: $trimmer, seq: $seq)';
}

/// Contador de secuencia 0–65535 que da la vuelta a 0.
class SeqCounter {
  int _next;

  /// [start] permite arrancar en otro valor (tests). Debe estar en 0–65535.
  SeqCounter([int start = 0]) : _next = start {
    if (start < ControlCommand.seqMin || start > ControlCommand.seqMax) {
      throw ArgumentError.value(start, 'start', 'fuera de rango (0–65535)');
    }
  }

  /// Devuelve el valor actual y avanza: 0, 1, …, 65535, 0, …
  int next() {
    final value = _next;
    _next = value == ControlCommand.seqMax ? ControlCommand.seqMin : value + 1;
    return value;
  }
}
