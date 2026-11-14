// Robot simulado: enlace por defecto de la APK de prueba (sin hardware).
// Dueño: Agente 1.
//
// Emula SOLO lo que el contrato dice que hace el ESP32 sensor (Directiva §3):
//   - recibe la línea JSON del comando y responde un ACK de RECEPCIÓN;
//   - valida la integridad del polígono y responde POK / PERR;
//   - manda GPS (aquí FICTICIO, marcado `simulated: true`);
//   - aplica su recorte de seguridad (sin conexión o comando > 300 ms →
//     dir, cutter y trimmer en 0).
// NO simula la Raspberry, el Brain ni los motores: nunca confirma ejecución,
// estado del robot ni telemetría que el ESP no tiene.

import 'dart:async';

import 'app_config.dart';
import 'control_command.dart';
import 'esp_protocol.dart';
import 'robot_link.dart';

class SimulatedRobotLink implements RobotLink {
  /// Coordenada GPS FICTICIA: "Null Island" (0°, 0°), en el océano Atlántico.
  /// Elegida a propósito para que nunca se confunda con una posición real.
  static const double fakeLat = 0.0;
  static const double fakeLon = 0.0;

  /// Cuántos comandos recibidos guarda el historial (anillo; la APK manda
  /// 10 Hz y no debe crecer sin límite).
  static const int historyLimit = 200;

  /// Timer de RESPALDO del corte (AUD-11). El corte se decide al consultar,
  /// con la antigüedad medida por [monotonicClock] (> 300 ms → corta). Este
  /// timer solo hace falta cuando el reloj no avanza con el tiempo falso
  /// (tests con fake_async y el `Stopwatch` por defecto). Son 301 ms ENTEROS:
  /// la VM trunca los timers a milisegundos (y redondea hacia abajo el
  /// instante de creación), así que nunca dispara con antigüedad ≤ 300 ms.
  static const Duration espStaleTimerDelay = Duration(milliseconds: 301);

  final AppConfig config;

  /// Demora connecting → connected.
  final Duration connectDelay;

  /// Período del GPS de prueba (~1 Hz).
  final Duration gpsPeriod;

  /// Reloj monotónico (tiempo transcurrido desde un origen arbitrario) para
  /// medir la antigüedad del último comando. Por defecto, un `Stopwatch` real
  /// (resolución de µs). Los tests pueden inyectar el tiempo falso.
  final Duration Function() monotonicClock;

  SimulatedRobotLink(
    this.config, {
    this.connectDelay = const Duration(milliseconds: 500),
    this.gpsPeriod = const Duration(seconds: 1),
    Duration Function()? monotonicClock,
  }) : monotonicClock = monotonicClock ?? _stopwatchClock();

  static Duration Function() _stopwatchClock() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  final _statusCtrl = StreamController<LinkStatus>.broadcast();
  final _msgCtrl = StreamController<RobotMessage>.broadcast();

  LinkStatus _status = LinkStatus.disconnected;
  int _connectGeneration = 0;
  Timer? _gpsTimer;
  Timer? _espStaleTimer;
  bool _disposed = false;

  // --- Estado del "ESP simulado" (lo que vería el firmware) -----------------
  final List<ControlCommand> _history = [];
  ControlCommand? _lastReceived;
  String? _lastLine;
  int _receivedCount = 0;
  Duration? _lastReceivedAt; // según monotonicClock
  bool _espStaleTimerFired = false;
  int _espPolygonId = 0;

  /// Antigüedad del último comando ≤ 300 ms (contrato: corta con MÁS de 300).
  bool get _espCommandFresh {
    final at = _lastReceivedAt;
    if (at == null || _espStaleTimerFired) return false;
    return monotonicClock() - at <= AppConfig.espCommandTimeout;
  }

  @override
  bool get isSimulated => true;

  @override
  LinkStatus get status => _status;

  @override
  Stream<LinkStatus> get statusStream => _statusCtrl.stream;

  @override
  Stream<RobotMessage> get messages => _msgCtrl.stream;

  // --- Inspección para tests ------------------------------------------------

  /// Último comando que recibió el ESP simulado (ya parseado de la línea JSON
  /// transmitida). null si nunca llegó ninguno.
  ControlCommand? get lastReceivedCommand => _lastReceived;

  /// Historial de comandos recibidos (los últimos [historyLimit]).
  List<ControlCommand> get receivedCommands => List.unmodifiable(_history);

  /// Total de comandos recibidos desde que se creó el enlace.
  int get receivedCommandCount => _receivedCount;

  /// Última línea JSON transmitida al ESP simulado (comando, POLY o PCLR).
  String? get lastTransmittedLine => _lastLine;

  /// Id del área vigente en el ESP simulado (índice 23 de /sensores; 0 = ninguna).
  int get espPolygonId => _espPolygonId;

