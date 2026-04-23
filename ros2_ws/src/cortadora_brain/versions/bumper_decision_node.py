# ------------------------------------------------------------
# Codigo Main Nodo Principal de Toma de Decisiones
# Funcion:
#   - Recibe datos del nodo de sensores
#   - Analiza estados de los finales de carrera
#   - Envia ordenes de movimiento al nodo de motores
#
# Nombre: bumper_decision_node.py
# Version: 1.0
# Fecha: 06/04/2026 01:14
# Autor: Angel Alegre
# ------------------------------------------------------------

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy

from std_msgs.msg import UInt8MultiArray, Int32MultiArray


class BumperDecisionNode(Node):
    STATE_IDLE = 0
    STATE_ACCEPTED = 1
    STATE_EXECUTING = 2
    STATE_DONE = 3
    STATE_ABORTED = 4
    STATE_ERROR = 5

    DIR_REVERSE = 0
    DIR_FORWARD = 1

    def __init__(self):
        super().__init__('bumper_decision_node')

        self.forward_pwm = 80
        self.reverse_pwm = 80
        self.reverse_time_ms = 3000

        bumper_qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
            reliability=ReliabilityPolicy.BEST_EFFORT
        )

        default_qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            depth=10
        )

        self.bumpers_sub = self.create_subscription(
            UInt8MultiArray,
            'bumpers',
            self.bumpers_callback,
            bumper_qos
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

        self.motor_ready = False
        self.started = False

        self.mode = 'INIT'
        self.next_cmd_id = 1
        self.pending_cmd_id = None

        self.bumpers_armed = True
        self.last_bumpers = [0, 0, 0]

        self.main_timer = self.create_timer(0.20, self.main_loop)

        self.get_logger().info('Nodo bumper_decision_node iniciado')

    def new_cmd_id(self) -> int:
        cmd_id = self.next_cmd_id
        self.next_cmd_id += 1
        return cmd_id

    def publish_motion_cmd(self, cmd_id: int, l_dir: int, l_pwm: int,
                           r_dir: int, r_pwm: int, duration_ms: int):
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

    def bumpers_callback(self, msg: UInt8MultiArray):
        data = list(msg.data)

        if len(data) < 3:
            self.get_logger().warn(f'bumpers inválido: {data}')
            return

        self.last_bumpers = data[:3]
        left, center, right = self.last_bumpers
        any_active = (left == 1 or center == 1 or right == 1)

        if not any_active:
            self.bumpers_armed = True
            return

        if self.mode != 'FORWARDING':
            return

        if not self.bumpers_armed:
            return

        self.bumpers_armed = False

        self.get_logger().warn(
            f'Bumper activado -> left={left}, center={center}, right={right}'
        )

        self.send_stop()

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
            self.get_logger().error(f'El ESP32 motor devolvió ERROR para cmd_id={cmd_id}')
            self.pending_cmd_id = None

    def main_loop(self):
        if not self.motor_ready:
            return

        if not self.started:
            self.started = True
            self.send_forward_continuous()


def main(args=None):
    rclpy.init(args=args)
    node = BumperDecisionNode()

    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        node.get_logger().info('Interrupción por teclado, cerrando nodo...')
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
