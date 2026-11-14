// App Gramanova (E7, robot cortadora) — APK de prueba (robot simulado por defecto).

import 'package:flutter/widgets.dart';

import 'app/lifecycle_observer.dart';
import 'app/link_factory.dart';
import 'app/session_controller.dart';
import 'core/app_config.dart';
import 'ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  const config = AppConfig.fromEnvironment;
  // El enlace se elige en un único lugar: lib/app/link_factory.dart.
  final link = createDefaultLink(config);
  final controller = SessionController(link: link, config: config);

  // Segundo plano / cierre → STOP seguro con envío inmediato.
  WidgetsBinding.instance.addObserver(SessionLifecycleObserver(controller));

  runApp(CortadoraApp(controller: controller));
}
