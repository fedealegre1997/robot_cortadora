// Auditor — ronda 2: BleRobotLink con un transporte falso PROPIO (no el del
// Agente 1). Verifica AUD-05 (costura), AUD-06 (cola con prioridad de STOP,
// condiciones del usuario), política de herramientas y reconexión.
//
// Condiciones del usuario para la cola (AUD-06):
//   (1) un STOP nunca se descarta;
//   (2) un STOP reemplaza cualquier pendiente;
//   (3) los no-STOP pueden coalescer al último;
//   (4) un STOP pendiente NO puede ser reemplazado por un no-STOP posterior:
//       se envía STOP y luego el normal, en orden.

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
const on = AppConfig(toolsEnabled: true);
const square = [(0, 0), (0, 100), (100, 100), (100, 0)];

/// Transporte falso: registra cada fragmento con el número de conexión en
/// que se ENTREGÓ a la radio; puede retener escrituras.
class AuditTransport implements BleTransport {
  int mtuValue = 517;
  int connection = 0;
  bool hold = false;
  final List<(int, List<int>)> writes = [];
  final List<Completer<void>> held = [];
  final _rx = StreamController<List<int>>.broadcast();
  final _lost = StreamController<void>.broadcast();

  @override
  String? get unavailableReason => null;
  @override
  int get mtu => mtuValue;
  @override
  Stream<List<int>> get received => _rx.stream;
  @override
  Stream<void> get linkLost => _lost.stream;

  @override
  Future<void> open() async => connection++;
  @override
  Future<void> close() async {}

