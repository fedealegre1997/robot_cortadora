// Botón STOP: grande, rojo y siempre visible (vive en el Scaffold principal,
// por encima de la navegación, así que está en todas las pantallas).
// Siempre habilitado: pedir STOP nunca es peligroso.
//
// AUD-02: el STOP se pide al APOYAR el dedo (Listener.onPointerDown). Un
// Listener no participa de la arena de gestos: no se cancela si el dedo se
// desliza, si otro gesto (scroll) gana la arena o si el sistema cancela el
// puntero. `onPressed` (teclado) y la acción semántica `onTap` (lector de
// pantalla) quedan como caminos adicionales. Con el dedo, `stop()` se llama
// dos veces (al apoyar y al levantar): es idempotente, solo sale un STOP más.

import 'package:flutter/material.dart';

import '../../app/session_controller.dart';
import '../labels.dart';
import '../theme.dart';

class StopButton extends StatelessWidget {
  const StopButton({super.key, required this.controller});

  final SessionController controller;

  static const buttonKey = Key('stop_button');

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: Labels.stopSemantics,
      onTap: controller.stop,
      excludeSemantics: true,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => controller.stop(),
        child: SizedBox(
          width: double.infinity,
          height: 76,
          child: FilledButton.icon(
            key: buttonKey,
            onPressed: controller.stop,
            style: FilledButton.styleFrom(
              backgroundColor: kStopRed,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w900,
                letterSpacing: 4,
              ),
            ),
            icon: const Icon(Icons.pan_tool, size: 32),
            label: const Text(Labels.stop),
          ),
        ),
      ),
    );
  }
}
