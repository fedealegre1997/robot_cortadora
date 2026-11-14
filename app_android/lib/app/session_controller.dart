// Controlador de sesión de la app E7 (Agente 2).
//
// Guarda lo que la app PIDE (state, dir, speed, cutter, trimmer) y lo envía
// al robot con un heartbeat a 10 Hz mientras haya conexión.
//
// Principio de autoridad (Directiva §3/§4): la app PIDE, la Raspberry DECIDE.
// Este controlador nunca asume que un comando se ejecutó: solo sabe lo que
// envió. No hay telemetría del robot, motores ni herramientas.
//
// Sin dependencias de widgets: se prueba con fake_async y un RobotLink falso.

import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../core/app_config.dart';
import '../core/control_command.dart';
import '../core/robot_link.dart';

/// Duración de un pulso de giro (modo "pulsos").
///
/// VALOR PROVISIONAL: el motor tiene una protección anti-repetición que puede
/// dar giro a tirones, así que todavía no se sabe qué pulso produce un giro
/// útil. Ajustar con pruebas en el robot real. Con el heartbeat a 100 ms, un
/// pulso de 300 ms viaja en unos 3 comandos con dir de giro.
const Duration kTurnPulseDuration = Duration(milliseconds: 300);

/// Velocidad inicial pedida (%). VALOR PROVISIONAL, conservador.
const int kDefaultSpeedPercent = 30;

/// Cómo se comanda el giro (izquierda/derecha).
enum TurnMode {
  /// dir de giro mientras se mantiene apretado, 0 al soltar.
  hold,

  /// Tocar = dir de giro durante [kTurnPulseDuration] y vuelve a 0.
  pulse,
}

/// Notificaciones:
/// - el propio controlador (ChangeNotifier) avisa solo cuando cambia lo
///   PEDIDO, el enlace o lo recibido (acciones del usuario, no el heartbeat);
/// - [sendTicks] avisa en cada envío (10 Hz). Solo lo escuchan las pocas
///   filas del panel que muestran seq / cantidad enviada, para no
///   reconstruir toda la pantalla en cada tick (teléfono de gama baja).
class SessionController extends ChangeNotifier {
  SessionController({
    required RobotLink link,
    required this.config,
    SeqCounter? seqCounter,
    this.pulseDuration = kTurnPulseDuration,
  })  : _link = link,
        _seq = seqCounter ?? SeqCounter() {
    _status = link.status;
    _statusSub = link.statusStream.listen(_onStatus);
    _messageSub = link.messages.listen(_onMessage);
    if (_status == LinkStatus.connected) {
      _startHeartbeat();
    }
  }

  final RobotLink _link;
  final AppConfig config;
  final SeqCounter _seq;
  final ValueNotifier<int> _sendTicks = ValueNotifier<int>(0);

  /// Duración del pulso de giro (por defecto [kTurnPulseDuration]).
  final Duration pulseDuration;

  late final StreamSubscription<LinkStatus> _statusSub;
  late final StreamSubscription<RobotMessage> _messageSub;

  LinkStatus _status = LinkStatus.disconnected;
  Timer? _heartbeat;
  Timer? _pulseTimer;
  bool _disposed = false;

  // ---- Lo pedido -----------------------------------------------------------
  RobotState _state = RobotState.stop;
  Direction _dir = Direction.none;
  int _speed = kDefaultSpeedPercent;
  bool _cutter = false;
  bool _trimmer = false;
  TurnMode _turnMode = TurnMode.hold;

  // ---- Lo enviado / lo recibido -------------------------------------------
  int? _lastSentSeq;
  int _sentCount = 0;
  GpsFix? _lastGps;
  int? _lastAckSeq;
  RobotMessage? _lastAreaResponse;
  String? _lastError;

  // ==== Getters =============================================================

  LinkStatus get linkStatus => _status;
  bool get isConnected => _status == LinkStatus.connected;
  bool get isSimulated => _link.isSimulated;
  bool get toolsEnabled => config.toolsEnabled;

  /// Cantidad de comandos enviados; notifica en cada envío (ver clase).
  ValueListenable<int> get sendTicks => _sendTicks;
  TurnMode get turnMode => _turnMode;
  bool get heartbeatActive => _heartbeat != null;

