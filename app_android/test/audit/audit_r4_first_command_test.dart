// Auditor — ronda 4: ¿qué es lo PRIMERO que sale por una conexión BLE nueva?
// SessionController (Agente 2) + BleRobotLink con transporte falso propio,
// con async y reloj REALES (sin fake_async).
//
// Limitación declarada por el Agente 1: lo que se pide durante `connecting`
// no se transmite; el STOP sale en el primer heartbeat después de conectar.

import 'dart:async';
import 'dart:convert';

import 'package:cortadora_e7/app/session_controller.dart';
import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/ble_robot_link.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:flutter_test/flutter_test.dart';

const on = AppConfig(toolsEnabled: true);

class R4Transport implements BleTransport {
  int connection = 0;
  Completer<void>? openGate;
  final List<(int, Duration, List<int>)> writes = [];
  final Stopwatch sw = Stopwatch()..start();
  final _rx = StreamController<List<int>>.broadcast();
  final _lost = StreamController<void>.broadcast();

  @override
  String? get unavailableReason => null;
  @override
  int get mtu => 517;
  @override
  Stream<List<int>> get received => _rx.stream;
  @override
  Stream<void> get linkLost => _lost.stream;

  Duration? openedAt;

  @override
  Future<void> open() async {
    connection++;
    final g = openGate;
    if (g != null) await g.future;
    openedAt = sw.elapsed;
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> write(List<int> chunk) async =>
      writes.add((connection, sw.elapsed, List.of(chunk)));

  void loseLink() => _lost.add(null);

  /// (comando, instante) escritos en [conn], en orden.
  List<(ControlCommand, Duration)> commands(int conn) {
    final out = <(ControlCommand, Duration)>[];
    var buf = <int>[];
    for (final (c, at, chunk) in writes) {
      if (c != conn) continue;
      buf.addAll(chunk);
      while (buf.contains(0x0A)) {
        final i = buf.indexOf(0x0A);
        final line = utf8.decode(buf.sublist(0, i));
        buf = buf.sublist(i + 1);
        if (line.contains('"t":"CMD"')) out.add((ControlCommand.fromJsonLine(line), at));
      }
    }
    return out;
  }
}

void expectSafeStop(ControlCommand c, String why) {
  expect((c.state, c.dir, c.speed, c.cutter, c.trimmer),
      (RobotState.stop, Direction.none, 0, 0, 0),
      reason: why);
}

void main() {
  test('primera conexión sin tocar nada: lo primero que sale es STOP completo, '
      '≤ ~100 ms después de conectar', () async {
    final t = R4Transport();
    final link = BleRobotLink.withTransport(on, t);
    final c = SessionController(link: link, config: on);
    await c.connect();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final cmds = t.commands(1);
    expect(cmds, isNotEmpty);
    final (first, at) = cmds.first;
    expectSafeStop(first, 'primer comando de la conexión 1: $first');
    final delay = at - t.openedAt!;
    // ignore: avoid_print
    print('R4 primer comando: ${first.state.name} a ${delay.inMilliseconds} ms del open()');
    expect(delay, lessThan(const Duration(milliseconds: 150)),
        reason: 'heartbeat 100 ms + tolerancia del reloj de Windows');
    await c.disconnect();
    c.dispose();
    await link.dispose();
  });

  test('reconexión después de una caída con MANUAL + adelante + herramientas pedidas: '
      'lo primero que sale por la conexión nueva es STOP completo (5 ciclos)', () async {
    final t = R4Transport();
    final link = BleRobotLink.withTransport(on, t);
    final c = SessionController(link: link, config: on);
    for (var k = 1; k <= 5; k++) {
      await c.connect();
      // Se pide DESPUÉS del primer tick (100 ms): así lo que se mide es que
      // nada de la conexión anterior se arrastra (un pedido explícito antes
      // del primer tick es otra cosa: ver la caracterización de abajo).
      await Future<void>.delayed(const Duration(milliseconds: 150));
      c.requestState(RobotState.manual);
      c.setSpeed(90);
      c.setCutter(true);
      c.setTrimmer(true);
      c.pressDirection(Direction.forward);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(t.commands(k).last.$1.dir, Direction.forward, reason: 'ciclo $k: precondición');
      t.loseLink(); // caída con todo "encendido"
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.isConnected, isFalse);
    }
    await c.connect();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    for (var conn = 2; conn <= t.connection; conn++) {
      final cmds = t.commands(conn);
      expect(cmds, isNotEmpty, reason: 'conexión $conn sin comandos');
      expectSafeStop(cmds.first.$1, 'conexión $conn: primer comando ${cmds.first.$1}');
    }
    await c.disconnect();
    c.dispose();
    await link.dispose();
  });

  test('lo que se pide durante `connecting` no sale; al conectar, el primero es STOP '
      '(la app arranca SIEMPRE en STOP)', () async {
    final t = R4Transport()..openGate = Completer<void>();
    final link = BleRobotLink.withTransport(on, t);
    final c = SessionController(link: link, config: on);
    final conn = c.connect();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.linkStatus, LinkStatus.connecting);
    // durante connecting: la UI está bloqueada; el controlador ignora pedidos
    c.requestState(RobotState.manual);
    c.pressDirection(Direction.forward);
    c.setCutter(true);
    c.stop();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(t.writes, isEmpty, reason: 'nada se transmite durante connecting');
    t.openGate!.complete();
    await conn;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expectSafeStop(t.commands(1).first.$1, 'primer comando tras connecting');
    await c.disconnect();
    c.dispose();
    await link.dispose();
  });

  // REGLA NUEVA (Paso 1, aprobada por el usuario): al pasar a connected el
  // controlador manda un STOP inmediato. La caracterización anterior ("pedidos
  // explícitos antes del primer tick salen primero") quedó OBSOLETA y se
  // invierte: ahora el primero es SIEMPRE STOP, y lo pedido sale después.
  test('pedidos EXPLÍCITOS antes del primer tick (100 ms): el primer comando es STOP; '
      'lo pedido sale DESPUÉS, en orden y sin perderse', () async {
    final t = R4Transport();
    final link = BleRobotLink.withTransport(on, t);
    final c = SessionController(link: link, config: on);
    await c.connect();
    await Future<void>.delayed(Duration.zero);
    c.requestState(RobotState.manual);
    c.setCutter(true);
    c.pressDirection(Direction.forward);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final cmds = t.commands(1).map((e) => e.$1).toList();
    // ignore: avoid_print
    print('R4 regla nueva: comandos de la conexión 1 = ${cmds.take(3).toList()}');
    expectSafeStop(cmds.first, 'primer comando de la conexión');
    final firstNonStop = cmds.firstWhere((x) => x.state != RobotState.stop);
    expect(firstNonStop.seq, greaterThan(cmds.first.seq));
    expect((firstNonStop.state, firstNonStop.dir, firstNonStop.cutter),
        (RobotState.manual, Direction.forward, 1),
        reason: 'lo pedido no se pierde');
    await c.disconnect();
    c.dispose();
    await link.dispose();
  });

  test('MANUAL pedido enseguida (< 100 ms): el primer comando sigue siendo un STOP completo',
      () async {
    final t = R4Transport();
    final link = BleRobotLink.withTransport(on, t);
    final c = SessionController(link: link, config: on);
    await c.connect();
    await Future<void>.delayed(Duration.zero);
    c.requestState(RobotState.manual);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expectSafeStop(t.commands(1).first.$1, 'primer comando con MANUAL pedido enseguida');
    await c.disconnect();
    c.dispose();
    await link.dispose();
  });
}
