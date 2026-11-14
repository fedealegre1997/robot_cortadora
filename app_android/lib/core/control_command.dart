// CONTRATO COMPARTIDO entre agentes (definido por el coordinador).
// Dueño de la implementación: Agente 1. Firmas públicas fijas (ver robot_link.dart).
//
// Campos EXACTOS de la Directiva §3.1 / docs/e7_app_android.md §4 (índices 16–21
// de /sensores en el ESP). No agregar ni renombrar campos del contrato.

/// `state`: 0 STOP, 1 MANUAL, 2 AUTO_RUN, 3 AUTO_PAUSE.
enum RobotState {
  stop(0),
  manual(1),
  autoRun(2),
  autoPause(3);

  final int code;
  const RobotState(this.code);
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
}

/// Comando de control manual (App → ESP, 10 Hz mientras haya conexión).
/// Inmutable. Constructor validado: un valor fuera de rango lanza
/// [ArgumentError] (nunca se recorta en silencio).
class ControlCommand {
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
    // TODO(Agente 1): validación completa de rangos.
    throw UnimplementedError('Agente 1');
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

  /// Copia con las herramientas forzadas a 0.
  ControlCommand withToolsOff() => throw UnimplementedError('Agente 1');

  /// JSON de una línea (esquema PROPUESTO por el Agente 1, ver docs §4).
  String toJsonLine() => throw UnimplementedError('Agente 1');
}

/// Contador de secuencia 0–65535 que da la vuelta a 0.
class SeqCounter {
  int next() => throw UnimplementedError('Agente 1');
}
