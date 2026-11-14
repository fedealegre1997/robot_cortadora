// Botón de mando discreto con "mantener apretado".
//
// Usa Listener (eventos de puntero crudos) en vez de onTap para que el
// pedido empiece al apoyar el dedo y termine al levantarlo o al cancelarse
// el puntero. Si el botón desaparece mientras está apretado (cambio de
// pantalla), también se llama a [onRelease].

import 'dart:async';

import 'package:flutter/material.dart';

class HoldButton extends StatefulWidget {
  const HoldButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPress,
    this.onRelease,
    this.active = false,
    this.size = 96,
  });

  final IconData icon;
  final String label;

  /// null = deshabilitado.
  final VoidCallback? onPress;

  /// Se llama al soltar / cancelar. En modo "pulsos" puede ser null.
  final VoidCallback? onRelease;

  /// Resalta el botón si su dirección es la que se está pidiendo.
  final bool active;

  final double size;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> {
  bool _pressed = false;

  bool get _enabled => widget.onPress != null;

  void _down(PointerDownEvent _) {
    if (!mounted || !_enabled) return;
    setState(() => _pressed = true);
    widget.onPress!();
  }

  // AUD-03: el Listener puede entregar el "up" de un dedo que se apoyó antes
  // de que el botón se desmontara (cambio de pestaña con otro dedo). En ese
  // caso no se toca el State: la dirección ya la bajó dispose() (y el shell).
  void _up(PointerEvent _) {
    if (!mounted || !_pressed) return;
    setState(() => _pressed = false);
    widget.onRelease?.call();
  }

  @override
  void didUpdateWidget(HoldButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si se deshabilita mientras está apretado, el controlador ya bajó dir.
    if (!_enabled && _pressed) _pressed = false;
  }

  @override
  void dispose() {
    final release = widget.onRelease;
    if (_pressed && release != null) {
      // Diferido: no se puede notificar listeners mientras se desmonta el árbol.
      scheduleMicrotask(release);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final highlighted = _enabled && (_pressed || widget.active);
    final Color bg;
    final Color fg;
    if (!_enabled) {
      bg = scheme.surfaceContainerHighest;
      fg = scheme.onSurface.withValues(alpha: 0.38);
    } else if (highlighted) {
      bg = scheme.primary;
      fg = scheme.onPrimary;
    } else {
      bg = scheme.primaryContainer;
      fg = scheme.onPrimaryContainer;
    }
    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
      excludeSemantics: true,
      child: Listener(
        onPointerDown: _down,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _enabled ? scheme.outline : scheme.outlineVariant,
              width: 2,
            ),
          ),
          padding: const EdgeInsets.all(6),
          // scaleDown: con textScaler alto el rótulo se achica, nunca desborda.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 40, color: fg),
                Text(
                  widget.label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
