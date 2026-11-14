// CONTRATO COMPARTIDO entre agentes (definido por el coordinador).
// Dueño de la implementación: Agente 1. Las firmas públicas NO se cambian sin
// avisar al coordinador: la UI (Agente 2) y los tests del auditor dependen de ellas.
//
// Fuente del contrato: Directiva — App de teléfono §3 y docs/e7_app_android.md.

import 'control_command.dart';

/// Estado del enlace con el ESP32 sensor (o con el robot simulado).
enum LinkStatus { disconnected, connecting, connected }

/// Mensajes que el ESP puede devolver a la app (Directiva §3.3: solo GPS,
/// ACK de comandos y respuesta del área). Nada del Brain ni de los motores.
sealed class RobotMessage {
  const RobotMessage();
}

/// `{"t":"POK","id":N}` — polígono recibido y aceptado (Directiva §3.2).
class PolygonAccepted extends RobotMessage {
  final int id;
  const PolygonAccepted(this.id);
}

/// `PERR` — polígono rechazado (Directiva §3.2). Formato exacto: pendiente
/// (Directiva §5, decisión abierta 2); la PROPUESTA está en docs/e7_app_android.md §5.
class PolygonRejected extends RobotMessage {
  final int? id;
  final String? reason;
  const PolygonRejected({this.id, this.reason});
}

/// ACK de un comando de control (fase 2, formato a definir con el firmware).
class CommandAck extends RobotMessage {
  final int seq;
  const CommandAck(this.seq);
}

/// Posición GPS que reporta el ESP (en modo simulado: datos de prueba).
class GpsFix extends RobotMessage {
  /// Latitud y longitud en grados decimales. `null` = sin fix.
  final double? lat;
  final double? lon;
  final int? fixQuality; // 0 sin fix, 1 GPS, 2 DGPS
  final int? satellites;
  final double? hdop;
  final bool simulated;
  const GpsFix({
    this.lat,
    this.lon,
    this.fixQuality,
    this.satellites,
    this.hdop,
    required this.simulated,
  });
}

/// Enlace con el robot. Dos implementaciones: `SimulatedRobotLink` (por
/// defecto en la APK de prueba) y `BleRobotLink` (flutter_blue_plus, sin uso
/// real hasta que exista el firmware BLE del ESP).
abstract class RobotLink {
  /// true en el robot simulado. La UI lo usa para el banner "MODO SIMULADO".
  bool get isSimulated;

  LinkStatus get status;
  Stream<LinkStatus> get statusStream;

  /// Mensajes ESP → app (POK/PERR, ACK, GPS).
  Stream<RobotMessage> get messages;

  Future<void> connect();
  Future<void> disconnect();

  /// Envía un comando de control. La implementación DEBE forzar `cutter` y
  /// `trimmer` a 0 si las herramientas están deshabilitadas (defensa en
  /// profundidad, además de la UI). Si no está conectado, no envía nada.
  Future<void> sendCommand(ControlCommand command);

  /// `{"t":"POLY","id":N,"p":[[lat,lon],...]}` — lat/lon int32 en 1e-7°,
  /// 3 a 10 vértices (Directiva §3.2). La APK 1 no tiene editor: solo tests.
  ///
  /// Polígono que no cumple la integridad del contrato (decisión del
  /// coordinador, AUD-07): la respuesta `POK`/`PERR` la da SOLO el ESP.
  /// - `BleRobotLink` lanza [ArgumentError] y no envía nada: nunca fabrica un
  ///   `PERR` que el ESP no mandó.
  /// - `SimulatedRobotLink` emula al ESP: recibe lo que se le mande y responde
  ///   `PERR` por el stream [messages], como lo haría el ESP real.
  Future<void> sendPolygon(int id, List<(int, int)> points);

  /// `{"t":"PCLR"}` — borrar el área.
  Future<void> clearPolygon();

  Future<void> dispose();
}
