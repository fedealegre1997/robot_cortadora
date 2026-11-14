// CONTRATO COMPARTIDO entre agentes (definido por el coordinador).

/// Configuración de compilación.
///
/// `TOOLS_ENABLED` habilita los pedidos de cortadora y bordeadora. Por defecto
/// `false`: en la APK de prueba los botones existen pero están bloqueados.
/// Solo se habilita con una compilación aparte pedida explícitamente por el
/// usuario: `--dart-define=TOOLS_ENABLED=true`.
class AppConfig {
  final bool toolsEnabled;

  const AppConfig({required this.toolsEnabled});

  /// Valor de la compilación actual.
  static const AppConfig fromEnvironment = AppConfig(
    toolsEnabled: bool.fromEnvironment('TOOLS_ENABLED', defaultValue: false),
  );

  /// Frecuencia del heartbeat (Directiva §3.1: 10 Hz).
  static const Duration heartbeatPeriod = Duration(milliseconds: 100);

  /// Timeout del ESP (Directiva §3.1): un comando con más de 300 ms = robot detenido.
  static const Duration espCommandTimeout = Duration(milliseconds: 300);
}
