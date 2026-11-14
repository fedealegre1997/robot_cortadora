// AUD-02 (STOP al apoyar el dedo) y AUD-03 (HoldButton desmontado con el
// dedo apoyado), a 360×800 dp como el Galaxy M12.

import 'package:cortadora_e7/app/session_controller.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/ui/app.dart';
import 'package:cortadora_e7/ui/labels.dart';
import 'package:cortadora_e7/ui/screens/connection_screen.dart';
import 'package:cortadora_e7/ui/screens/control_screen.dart';
import 'package:cortadora_e7/ui/widgets/stop_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app/fakes.dart';

Future<(FakeRobotLink, SessionController)> pumpManual(
    WidgetTester tester) async {
  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = const Size(720, 1600);
  addTearDown(tester.view.reset);
  final link = FakeRobotLink();
  final c = makeController(link);
  await tester.pumpWidget(CortadoraApp(controller: c));
  // ensureVisible lo lleva arriba: así no queda detrás del STOP.
  await tester.ensureVisible(find.byKey(ConnectionScreen.connectKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ConnectionScreen.connectKey));
  await tester.pump();
  await tester.tap(find.text('Control'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ControlScreen.stateKey(RobotState.manual)));
  await tester.pump();
  expect(c.state, RobotState.manual);
  return (link, c);
}

Future<void> finish(
    WidgetTester tester, SessionController c, FakeRobotLink link) async {
  await tester.pumpWidget(const SizedBox.shrink());
  c.dispose();
  await link.dispose();
}

void expectAllStopFrom(FakeRobotLink link, int from) {
  for (final cmd in link.sent.skip(from)) {
    expect(cmd.state, RobotState.stop);
    expect(cmd.dir, Direction.none);
    expect(cmd.speed, 0);
    expect(cmd.cutter, 0);
    expect(cmd.trimmer, 0);
  }
}

Finder get stopFinder => find.byKey(StopButton.buttonKey);

void main() {
  group('AUD-02: STOP al apoyar el dedo', () {
    testWidgets('apoyar el dedo ya pide STOP (antes de levantarlo)',
        (tester) async {
      final (link, c) = await pumpManual(tester);
      final n = link.sent.length;
      final g = await tester.startGesture(tester.getCenter(stopFinder));
      // Sin pump: el envío es sincrónico al apoyar.
      expect(c.state, RobotState.stop);
      expect(link.sent.length, greaterThan(n));
      expectAllStopFrom(link, n);
      await g.up();
      await tester.pump();
      await finish(tester, c, link);
    });

    testWidgets('dedo que se desliza (> 18 dp) no pierde el STOP',
        (tester) async {
      final (link, c) = await pumpManual(tester);
      final n = link.sent.length;
      final g = await tester.startGesture(tester.getCenter(stopFinder));
      await tester.pump(const Duration(milliseconds: 30));
      await g.moveBy(const Offset(60, -10));
      await tester.pump();
      await g.moveBy(const Offset(0, -200)); // incluso fuera del botón
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(c.state, RobotState.stop);
      expectAllStopFrom(link, n);
      await finish(tester, c, link);
    });

    testWidgets('dedo cancelado por el sistema no pierde el STOP',
        (tester) async {
      final (link, c) = await pumpManual(tester);
      final n = link.sent.length;
      final g = await tester.startGesture(tester.getCenter(stopFinder));
      await tester.pump(const Duration(milliseconds: 30));
      await g.cancel();
      await tester.pump();
      expect(c.state, RobotState.stop);
      expect(link.sent.length, greaterThan(n));
      expectAllStopFrom(link, n);
      await finish(tester, c, link);
    });

    testWidgets('dos dedos: manteniendo adelante, otro dedo en STOP → STOP',
        (tester) async {
      final (link, c) = await pumpManual(tester);
      final fwd = find.byKey(ControlScreen.directionKey(Direction.forward));
      await tester.scrollUntilVisible(fwd, 100,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final a = await tester.startGesture(tester.getCenter(fwd), pointer: 1);
      await tester.pump(const Duration(milliseconds: 200));
      expect(link.sent.last.dir, Direction.forward);

      final n = link.sent.length;
      final b =
          await tester.startGesture(tester.getCenter(stopFinder), pointer: 2);
      expect(c.state, RobotState.stop);
      expect(c.dir, Direction.none);
      // El dedo de adelante sigue apoyado: no vuelve a pedir dirección.
      await tester.pump(const Duration(milliseconds: 500));
      expectAllStopFrom(link, n);
      await b.up();
      await a.up();
      await tester.pump(const Duration(milliseconds: 300));
      expectAllStopFrom(link, n);
      await finish(tester, c, link);
    });

    testWidgets('toque normal: stop() doble es inocuo (solo STOPs, ≤ 2 inmediatos)',
        (tester) async {
      final (link, c) = await pumpManual(tester);
      final n = link.sent.length;
      await tester.tap(stopFinder);
      expect(c.state, RobotState.stop);
      expect(link.sent.length - n, inInclusiveRange(1, 2));
      expectAllStopFrom(link, n);
      // Después del STOP se puede volver a MANUAL normalmente.
      await tester.pump();
      await tester.tap(find.byKey(ControlScreen.stateKey(RobotState.manual)));
      await tester.pump();
      expect(c.state, RobotState.manual);
      await finish(tester, c, link);
    });

    testWidgets('lector de pantalla: la acción "tocar" del STOP pide STOP',
        (tester) async {
      final semantics = tester.ensureSemantics();
      final (link, c) = await pumpManual(tester);
      final node = tester.getSemantics(stopFinder);
      expect(node.label, Labels.stopSemantics);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      tester.semantics.tap(find.semantics.byLabel(Labels.stopSemantics));
      await tester.pump();
      expect(c.state, RobotState.stop);
      await finish(tester, c, link);
      semantics.dispose();
    });
  });

  group('AUD-03: HoldButton desmontado con el dedo apoyado', () {
    testWidgets('cambiar de pestaña con otro dedo y después levantar: '
        'sin excepción y dir 0', (tester) async {
      final (link, c) = await pumpManual(tester);
      final fwd = find.byKey(ControlScreen.directionKey(Direction.forward));
      await tester.scrollUntilVisible(fwd, 100,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final g = await tester.startGesture(tester.getCenter(fwd), pointer: 5);
      await tester.pump(const Duration(milliseconds: 200));
      expect(c.dir, Direction.forward);

      await tester.tap(find.text('Conexión'));
      await tester.pumpAndSettle();
      expect(c.dir, Direction.none);

      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(c.dir, Direction.none);
      expect(link.sent.last.dir, Direction.none);
      await finish(tester, c, link);
    });

    testWidgets('desmontar toda la app con el dedo apoyado: sin excepción',
        (tester) async {
      final (link, c) = await pumpManual(tester);
      final fwd = find.byKey(ControlScreen.directionKey(Direction.forward));
      await tester.scrollUntilVisible(fwd, 100,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final g = await tester.startGesture(tester.getCenter(fwd));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(); // corre la microtarea de dispose()
      expect(c.dir, Direction.none);
      await g.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
      c.dispose();
      await link.dispose();
    });
  });
}