  /// Lo que el ESP simulado publicaría en los índices 16–21 de /sensores tras
  /// su recorte de seguridad (contrato: sin conexión o último comando con
  /// MÁS de 300 ms) → dir, cutter y trimmer en 0. Con 300 ms justos todavía no
  /// corta; con más, sí. La antigüedad se calcula AL CONSULTAR con
  /// [monotonicClock] (resolución de µs con el Stopwatch por defecto), sin
  /// depender de la resolución de los timers. state, speed y seq se
  /// conservan. null si nunca llegó un comando.
  ControlCommand? get espPublishedCommand {
    final last = _lastReceived;
    if (last == null) return null;
    if (_status == LinkStatus.connected && _espCommandFresh) return last;
    return last.copyWith(dir: Direction.none, cutter: 0, trimmer: 0);
  }

  // --- Conexión -------------------------------------------------------------

  @override
  Future<void> connect() async {
    if (_disposed || _status != LinkStatus.disconnected) return;
    final gen = ++_connectGeneration;
    _setStatus(LinkStatus.connecting);
    await Future<void>.delayed(connectDelay);
    if (_disposed || gen != _connectGeneration) return; // cancelado
    _setStatus(LinkStatus.connected);
    _emitFakeGps();
    _gpsTimer = Timer.periodic(gpsPeriod, (_) => _emitFakeGps());
  }

  @override
  Future<void> disconnect() async {
    _dropLink();
  }

  /// Simula la pérdida del enlace (fuera de alcance, ESP reiniciado, etc.):
  /// el estado pasa a disconnected sin que la app lo pida.
  void simulateLinkLoss() => _dropLink();

  void _dropLink() {
    _connectGeneration++;
    _gpsTimer?.cancel();
    _gpsTimer = null;
    _espStaleTimer?.cancel();
    _espStaleTimer = null;
    _lastReceivedAt = null; // el comando viejo ya no es "reciente"
    _setStatus(LinkStatus.disconnected);
  }

  // --- Envío ----------------------------------------------------------------

  @override
  Future<void> sendCommand(ControlCommand command) async {
    if (_disposed || _status != LinkStatus.connected) return;
    final toSend = command.applyToolsPolicy(toolsEnabled: config.toolsEnabled);
    _espReceiveCommandLine(toSend.toJsonLine());
  }

  @override
  Future<void> sendPolygon(int id, List<(int, int)> points) async {
    if (_disposed || _status != LinkStatus.connected) return;
    _espReceivePolygonLine(EspProtocol.encodePolygon(id, points));
  }

  @override
  Future<void> clearPolygon() async {
    if (_disposed || _status != LinkStatus.connected) return;
    // El contrato no define respuesta a PCLR: el ESP simulado no responde nada.
    _lastLine = EspProtocol.encodeClear();
    _espPolygonId = 0;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _dropLink();
    _disposed = true;
    await _statusCtrl.close();
    await _msgCtrl.close();
  }

  // --- Lado ESP simulado ----------------------------------------------------

  void _espReceiveCommandLine(String line) {
    _lastLine = line;
    final ControlCommand cmd;
    try {
      cmd = ControlCommand.fromJsonLine(line);
    } on FormatException {
      return; // un ESP real descartaría la línea sin ACK
    }
    _lastReceived = cmd;
    _receivedCount++;
    _history.add(cmd);
    if (_history.length > historyLimit) _history.removeAt(0);

    // "Más de 300 ms" (AUD-01/AUD-11): se guarda el instante y la antigüedad
    // se evalúa al consultar (ver _espCommandFresh). El timer es solo respaldo.
    _lastReceivedAt = monotonicClock();
    _espStaleTimerFired = false;
    _espStaleTimer?.cancel();
    _espStaleTimer = Timer(espStaleTimerDelay, () {
      _espStaleTimerFired = true;
    });

    // ACK de RECEPCIÓN (no de ejecución), pasando por el codec como el real.
    _emitLine(EspProtocol.encodeAck(cmd.seq));
  }

  void _espReceivePolygonLine(String line) {
    _lastLine = line;
    final r = EspProtocol.parsePolygonLine(line);
    if (r.isValid) {
      _espPolygonId = r.id!; // doble buffer: solo pasa a vigente si es válido
      _emitLine(EspProtocol.encodePok(r.id!));
    } else {
      _emitLine(EspProtocol.encodePerr(id: r.id, code: r.error!));
    }
  }

  void _emitLine(String line) {
    final msg = EspProtocol.decodeEspLine(line);
    if (msg != null) _add(msg);
  }

  void _emitFakeGps() {
    _add(const GpsFix(
      lat: fakeLat,
      lon: fakeLon,
      fixQuality: 1, // "con fix" para que la UI muestre la posición de prueba
      satellites: null, // sin datos inventados de calidad
      hdop: null,
      simulated: true,
    ));
  }

  void _add(RobotMessage m) {
    if (!_msgCtrl.isClosed) _msgCtrl.add(m);
  }

  void _setStatus(LinkStatus s) {
    if (_status == s) return;
    _status = s;
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
  }
}
