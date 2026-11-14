// Textos de la UI (español). Centralizados para que la pantalla de mapa
// futura y los tests usen los mismos rótulos.

import '../core/control_command.dart';
import '../core/robot_link.dart';

abstract final class Labels {
  static const appTitle = 'Robot Cortadora E7';
  static const simulatedBanner = 'MODO SIMULADO';
  static const simulatedBannerDetail =
      'Sin robot real: los comandos van al simulador.';
  static const stop = 'STOP';
  static const stopSemantics = 'STOP: pedir detener todo';
  static const toolsLocked = 'Herramientas bloqueadas en esta APK de prueba';
  static const blePending = 'pendiente del firmware BLE del ESP';
  static const requestedTitle = 'Lo que la app está pidiendo';
  static const requestedLegend =
      'Esto es lo pedido, no lo confirmado. La app no recibe el estado del robot.';
  static const ackMeaning = 'recibido por el ESP';
  static const autoNotice =
      'Modo autónomo: iniciar, pausar y detener solo cambian el estado pedido. '
      'Esta APK no tiene editor de área: sin un área válida cargada en el '
      'robot, la Raspberry no permite AUTO_RUN y puede ignorar el pedido.';
  static const turnNotice =
      'El giro puede ser a tirones (protección anti-repetición del motor). '
      'Elegí "Mantener" o "Pulsos" según cómo responda.';
  static const notConnected =
      'Sin conexión: los controles están bloqueados. Si el ESP no recibe '
      'comandos durante más de 300 ms, detiene todo.';

  static String state(RobotState s) => switch (s) {
        RobotState.stop => 'STOP',
        RobotState.manual => 'MANUAL',
        RobotState.autoRun => 'AUTO_RUN',
        RobotState.autoPause => 'AUTO_PAUSE',
      };

  static String direction(Direction d) => switch (d) {
        Direction.none => 'nada',
        Direction.forward => 'adelante',
        Direction.backward => 'atrás',
        Direction.left => 'izquierda',
        Direction.right => 'derecha',
      };

  static String linkStatus(LinkStatus s) => switch (s) {
        LinkStatus.disconnected => 'desconectado',
        LinkStatus.connecting => 'conectando…',
        LinkStatus.connected => 'conectado',
      };
}
