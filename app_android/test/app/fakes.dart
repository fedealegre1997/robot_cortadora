// Dobles de prueba PROPIOS del Agente 2 (no son tests: no terminan en _test).
//
// FakeRobotLink: RobotLink en memoria que registra lo enviado SIN filtrar las
// herramientas (así se verifica al controlador por sí solo). Los comandos y
// el seq son los reales del core (ControlCommand / SeqCounter).

import 'dart:async';

import 'package:cortadora_e7/app/session_controller.dart';
import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';

class FakeRobotLink implements RobotLink {
  FakeRobotLink({this.isSimulated = true, this.clock});

  @override
  final bool isSimulated;

  /// Reloj para sellar cada envío (en fake_async: `() => async.elapsed`).
  final Duration Function()? clock;

  final _statusCtrl = StreamController<LinkStatus>.broadcast(sync: true);
  final _messageCtrl = StreamController<RobotMessage>.broadcast(sync: true);
  LinkStatus _status = LinkStatus.disconnected;

  /// Comandos entregados mientras estaba conectado.
  final List<ControlCommand> sent = [];
  final List<Duration> sentAt = [];

  void setStatus(LinkStatus s) {
    _status = s;
    _statusCtrl.add(s);
  }

  void emit(RobotMessage m) => _messageCtrl.add(m);

  @override
  LinkStatus get status => _status;

  @override
  Stream<LinkStatus> get statusStream => _statusCtrl.stream;

  @override
  Stream<RobotMessage> get messages => _messageCtrl.stream;

  @override
  Future<void> connect() async {
    setStatus(LinkStatus.connecting);
    setStatus(LinkStatus.connected);
  }

  @override
  Future<void> disconnect() async => setStatus(LinkStatus.disconnected);

  @override
  Future<void> sendCommand(ControlCommand command) async {
    if (_status != LinkStatus.connected) return;
    sent.add(command);
    sentAt.add(clock?.call() ?? Duration.zero);
  }

  @override
  Future<void> sendPolygon(int id, List<(int, int)> points) async {}

  @override
  Future<void> clearPolygon() async {}

  @override
  Future<void> dispose() async {
    await _statusCtrl.close();
    await _messageCtrl.close();
  }
}

/// Controlador sobre el enlace falso.
SessionController makeController(
  FakeRobotLink link, {
  bool toolsEnabled = false,
  int seqStart = 0,
}) =>
    SessionController(
      link: link,
      config: AppConfig(toolsEnabled: toolsEnabled),
      seqCounter: SeqCounter(seqStart),
    );