  @override
  Future<void> write(List<int> chunk) {
    writes.add((connection, List.of(chunk)));
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

  /// Líneas completas escritas en la conexión [conn] (las que no terminan en
  /// `\n` se ignoran).
  List<String> lines(int conn) {
    final bytes = [
      for (final (c, chunk) in writes)
        if (c == conn) ...chunk
    ];
    final s = utf8.decode(bytes, allowMalformed: true);
    final parts = s.split('\n');
    return parts.sublist(0, parts.length - 1);
  }

  /// Comandos válidos escritos en [conn], en orden.
  List<ControlCommand> commands(int conn) => [
        for (final l in lines(conn))
          if (l.contains('"t":"CMD"')) ?_tryParse(l)
      ];

  static ControlCommand? _tryParse(String l) {
    try {
      return ControlCommand.fromJsonLine(l);
    } on FormatException {
      return null;
    }
  }
}

ControlCommand manual(int seq, {Direction dir = Direction.forward}) =>
    ControlCommand(
        state: RobotState.manual,
        dir: dir,
        speed: 60,
        cutter: 1,
        trimmer: 1,
        seq: seq);

ControlCommand stopCmd(int seq) => ControlCommand.safeStop(seq);

(BleRobotLink, AuditTransport) connected(FakeAsync async, {AppConfig cfg = off}) {
  final t = AuditTransport();
  final link = BleRobotLink.withTransport(cfg, t);
  link.connect();
  async.flushMicrotasks();
  expect(link.status, LinkStatus.connected);
  return (link, t);
}

void main() {
  group('AUD-06: condiciones del usuario sobre la cola', () {
    test('(1)(2)(3)(4) escritura retenida; luego MANUAL×2, STOP, MANUAL×2 → '
        'salen: actual, STOP, último MANUAL', () {
      fakeAsync((async) {
        final (link, t) = connected(async);
        t.hold = true;
        link.sendCommand(manual(1));
        async.flushMicrotasks();
        link.sendCommand(manual(2));
        link.sendCommand(manual(3));
        link.sendCommand(stopCmd(4)); // (2) reemplaza a 2 y 3
        link.sendCommand(manual(5)); // (4) va detrás del STOP
        link.sendCommand(manual(6)); // (3) coalesce: reemplaza a 5
        async.flushMicrotasks();
        t.hold = false;
        t.releaseAll();
        async.flushMicrotasks();
        final out = t.commands(1);
        expect(out.map((c) => c.seq).toList(), [1, 4, 6]);
        expect(out[1].state, RobotState.stop);
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('(4) un no-STOP posterior NUNCA reemplaza al STOP pendiente, aunque lleguen 100',
        () {
      fakeAsync((async) {
        final (link, t) = connected(async);
        t.hold = true;
        link.sendCommand(manual(1));
        async.flushMicrotasks();
        link.sendCommand(stopCmd(2));
        for (var s = 3; s < 103; s++) {
          link.sendCommand(manual(s));
        }
        t.hold = false;
        t.releaseAll();
        async.flushMicrotasks();
        expect(t.commands(1).map((c) => c.seq).toList(), [1, 2, 102]);
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('(1) STOP con error de escritura en la actual: el STOP pendiente sale igual', () {
      fakeAsync((async) {
        final (link, t) = connected(async);
        t.hold = true;
        link.sendCommand(manual(1));
        async.flushMicrotasks();
        link.sendCommand(stopCmd(2));
        t.hold = false;
        t.releaseAll(error: StateError('GATT 133'));
        async.flushMicrotasks();
        expect(t.commands(1).map((c) => c.seq), contains(2));
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('(caracterización) STOP + STOP más nuevo: sale solo el más nuevo '
        '(ambos son STOP seguros; no se pierde la orden de detener)', () {
      fakeAsync((async) {
        final (link, t) = connected(async);
        t.hold = true;
        link.sendCommand(manual(1));
        async.flushMicrotasks();
        link.sendCommand(stopCmd(2));
        link.sendCommand(stopCmd(3));
        t.hold = false;
        t.releaseAll();
        async.flushMicrotasks();
        expect(t.commands(1).map((c) => c.seq).toList(), [1, 3]);
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('propiedad (2000 secuencias aleatorias, semilla fija): ningún STOP es '
        'adelantado por un comando posterior; el orden es creciente; el último sale', () {
      final rnd = math.Random(1311);
      for (var round = 0; round < 2000; round++) {
        fakeAsync((async) {
          final (link, t) = connected(async);
          final sent = <ControlCommand>[];
          var seq = 0;
          final n = 1 + rnd.nextInt(30);
          for (var i = 0; i < n; i++) {
            if (rnd.nextInt(4) == 0) {
              t.hold = !t.hold;
              if (!t.hold) t.releaseAll(error: rnd.nextInt(5) == 0 ? 'err' : null);
            }
            final cmd = rnd.nextInt(3) == 0 ? stopCmd(seq) : manual(seq);
            seq++;
            sent.add(cmd);
            link.sendCommand(cmd);
            if (rnd.nextBool()) async.flushMicrotasks();
          }
          t.hold = false;
          t.releaseAll();
          async.flushMicrotasks();
          final out = t.commands(1);
          final outSeqs = out.map((c) => c.seq).toList();
          // orden de llegada (nunca uno viejo después de uno nuevo)
          for (var i = 1; i < outSeqs.length; i++) {
            expect(outSeqs[i], greaterThan(outSeqs[i - 1]), reason: 'ronda $round $outSeqs');
          }
          // el último comando enviado siempre sale
          expect(outSeqs.last, sent.last.seq, reason: 'ronda $round');
          // para cada STOP enviado, lo primero que sale con seq ≥ al suyo es un STOP
          for (final s in sent.where((c) => c.state == RobotState.stop)) {
            final first = out.firstWhere((c) => c.seq >= s.seq);
            expect(first.state, RobotState.stop,
                reason: 'ronda $round: STOP seq ${s.seq} adelantado por $first ($outSeqs)');
          }
          // herramientas siempre filtradas
          expect(out.where((c) => c.cutter != 0 || c.trimmer != 0), isEmpty);
          link.dispose();
          async.flushMicrotasks();
        });
      }
    });
  });

  group('AUD-05: camino conectado ejercitable', () {
    test('toolsEnabled=false: los BYTES escritos llevan cutter/trimmer 0; '
        'MTU 23 → fragmentos ≤ 20 B', () {
      fakeAsync((async) {
        final (link, t) = connected(async);
        t.mtuValue = 23;
        for (var s = 0; s < 20; s++) {
          link.sendCommand(manual(s));
          async.flushMicrotasks();
        }
        expect(t.writes.every((w) => w.$2.length <= 20), isTrue);
        final lines = t.lines(1);
        expect(lines, hasLength(20));
        for (final l in lines) {
          expect(l, contains('"cutter":0,"trimmer":0'));
        }
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('toolsEnabled=true: pasan', () {
      fakeAsync((async) {
        final (link, t) = connected(async, cfg: on);
        link.sendCommand(manual(1));
        async.flushMicrotasks();
        expect(t.commands(1).single.cutter, 1);
        link.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('reconexión (hallazgos nuevos si fallan)', () {
    test('pérdida de enlace con STOP pendiente: lo pendiente se borra y no sale después', () {
      fakeAsync((async) {
        final (link, t) = connected(async);
        t.hold = true;
        link.sendCommand(manual(1));
        async.flushMicrotasks();
        link.sendCommand(stopCmd(2));
        t.loseLink();
        async.flushMicrotasks();
        expect(link.status, LinkStatus.disconnected);
        t.hold = false;
        t.releaseAll();
        async.flushMicrotasks();
        expect(t.commands(1).map((c) => c.seq).toList(), [1]);
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('nada que se pidió ANTES de la caída sale por la conexión NUEVA', () {
      fakeAsync((async) {
        final (link, t) = connected(async);
        t.hold = true;
        unawaited(link.sendPolygon(1, square).catchError((_) {}));
        async.flushMicrotasks(); // el POLY quedó retenido en la radio
        link.sendCommand(manual(7)); // MANUAL adelante, detrás del POLY
        async.flushMicrotasks();
        t.loseLink(); // se cae el enlace
        async.flushMicrotasks();
        link.connect(); // reconexión (conexión 2)
        async.flushMicrotasks();
        expect(link.status, LinkStatus.connected);
        t.hold = false;
        t.releaseAll(); // la radio "termina" la escritura vieja
        async.flushMicrotasks();
        link.sendCommand(stopCmd(8)); // lo que pide la app tras reconectar
        async.flushMicrotasks();
        final conn2 = t.commands(2);
        expect(conn2.where((c) => c.seq == 7), isEmpty,
            reason: 'el MANUAL adelante seq 7 es de ANTES de la caída y salió por '
                'la conexión nueva: ${conn2.map((c) => '${c.state.name}/${c.dir.name}/seq${c.seq}').toList()}');
        link.dispose();
        async.flushMicrotasks();
      });
    });

    test('una escritura colgada de la conexión vieja no bloquea el STOP de la nueva (< 300 ms)',
        () {
      fakeAsync((async) {
        final (link, t) = connected(async);
        t.hold = true;
        link.sendCommand(manual(1));
        async.flushMicrotasks(); // la radio no responde
        t.loseLink();
        async.flushMicrotasks();
        link.connect();
        async.flushMicrotasks();
        t.hold = false;
        // La escritura vieja falla recién a los 15 s (timeout típico de write).
        Timer(const Duration(seconds: 15), () => t.releaseAll(error: 'timeout'));
        final tReconnect = async.elapsed;
        link.sendCommand(stopCmd(2));
        Duration? stopAt;
        for (var i = 0; i < 160 && stopAt == null; i++) {
          async.elapse(const Duration(milliseconds: 100));
          if (t.commands(2).any((c) => c.seq == 2)) stopAt = async.elapsed - tReconnect;
        }
        expect(stopAt, isNotNull);
        expect(stopAt!, lessThan(const Duration(milliseconds: 300)),
            reason: 'el STOP de la conexión nueva salió recién a los $stopAt');
        link.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('AUD-09: licencia decidida, conexión real sigue bloqueada', () {
    test('BleConfig.license == License.nonprofit; UUID null; connect() real lanza sin tocar la radio',
        () async {
      expect(BleConfig.license.name, 'nonprofit');
      expect(BleConfig.serviceUuid, isNull);
      expect(BleConfig.rxCharacteristicUuid, isNull);
      expect(BleConfig.txCharacteristicUuid, isNull);
      expect(BleConfig.isConfigured, isFalse);
      final link = BleRobotLink(off);
      await expectLater(link.connect(), throwsA(isA<BleLinkException>()));
      expect(link.status, LinkStatus.disconnected);
      await link.dispose();
    });
  });
}
