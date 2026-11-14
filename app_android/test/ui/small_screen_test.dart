// Teléfono de prueba: Samsung Galaxy M12 (SM-M127F), 720×1600 px a 2.0 →
// 360×800 dp lógicos, en vertical. Se simulan barra de estado (24 dp) y
// barra de navegación de Samsung (48 dp), y texto grande (textScaler 1.3).
// Verifica: STOP visible sin scroll y tocable, y ningún overflow.

import 'package:cortadora_e7/app/session_controller.dart';
import 'package:cortadora_e7/core/control_command.dart';
import 'package:cortadora_e7/core/robot_link.dart';
import 'package:cortadora_e7/ui/app.dart';
import 'package:cortadora_e7/ui/screens/connection_screen.dart';
import 'package:cortadora_e7/ui/screens/control_screen.dart';
import 'package:cortadora_e7/ui/widgets/stop_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../app/fakes.dart';

const double dpr = 2.0;
const Size logical = Size(360, 800);
const double statusBar = 24;
const double navBar = 48;

Future<void> setUpM12(WidgetTester tester) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logical * dpr;
  const pad = FakeViewPadding(top: statusBar * dpr, bottom: navBar * dpr);
  tester.view.padding = pad;
  tester.view.viewPadding = pad;
  tester.platformDispatcher.textScaleFactorTestValue = 1.3;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// STOP entero dentro del área útil (sin barra de estado ni de navegación)
/// y tocable (nada lo tapa).
void expectStopVisible(WidgetTester tester) {
  final stop = find.byKey(StopButton.buttonKey);
  expect(stop.hitTestable(), findsOneWidget);
  final r = tester.getRect(stop);
  expect(r.top, greaterThanOrEqualTo(statusBar));
  expect(r.bottom, lessThanOrEqualTo(logical.height - navBar));
  expect(r.left, greaterThanOrEqualTo(0));
  expect(r.right, lessThanOrEqualTo(logical.width));
  expect(r.height, greaterThanOrEqualTo(48));
}

/// Recorre todo el contenido desplazable, verificando en cada paso que no
/// hubo overflow y que el STOP sigue visible.
Future<void> scrollThrough(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.drag(find.byType(ListView), const Offset(0, -250));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expectStopVisible(tester);
  }
}

void main() {
  for (final toolsEnabled in [false, true]) {
    testWidgets(
        '360×800 dp, texto 1.3: STOP visible y sin overflow '
        '(toolsEnabled=$toolsEnabled)', (tester) async {
      await setUpM12(tester);
      final link = FakeRobotLink();
      final c = makeController(link, toolsEnabled: toolsEnabled);

      await tester.pumpWidget(CortadoraApp(controller: c));
      expect(tester.takeException(), isNull);
      expectStopVisible(tester);

      // Pantalla de conexión, desconectado.
      await scrollThrough(tester);
      await tester.drag(find.byType(ListView), const Offset(0, 3000));
      await tester.pump();
      await tester.scrollUntilVisible(
          find.byKey(ConnectionScreen.connectKey), 100,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byKey(ConnectionScreen.connectKey));
      await tester.pump();

      // Pantalla de control, conectado, MANUAL.
      await tester.tap(find.text('Control'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expectStopVisible(tester);
      await tester.tap(find.byKey(ControlScreen.stateKey(RobotState.manual)));
      await tester.pump();
      if (toolsEnabled) {
        await tester.scrollUntilVisible(find.byKey(ControlScreen.cutterKey), 100,
            scrollable: find.byType(Scrollable).first);
        await tester.pump();
        await tester.tap(find.byKey(ControlScreen.cutterKey));
        await tester.pump();
        expect(c.cutter, isTrue);
      }
      await scrollThrough(tester);

      // Modo pulso (otros rótulos en los botones de giro).
      await tester.drag(find.byType(ListView), const Offset(0, 3000));
      await tester.pump();
      c.setTurnMode(TurnMode.pulse);
      await tester.pump();
      await scrollThrough(tester);

      // Los botones de dirección son grandes (≥ 48 dp; diseño: 96 dp).
      await tester.drag(find.byType(ListView), const Offset(0, 3000));
      await tester.pump();
      await tester.scrollUntilVisible(
          find.byKey(ControlScreen.directionKey(Direction.backward)), 100,
          scrollable: find.byType(Scrollable).first);
      await tester.pump();
      for (final d in [
        Direction.forward,
        Direction.backward,
        Direction.left,
        Direction.right,
      ]) {
        final s = tester.getSize(find.byKey(ControlScreen.directionKey(d)));
        expect(s.width, greaterThanOrEqualTo(48));
        expect(s.height, greaterThanOrEqualTo(48));
      }

      // Sin conexión (otro aviso arriba) tampoco hay overflow.
      link.setStatus(LinkStatus.disconnected);
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, 3000));
      await tester.pump();
      await scrollThrough(tester);

      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }
}
