// Barrido del ciclo de vida de BleRobotLink con ASYNC REAL (sin fake_async:
// con fake_async el cierre se congela después del primer await, ver
// AUDITORIA.md, Ronda 3).
//
// Invariantes que se verifican en cada combinación (expectConsistent):
//   I1  connected ⇒ transporte abierto; disconnected ⇒ transporte cerrado.
//   I2  nunca un open() empieza mientras corre un close() (close() durante
//       open() sí está permitido: es la cancelación del contrato).
//   I3  nada de una generación vieja se escribe en la nueva; nunca se escribe
//       con el transporte cerrado.
//   I4  STOP de la conexión vigente en < 300 ms.
//   I5  sin StateError por streams cerrados; todo Future completa.
//   I6  sin fugas: conectado ⇒ 1 escucha de rx y de linkLost; si no, 0.

import 'dart:async';
import 'dart:convert';

import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/ble_robot_link.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:flutter_test/flutter_test.dart';

const off = AppConfig(toolsEnabled: false);
const square = [(0, 0), (0, 100), (100, 100), (100, 0)];

/// Transporte falso que CUMPLE el contrato de [BleTransport] (close() cancela
/// un open() en curso) y registra violaciones de las invariantes.
class LifecycleTransport implements BleTransport {
  LifecycleTransport({bool syncLost = false}) {
    _lost = StreamController<void>.broadcast(
      sync: syncLost,
      onListen: () => lostListeners++,
      onCancel: () => lostListeners--,
    );
    _rx = StreamController<List<int>>.broadcast(
      onListen: () => rxListeners++,
      onCancel: () => rxListeners--,
    );
  }

  late final StreamController<void> _lost;
  late final StreamController<List<int>> _rx;
  int rxListeners = 0;
  int lostListeners = 0;

  bool isOpen = false;
  int connection = 0;
  final List<String> events = [];
  final List<String> violations = [];

  // Control de tiempos.
  Completer<void>? openGate; // open() espera esto
  Completer<void>? closeGate; // close() espera esto
  Object? openError; // el próximo open() falla con esto
  bool loseLinkAtEndOfOpen = false; // caída justo al terminar open()
  bool holdWrites = false;
  final List<Completer<void>> held = [];

  int _closing = 0;
  Completer<void>? _cancelOpen;

  final List<(int, List<int>)> writes = [];

  @override
  String? get unavailableReason => null;
  @override
  int get mtu => 517;
  @override
  Stream<List<int>> get received => _rx.stream;
  @override
  Stream<void> get linkLost => _lost.stream;

  @override
  Future<void> open() async {
    if (_closing > 0) violations.add('open() con un close() en curso');
    final n = ++connection;
    events.add('open#$n');
    final cancel = _cancelOpen = Completer<void>();
    try {
      final gate = openGate;
      if (gate != null) {
        await Future.any([gate.future, cancel.future]);
      } else {
        await Future<void>.delayed(Duration.zero);
      }
      if (cancel.isCompleted) {
        events.add('open#$n cancelado');
        throw const BleLinkException('conexión cancelada');
      }
      final err = openError;
      if (err != null) {
        openError = null;
        events.add('open#$n falló');
        throw err;
      }
      isOpen = true;
      events.add('open#$n ok');
      if (loseLinkAtEndOfOpen) {
        loseLinkAtEndOfOpen = false;
        _lost.add(null);
      }
    } finally {
      if (identical(_cancelOpen, cancel)) _cancelOpen = null;
    }
  }

  @override
  Future<void> close() async {
    _closing++;
    events.add('close');
    final c = _cancelOpen;
    if (c != null && !c.isCompleted) c.complete(); // contrato: cancela open()
    isOpen = false;
    try {
      final gate = closeGate;
      if (gate != null) await gate.future;
    } finally {
      _closing--;
    }
  }

  @override
  Future<void> write(List<int> chunk) {
    if (!isOpen) violations.add('write con el transporte cerrado');
    writes.add((connection, List.of(chunk)));
    if (!holdWrites) return Future.value();
    final c = Completer<void>();
    held.add(c);
    return c.future;
  }

