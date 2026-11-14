import 'dart:async';
import 'dart:convert';

import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/ble_robot_link.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/esp_protocol.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show License;
import 'package:flutter_test/flutter_test.dart';

const toolsOff = AppConfig(toolsEnabled: false);
const toolsOn = AppConfig(toolsEnabled: true);
const square = [(0, 0), (0, 100), (100, 100), (100, 0)];

/// Transporte falso: registra los fragmentos escritos y permite RETENER las
/// escrituras para simular "escritura BLE en curso".
class FakeTransport implements BleTransport {
  @override
  String? unavailableReason;

  @override
  int mtu = 517;

  /// Fragmentos en el orden en que se entregaron a la "radio".
  final List<List<int>> chunks = [];

  /// Número de conexión (1, 2, …) en que salió cada fragmento de [chunks].
  final List<int> chunkConnection = [];
  int connection = 0;

  /// Si es true, cada write() queda pendiente hasta [releaseOne]/[releaseAll].
  bool holdWrites = false;
  final List<Completer<void>> _held = [];

  /// Si no es null, el próximo write() falla con este error.
  Object? failNextWrite;

  Completer<void>? openGate;
  int openCalls = 0;
  int closeCalls = 0;

  final _rx = StreamController<List<int>>.broadcast();
  final _lost = StreamController<void>.broadcast();

  @override
  Stream<List<int>> get received => _rx.stream;

  @override
  Stream<void> get linkLost => _lost.stream;

  @override
  Future<void> open() async {
    openCalls++;
    connection++;
    if (openGate != null) await openGate!.future;
  }

  @override
  Future<void> close() async => closeCalls++;

  @override
  Future<void> write(List<int> chunk) async {
    chunks.add(List.of(chunk));
    chunkConnection.add(connection);
    final err = failNextWrite;
    if (err != null) {
      failNextWrite = null;
      throw err;
    }
    if (holdWrites) {
      final c = Completer<void>();
      _held.add(c);
      await c.future;
    }
  }

  int get heldCount => _held.length;

  void releaseOne() => _held.removeAt(0).complete();

  void notify(String s) => _rx.add(utf8.encode(s));
  void loseLink() => _lost.add(null);

  /// Todo lo escrito, reensamblado en líneas (sin `\n`).
  List<String> get lines {
    final s = utf8.decode(chunks.expand((c) => c).toList());
    final parts = s.split('\n');
    return parts.sublist(0, parts.length - 1);
  }

  List<ControlCommand> get commands => [
        for (final l in lines)
          if (l.startsWith('{"t":"CMD"')) ControlCommand.fromJsonLine(l),
      ];

  /// Bytes escritos durante la conexión [conn], tal cual (pueden incluir
  /// líneas incompletas).
  String bytesOf(int conn) => utf8.decode([
        for (var i = 0; i < chunks.length; i++)
          if (chunkConnection[i] == conn) ...chunks[i],
      ], allowMalformed: true);

  /// Comandos completos escritos durante la conexión [conn].
  List<ControlCommand> commandsOf(int conn) {
    final parts = bytesOf(conn).split('\n');
    return [
      for (final l in parts.sublist(0, parts.length - 1))
        if (l.startsWith('{"t":"CMD"')) ControlCommand.fromJsonLine(l),
    ];
  }
}

/// Vacía la cola de eventos (microtareas + timers de 0).
Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Libera escrituras retenidas una por una hasta que no quede ninguna.
Future<void> drain(FakeTransport t) async {
  await settle();
  while (t.heldCount > 0) {
    t.releaseOne();
    await settle();
  }
}

ControlCommand manual(int seq, {Direction dir = Direction.forward, int tools = 0}) =>
    ControlCommand(
      state: RobotState.manual,
      dir: dir,
      speed: 60,
      cutter: tools,
      trimmer: tools,
      seq: seq,
    );

Future<(BleRobotLink, FakeTransport)> connected(AppConfig cfg, {int mtu = 517}) async {
  final t = FakeTransport()..mtu = mtu;
  final link = BleRobotLink.withTransport(cfg, t);
  await link.connect();
  expect(link.status, LinkStatus.connected);
  return (link, t);
}

