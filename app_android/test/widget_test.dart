// Smoke test de la app (reemplaza el test de contador de la plantilla).
// Usa el RobotLink falso propio: no depende de lib/core implementado.

import 'package:cortadora_e7/ui/app.dart';
import 'package:cortadora_e7/ui/labels.dart';
import 'package:cortadora_e7/ui/widgets/stop_button.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app/fakes.dart';

void main() {
  testWidgets('la app arranca con banner simulado y STOP visible',
      (tester) async {
    final link = FakeRobotLink();
    final c = makeController(link);
    await tester.pumpWidget(CortadoraApp(controller: c));

    expect(find.text(Labels.appTitle), findsOneWidget);
    expect(find.text(Labels.simulatedBanner), findsOneWidget);
    expect(find.byKey(StopButton.buttonKey), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