  void loseLink() => _lost.add(null);

  List<ControlCommand> commands(int conn) {
    final bytes = [
      for (final (c, chunk) in writes)
        if (c == conn) ...chunk
    ];
    final parts = utf8.decode(bytes, allowMalformed: true).split('\n');
    return [
      for (final l in parts.sublist(0, parts.length - 1))
        if (l.startsWith('{"t":"CMD"')) ControlCommand.fromJsonLine(l),
    ];
  }

  int get totalWrites => writes.length;
}

ControlCommand manual(int seq) => ControlCommand(
    state: RobotState.manual,
    dir: Direction.forward,
    speed: 60,
    cutter: 1,
    trimmer: 1,
    seq: seq);

ControlCommand stopCmd(int seq) => ControlCommand.safeStop(seq);

Future<void> settle() => pumpEventQueue(times: 50);

/// I1, I2, I3 (escritura con transporte cerrado), I6.
void expectConsistent(BleRobotLink link, LifecycleTransport t, {String why = ''}) {
  expect(t.violations, isEmpty, reason: '$why eventos=${t.events}');
  switch (link.status) {
    case LinkStatus.connected:
      expect(t.isOpen, isTrue, reason: '$why connected con el transporte cerrado ${t.events}');
      expect((t.rxListeners, t.lostListeners), (1, 1), reason: '$why escuchas');
    case LinkStatus.disconnected:
      expect(t.isOpen, isFalse, reason: '$why disconnected con el transporte abierto ${t.events}');
      expect((t.rxListeners, t.lostListeners), (0, 0), reason: '$why fuga de escuchas');
    case LinkStatus.connecting:
      fail('$why quedó en connecting en reposo');
  }
}

