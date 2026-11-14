// Tests de widgets de la UI con el RobotLink falso propio (test/app/fakes.dart).

import 'package:cortadora_e7/app/session_controller.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:cortadora_e7/ui/app.dart';
import 'package:cortadora_e7/ui/labels.dart';
import 'package:cortadora_e7/ui/screens/connection_screen.dart';
import 'package:cortadora_e7/ui/screens/control_screen.dart';
import 'package:cortadora_e7/ui/widgets/stop_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app/fakes.dart';

Future<(FakeRobotLink, SessionController)> pumpApp(
  WidgetTester tester, {
  bool simulated = true,
  bool toolsEnabled = false,
}) async {
  // Pantalla de teléfono vertical.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);

  final link = FakeRobotLink(isSimulated: simulated);
  final c = makeController(link, toolsEnabled: toolsEnabled);
  _current = c;
  await tester.pumpWidget(CortadoraApp(controller: c));
  addTearDown(link.dispose);
  return (link, c);
}

SessionController? _current;

/// Desmonta la app y desecha el controlador DENTRO del test: el framework
/// verifica timers pendientes (heartbeat) antes de correr los tearDown.
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  _current?.dispose();
  _current = null;
}

Future<void> goToControl(WidgetTester tester) async {
  await tester.tap(find.text('Control'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('banner MODO SIMULADO y STOP visibles en todas las pantallas',
      (tester) async {
    await pumpApp(tester);

    expect(find.text(Labels.simulatedBanner), findsOneWidget);
    expect(find.byKey(StopButton.buttonKey), findsOneWidget);
    expect(find.text('Robot simulado'), findsOneWidget);

    await goToControl(tester);
    expect(find.text(Labels.simulatedBanner), findsOneWidget);
    expect(find.byKey(StopButton.buttonKey), findsOneWidget);

    // El STOP está siempre habilitado.
    final stop = tester.widget<ButtonStyleButton>(
        find.byKey(StopButton.buttonKey));
    expect(stop.onPressed, isNotNull);
    await unmount(tester);
  });

  testWidgets('sin banner si el enlace no es simulado', (tester) async {
    await pumpApp(tester, simulated: false);
    expect(find.text(Labels.simulatedBanner), findsNothing);
    expect(find.byKey(StopButton.buttonKey), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('robot real (BLE) visible pero deshabilitado con aviso',
      (tester) async {
    await pumpApp(tester);
    final ble = tester.widget<ListTile>(find.byKey(ConnectionScreen.bleOptionKey));
    expect(ble.enabled, isFalse);
    expect(find.textContaining(Labels.blePending), findsOneWidget);
    final sim =
        tester.widget<ListTile>(find.byKey(ConnectionScreen.simulatedOptionKey));
    expect(sim.enabled, isTrue);
    expect(find.text('Enlace: desconectado'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('herramientas deshabilitadas con aviso cuando toolsEnabled=false',
      (tester) async {
    final (link, _) = await pumpApp(tester);
    await tester.tap(find.byKey(ConnectionScreen.connectKey));
    await tester.pump();
    expect(find.text('Enlace: conectado'), findsOneWidget);

    await goToControl(tester);
    await tester.tap(find.byKey(ControlScreen.stateKey(RobotState.manual)));
    await tester.pump();

    await tester.scrollUntilVisible(
        find.byKey(ControlScreen.cutterKey), 200,
        scrollable: find.byType(Scrollable).first);
    for (final k in [ControlScreen.cutterKey, ControlScreen.trimmerKey]) {
      final b = tester.widget<ButtonStyleButton>(find.byKey(k));
      expect(b.onPressed, isNull, reason: 'herramienta $k debe estar bloqueada');
    }
    expect(find.text(Labels.toolsLocked), findsOneWidget);

    await tester.tap(find.byKey(ControlScreen.cutterKey), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(link.sent, isNotEmpty);
    expect(link.sent.map((e) => e.cutter), everyElement(0));
    expect(link.sent.map((e) => e.trimmer), everyElement(0));
    await unmount(tester);
  });

  testWidgets('panel de lo pedido con la leyenda de no confirmado',
      (tester) async {
    final (link, _) = await pumpApp(tester);
    await tester.tap(find.byKey(ConnectionScreen.connectKey));
    await tester.pump();
    await goToControl(tester);
    link.emit(const GpsFix(lat: -25.28, lon: -57.63, simulated: true));
    link.emit(const CommandAck(7));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.scrollUntilVisible(
        find.text(Labels.requestedLegend), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text(Labels.requestedTitle), findsOneWidget);
    expect(find.text(Labels.requestedLegend), findsOneWidget);
    expect(find.text('GPS (simulado)'), findsOneWidget);
    expect(find.textContaining(Labels.ackMeaning), findsOneWidget);
    expect(find.textContaining('ejecutado)'), findsOneWidget);
    expect(find.textContaining('10 Hz'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('mantener apretado adelante pide dir 1; soltar pide dir 0',
      (tester) async {
    final (link, c) = await pumpApp(tester);
    await tester.tap(find.byKey(ConnectionScreen.connectKey));
    await tester.pump();
    await goToControl(tester);
    await tester.tap(find.byKey(ControlScreen.stateKey(RobotState.manual)));
    await tester.pump();

    final fwd = find.byKey(ControlScreen.directionKey(Direction.forward));
    await tester.ensureVisible(fwd);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(fwd));
    await tester.pump(const Duration(milliseconds: 350));
    expect(c.dir, Direction.forward);
    expect(link.sent.last.dir, Direction.forward);

    await gesture.up();
    await tester.pump();
    expect(c.dir, Direction.none);
    expect(link.sent.last.dir, Direction.none);
    await unmount(tester);
  });

  testWidgets('el botón STOP pide STOP de inmediato', (tester) async {
    final (link, c) = await pumpApp(tester);
    await tester.tap(find.byKey(ConnectionScreen.connectKey));
    await tester.pump();
    await goToControl(tester);
    await tester.tap(find.byKey(ControlScreen.stateKey(RobotState.manual)));
    await tester.pump();
    expect(c.state, RobotState.manual);

    final n = link.sent.length;
    await tester.tap(find.byKey(StopButton.buttonKey));
    await tester.pump();
    expect(c.state, RobotState.stop);
    // Al apoyar (AUD-02) y al levantar (onPressed): 1 o 2 STOP inmediatos.
    expect(link.sent.length - n, inInclusiveRange(1, 2));
    expect(link.sent.skip(n).map((e) => e.state),
        everyElement(RobotState.stop));
    expect(link.sent.last.state, RobotState.stop);
    await unmount(tester);
  });

  testWidgets('modo pulso: tocar izquierda pide un pulso de giro',
      (tester) async {
    final (link, c) = await pumpApp(tester);
    await tester.tap(find.byKey(ConnectionScreen.connectKey));
    await tester.pump();
    await goToControl(tester);
    await tester.tap(find.byKey(ControlScreen.stateKey(RobotState.manual)));
    await tester.pump();

    await tester.scrollUntilVisible(find.byKey(ControlScreen.turnModeKey), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pulsos'));
    await tester.pumpAndSettle();
    expect(c.turnMode, TurnMode.pulse);

    final left = find.byKey(ControlScreen.directionKey(Direction.left));
    await tester.scrollUntilVisible(left, -150,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(left);
    await tester.pump(const Duration(milliseconds: 150));
    expect(c.dir, Direction.left);
    await tester.pump(kTurnPulseDuration);
    expect(c.dir, Direction.none);
    expect(link.sent.last.dir, Direction.none);
    await unmount(tester);
  });

  testWidgets('cambiar de pantalla suelta la dirección', (tester) async {
    final (_, c) = await pumpApp(tester);
    await tester.tap(find.byKey(ConnectionScreen.connectKey));
    await tester.pump();
    await goToControl(tester);
    await tester.tap(find.byKey(ControlScreen.stateKey(RobotState.manual)));
    await tester.pump();
    c.pressDirection(Direction.backward);
    await tester.pump();
    await tester.tap(find.text('Conexión'));
    await tester.pumpAndSettle();
    expect(c.dir, Direction.none);
    await unmount(tester);
  });
}
