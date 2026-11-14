// Auditor — ronda 3: AUD-12/AUD-13 (generación de conexión) y carreras de
// reconexión en BleRobotLink. Transporte falso PROPIO con registro de eventos
// (open/close/write por conexión). El archivo de la ronda 2
// (audit_ble_test.dart) NO se tocó: sirve de regresión.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/ble_robot_link.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const off = AppConfig(toolsEnabled: false);
const square = [(0, 0), (0, 100), (100, 100), (100, 0)];

class R3Transport implements BleTransport {
  R3Transport({bool syncLost = false})
      : _lost = StreamController<void>.broadcast(sync: syncLost);
  int mtuValue = 517;
  int connection = 0; // sube en cada open()
  bool hold = false;
  final List<String> events = []; // 'open#n', 'close', 'write#n'
  final List<(int, List<int>)> writes = [];
  final List<Completer<void>> held = [];
  final _rx = StreamController<List<int>>.broadcast();
  final StreamController<void> _lost;
  bool get hasLostListener => _lost.hasListener;

  @override
  String? get unavailableReason => null;
  @override
  int get mtu => mtuValue;
  @override
  Stream<List<int>> get received => _rx.stream;
  @override
  Stream<void> get linkLost => _lost.stream;

  @override
  Future<void> open() async {
    connection++;
    events.add('open#$connection');
  }

  @override
  Future<void> close() async => events.add('close');

  @override
  Future<void> write(List<int> chunk) {
    writes.add((connection, List.of(chunk)));
    events.add('write#$connection');
    if (!hold) return Future.value();
    final c = Completer<void>();
    held.add(c);
    return c.future;
  }

  void releaseAll({Object? error}) {
    final l = List.of(held);
    held.clear();
    for (final c in l) {
      error == null ? c.complete() : c.completeError(error);
    }
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
        if (l.contains('"t":"CMD"')) ?_parse(l)
    ];
  }

  static ControlCommand? _parse(String l) {
    try {
      return ControlCommand.fromJsonLine(l);
    } on FormatException {
      return null;
    }
  }
}

ControlCommand manual(int seq) => ControlCommand(
    state: RobotState.manual,
    dir: Direction.forward,
    speed: 60,
    cutter: 1,
    trimmer: 1,
    seq: seq);

ControlCommand stopCmd(int seq) => ControlCommand.safeStop(seq);

