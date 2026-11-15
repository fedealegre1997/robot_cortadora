// Auditor — Paso 1: STOP inmediato al conectar. Tests PROPIOS, independientes
// de los del Agente 2 (doble de enlace propio, con streams sincrónicos o
// asíncronos a elección; simulador real; main.dart real).
//
// Regla (aprobada por el usuario): el primer envío de CADA conexión es un
// STOP completo (state STOP, dir none, speed 0, cutter 0, trimmer 0), con seq
// válido y sincrónico con el cambio a `connected`; el heartbeat arranca
// después (ticks a 100 ms exactos desde ese instante).

import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:cortadora_e7/app/session_controller.dart';
import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:cortadora_e7/core/simulated_robot_link.dart';
import 'package:cortadora_e7/main.dart' as app_main;
import 'package:cortadora_e7/ui/app.dart';
import 'package:cortadora_e7/ui/screens/connection_screen.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';

const tick = Duration(milliseconds: 100);

/// Enlace propio. [sync]: los streams entregan DENTRO de setStatus().
class PLink implements RobotLink {
  PLink({required bool sync, this.clock})
      : _status = StreamController<LinkStatus>.broadcast(sync: sync),
        _msgs = StreamController<RobotMessage>.broadcast(sync: sync);

  final Duration Function()? clock;
  final StreamController<LinkStatus> _status;
  final StreamController<RobotMessage> _msgs;
  LinkStatus _s = LinkStatus.disconnected;

  final List<ControlCommand> sent = [];
  final List<Duration> sentAt = [];
  final List<String> log = []; // 'status:x' y 'send'

  void setStatus(LinkStatus s) {
    _s = s;
    log.add('status:${s.name}');
    _status.add(s);
  }

  @override
  bool get isSimulated => true;
  @override
  LinkStatus get status => _s;
  @override
  Stream<LinkStatus> get statusStream => _status.stream;
  @override
  Stream<RobotMessage> get messages => _msgs.stream;
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> sendCommand(ControlCommand command) async {
    if (_s != LinkStatus.connected) return;
    log.add('send');
    sent.add(command);
    sentAt.add(clock?.call() ?? Duration.zero);
  }

  @override
  Future<void> sendPolygon(int id, List<(int, int)> points) async {}
  @override
  Future<void> clearPolygon() async {}
  @override
  Future<void> dispose() async {}
}

void expectFullStop(ControlCommand c, String why) {
  expect((c.state, c.dir, c.speed, c.cutter, c.trimmer),
      (RobotState.stop, Direction.none, 0, 0, 0),
      reason: why);
  expect(c.seq, inInclusiveRange(0, 65535), reason: why);
}

/// Pide TODO (con herramientas si se puede).
void requestEverything(SessionController c) {
  c.requestState(RobotState.manual);
  c.setSpeed(100);
  c.setCutter(true);
  c.setTrimmer(true);
  c.pressDirection(Direction.forward);
}