void main() {
  group('configuración real (sin firmware BLE)', () {
    test('UUID PENDIENTES: no está configurado; licencia nonprofit (decisión del usuario)', () {
      expect(BleConfig.isConfigured, isFalse);
      expect(BleConfig.license, License.nonprofit);
    });

    test('connect() falla con error claro y no cambia de estado', () async {
      final link = BleRobotLink(toolsOff);
      final statuses = <LinkStatus>[];
      link.statusStream.listen(statuses.add);
      await expectLater(
        link.connect(),
        throwsA(isA<BleLinkException>().having(
            (e) => e.message, 'message', contains('firmware BLE del ESP pendiente'))),
      );
      await settle();
      expect(link.status, LinkStatus.disconnected);
      expect(statuses, isEmpty);
      expect(link.isSimulated, isFalse);
      await link.dispose();
    });
  });

  group('conexión con transporte inyectado', () {
    test('connecting → connected; disconnect cierra el transporte', () async {
      final t = FakeTransport();
      final link = BleRobotLink.withTransport(toolsOff, t);
      final statuses = <LinkStatus>[];
      link.statusStream.listen(statuses.add);
      await link.connect();
      await link.disconnect();
      await settle();
      expect(statuses,
          [LinkStatus.connecting, LinkStatus.connected, LinkStatus.disconnected]);
      expect(t.openCalls, 1);
      expect(t.closeCalls, 1);
    });

    test('transporte no disponible: lanza su motivo sin cambiar de estado', () async {
      final t = FakeTransport()..unavailableReason = 'motivo X';
      final link = BleRobotLink.withTransport(toolsOff, t);
      await expectLater(link.connect(), throwsA(isA<BleLinkException>()));
      expect(link.status, LinkStatus.disconnected);
      expect(t.openCalls, 0);
    });

    test('disconnect() durante open(): no queda conectado', () async {
      final t = FakeTransport()..openGate = Completer<void>();
      final link = BleRobotLink.withTransport(toolsOff, t);
      final f = link.connect();
      await settle();
      expect(link.status, LinkStatus.connecting);
      // disconnect() espera a que el transporte quede cerrado; ese cierre va
      // DETRÁS del open() en curso (AUD-15), así que se libera el open().
      final d = link.disconnect();
      expect(link.status, LinkStatus.disconnected);
      t.openGate!.complete();
      await d;
      await f;
      expect(link.status, LinkStatus.disconnected);
      expect(t.closeCalls, greaterThanOrEqualTo(1), reason: 'cerrado después del open');
      await link.sendCommand(manual(1));
      expect(t.chunks, isEmpty);
    });
  });

  group('sin conexión no envía', () {
    test('antes de conectar: nada llega al transporte', () async {
      final t = FakeTransport();
      final link = BleRobotLink.withTransport(toolsOn, t);
      await link.sendCommand(manual(1));
      await link.sendCommand(ControlCommand.safeStop(2));
      await link.sendPolygon(1, square);
      await link.clearPolygon();
      await settle();
      expect(t.chunks, isEmpty);
    });

    test('después de desconectar y tras pérdida de enlace: nada', () async {
      final (link, t) = await connected(toolsOn);
      await link.disconnect();
      await link.sendCommand(manual(1));
      expect(t.chunks, isEmpty);

      final (link2, t2) = await connected(toolsOn);
      t2.loseLink();
      await settle();
      expect(link2.status, LinkStatus.disconnected);
      expect(t2.closeCalls, 1);
      await link2.sendCommand(manual(2));
      await link2.clearPolygon();
      await settle();
      expect(t2.chunks, isEmpty);
    });

    test('sendPolygon inválido lanza ArgumentError y no escribe (ni conectado)', () async {
      final (link, t) = await connected(toolsOff);
      expect(() => link.sendPolygon(1, const [(0, 0), (0, 1)]), throwsArgumentError);
      expect(() => link.sendPolygon(0, square), throwsArgumentError);
      await settle();
      expect(t.chunks, isEmpty);
    });
  });

  group('política de herramientas', () {
    test('toolsEnabled=false: lo escrito siempre lleva cutter/trimmer = 0', () async {
      final (link, t) = await connected(toolsOff);
      for (var i = 0; i < 20; i++) {
        await link.sendCommand(manual(i, tools: 1));
      }
      expect(t.commands, hasLength(20));
      for (final c in t.commands) {
        expect((c.cutter, c.trimmer), (0, 0));
        expect(c.speed, 60);
      }
      expect(t.lines.every((l) => l.contains('"cutter":0,"trimmer":0')), isTrue);
    });

    test('toolsEnabled=false también en comandos que quedaron pendientes', () async {
      final (link, t) = await connected(toolsOff);
      t.holdWrites = true;
      unawaited(link.sendCommand(manual(1, tools: 1)));
      await settle();
      await link.sendCommand(manual(2, tools: 1));
      await drain(t);
      expect(t.commands.map((c) => (c.seq, c.cutter, c.trimmer)), [(1, 0, 0), (2, 0, 0)]);
    });

    test('toolsEnabled=true: los pedidos pasan', () async {
      final (link, t) = await connected(toolsOn);
      await link.sendCommand(manual(1, tools: 1));
      expect(t.commands.single, manual(1, tools: 1));
    });
  });

  group('fragmentación por MTU', () {
    final worstCmd = ControlCommand(
      state: RobotState.autoPause,
      dir: Direction.right,
      speed: 100,
      cutter: 1,
      trimmer: 1,
      seq: 65535,
    );

    test('chunkLine', () {
      final bytes = utf8.encode(worstCmd.toJsonLine());
      final c23 = BleRobotLink.chunkLine(bytes, 23);
      expect(c23.map((c) => c.length), [20, 20, 20, 17]);
      expect(c23.expand((c) => c).toList(), bytes);
      expect(BleRobotLink.chunkLine(bytes, 80).length, 1);
      expect(BleRobotLink.chunkLine(bytes, 79).length, 2);
      expect(BleRobotLink.chunkLine(bytes, 10).first.length, 20);
    });

    test('MTU 23: el comando sale en 4 escrituras de ≤ 20 B y se reconstruye', () async {
      final (link, t) = await connected(toolsOn, mtu: 23);
      await link.sendCommand(worstCmd);
      expect(t.chunks.map((c) => c.length), [20, 20, 20, 17]);
      expect(t.commands.single, worstCmd);
    });

    test('MTU 80: el peor comando sale en una sola escritura', () async {
      final (link, t) = await connected(toolsOn, mtu: 80);
      await link.sendCommand(worstCmd);
      expect(t.chunks, hasLength(1));
    });

    test('MTU 23: POLY de 10 vértices (peor int32) = 15 escrituras', () async {
      final (link, t) = await connected(toolsOff, mtu: 23);
      const mn = EspProtocol.int32Min;
      final pts = List.filled(10, (mn, mn));
      await link.sendPolygon(65535, pts);
      expect(t.chunks, hasLength(15));
      expect(t.chunks.every((c) => c.length <= 20), isTrue);
      expect('${t.lines.single}\n', EspProtocol.encodePolygon(65535, pts));
    });

    test('un comando durante un POLY no se intercala con sus fragmentos', () async {
      final (link, t) = await connected(toolsOff, mtu: 23);
      t.holdWrites = true;
      final poly = link.sendPolygon(7, square);
      await settle();
      unawaited(link.sendCommand(ControlCommand.safeStop(1)));
      await drain(t);
      await poly;
      expect(t.lines, hasLength(2));
      expect(t.lines[0], startsWith('{"t":"POLY","id":7'));
      expect(ControlCommand.fromJsonLine(t.lines[1]), ControlCommand.safeStop(1));
    });
  });

  group('cola de comandos: STOP con prioridad absoluta (AUD-06)', () {
    ControlCommand stop(int seq) => ControlCommand.safeStop(seq);

    group('regla pura enqueueCommand', () {
      List<int> seqs(List<ControlCommand> l) => l.map((c) => c.seq).toList();

      test('(3) no-STOP coalesce al último', () {
        final p = <ControlCommand>[];
        BleRobotLink.enqueueCommand(p, manual(1));
        BleRobotLink.enqueueCommand(p, manual(2));
        BleRobotLink.enqueueCommand(p, manual(3));
        expect(seqs(p), [3]);
      });

      test('(2) STOP reemplaza a todo lo pendiente', () {
        final p = <ControlCommand>[];
        BleRobotLink.enqueueCommand(p, manual(1));
        BleRobotLink.enqueueCommand(p, stop(2));
        expect(seqs(p), [2]);
        expect(p.single.state, RobotState.stop);
      });

      test('(4) no-STOP posterior va DETRÁS del STOP pendiente', () {
        final p = <ControlCommand>[];
        BleRobotLink.enqueueCommand(p, stop(1));
        BleRobotLink.enqueueCommand(p, manual(2));
        BleRobotLink.enqueueCommand(p, manual(3));
        expect(seqs(p), [1, 3]);
        expect(p.first.state, RobotState.stop);
      });

      test('(1) un STOP nunca desaparece salvo por otro STOP más nuevo', () {
        final p = <ControlCommand>[];
        BleRobotLink.enqueueCommand(p, stop(1));
        for (var i = 2; i < 50; i++) {
          BleRobotLink.enqueueCommand(p, manual(i));
        }
        expect(p.first, stop(1));
        BleRobotLink.enqueueCommand(p, stop(50));
        expect(seqs(p), [50]);
      });
    });

    test('escritura en curso → STOP → MANUAL adelante: salen STOP y luego MANUAL', () async {
      final (link, t) = await connected(toolsOff);
      t.holdWrites = true;
      unawaited(link.sendCommand(manual(1))); // escritura en curso
      await settle();
      expect(t.heldCount, 1);
      await link.sendCommand(stop(2)); // llega STOP
      await link.sendCommand(manual(3, dir: Direction.forward)); // y luego MANUAL
      expect(t.commands.map((c) => c.seq), [1], reason: 'nada se adelantó');
      await drain(t);
      expect(t.commands.map((c) => (c.seq, c.state)), [
        (1, RobotState.manual),
        (2, RobotState.stop),
        (3, RobotState.manual),
      ]);
      expect(t.commands.last.dir, Direction.forward);
    });

    test('(1) STOP con escritura en curso NO se descarta', () async {
      final (link, t) = await connected(toolsOff);
      t.holdWrites = true;
      unawaited(link.sendCommand(manual(1)));
      await settle();
      await link.sendCommand(stop(2));
      await drain(t);
      expect(t.commands.map((c) => c.seq), [1, 2]);
      expect(t.commands.last.state, RobotState.stop);
    });

    test('(2) STOP reemplaza a los no-STOP pendientes no enviados', () async {
      final (link, t) = await connected(toolsOff);
      t.holdWrites = true;
      unawaited(link.sendCommand(manual(1)));
      await settle();
      await link.sendCommand(manual(2));
      await link.sendCommand(manual(3));
      await link.sendCommand(stop(4));
      await drain(t);
      expect(t.commands.map((c) => c.seq), [1, 4]);
    });

    test('(3) no-STOP pendientes coalescen al último', () async {
      final (link, t) = await connected(toolsOff);
      t.holdWrites = true;
      unawaited(link.sendCommand(manual(1)));
      await settle();
      for (var i = 2; i <= 10; i++) {
        await link.sendCommand(manual(i));
      }
      await drain(t);
      expect(t.commands.map((c) => c.seq), [1, 10]);
    });

    test('(4) STOP pendiente + varios MANUAL: STOP primero, después el último', () async {
      final (link, t) = await connected(toolsOff);
      t.holdWrites = true;
      unawaited(link.sendCommand(manual(1)));
      await settle();
      await link.sendCommand(stop(2));
      await link.sendCommand(manual(3));
      await link.sendCommand(manual(4));
      await drain(t);
      expect(t.commands.map((c) => c.seq), [1, 2, 4]);
    });

    test('un error de escritura no pierde el STOP pendiente', () async {
      final (link, t) = await connected(toolsOff);
      t.holdWrites = true;
      t.failNextWrite = StateError('fallo de radio');
      unawaited(link.sendCommand(manual(1))); // falla
      await link.sendCommand(stop(2));
      await drain(t);
      expect(t.commands.last, stop(2));
    });

    test('a 10 Hz sin escrituras retenidas no se pierde ningún comando', () async {
      final (link, t) = await connected(toolsOff, mtu: 23);
      final seq = SeqCounter(65530);
      for (var i = 0; i < 12; i++) {
        await link.sendCommand(i.isEven ? manual(seq.next()) : stop(seq.next()));
      }
      expect(t.commands.map((c) => c.seq),
          [65530, 65531, 65532, 65533, 65534, 65535, 0, 1, 2, 3, 4, 5]);
    });
  });

  group('reconexión: generación de conexión (AUD-12/13)', () {
    test('un comando encolado detrás de un POLY retenido no sale por la conexión nueva',
        () async {
      final (link, t) = await connected(toolsOff);
      t.holdWrites = true;
      final poly = link.sendPolygon(1, square);
      // La escritura del POLY quedó en la radio sin confirmar cuando se cayó
      // el enlace: se informa error (no se sabe si llegó; defecto D2).
      final polyCheck = expectLater(poly, throwsA(isA<BleLinkException>()));
      await settle();
      unawaited(link.sendCommand(manual(7))); // detrás del POLY
      await settle();
      t.loseLink();
      await settle();
      expect(link.status, LinkStatus.disconnected);
      await link.connect(); // conexión 2
      expect(link.status, LinkStatus.connected);
      t.holdWrites = false;
      await drain(t); // la radio "termina" la escritura vieja
      await polyCheck;
      await link.sendCommand(ControlCommand.safeStop(8));
      await settle();
      expect(t.commandsOf(2).map((c) => c.seq), [8]);
      expect(t.bytesOf(2), isNot(contains('"seq":7')));
    });

    test('lo que quedó pendiente (STOP incluido) se descarta con la conexión vieja', () async {
      final (link, t) = await connected(toolsOff);
      t.holdWrites = true;
      unawaited(link.sendCommand(manual(1)));
      await settle();
      await link.sendCommand(ControlCommand.safeStop(2)); // pendiente
      await link.sendCommand(manual(3)); // pendiente detrás del STOP
      t.loseLink();
      await settle();
      await link.connect();
      t.holdWrites = false;
      await drain(t);
      await link.sendCommand(manual(4));
      await settle();
      expect(t.commandsOf(1).map((c) => c.seq), [1]);
      expect(t.commandsOf(2).map((c) => c.seq), [4]);
    });

    test('una línea de la conexión vieja a medio escribir no sigue en la nueva', () async {
      final (link, t) = await connected(toolsOff, mtu: 23);
      t.holdWrites = true;
      unawaited(link.sendPolygon(1, square).catchError((_) {}));
      await settle();
      expect(t.chunks, hasLength(1)); // primer fragmento en vuelo
      t.loseLink();
      await settle();
      await link.connect();
      t.holdWrites = false;
      await drain(t);
      expect(t.bytesOf(2), isEmpty, reason: 'ningún fragmento del POLY viejo');
    });

    test('sendPolygon cortado por la caída informa error (no da por enviado)', () async {
      final (link, t) = await connected(toolsOff, mtu: 23);
      t.holdWrites = true;
      final poly = link.sendPolygon(1, square);
      final check = expectLater(poly, throwsA(isA<BleLinkException>()));
      await settle();
      t.loseLink();
      await settle();
      t.holdWrites = false;
      await drain(t);
      await check;
    });

    test('una escritura colgada de la conexión vieja no bloquea el STOP de la nueva', () {
      fakeAsync((async) {
        final t = FakeTransport();
        final link = BleRobotLink.withTransport(toolsOff, t);
        link.connect();
        async.flushMicrotasks();
        t.holdWrites = true;
        link.sendCommand(manual(1)); // la radio no responde nunca
        async.flushMicrotasks();
        link.sendCommand(manual(2)); // pendiente
        t.loseLink();
        async.flushMicrotasks();
        link.connect();
        async.flushMicrotasks();
        t.holdWrites = false;
        final t0 = async.elapsed;
        link.sendCommand(ControlCommand.safeStop(3));
        async.flushMicrotasks();
        expect(async.elapsed - t0, Duration.zero);
        expect(t.commandsOf(2).map((c) => c.seq), [3], reason: 'STOP inmediato');
        // y los siguientes también salen, sin esperar a la escritura vieja
        link.sendCommand(manual(4));
        async.elapse(const Duration(milliseconds: 100));
        expect(t.commandsOf(2).map((c) => c.seq), [3, 4]);
        // cuando la vieja por fin termina, no escribe nada más ni rompe la cola
        t.releaseOne();
        async.flushMicrotasks();
        link.sendCommand(manual(5));
        async.flushMicrotasks();
        expect(t.commandsOf(2).map((c) => c.seq), [3, 4, 5]);
        expect(t.commandsOf(1).map((c) => c.seq), [1]);
      });
    });

    test('las 4 condiciones de AUD-06 siguen valiendo en la conexión nueva', () async {
      final (link, t) = await connected(toolsOff);
      t.loseLink();
      await settle();
      await link.connect();
      t.holdWrites = true;
      unawaited(link.sendCommand(manual(1)));
      await settle();
      await link.sendCommand(manual(2));
      await link.sendCommand(ControlCommand.safeStop(3)); // (1)(2)
      await link.sendCommand(manual(4)); // (4)
      await link.sendCommand(manual(5)); // (3)
      await drain(t);
      expect(t.commandsOf(2).map((c) => (c.seq, c.state)), [
        (1, RobotState.manual),
        (3, RobotState.stop),
        (5, RobotState.manual),
      ]);
    });
  });

  group('recepción', () {
    test('reensambla notificaciones fragmentadas y decodifica POK/ACK/PERR', () async {
      final (link, t) = await connected(toolsOff);
      final msgs = <RobotMessage>[];
      link.messages.listen(msgs.add);
      t.notify('{"t":"POK",');
      t.notify('"id":3}\n{"t":"ACK","seq":9}\n{"t":"PERR","e":"FMT"}\n');
      t.notify('{"t":"POK","id":0}\n'); // fuera de rango: se descarta
      await settle();
      expect(msgs, hasLength(3));
      expect((msgs[0] as PolygonAccepted).id, 3);
      expect((msgs[1] as CommandAck).seq, 9);
      expect((msgs[2] as PolygonRejected).reason, 'FMT');
    });
  });
}
