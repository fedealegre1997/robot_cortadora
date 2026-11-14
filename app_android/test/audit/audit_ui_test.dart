// Auditor — tests 4, 5 y 6 a nivel UI (widgets) + cableado de main.dart.

import 'package:cortadora_e7/app/lifecycle_observer.dart';
import 'package:cortadora_e7/app/session_controller.dart';
import 'package:cortadora_e7/core/app_config.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:cortadora_e7/main.dart' as app_main;
import 'package:cortadora_e7/ui/app.dart';
import 'package:cortadora_e7/ui/labels.dart';
import 'package:cortadora_e7/ui/screens/connection_screen.dart';
import 'package:cortadora_e7/ui/screens/control_screen.dart';
import 'package:cortadora_e7/ui/widgets/simulated_banner.dart';
import 'package:cortadora_e7/ui/widgets/stop_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_helpers.dart';

/// Galaxy M12: 360×800 dp a 2.0.
Future<(RecordingLink, SessionController)> pumpM12(WidgetTester tester,
    {bool toolsEnabled = false}) async {
  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = const Size(720, 1600);
  addTearDown(tester.view.reset);
  final link = RecordingLink();
  final c = SessionController(
      link: link, config: AppConfig(toolsEnabled: toolsEnabled));
  await tester.pumpWidget(CortadoraApp(controller: c));
  return (link, c);
}

Future<void> tapConnect(WidgetTester tester) async {
  // En 360×800 el botón queda debajo del pliegue: hay que llevarlo a la vista.
  await tester.ensureVisible(find.byKey(ConnectionScreen.connectKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ConnectionScreen.connectKey));
}

Future<void> connectAndManual(WidgetTester tester, RecordingLink link) async {
  await tapConnect(tester);
  await tester.pump(); // stream asíncrono
  await tester.pump();
  await tester.tap(find.text('Control'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ControlScreen.stateKey(RobotState.manual)));
  await tester.pump();
}

Future<void> finish(WidgetTester tester, SessionController c, RecordingLink link) async {
  await tester.pumpWidget(const SizedBox.shrink());
  c.dispose();
  await link.dispose();
}