void main() {
  for (final tools in [false, true]) {
    group('toolsEnabled=$tools', () {
      final cfg = AppConfig(toolsEnabled: tools);

      test('el primer envío es un STOP completo, SINCRÓNICO con el cambio a connected; '
          'el primer tick llega 100 ms después', () {
        fakeAsync((async) {
          final link = PLink(sync: true, clock: () => async.elapsed);
          final c = SessionController(link: link, config: cfg);
          async.elapse(const Duration(seconds: 1)); // desconectado: nada
          expect(link.sent, isEmpty);
          final t0 = async.elapsed;
          link.setStatus(LinkStatus.connected);
          // SIN flushMicrotasks ni elapse: ya salió.
          expect(link.sent, hasLength(1));
          expect(link.log, ['status:connected', 'send']);
          expectFullStop(link.sent.first, 'primer envío');
          expect(link.sentAt.first, t0);
          async.elapse(tick - const Duration(milliseconds: 1));
          expect(link.sent, hasLength(1), reason: 'aún no hay tick');
          async.elapse(const Duration(milliseconds: 1));
          expect(link.sent, hasLength(2));
          expect(link.sentAt[1] - t0, tick);
          expect(link.sent[1].seq, link.sent[0].seq + 1);
          c.dispose();
          expect(async.periodicTimerCount, 0);
        });
      });

      test('mismo resultado con streams ASÍNCRONOS (como los enlaces reales)', () {
        fakeAsync((async) {
          final link = PLink(sync: false, clock: () => async.elapsed);
          final c = SessionController(link: link, config: cfg);
          link.setStatus(LinkStatus.connected);
          expect(link.sent, isEmpty, reason: 'el aviso aún no llegó');
          async.flushMicrotasks();
          expect(link.sent, hasLength(1));
          expectFullStop(link.sent.first, 'primer envío');
          async.elapse(tick * 3);
          expect(link.sent, hasLength(4));
          expect(link.sentAt[1] - link.sentAt[0], tick);
          c.dispose();
        });
      });

      test('7 reconexiones seguidas con TODO pedido antes de cada caída: el primer envío '
          'de cada conexión es STOP completo y nada se arrastra', () {
        fakeAsync((async) {
          final link = PLink(sync: false, clock: () => async.elapsed);
          final c = SessionController(link: link, config: cfg);
          for (var k = 0; k < 7; k++) {
            link.setStatus(LinkStatus.connected);
            async.flushMicrotasks();
            final startIdx = link.sent.length - 1;
            expectFullStop(link.sent[startIdx], 'conexión $k: primer envío');
            async.elapse(const Duration(milliseconds: 20));
            requestEverything(c);
            async.elapse(const Duration(milliseconds: 350));
            expect(link.sent.last.state, RobotState.manual, reason: 'precondición conexión $k');
            expect(link.sent.last.dir, Direction.forward);
            expect(link.sent.last.cutter, tools ? 1 : 0);
            link.setStatus(LinkStatus.disconnected); // caída con TODO encendido
            async.flushMicrotasks();
            expect(c.state, RobotState.stop);
            expect(c.heartbeatActive, isFalse);
            async.elapse(const Duration(milliseconds: 500)); // sin enlace: nada
          }
          // seq: sin saltos ni repetidos en TODA la sesión
          for (var i = 1; i < link.sent.length; i++) {
            expect(link.sent[i].seq, (link.sent[i - 1].seq + 1) % 65536, reason: 'envío $i');
          }
          // el primero de cada conexión = el que sigue a un status:connected
          for (var i = 0; i < link.log.length - 1; i++) {
            if (link.log[i] == 'status:connected') {
              expect(link.log[i + 1], 'send', reason: 'después de connected lo primero es un envío');
            }
          }
          c.dispose();
        });
      });

      test('pedidos DURANTE connecting (y en el instante exacto de connected, ANTES de que el '
          'controlador se entere) no salen; el primero es STOP', () {
        fakeAsync((async) {
          final link = PLink(sync: true, clock: () => async.elapsed);
          late SessionController c;
          var injected = false;
          // Registrado ANTES que el controlador: corre antes que su _onStatus.
          link.statusStream.listen((s) {
            if (s == LinkStatus.connected) {
              injected = true;
              requestEverything(c);
            }
          });
          c = SessionController(link: link, config: cfg);
          link.setStatus(LinkStatus.connecting);
          requestEverything(c);
          c.stop();
          async.elapse(const Duration(seconds: 1));
          expect(link.sent, isEmpty);
          expect(c.state, RobotState.stop);
          link.setStatus(LinkStatus.connected);
          expect(injected, isTrue);
          expect(link.sent, hasLength(1));
          expectFullStop(link.sent.first, 'primer envío');
          expect(c.state, RobotState.stop, reason: 'lo pedido durante connecting se ignora');
          async.elapse(tick * 3);
          for (final s in link.sent) {
            expectFullStop(s, 'todo lo enviado sin que el usuario pida nada tras conectar');
          }
          c.dispose();
        });
      });

      test('streams asíncronos: pedidos entre el cambio del enlace y la entrega del aviso se '
          'ignoran (el controlador aún no está conectado); el primer envío es STOP', () {
        fakeAsync((async) {
          final link = PLink(sync: false, clock: () => async.elapsed);
          final c = SessionController(link: link, config: cfg);
          link.setStatus(LinkStatus.connected);
          requestEverything(c); // ventana de la microtarea
          async.flushMicrotasks();
          expect(link.sent, hasLength(1));
          expectFullStop(link.sent.first, 'primer envío');
          expect(c.state, RobotState.stop);
          c.dispose();
        });
      });

      test('el controlador NACE ya conectado: STOP sincrónico en el constructor, con herramientas '
          'pedidas imposibles', () {
        fakeAsync((async) {
          final link = PLink(sync: true, clock: () => async.elapsed)
            ..setStatus(LinkStatus.connected);
          final c = SessionController(link: link, config: cfg);
          expect(link.sent, hasLength(1));
          expectFullStop(link.sent.first, 'nace conectado');
          expect(c.heartbeatActive, isTrue);
          async.elapse(tick);
          expect(link.sent, hasLength(2));
          expect(link.sentAt[1] - link.sentAt[0], tick);
          c.dispose();
        });
      });
    });
  }

  group('riesgos de la regla nueva', () {
    test('connected DUPLICADO: no hay segundo STOP, ni segundo heartbeat (ya estaba conectado)', () {
      fakeAsync((async) {
        final link = PLink(sync: true, clock: () => async.elapsed);
        final c = SessionController(link: link, config: const AppConfig(toolsEnabled: true));
        link.setStatus(LinkStatus.connected);
        async.elapse(const Duration(milliseconds: 250));
        requestEverything(c);
        final n = link.sent.length;
        link.setStatus(LinkStatus.connected); // repite
        link.setStatus(LinkStatus.connected);
        expect(link.sent.length, n, reason: 'ningún envío extra por el connected repetido');
        expect(c.state, RobotState.manual, reason: 'no baja lo pedido ni lo toca');
        expect(async.periodicTimerCount, 1);
        async.elapse(tick * 10);
        expect(link.sent.length - n, 10, reason: 'sigue a 10 Hz exactos');
        c.dispose();
      });
    });

    test('connected → connecting → connected inmediato: dos STOP, un solo heartbeat, nada '
        'no-STOP en el medio', () {
      fakeAsync((async) {
        final link = PLink(sync: true, clock: () => async.elapsed);
        final c = SessionController(link: link, config: const AppConfig(toolsEnabled: true));
        link.setStatus(LinkStatus.connected);
        async.elapse(const Duration(milliseconds: 150));
        requestEverything(c);
        async.elapse(tick);
        final n = link.sent.length;
        link.setStatus(LinkStatus.connecting);
        expect(async.periodicTimerCount, 0);
        link.setStatus(LinkStatus.connected); // mismo instante
        expect(async.periodicTimerCount, 1);
        expect(link.sent.length, n + 1);
        expectFullStop(link.sent.last, 'STOP al volver a conectar');
        async.elapse(tick * 5);
        for (final s in link.sent.skip(n)) {
          expectFullStop(s, 'todo lo posterior a la reconexión');
        }
        c.dispose();
      });
    });

    test('segundo plano y pérdida de conexión siguen mandando STOP (regresión)', () {
      fakeAsync((async) {
        final link = PLink(sync: true, clock: () => async.elapsed);
        final c = SessionController(link: link, config: const AppConfig(toolsEnabled: true));
        link.setStatus(LinkStatus.connected);
        async.elapse(tick);
        requestEverything(c);
        async.elapse(tick);
        final n = link.sent.length;
        c.handleLifecycleState(AppLifecycleState.paused);
        expect(link.sent.length, n + 1);
        expectFullStop(link.sent.last, 'paused');
        async.elapse(tick * 3);
        link.sent.skip(n).forEach((s) => expectFullStop(s, 'en segundo plano'));
        c.handleLifecycleState(AppLifecycleState.resumed);
        requestEverything(c);
        async.elapse(tick);
        link.setStatus(LinkStatus.disconnected);
        expect(c.state, RobotState.stop);
        expect(c.heartbeatActive, isFalse);
        final m = link.sent.length;
        async.elapse(const Duration(seconds: 2));
        expect(link.sent.length, m, reason: 'sin enlace no sale nada');
        c.dispose();
      });
    });
  });

  group('con el simulador real y con main.dart real', () {
    test('SimulatedRobotLink: el primer comando recibido por el "ESP" es STOP, también tras '
        '6 caídas con todo pedido (tools true)', () {
      fakeAsync((async) {
        const cfg = AppConfig(toolsEnabled: true);
        final link = SimulatedRobotLink(cfg);
        final c = SessionController(link: link, config: cfg);
        var firstOfEach = <ControlCommand>[];
        for (var k = 0; k < 7; k++) {
          final before = link.receivedCommandCount;
          c.connect();
          async.elapse(const Duration(milliseconds: 500));
          async.flushMicrotasks();
          expect(c.isConnected, isTrue, reason: 'ciclo $k');
          final all = link.receivedCommands;
          final firstNew = all[all.length - (link.receivedCommandCount - before)];
          firstOfEach.add(firstNew);
          expectFullStop(firstNew, 'ciclo $k: primer comando de la conexión');
          async.elapse(const Duration(milliseconds: 30));
          requestEverything(c);
          async.elapse(const Duration(milliseconds: 300));
          expect(link.lastReceivedCommand!.state, RobotState.manual);
          expect(link.lastReceivedCommand!.cutter, 1);
          link.simulateLinkLoss();
          async.flushMicrotasks();
        }
        expect(firstOfEach, hasLength(7));
        c.dispose();
        link.dispose();
        async.flushMicrotasks();
      });
    });

    testWidgets('main.dart real: al conectar, exactamente 1 envío (STOP) en el instante de '
        'connected; el estado queda STOP', (tester) async {
      app_main.main();
      await tester.pump();
      final c = tester.widget<CortadoraApp>(find.byType(CortadoraApp)).controller;
      await tester.ensureVisible(find.byKey(ConnectionScreen.connectKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ConnectionScreen.connectKey));
      await tester.pump();
      expect(c.sentCount, 0);
      await tester.pump(const Duration(milliseconds: 500)); // connectDelay del simulador
      expect(c.isConnected, isTrue);
      expect(c.sentCount, 1, reason: 'solo el STOP inmediato, antes de cualquier tick');
      expect(c.lastSentSeq, 0);
      expect(c.state, RobotState.stop);
      expect(c.cutter, isFalse);
      await tester.pump(const Duration(milliseconds: 100));
      expect(c.sentCount, 2);
      await c.disconnect();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  });
}
