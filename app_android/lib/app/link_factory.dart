// ÚNICO lugar donde se elige y construye el enlace con el robot.
//
// En la APK de prueba el enlace por defecto es el robot SIMULADO. El robot
// real (BLE) queda pendiente del firmware BLE del ESP: cuando exista, se
// cablea acá (y se habilita la opción en la pantalla de conexión).

import '../core/app_config.dart';
import '../core/robot_link.dart';
import '../core/simulated_robot_link.dart';

/// Enlace por defecto de la app: robot simulado.
RobotLink createDefaultLink(AppConfig config) => SimulatedRobotLink(config);
