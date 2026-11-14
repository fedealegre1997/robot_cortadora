// Adaptador entre el ciclo de vida de Flutter y el controlador de sesión.
// Cualquier estado distinto de `resumed` (inactive, hidden, paused, detached)
// → STOP seguro con envío inmediato (ver SessionController.handleLifecycleState).

import 'package:flutter/widgets.dart';

import 'session_controller.dart';

class SessionLifecycleObserver with WidgetsBindingObserver {
  SessionLifecycleObserver(this.controller);

  final SessionController controller;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    controller.handleLifecycleState(state);
  }
}