void main() {
  group('A4 UI: soltar → dir 0', () {
    testWidgets('pointer CANCEL (el sistema roba el gesto) baja dir a 0', (tester) async {
      final (link, c) = await pumpM12(tester);
      await connectAndManual(tester, link);
      final fwd = find.byKey(ControlScreen.directionKey(Direction.forward));
      await tester.scrollUntilVisible(fwd, 100, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final g = await tester.startGesture(tester.getCenter(fwd));
      await tester.pump(const Duration(milliseconds: 300));
      expect(link.sent.last.dir, Direction.forward);
      await g.cancel();
      await tester.pump();
      expect(c.dir, Direction.none);
      expect(link.sent.last.dir, Direction.none);
      await finish(tester, c, link);
    });

    testWidgets('dedo que se desliza FUERA del botón (o arrastra la lista) y se levanta → dir 0',
        (tester) async {
      final (link, c) = await pumpM12(tester);
      await connectAndManual(tester, link);
      final fwd = find.byKey(ControlScreen.directionKey(Direction.forward));
      await tester.scrollUntilVisible(fwd, 100, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final g = await tester.startGesture(tester.getCenter(fwd));
      await tester.pump(const Duration(milliseconds: 200));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(0, -40)); // arrastra (puede scrollear)
        await tester.pump(const Duration(milliseconds: 20));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(c.dir, Direction.none);
      expect(link.sent.last.dir, Direction.none);
      await finish(tester, c, link);
    });

    testWidgets('dos dedos: adelante + atrás, soltar cualquiera → dir 0 (falla segura)',
        (tester) async {
      final (link, c) = await pumpM12(tester);
      await connectAndManual(tester, link);
      final fwd = find.byKey(ControlScreen.directionKey(Direction.forward));
      final back = find.byKey(ControlScreen.directionKey(Direction.backward));
      await tester.scrollUntilVisible(back, 100, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final a = await tester.startGesture(tester.getCenter(fwd), pointer: 1);
      await tester.pump(const Duration(milliseconds: 150));
      final b = await tester.startGesture(tester.getCenter(back), pointer: 2);
      await tester.pump(const Duration(milliseconds: 150));
      expect(c.dir, Direction.backward);
      await b.up();
      await tester.pump();
      expect(c.dir, Direction.none, reason: 'nunca queda un giro/avance colgado');
      await a.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.dir, Direction.none);
      expect(link.sent.last.dir, Direction.none);
      await finish(tester, c, link);
    });

    testWidgets('cambiar de pestaña con otro dedo mientras se mantiene adelante → dir 0',
        (tester) async {
      final (link, c) = await pumpM12(tester);
      await connectAndManual(tester, link);
      final fwd = find.byKey(ControlScreen.directionKey(Direction.forward));
      await tester.scrollUntilVisible(fwd, 100, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final g = await tester.startGesture(tester.getCenter(fwd), pointer: 7);
      await tester.pump(const Duration(milliseconds: 200));
      expect(c.dir, Direction.forward);
      await tester.tap(find.text('Conexión'));
      await tester.pumpAndSettle();
      expect(c.dir, Direction.none);
      expect(link.sent.last.dir, Direction.none);
      await g.up();
      await tester.pump();
      await finish(tester, c, link);
    });
  });

  group('A5 UI: STOP', () {
    testWidgets('STOP mide ≥ 76 dp de alto y está fuera del scroll', (tester) async {
      final (link, c) = await pumpM12(tester);
      final r = tester.getRect(find.byKey(StopButton.buttonKey));
      expect(r.height, greaterThanOrEqualTo(76));
      expect(
          find.ancestor(
              of: find.byKey(StopButton.buttonKey), matching: find.byType(Scrollable)),
          findsNothing);
      await finish(tester, c, link);
    });

    testWidgets('STOP se dispara aunque el dedo se deslice al apretarlo (pánico)',
        (tester) async {
      final (link, c) = await pumpM12(tester);
      await connectAndManual(tester, link);
      expect(c.state, RobotState.manual);
      final stop = find.byKey(StopButton.buttonKey);
      final g = await tester.startGesture(tester.getCenter(stop));
      await tester.pump(const Duration(milliseconds: 50));
      await g.moveBy(const Offset(40, 0)); // > kTouchSlop (18 dp), sigue dentro del botón
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(c.state, RobotState.stop,
          reason: 'un STOP apretado con deslizamiento no debe perderse');
      await finish(tester, c, link);
    });

    testWidgets('STOP se envía al APOYAR el dedo, no al levantarlo', (tester) async {
      final (link, c) = await pumpM12(tester);
      await connectAndManual(tester, link);
      final stop = find.byKey(StopButton.buttonKey);
      final n = link.sent.length;
      final g = await tester.startGesture(tester.getCenter(stop));
      // Ronda 2 (refuerzo tras la prueba de mutación B): además del estado,
      // el comando STOP tiene que haber SALIDO al apoyar, sin esperar al tick.
      expect(link.sent.length, n + 1, reason: 'envío inmediato al apoyar');
      expect(link.sent.last.state, RobotState.stop);
      await tester.pump(const Duration(milliseconds: 10));
      expect(c.state, RobotState.stop,
          reason: 'mientras el dedo sigue apoyado, el STOP ya debería haberse pedido');
      await g.up();
      await tester.pump();
      await finish(tester, c, link);
    });

    // ---- Ronda 2 (pedido del usuario): el STOP se dispara al TOCAR y no se
    // cancela si el dedo se desliza (> 18 dp y fuera del botón) ni si el
    // sistema cancela el gesto. Con el doble propio de streams asíncronos.
    void expectOnlySafeStops(RecordingLink link, int from) {
      for (final cmd in link.sent.skip(from)) {
        expect((cmd.state, cmd.dir, cmd.speed, cmd.cutter, cmd.trimmer),
            (RobotState.stop, Direction.none, 0, 0, 0),
            reason: 'después de tocar STOP solo pueden salir STOP: $cmd');
      }
    }

    testWidgets('R2 STOP: dedo que se desliza > 18 dp y SALE del botón → STOP al apoyar, '
        'y solo STOP después', (tester) async {
      final (link, c) = await pumpM12(tester, toolsEnabled: true);
      await connectAndManual(tester, link);
      c.setCutter(true);
      c.pressDirection(Direction.forward);
      await tester.pump(const Duration(milliseconds: 150));
      expect(link.sent.last.cutter, 1);
      final n = link.sent.length;
      final stopRect = tester.getRect(find.byKey(StopButton.buttonKey));
      final g = await tester.startGesture(stopRect.center);
      expect(c.state, RobotState.stop, reason: 'al apoyar, sin esperar a levantar');
      expect(link.sent.length, n + 1);
      await g.moveBy(const Offset(25, 0)); // > kTouchSlop
      await tester.pump(const Duration(milliseconds: 120));
      await g.moveTo(Offset(stopRect.center.dx, stopRect.top - 150)); // fuera del botón
      await tester.pump(const Duration(milliseconds: 250));
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.state, RobotState.stop);
      expectOnlySafeStops(link, n);
      await finish(tester, c, link);
    });

    testWidgets('R2 STOP: gesto CANCELADO por el sistema → el STOP ya salió y no se revierte',
        (tester) async {
      final (link, c) = await pumpM12(tester);
      await connectAndManual(tester, link);
      c.pressDirection(Direction.backward);
      await tester.pump(const Duration(milliseconds: 150));
      final n = link.sent.length;
      final g = await tester.startGesture(tester.getCenter(find.byKey(StopButton.buttonKey)));
      expect(c.state, RobotState.stop);
      expect(link.sent.length, n + 1, reason: 'el STOP salió al apoyar, antes del cancel');
      await tester.pump(const Duration(milliseconds: 50));
      await g.cancel();
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.state, RobotState.stop);
      expect(link.sent.length, greaterThan(n));
      expectOnlySafeStops(link, n);
      await finish(tester, c, link);
    });

    testWidgets('R2 STOP: toque normal → EXACTAMENTE 2 envíos inmediatos (apoyar + levantar), '
        'ambos STOP completos; nada distinto en el medio', (tester) async {
      final (link, c) = await pumpM12(tester, toolsEnabled: true);
      await connectAndManual(tester, link);
      c.setCutter(true);
      c.pressDirection(Direction.forward);
      await tester.pump(const Duration(milliseconds: 150));
      final n = link.sent.length;
      await tester.tap(find.byKey(StopButton.buttonKey));
      expect(link.sent.length - n, 2, reason: 'pointer down + onPressed al levantar');
      expectOnlySafeStops(link, n);
      await tester.pump(const Duration(seconds: 1));
      expectOnlySafeStops(link, n);
      await finish(tester, c, link);
    });

    testWidgets('R2 STOP: mantener el STOP apretado 2 s → todo lo que sale es STOP', (tester) async {
      final (link, c) = await pumpM12(tester);
      await connectAndManual(tester, link);
      c.pressDirection(Direction.forward);
      await tester.pump(const Duration(milliseconds: 150));
      final n = link.sent.length;
      final g = await tester.startGesture(tester.getCenter(find.byKey(StopButton.buttonKey)));
      await tester.pump(const Duration(seconds: 2));
      expect(link.sent.length - n, greaterThanOrEqualTo(20));
      expectOnlySafeStops(link, n);
      await g.up();
      await tester.pump();
      expectOnlySafeStops(link, n);
      await finish(tester, c, link);
    });

    testWidgets('ciclo de vida REAL (binding → SessionLifecycleObserver): paused → STOP',
        (tester) async {
      final (link, c) = await pumpM12(tester, toolsEnabled: true);
      final obs = SessionLifecycleObserver(c);
      tester.binding.addObserver(obs);
      addTearDown(() => tester.binding.removeObserver(obs));
      await connectAndManual(tester, link);
      c.setCutter(true);
      c.pressDirection(Direction.forward);
      await tester.pump(const Duration(milliseconds: 200));
      expect(link.sent.last.cutter, 1);
      final n = link.sent.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(link.sent.length, greaterThan(n), reason: 'envío inmediato');
      expect((link.sent[n].state, link.sent[n].dir, link.sent[n].cutter),
          (RobotState.stop, Direction.none, 0));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.state, RobotState.stop);
      for (final cmd in link.sent.skip(n)) {
        expect((cmd.state, cmd.dir, cmd.cutter, cmd.trimmer),
            (RobotState.stop, Direction.none, 0, 0));
      }
      await finish(tester, c, link);
    });
  });

  group('A6 UI: herramientas bloqueadas', () {
    testWidgets('toolsEnabled=false: botones deshabilitados, aviso visible, tocar no envía 1',
        (tester) async {
      final (link, c) = await pumpM12(tester);
      await connectAndManual(tester, link);
      for (final k in [ControlScreen.cutterKey, ControlScreen.trimmerKey]) {
        await tester.scrollUntilVisible(find.byKey(k), 100,
            scrollable: find.byType(Scrollable).first);
        await tester.pump();
        final b = tester.widget<ButtonStyleButton>(find.byKey(k));
        expect(b.onPressed, isNull);
        await tester.tap(find.byKey(k), warnIfMissed: false);
        await tester.pump();
      }
      expect(find.text(Labels.toolsLocked), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(link.sent, isNotEmpty);
      expect(link.sent.where((e) => e.cutter == 1 || e.trimmer == 1), isEmpty);
      await finish(tester, c, link);
    });
  });

  group('main.dart (cableado real)', () {
    testWidgets('arranca con robot simulado, banner, STOP; paused → STOP; desconectar',
        (tester) async {
      app_main.main();
      await tester.pump();
      expect(find.byKey(SimulatedBanner.bannerKey), findsOneWidget);
      expect(find.text(Labels.simulatedBanner), findsOneWidget);
      expect(find.byKey(StopButton.buttonKey), findsOneWidget);
      final c = tester.widget<CortadoraApp>(find.byType(CortadoraApp)).controller;
      expect(c.isSimulated, isTrue);
      expect(c.toolsEnabled, isFalse);

      await tapConnect(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(c.isConnected, isTrue);
      c.requestState(RobotState.manual);
      c.pressDirection(Direction.forward);
      await tester.pump(const Duration(milliseconds: 200));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(c.state, RobotState.stop, reason: 'main.dart registra el observer');
      expect(c.dir, Direction.none);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await c.disconnect();
      await tester.pump(const Duration(milliseconds: 200));
      expect(c.linkStatus, LinkStatus.disconnected);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  });
}