/// I4: el STOP de la conexión vigente sale en < 300 ms.
Future<void> expectStopFast(BleRobotLink link, LifecycleTransport t, int seq) async {
  expect(link.status, LinkStatus.connected);
  final sw = Stopwatch()..start();
  await link.sendCommand(stopCmd(seq));
  while (!t.commands(t.connection).any((c) => c.seq == seq) &&
      sw.elapsed < const Duration(milliseconds: 300)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(t.commands(t.connection).map((c) => c.seq), contains(seq),
      reason: 'STOP no salió en ${sw.elapsed}');
  expect(sw.elapsed, lessThan(const Duration(milliseconds: 300)));
}

Future<(BleRobotLink, LifecycleTransport)> connectedLink({bool syncLost = false}) async {
  final t = LifecycleTransport(syncLost: syncLost);
  final link = BleRobotLink.withTransport(off, t);
  await link.connect();
  await settle();
  expect(link.status, LinkStatus.connected);
  return (link, t);
}

void main() {
  group('connect / connect', () {
    test('C1 dos connect() concurrentes: un solo open(), mismo resultado', () async {
      final t = LifecycleTransport();
      final link = BleRobotLink.withTransport(off, t);
      final a = link.connect();
      final b = link.connect();
      await Future.wait([a, b]);
      await settle();
      expect(t.events.where((e) => e.startsWith('open#') && !e.contains(' ')), ['open#1']);
      expectConsistent(link, t);
      await expectStopFast(link, t, 1);
      await link.dispose();
    });

    test('C2 connect() ya conectado: no hace nada', () async {
      final (link, t) = await connectedLink();
      await link.connect();
      await settle();
      expect(t.connection, 1);
      expectConsistent(link, t);
      await link.dispose();
    });
  });

  group('disconnect durante connect', () {
    test('C3 ANTES del open() (el open espera el cierre anterior): no abre', () async {
      final (link, t) = await connectedLink();
      t.closeGate = Completer<void>();
      t.loseLink();
      await settle();
      final c = link.connect(); // espera al close() colgado
      await settle();
      expect(link.status, LinkStatus.connecting);
      expect(t.connection, 1, reason: 'el open() nuevo no puede empezar antes del close()');
      final d = link.disconnect();
      expect(link.status, LinkStatus.disconnected);
      t.closeGate!.complete();
      t.closeGate = null;
      await Future.wait([c, d]);
      await settle();
      expect(t.connection, 1, reason: 'cancelado antes de abrir: no abre nada');
      expectConsistent(link, t);
      await link.dispose();
    });

    test('C4 DURANTE el open(): se cancela, connect() completa sin error, queda cerrado',
        () async {
      final t = LifecycleTransport()..openGate = Completer<void>();
      final link = BleRobotLink.withTransport(off, t);
      final c = link.connect();
      await settle();
      expect(t.events, ['open#1']);
      await link.disconnect(); // close() cancela el open() (contrato)
      await c;
      await settle();
      expect(link.status, LinkStatus.disconnected);
      expect(t.events.last, 'close');
      expectConsistent(link, t);
      await link.dispose();
    });

    test('C5 DESPUÉS del open() (ya conectado): cierra', () async {
      final (link, t) = await connectedLink();
      await link.disconnect();
      await settle();
      expectConsistent(link, t);
      await link.dispose();
    });

    test('C6 disconnect durante open() y connect() inmediato: el nuevo SÍ conecta', () async {
      final t = LifecycleTransport()..openGate = Completer<void>();
      final link = BleRobotLink.withTransport(off, t);
      final c1 = link.connect();
      await settle();
      final d = link.disconnect();
      t.openGate = null;
      final c2 = link.connect(); // el usuario vuelve a apretar "conectar"
      await Future.wait([c1, d, c2]);
      await settle();
      expect(link.status, LinkStatus.connected,
          reason: 'el connect() nuevo no puede devolver el intento cancelado ${t.events}');
      expectConsistent(link, t);
      await expectStopFast(link, t, 1);
      await link.dispose();
    });
  });

  group('pérdidas del enlace', () {
    test('C7 pérdida DURANTE el open(): queda desconectado y cerrado', () async {
      final t = LifecycleTransport()..openGate = Completer<void>();
      final link = BleRobotLink.withTransport(off, t);
      final c = link.connect();
      await settle();
      t.loseLink();
      await c;
      await settle();
      expectConsistent(link, t);
      // y se puede volver a conectar en seguida
      t.openGate = null;
      await link.connect();
      await settle();
      expectConsistent(link, t);
      expect(link.status, LinkStatus.connected);
      await link.dispose();
    });

    test('C8 pérdida al TERMINAR el open() (antes de pasar a connected)', () async {
      for (final syncLost in [false, true]) {
        final t = LifecycleTransport(syncLost: syncLost)..loseLinkAtEndOfOpen = true;
        final link = BleRobotLink.withTransport(off, t);
        await link.connect();
        await settle();
        expectConsistent(link, t, why: 'syncLost=$syncLost');
        expect(link.status, LinkStatus.disconnected);
        await link.dispose();
      }
    });

    test('C9 pérdida DURANTE el cierre (close colgado) y doble pérdida: un solo close()',
        () async {
      final (link, t) = await connectedLink();
      t.closeGate = Completer<void>();
      t.loseLink();
      t.loseLink(); // doble pérdida
      await settle();
      t.loseLink(); // pérdida durante el cierre
      await settle();
      expect(t.events.where((e) => e == 'close'), hasLength(1));
      t.closeGate!.complete();
      t.closeGate = null;
      await settle();
      expectConsistent(link, t);
      await link.dispose();
    });

    test('C10 pérdida de la conexión VIEJA llegando tarde no afecta a la nueva', () async {
      final (link, t) = await connectedLink(syncLost: true);
      t.loseLink();
      await link.connect();
      await settle();
      // un aviso tardío de la caída anterior no existe para la generación nueva,
      // pero una caída REAL de la nueva sí se detecta:
      expectConsistent(link, t);
      t.loseLink();
      await settle();
      expect(link.status, LinkStatus.disconnected);
      expectConsistent(link, t);
      await link.dispose();
    });

    test('C11 reconexión INMEDIATA tras pérdida, 30 veces (desde el aviso de estado y '
        'directa): sin cruces, STOP < 300 ms en cada conexión', () async {
      final t = LifecycleTransport();
      final link = BleRobotLink.withTransport(off, t);
      var autoReconnect = true;
      final sub = link.statusStream.listen((s) {
        if (s == LinkStatus.disconnected && autoReconnect) link.connect();
      });
      await link.connect();
      var seq = 0;
      for (var k = 0; k < 30; k++) {
        await settle();
        expect(link.status, LinkStatus.connected, reason: 'ciclo $k ${t.events}');
        expectConsistent(link, t, why: 'ciclo $k');
        final conn = t.connection;
        t.holdWrites = true;
        unawaited(link.sendCommand(manual(seq++))); // queda colgado
        await link.sendCommand(stopCmd(seq++)); // pendiente
        t.holdWrites = false;
        t.loseLink();
        if (k.isOdd) await link.connect(); // además, reconexión directa
        await settle();
        expect(t.commands(t.connection), isEmpty,
            reason: 'ciclo $k: algo de la conexión $conn salió por la ${t.connection}');
        await expectStopFast(link, t, seq++);
      }
      autoReconnect = false;
      await sub.cancel();
      for (final c in t.held) {
        c.complete();
      }
      await settle();
      expect(t.violations, isEmpty);
      await link.dispose();
      await settle();
      expectConsistent(link, t);
    });
  });

  group('dispose', () {
    test('C12 dispose DURANTE connect (open colgado): todo completa, streams cerrados',
        () async {
      final t = LifecycleTransport()..openGate = Completer<void>();
      final link = BleRobotLink.withTransport(off, t);
      var statusDone = false, msgDone = false;
      link.statusStream.listen(null, onDone: () => statusDone = true);
      link.messages.listen(null, onDone: () => msgDone = true);
      final c = link.connect();
      await settle();
      await link.dispose();
      await c;
      await settle();
      expect((statusDone, msgDone), (true, true));
      expectConsistent(link, t);
    });

    test('C13 dispose DURANTE disconnect (close colgado): ambos completan', () async {
      final (link, t) = await connectedLink();
      t.closeGate = Completer<void>();
      final d = link.disconnect();
      final p = link.dispose();
      await settle();
      t.closeGate!.complete();
      t.closeGate = null;
      await Future.wait([d, p]);
      await settle();
      expectConsistent(link, t);
    });

    test('C14 dispose con escrituras COLGADAS: sendCommand completa y sendPolygon falla '
        'en seguida (no esperan a la radio)', () async {
      final (link, t) = await connectedLink();
      t.holdWrites = true;
      final cmd = link.sendCommand(manual(1));
      final poly = link.sendPolygon(1, square);
      final polyResult = poly.then<Object?>((_) => null, onError: (Object e) => e);
      await settle();
      await link.dispose();
      final results = await Future.wait([cmd.then((_) => 'ok'), polyResult])
          .timeout(const Duration(seconds: 1), onTimeout: () => ['colgado', 'colgado']);
      expect(results[0], 'ok', reason: 'sendCommand quedó esperando a la radio');
      expect(results[1], isA<BleLinkException>(), reason: 'sendPolygon: ${results[1]}');
      expectConsistent(link, t);
      for (final c in t.held) {
        c.completeError('timeout tardío'); // no debe producir errores sin manejar
      }
      await settle();
    });

    test('C15 disconnect con escritura colgada: los Futures completan y la reconexión '
        'manda STOP en < 300 ms', () async {
      final (link, t) = await connectedLink();
      t.holdWrites = true;
      final poly = link.sendPolygon(1, square);
      final polyResult = poly.then<Object?>((_) => null, onError: (Object e) => e);
      await settle();
      await link.disconnect();
      final r = await polyResult.timeout(const Duration(seconds: 1), onTimeout: () => 'colgado');
      expect(r, isA<BleLinkException>());
      t.holdWrites = false;
      await link.connect();
      await settle();
      await expectStopFast(link, t, 2);
      expect(t.commands(2).map((c) => c.seq), [2]);
      expectConsistent(link, t);
      await link.dispose();
    });

    test('C16 llamadas DESPUÉS de dispose: completan sin efecto y sin StateError', () async {
      final (link, t) = await connectedLink();
      await link.dispose();
      final writes = t.totalWrites;
      await link.connect();
      await link.disconnect();
      await link.sendCommand(stopCmd(1));
      await link.sendPolygon(1, square);
      await link.clearPolygon();
      expect(() => link.sendPolygon(1, const [(0, 0)]), throwsArgumentError);
      t.loseLink();
      t._rx.add(utf8.encode('{"t":"POK","id":1}\n'));
      await link.dispose(); // idempotente
      await settle();
      expect(t.totalWrites, writes);
      expect(t.connection, 1);
      expect(link.status, LinkStatus.disconnected);
      expectConsistent(link, t);
    });
  });

  group('envíos durante cada transición', () {
    test('C17 sendCommand/sendPolygon durante connecting, closing y recién conectado',
        () async {
      final t = LifecycleTransport()..openGate = Completer<void>();
      final link = BleRobotLink.withTransport(off, t);
      final c = link.connect();
      await settle();
      // connecting: no se escribe nada (todavía no hay conexión)
      await link.sendCommand(stopCmd(1));
      await link.sendPolygon(1, square);
      expect(t.totalWrites, 0);
      t.openGate!.complete();
      t.openGate = null;
      await c;
      // recién conectado: sale por la conexión 1
      await expectStopFast(link, t, 2);
      // closing (close colgado): nada se escribe
      t.closeGate = Completer<void>();
      final d = link.disconnect();
      final before = t.totalWrites;
      await link.sendCommand(stopCmd(3));
      await link.sendPolygon(2, square);
      await link.clearPolygon();
      expect(t.totalWrites, before);
      t.closeGate!.complete();
      t.closeGate = null;
      await d;
      await settle();
      expect(t.commands(1).map((c) => c.seq), [2]);
      expectConsistent(link, t);
      await link.dispose();
    });

    test('C18 comando en vuelo cuando se cae el enlace: no sale por la conexión nueva',
        () async {
      final (link, t) = await connectedLink();
      t.holdWrites = true;
      final first = link.sendCommand(manual(1));
      await settle();
      await link.sendCommand(manual(2)); // pendiente
      t.loseLink();
      await settle();
      t.holdWrites = false;
      await link.connect();
      for (final h in t.held) {
        h.complete(); // la escritura vieja termina DESPUÉS de reconectar
      }
      await first;
      await settle();
      await expectStopFast(link, t, 3);
      expect(t.commands(2).map((c) => c.seq), [3]);
      expectConsistent(link, t);
      await link.dispose();
    });
  });

  group('fallos', () {
    test('C19 open() falla: error al llamador, desconectado, cerrado, sin fugas; '
        'reconectar funciona', () async {
      final t = LifecycleTransport()..openError = StateError('GATT 133');
      final link = BleRobotLink.withTransport(off, t);
      await expectLater(link.connect(), throwsA(isA<StateError>()));
      await settle();
      expectConsistent(link, t);
      await link.connect();
      await settle();
      expectConsistent(link, t);
      expect(link.status, LinkStatus.connected);
      await link.dispose();
    });

    test('C20 sin fugas tras 50 ciclos conectar/caer/desconectar y dispose', () async {
      final t = LifecycleTransport();
      final link = BleRobotLink.withTransport(off, t);
      for (var k = 0; k < 50; k++) {
        await link.connect();
        if (k.isEven) {
          t.loseLink();
        } else {
          await link.disconnect();
        }
        await settle();
        expectConsistent(link, t, why: 'ciclo $k');
      }
      await link.dispose();
      expectConsistent(link, t);
    });
  });
}