  /// Estado pedido.
  RobotState get state => _state;

  /// Dirección pedida. Fuera de MANUAL siempre es [Direction.none].
  Direction get dir => _state == RobotState.manual ? _dir : Direction.none;

  /// Velocidad elegida por el usuario (se conserva entre STOPs).
  int get selectedSpeed => _speed;

  /// Velocidad que viaja en el comando: 0 en STOP (como `safeStop`).
  int get outgoingSpeed => _state == RobotState.stop ? 0 : _speed;

  /// Cortadora pedida. Siempre false si las herramientas están bloqueadas o
  /// el estado es STOP.
  bool get cutter =>
      config.toolsEnabled && _state != RobotState.stop && _cutter;

  /// Bordeadora pedida. Mismas reglas que [cutter].
  bool get trimmer =>
      config.toolsEnabled && _state != RobotState.stop && _trimmer;

  /// seq del último comando entregado al enlace (null si no se envió nada).
  int? get lastSentSeq => _lastSentSeq;

  /// Cantidad de comandos entregados al enlace en esta sesión.
  int get sentCount => _sentCount;

  /// Frecuencia nominal del heartbeat en Hz.
  double get heartbeatHz =>
      Duration.millisecondsPerSecond / AppConfig.heartbeatPeriod.inMilliseconds;

  /// Última posición GPS reportada por el ESP.
  GpsFix? get lastGps => _lastGps;

  /// seq del último ACK: significa "recibido por el ESP", NUNCA "ejecutado".
  int? get lastAckSeq => _lastAckSeq;

  /// Última respuesta de área (PolygonAccepted / PolygonRejected).
  RobotMessage? get lastAreaResponse => _lastAreaResponse;

  /// Último error de envío/conexión (texto para mostrar).
  String? get lastError => _lastError;

  // ==== Conexión ============================================================

  Future<void> connect() async {
    _lastError = null;
    try {
      await _link.connect();
    } catch (e) {
      _lastError = 'No se pudo conectar: $e';
      _notify();
    }
  }

  /// Envía STOP de inmediato y después desconecta.
  Future<void> disconnect() async {
    stop();
    try {
      await _link.disconnect();
    } catch (e) {
      _lastError = 'Error al desconectar: $e';
      _notify();
    }
  }

  // ==== Pedidos =============================================================

  /// STOP: state STOP, dir 0, speed 0, cutter 0, trimmer 0. Se envía de
  /// inmediato (si hay conexión), además del heartbeat.
  void stop() {
    _resetToSafeStop();
    _sendCurrent();
    _notify();
  }

  /// Pide un estado. STOP equivale a [stop]. Fuera de MANUAL, dir = 0.
  /// AUTO_RUN / AUTO_PAUSE solo cambian `state`: la Raspberry decide (y sin
  /// un polígono válido no permite AUTO_RUN).
  void requestState(RobotState newState) {
    if (newState == RobotState.stop) {
      stop();
      return;
    }
    if (!isConnected) return; // sin enlace todo queda en STOP
    final hadMotion = _dir != Direction.none;
    _state = newState;
    if (newState != RobotState.manual) {
      _clearDirection();
      if (hadMotion) _sendCurrent(); // bajar la dirección cuanto antes
    }
    _notify();
  }

  /// Apretar un control de dirección (modo "mantener"). Solo en MANUAL.
  void pressDirection(Direction d) {
    if (d == Direction.none) {
      releaseDirection();
      return;
    }
    if (_state != RobotState.manual || !isConnected) return;
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _dir = d;
    _notify();
  }

  /// Soltar cualquier control de dirección → dir = 0, con envío inmediato.
  void releaseDirection() {
    if (_dir == Direction.none && _pulseTimer == null) return;
    _clearDirection();
    _sendCurrent();
    _notify();
  }

  /// Pulso de giro: dir de giro durante [pulseDuration] y vuelve a 0.
  /// Solo izquierda/derecha y solo en MANUAL.
  void pulseTurn(Direction d) {
    if (d != Direction.left && d != Direction.right) {
      throw ArgumentError.value(d, 'd', 'el pulso solo admite left/right');
    }
    if (_state != RobotState.manual || !isConnected) return;
    _pulseTimer?.cancel();
    _dir = d;
    _pulseTimer = Timer(pulseDuration, () {
      _pulseTimer = null;
      if (_dir == d) {
        _dir = Direction.none;
        _sendCurrent();
        _notify();
      }
    });
    _notify();
  }

