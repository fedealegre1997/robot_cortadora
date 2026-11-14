// Auditor (Agente 4): dobles de prueba PROPIOS, independientes de los del
// Agente 2 (test/app/fakes.dart). No termina en _test: no es un test.
//
// RecordingLink: RobotLink en memoria que registra TODO lo que le entrega el
// controlador, SIN aplicar la política de herramientas (así se audita al
// controlador por sí solo). A diferencia del fake del Agente 2, sus streams
// son ASÍNCRONOS (broadcast sin `sync`), igual que los enlaces reales del
// core: los cambios de estado le llegan al controlador en una microtarea.

import 'dart:async';
import 'dart:convert';

import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';

class RecordingLink implements RobotLink {
  RecordingLink({this.clock, this.isSimulated = true});

  final Duration Function()? clock;

  @override
  final bool isSimulated;

  final _status = StreamController<LinkStatus>.broadcast();
  final _msgs = StreamController<RobotMessage>.broadcast();
  LinkStatus _s = LinkStatus.disconnected;

  final List<ControlCommand> sent = [];
  final List<Duration> sentAt = [];

  /// Líneas JSON tal como saldrían por el enlace (sin filtrar).
  final List<String> lines = [];

  void setStatus(LinkStatus s) {
    _s = s;
    _status.add(s);
  }

  void emit(RobotMessage m) => _msgs.add(m);

  @override
  LinkStatus get status => _s;

  @override
  Stream<LinkStatus> get statusStream => _status.stream;

  @override
  Stream<RobotMessage> get messages => _msgs.stream;

  @override
  Future<void> connect() async {
    setStatus(LinkStatus.connecting);
    setStatus(LinkStatus.connected);
  }

  @override
  Future<void> disconnect() async => setStatus(LinkStatus.disconnected);

  @override
  Future<void> sendCommand(ControlCommand command) async {
    if (_s != LinkStatus.connected) return;
    sent.add(command);
    sentAt.add(clock?.call() ?? Duration.zero);
    lines.add(command.toJsonLine());
  }

  @override
  Future<void> sendPolygon(int id, List<(int, int)> points) async {}

  @override
  Future<void> clearPolygon() async {}

  @override
  Future<void> dispose() async {
    await _status.close();
    await _msgs.close();
  }
}

/// Oráculo INDEPENDIENTE del parser del Agente 1: valida una línea de comando
/// contra el contrato (campos, orden propuesto, enteros, rangos). Devuelve
/// null si es válida o el motivo.
String? auditCommandLine(String line) {
  if (!line.endsWith('\n')) return 'no termina en \\n';
  if ('\n'.allMatches(line).length != 1) return 'más de un \\n';
  final body = line.substring(0, line.length - 1);
  final re = RegExp(r'^\{"t":"CMD","state":(-?\d+),"dir":(-?\d+),"speed":(-?\d+),'
      r'"cutter":(-?\d+),"trimmer":(-?\d+),"seq":(-?\d+)\}$');
  final m = re.firstMatch(body);
  if (m == null) return 'forma inesperada: $body';
  final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  const lo = [0, 0, 0, 0, 0, 0];
  const hi = [3, 4, 100, 1, 1, 65535];
  const names = ['state', 'dir', 'speed', 'cutter', 'trimmer', 'seq'];
  for (var i = 0; i < 6; i++) {
    if (v[i] < lo[i] || v[i] > hi[i]) return '${names[i]}=${v[i]} fuera de rango';
  }
  // además debe ser JSON válido
  try {
    jsonDecode(body);
  } on FormatException catch (e) {
    return 'JSON inválido: $e';
  }
  return null;
}
