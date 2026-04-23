# ------------------------------------------------------------
# Codigo Main Nodo Principal de Toma de Decisiones
# Funcion:
#   - Recibe datos del nodo de sensores desde el topic "sensores"
#   - Analiza estados de los finales de carrera
#   - Envia ordenes de movimiento al nodo de motores
#
# Topic de sensores esperado:
#   [bumper_izq, bumper_centro, bumper_der,
#    ultra_izq, ultra_centro, ultra_der,
#    roll, pitch, yaw,
#    gps_lat, gps_lon, gps_alt, gps_fix]
#
# Logica actual:
#   - Espera datos del nodo de motores y del nodo de sensores
#   - Inicia avance continuo
#   - Si se activa cualquier bumper durante el avance:
#       1) envia STOP
#       2) cuando el STOP termina, envia retroceso temporizado
#       3) cuando el retroceso termina, vuelve a avanzar
#
# Nombre: sensor_decision_node.py
# Version: 2.0
# Fecha: 23/04/2026
# Autor: Angel Alegre
# ------------------------------------------------------------

import math
from typing import List

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy

from std_msgs.msg import Float32MultiArray, Int32MultiArray


class SensorDecisionNode(Node):
    # Estados devueltos por el ESP32 motor
    STATE_IDLE = 0
    STATE_ACCEPTED = 1
    STATE_EXECUTING = 2
    STATE_DONE = 3
    STATE_ABORTED = 4
    STATE_ERROR = 5

    # Convencion logica compartida con el nodo motor
    DIR_REVERSE = 0
    DIR_FORWARD = 1

    def __init__(self):
        super().__init__('sensor_decision_node')

        # ----------------------------------------------------
        # Parametros de prueba / ajuste rapido
        # ----------------------------------------------------
        self.forward_pwm = 80
        self.reverse_pwm = 80
        self.reverse_time_ms = 3000

        # ----------------------------------------------------
        # QoS
        # ----------------------------------------------------
        sensor_qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
            reliability=ReliabilityPolicy.BEST_EFFORT
        )

        default_qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            depth=10
        )

        # ----------------------------------------------------
        # Subs / pubs
        # ----------------------------------------------------
        self.sensores_sub = self.create_subscription(
            Float32MultiArray,
            'sensores',
            self.sensores_callback,
            sensor_qos
        )

        self.motion_status_sub = self.create_subscription(
            Int32MultiArray,
            'motion_status',
            self.motion_status_callback,
            default_qos
        )

        self.motion_cmd_pub = self.create_publisher(
            Int32MultiArray,
            'motion_cmd',
            default_qos
        )

        # ----------------------------------------------------
        # Estado interno
        # ----------------------------------------------------
        self.motor_ready = False
        self.sensor_ready = False
        self.started = False

        self.mode = 'INIT'
        self.next_cmd_id = 1
        self.pending_cmd_id = None

        self.bumpers_armed = True
        self.last_sensores: List[float] = []
        self.last_bumpers = [0, 0, 0]

        # Timer principal
        self.main_timer = self.create_timer(0.20, self.main_loop)

        self.get_logger().info('Nodo sensor_decision_node iniciado')

    # ========================================================
    # Helpers de comandos
    # ========================================================
    def new_cmd_id(self) -> int:
        cmd_id = self.next_cmd_id
        self.next_cmd_id += 1
        return cmd_id

    def publish_motion_cmd(
        self,
        cmd_id: int,
        l_dir: int,
        l_pwm: int,
        r_dir: int,
        r_pwm: int,
        duration_ms: int
    ):
        msg = Int32MultiArray()
        msg.data = [cmd_id, l_dir, l_pwm, r_dir, r_pwm, duration_ms]
        self.motion_cmd_pub.publish(msg)
        self.get_logger().info(f'CMD -> id={cmd_id}, data={list(msg.data)}')

    def send_forward_continuous(self):
        cmd_id = self.new_cmd_id()
        self.publish_motion_cmd(
            cmd_id,
            self.DIR_FORWARD, self.forward_pwm,
            self.DIR_FORWARD, self.forward_pwm,
            0
        )
        self.mode = 'FORWARDING'
        self.pending_cmd_id = None
        self.get_logger().info('Estado -> FORWARDING')

    def send_stop(self):
        cmd_id = self.new_cmd_id()
        # En el nodo motor, STOP se detecta por PWM = 0 en ambos lados
        self.publish_motion_cmd(cmd_id, 0, 0, 0, 0, 1)
        self.mode = 'WAIT_STOP_DONE'
        self.pending_cmd_id = cmd_id
        self.get_logger().info(f'Estado -> WAIT_STOP_DONE (cmd_id={cmd_id})')

    def send_reverse_timed(self):
        cmd_id = self.new_cmd_id()
        self.publish_motion_cmd(
            cmd_id,
            self.DIR_REVERSE, self.reverse_pwm,
            self.DIR_REVERSE, self.reverse_pwm,
            self.reverse_time_ms
        )
        self.mode = 'WAIT_REVERSE_DONE'
        self.pending_cmd_id = cmd_id
        self.get_logger().info(f'Estado -> WAIT_REVERSE_DONE (cmd_id={cmd_id})')

    # ========================================================
    # Callback sensores
    # ========================================================
    def sensores_callback(self, msg: Float32MultiArray):
        data = list(msg.data)

        if len(data) < 3:
            self.get_logger().warn(f'sensores inválido: {data}')
            return

        self.sensor_ready = True
        self.last_sensores = data

        # Convencion actual del firmware:
        # data[0] = bumper izquierdo
        # data[1] = bumper centro
        # data[2] = bumper derecho
        left = 1 if data[0] >= 0.5 else 0
        center = 1 if data[1] >= 0.5 else 0
        right = 1 if data[2] >= 0.5 else 0

        self.last_bumpers = [left, center, right]
        any_active = (left == 1 or center == 1 or right == 1)

        # Rearmado cuando todos vuelven a cero
        if not any_active:
            self.bumpers_armed = True
            return

        # Solo reaccionar si estamos avanzando
        if self.mode != 'FORWARDING':
            return

        # Evitar múltiples disparos con el mismo contacto sostenido
        if not self.bumpers_armed:
            return

        self.bumpers_armed = False

        self.get_logger().warn(
            f'Bumper activado -> left={left}, center={center}, right={right}'
        )

        self.send_stop()

    # ========================================================
    # Callback estado motores
    # ========================================================
    def motion_status_callback(self, msg: Int32MultiArray):
        data = list(msg.data)

        if len(data) < 7:
            self.get_logger().warn(f'motion_status inválido: {data}')
            return

        cmd_id = int(data[0])
        state = int(data[1])
        remaining_ms = int(data[6])

        self.motor_ready = True

        if state in (self.STATE_DONE, self.STATE_ABORTED, self.STATE_ERROR):
            self.get_logger().info(
                f'STATUS -> id={cmd_id}, state={state}, remaining={remaining_ms}'
            )

        if self.pending_cmd_id is None:
            return

        if cmd_id != self.pending_cmd_id:
            return

        if state == self.STATE_DONE:
            if self.mode == 'WAIT_STOP_DONE':
                self.pending_cmd_id = None
                self.send_reverse_timed()

            elif self.mode == 'WAIT_REVERSE_DONE':
                self.pending_cmd_id = None
                self.send_forward_continuous()

        elif state == self.STATE_ERROR:
            self.get_logger().error(
                f'El ESP32 motor devolvió ERROR para cmd_id={cmd_id}'
            )
            self.pending_cmd_id = None
            self.mode = 'INIT'

    # ========================================================
    # Lazo principal
    # ========================================================
    def main_loop(self):
        # Esperar ambos nodos
        if not self.motor_ready:
            return

        if not self.sensor_ready:
            return

        # Arranque inicial
        if not self.started:
            self.started = True
            self.send_forward_continuous()

    # ========================================================
    # Parada segura opcional
    # ========================================================
    def send_stop_if_possible(self):
        try:
            self.publish_motion_cmd(9999, 0, 0, 0, 0, 1)
        except Exception:
            pass


def main(args=None):
    rclpy.init(args=args)
    node = SensorDecisionNode()

    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        node.get_logger().info('Interrupción por teclado, cerrando nodo...')
    finally:
        node.send_stop_if_possible()
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()