  void setTurnMode(TurnMode mode) {
    if (mode == _turnMode) return;
    _turnMode = mode;
    // Cambiar de modo nunca deja un giro "colgado".
    if (_dir == Direction.left || _dir == Direction.right) {
      releaseDirection();
    }
    _notify();
  }

  /// Velocidad pedida 0–100 %. Fuera de rango lanza [RangeError] (no se
  /// recorta en silencio).
  void setSpeed(int percent) {
    RangeError.checkValueInInterval(percent, 0, 100, 'percent');
    _speed = percent;
    _notify();
  }

  /// Pedido de cortadora. Con `toolsEnabled == false` se ignora y queda en 0.
  void setCutter(bool on) {
    _cutter = _toolRequestAllowed(on);
    _notify();
  }

  /// Pedido de bordeadora. Con `toolsEnabled == false` se ignora y queda en 0.
  void setTrimmer(bool on) {
    _trimmer = _toolRequestAllowed(on);
    _notify();
  }

  bool _toolRequestAllowed(bool on) =>
      on && config.toolsEnabled && isConnected && _state != RobotState.stop;

  // ==== Ciclo de vida =======================================================

  /// Cualquier estado distinto de `resumed` (inactive, hidden, paused,
  /// detached) → STOP seguro y envío inmediato. Al volver queda en STOP.
  void handleLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle != AppLifecycleState.resumed) {
      stop();
    }
  }

  // ==== Internos ============================================================

  void _onStatus(LinkStatus newStatus) {
    final wasConnected = _status == LinkStatus.connected;
    _status = newStatus;
    final nowConnected = newStatus == LinkStatus.connected;
    if (nowConnected && !wasConnected) {
      // Al (re)conectar se arranca SIEMPRE en STOP: nunca se retoma lo anterior.
      _resetToSafeStop();
      _startHeartbeat();
    } else if (!nowConnected) {
      // Pérdida de conexión: lo pedido pasa a STOP seguro.
      _stopHeartbeat();
      _resetToSafeStop();
    }
    _notify();
  }

  void _onMessage(RobotMessage message) {
    switch (message) {
      case GpsFix():
        _lastGps = message;
      case CommandAck():
        _lastAckSeq = message.seq;
      case PolygonAccepted():
      case PolygonRejected():
        _lastAreaResponse = message;
    }
    _notify();
  }

  void _resetToSafeStop() {
    _state = RobotState.stop;
    _clearDirection();
    _cutter = false;
    _trimmer = false;
  }

  void _clearDirection() {
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _dir = Direction.none;
  }

  void _startHeartbeat() {
    // `??=`: nunca hay dos timers. Los cambios de UI no lo tocan.
    _heartbeat ??=
        Timer.periodic(AppConfig.heartbeatPeriod, (_) => _sendCurrent());
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  /// Arma el comando con lo pedido y un seq nuevo, y lo entrega al enlace.
  void _sendCurrent() {
    if (_disposed || _status != LinkStatus.connected) return;
    final ControlCommand command;
    try {
      command = ControlCommand(
        state: _state,
        dir: dir,
        speed: outgoingSpeed,
        cutter: cutter ? 1 : 0,
        trimmer: trimmer ? 1 : 0,
        seq: _seq.next(),
        // Defensa en profundidad: además de los getters, la política del core.
      ).applyToolsPolicy(toolsEnabled: config.toolsEnabled);
    } catch (e) {
      _lastError = 'No se pudo armar el comando: $e';
      return;
    }
    _lastSentSeq = command.seq;
    _sentCount++;
    unawaited(_deliver(command));
    if (!_disposed) _sendTicks.value = _sentCount;
  }

  Future<void> _deliver(ControlCommand command) async {
    try {
      await _link.sendCommand(command);
    } catch (e) {
      _lastError = 'Error al enviar: $e';
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopHeartbeat();
    _pulseTimer?.cancel();
    _pulseTimer = null;
    unawaited(_statusSub.cancel());
    unawaited(_messageSub.cancel());
    _sendTicks.dispose();
    super.dispose();
  }
}
