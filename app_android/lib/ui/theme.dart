// Tema Material 3 para uso en exterior con una mano: claro (mejor a pleno
// sol), contraste alto y botones grandes.

import 'package:flutter/material.dart';

/// Rojo de STOP: fijo, no depende del tema.
const Color kStopRed = Color(0xFFC62828);

/// Ámbar del banner de modo simulado.
const Color kSimulatedAmber = Color(0xFFFFB300);

/// Alto mínimo de los botones de mando.
const double kBigButtonHeight = 64;

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1B5E20),
    contrastLevel: 1.0,
  );
  const bigText = TextStyle(fontSize: 18, fontWeight: FontWeight.w700);
  const minSize = Size(64, kBigButtonHeight);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    visualDensity: VisualDensity.standard,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: minSize, textStyle: bigText),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: minSize,
        textStyle: bigText,
        side: BorderSide(color: scheme.outline, width: 2),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        minimumSize: const Size(48, 56),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
  );
}