void main() {
  test('propiedad multi-conexión (1500 secuencias, semilla 2611): nada cruza de una '
      'conexión a otra y AUD-06 vale dentro de cada conexión', () {
    final rnd = math.Random(2611);
    for (var round = 0; round < 1500; round++) {
      fakeAsync((async) {
        final t = R3Transport();
        final link = BleRobotLink.withTransport(off, t);
        link.connect();
        async.flushMicrotasks();
        final sentIn = <int, List<ControlCommand>>{}; // conexión → enviados
        var seq = 0;
        final n = 5 + rnd.nextInt(40);
        for (var i = 0; i < n; i++) {
          final r = rnd.nextInt(10);
          if (r == 0) {
            t.loseLink(); // caída, con lo que esté retenido o pendiente
            async.flushMicrotasks();
            if (rnd.nextBool()) t.releaseAll(error: rnd.nextBool() ? 'x' : null);
            link.connect();
            async.flushMicrotasks();
            continue;
          }
          if (r == 1) {
            t.hold = !t.hold;
            if (!t.hold) t.releaseAll();
          }
          final cmd = rnd.nextInt(3) == 0 ? stopCmd(seq) : manual(seq);
          seq++;
          if (link.status == LinkStatus.connected) {
            sentIn.putIfAbsent(t.connection, () => []).add(cmd);
          }
          link.sendCommand(cmd);
          if (rnd.nextBool()) async.flushMicrotasks();
        }
        t.hold = false;
        t.releaseAll();
        async.flushMicrotasks();
        for (var conn = 1; conn <= t.connection; conn++) {
          final sent = sentIn[conn] ?? const <ControlCommand>[];
          final sentSeqs = sent.map((c) => c.seq).toSet();
          final out = t.commands(conn);
          final outSeqs = out.map((c) => c.seq).toList();
          // 1) solo sale por la conexión k lo pedido durante la conexión k
          expect(outSeqs.every(sentSeqs.contains), isTrue,
              reason: 'ronda $round conn $conn: salió $outSeqs, pedidos ${sentSeqs.toList()}');
          // 2) orden creciente
          for (var i = 1; i < outSeqs.length; i++) {
            expect(outSeqs[i], greaterThan(outSeqs[i - 1]), reason: 'ronda $round conn $conn');
          }
          // 3) ningún STOP adelantado por un comando posterior
          for (final s in sent.where((c) => c.state == RobotState.stop)) {
            final after = out.where((c) => c.seq >= s.seq);
            if (after.isNotEmpty) {
              expect(after.first.state, RobotState.stop,
                  reason: 'ronda $round conn $conn: STOP ${s.seq} adelantado ($outSeqs)');
            }
          }
        }
        // 4) en la conexión vigente, lo último pedido sale
        if (link.status == LinkStatus.connected) {
          final sent = sentIn[t.connection];
          if (sent != null && sent.isNotEmpty) {
            expect(t.commands(t.connection).last.seq, sent.last.seq, reason: 'ronda $round');
          }
        }
        link.dispose();
        async.flushMicrotasks();
      });
    }
  });

  test('tres caídas seguidas con escrituras colgadas: en cada conexión nueva el STOP sale '
      'en < 300 ms y nada de las viejas', () {
    fakeAsync((async) {
      final t = R3Transport();
      final link = BleRobotLink.withTransport(off, t);
      link.connect();
      async.flushMicrotasks();
      var seq = 0;
      for (var k = 0; k < 3; k++) {
        t.hold = true;
        link.sendCommand(manual(seq++)); // queda colgado
        link.sendCommand(stopCmd(seq++)); // pendiente
        async.flushMicrotasks();
        t.loseLink();
        async.flushMicrotasks();
        link.connect();
        async.flushMicrotasks();
        t.hold = false;
        final stopSeq = seq++;
        final tRe = async.elapsed;
        link.sendCommand(stopCmd(stopSeq));
        async.elapse(const Duration(milliseconds: 100));
        final conn = t.connection;
        expect(t.commands(conn).map((c) => c.seq), contains(stopSeq),
            reason: 'conexión $conn: el STOP no salió en ${async.elapsed - tRe}');
        expect(t.commands(conn).every((c) => c.seq >= stopSeq), isTrue,
            reason: 'conexión $conn: salió algo de antes: ${t.commands(conn).map((c) => c.seq)}');
      }
      // las escrituras viejas terminan tarde (con error): no salen por la vigente
      final conn = t.connection;
      final before = t.commands(conn).length;
      t.releaseAll(error: 'timeout');
      async.flushMicrotasks();
      expect(t.commands(conn).length, before);
      link.dispose();
      async.flushMicrotasks();
    });
  });

  test('pérdida de enlace en medio del await del bucle: el bucle viejo no toca la cola nueva '
      'ni libera el "escribiendo" de la conexión nueva', () {
    fakeAsync((async) {
      final t = R3Transport();
      final link = BleRobotLink.withTransport(off, t);
      link.connect();
      async.flushMicrotasks();
      t.hold = true;
      link.sendCommand(manual(1)); // bucle viejo esperando
      async.flushMicrotasks();
      t.loseLink();
      async.flushMicrotasks();
      link.connect();
      async.flushMicrotasks();
      // conexión nueva: una escritura retenida y un STOP pendiente
      link.sendCommand(manual(2));
      async.flushMicrotasks();
      link.sendCommand(stopCmd(3));
      // ahora termina la escritura VIEJA (la del bucle viejo)
      t.held.first.complete();
      t.held.removeAt(0);
      async.flushMicrotasks();
      // el STOP 3 no debe haber salido todavía (la escritura 2 sigue retenida)…
      expect(t.commands(2).map((c) => c.seq), isNot(contains(3)));
      // …y sale apenas termina la 2, en orden
      t.hold = false;
      t.releaseAll();
      async.flushMicrotasks();
      expect(t.commands(2).map((c) => c.seq).toList(), [2, 3]);
      link.dispose();
      async.flushMicrotasks();
    });
  });

  test('POLY cortado por la caída: sendPolygon informa error (no da por enviado algo que no salió)',
      () {
    fakeAsync((async) {
      final t = R3Transport()..mtuValue = 23; // POLY en varios fragmentos
      final link = BleRobotLink.withTransport(off, t);
      link.connect();
      async.flushMicrotasks();
      t.hold = true;
      Object? err;
      var ok = false;
      link.sendPolygon(1, square).then((_) {
        ok = true;
      }, onError: (Object e) {
        err = e;
      });
      async.flushMicrotasks();
      t.loseLink();
      async.flushMicrotasks();
      t.hold = false;
      t.releaseAll();
      async.flushMicrotasks();
      expect(ok, isFalse);
      expect(err, isA<BleLinkException>());
      link.dispose();
      async.flushMicrotasks();
    });
  });

  // ---------------------------------------------------------------------------
  // Carreras de teardown/reconexión: con RELOJ y microtareas REALES (sin
  // fake_async). Motivo: StreamSubscription.cancel() devuelve un Future ya
  // completado de la zona raíz; con fake_async la continuación de
  // `await _rxSub?.cancel()` va a la cola de microtareas REAL y _teardown()
  // queda congelado durante todo el test (no se ejercita su segunda mitad).
  // ---------------------------------------------------------------------------

  test('tras una caída del enlace, el transporte se CIERRA (async real)', () async {
    for (final syncLost in [false, true]) {
      final t = R3Transport(syncLost: syncLost);
      final link = BleRobotLink.withTransport(off, t);
      await link.connect();
      t.loseLink();
      await pumpEventQueue();
      // ignore: avoid_print
      print('R3 cierre tras caída (syncLost=$syncLost): eventos=${t.events}');
      expect(link.status, LinkStatus.disconnected);
      expect(t.events.last, 'close', reason: 'syncLost=$syncLost eventos=${t.events}');
      await link.dispose();
    }
  });

  test('CARRERA: reconexión desde el aviso de "desconectado" (streams asíncronos, async real) '
      '→ la conexión nueva queda abierta y una caída posterior SE DETECTA', () async {
    final t = R3Transport();
    final link = BleRobotLink.withTransport(off, t);
    link.statusStream.listen((s) {
      if (s == LinkStatus.disconnected && t.connection == 1) link.connect();
    });
    await link.connect();
    t.loseLink();
    await pumpEventQueue();
    // ignore: avoid_print
    print('R3 reconexión desde el aviso: estado=${link.status.name} eventos=${t.events} '
        'escucha linkLost=${t.hasLostListener}');
    expect(link.status, LinkStatus.connected);
    expect(t.connection, 2);
    final afterOpen2 = t.events.sublist(t.events.indexOf('open#2') + 1);
    expect(afterOpen2, isNot(contains('close')),
        reason: 'el transporte de la conexión 2 se cerró después de abrirse: ${t.events}');
    expect(t.hasLostListener, isTrue,
        reason: 'nadie escucha linkLost en la conexión 2: una caída no se detectaría');
    t.loseLink();
    await pumpEventQueue();
    expect(link.status, LinkStatus.disconnected,
        reason: 'la caída de la conexión 2 no se detectó');
    await link.dispose();
  });

  test('CARRERA forzada: connect() mientras _teardown() de la caída sigue en sus await '
      '(intercalado garantizado, async real) → la conexión nueva queda sana', () async {
    // Aviso de caída SÍNCRONO: _onLinkLost corre dentro de loseLink() y
    // _teardown() queda suspendido en su primer await cuando loseLink()
    // vuelve. El connect() siguiente cae garantizado en el medio.
    final t = R3Transport(syncLost: true);
    final link = BleRobotLink.withTransport(off, t);
    await link.connect();
    t.loseLink();
    expect(link.status, LinkStatus.disconnected);
    expect(t.events.contains('close'), isFalse, reason: 'precondición: teardown sin terminar');
    final reconnect = link.connect();
    await reconnect;
    await pumpEventQueue();
    // ignore: avoid_print
    print('R3 carrera forzada: estado=${link.status.name} eventos=${t.events} '
        'escucha linkLost=${t.hasLostListener}');
    expect(link.status, LinkStatus.connected);
    final afterOpen2 = t.events.sublist(t.events.indexOf('open#2') + 1);
    expect(afterOpen2, isNot(contains('close')),
        reason: 'el transporte de la conexión 2 se cerró después de abrirse: ${t.events}');
    expect(t.hasLostListener, isTrue,
        reason: 'nadie escucha linkLost en la conexión 2: una caída no se detectaría');
    t.loseLink();
    await pumpEventQueue();
    expect(link.status, LinkStatus.disconnected,
        reason: 'la caída de la conexión 2 no se detectó');
    await link.dispose();
  });

  test('reconexión "humana" (async real, después de que termina el teardown): 5 ciclos '
      'conectar → STOP → caída, sin cruces', () async {
    final t = R3Transport();
    final link = BleRobotLink.withTransport(off, t);
    for (var k = 1; k <= 5; k++) {
      await link.connect();
      expect(link.status, LinkStatus.connected);
      await link.sendCommand(stopCmd(k));
      expect(t.commands(k).single.seq, k);
      t.loseLink();
      await pumpEventQueue();
      expect(link.status, LinkStatus.disconnected);
      expect(t.events.last, 'close');
    }
    await link.dispose();
  });
}
