# ------------------------------------------------------------
# Brain v3.0 — Nodo principal de toma de decisiones
#
# Protocolo v4.0 del motor (sin encoders, rumbo con IMU).
#
# motion_cmd  = [cmd_id, modo, param, bordeadora_on, cortadora_on]
# motion_status = [cmd_id, estado, pwm_izq, pwm_der, feedback,
#                  rumbo, rumbo_obj, imu_estado, seg_desde_cal]
#
# sensores (24 valores):
#   0-2   bumpers (izq, centro, der)
#   3-5   ultrasonidos cm
#   6-8   roll, pitch, yaw
#   9-14  GPS
#   15-23 APP
#
# Lógica:
#   1. Esperar sensores + motor listos
#   2. Calibrar IMU (5 s)
#   3. Avanzar recto continuo a FORWARD_SPEED cm/s, con CORTADORA + BORDEADORA encendidas
#   4. Reacción a obstáculo → STOP → retroceder (REVERSE_TIME_S) → girar → avanzar:
#        - bumper DERECHO   → giro 90° IZQUIERDA
#        - bumper IZQUIERDO → giro 90° DERECHA (espejo)
#        - bumper CENTRAL   → giro 180° (izquierda)
#        - ultrasónico CENTRAL < ULTRA_STOP_CM → giro 90° IZQUIERDA
#
# Versión: 3.1
# Fecha: 2026-11-15
# Autor: Angel Alegre
# ------------------------------------------------------------

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from std_msgs.msg import Float32MultiArray, Int32MultiArray


# Modos del protocolo v4
MODE_STOP = 0
MODE_ADELANTE = 1
MODE_ATRAS = 2
MODE_GIRO_IZQ = 3
MODE_GIRO_DER = 4
MODE_PIVOT = 5
MODE_CALIBRAR = 6
MODE_FIJAR_RUMBO = 7

# Estados del motor
ST_IDLE = 0
ST_ACCEPTED = 1
ST_EXECUTING = 2
ST_DONE = 3
ST_ABORTED = 4
ST_ERROR = 5

# IMU estados
IMU_FALLA = 0
IMU_INICIANDO = 1
IMU_LISTO = 2
IMU_RECALIBRANDO = 3


class BrainNode(Node):

    FORWARD_SPEED = 15      # cm/s
    REVERSE_SPEED = 15      # cm/s
    REVERSE_TIME_S = 2.0    # segundos de retroceso (controlado por timer, motor continuo)
    TURN_DEGREES = 90       # grados del giro lateral (bumper izq/der, ultrasonico)
    TURN_DEGREES_CEN = 180  # grados del giro con bumper central (media vuelta)
    ULTRA_STOP_CM = 30      # distancia del ultrasonico CENTRAL para reaccionar (cm)
    START_GRACE_S = 3.0     # tras arrancar, ignorar bumpers/ultrasonico estos segundos
    # Accesorios en operacion normal (CUIDADO: la cuchilla gira)
    CORTADORA = 1           # cortadora principal encendida
    BORDEADORA = 1          # bordeadora encendida

    def __init__(self):
        super().__init__('brain_node')

        # --- QoS ---
        sensor_qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST, depth=10,
            reliability=ReliabilityPolicy.BEST_EFFORT,
        )
        default_qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST, depth=10,
        )

        # --- Subs / Pubs ---
        self.create_subscription(
            Float32MultiArray, '/sensores',
            self.sensores_cb, sensor_qos)
        self.create_subscription(
            Int32MultiArray, '/motion_status',
            self.status_cb, default_qos)
        self.cmd_pub = self.create_publisher(
            Int32MultiArray, '/motion_cmd', default_qos)

        # --- Estado ---
        self.next_cmd_id = 1
        self.pending_cmd_id = None
        self.state = 'WAIT_READY'
        self.sensor_ready = False
        self.motor_ready = False
        self.imu_estado = IMU_FALLA

        self.bumpers = [0, 0, 0]
        self.bumpers_armed = True
        # Giro pendiente segun el disparador (modo + grados)
        self.pending_turn_modo = MODE_GIRO_IZQ
        self.pending_turn_deg = self.TURN_DEGREES
        # Bandera de arranque: la secuencia espera el bumper DERECHO para largar
        self.start_time_run = None

        self.reverse_timer = None
        self.cmd_sent_time = None
        self.CMD_TIMEOUT = 10.0
        self.startup_time = self.get_clock().now()
        self.STARTUP_DELAY = 8.0  # esperar que la IMU se estabilice
        self.cal_attempts = 0
        self.MAX_CAL_ATTEMPTS = 5

        self.create_timer(0.2, self.tick)
        self.get_logger().info('Brain v3.1 iniciado — esperando sensores y motor')

    # --------------------------------------------------------
    # Publicar comando
    # --------------------------------------------------------
    def send_cmd(self, modo, param=0, bordeadora=0, cortadora=0):
        cmd_id = self.next_cmd_id
        self.next_cmd_id += 1
        msg = Int32MultiArray()
        msg.data = [cmd_id, modo, param, bordeadora, cortadora]
        self.cmd_pub.publish(msg)
        self.pending_cmd_id = cmd_id
        self.cmd_sent_time = self.get_clock().now()
        self.get_logger().info(
            f'CMD #{cmd_id} → modo={modo} param={param} bord={bordeadora} cort={cortadora}')
        return cmd_id

    # --------------------------------------------------------
    # Callbacks
    # --------------------------------------------------------
    def sensores_cb(self, msg: Float32MultiArray):
        d = list(msg.data)
        if len(d) < 6:          # bumpers (0-2) + ultrasonidos (3-5)
            return
        self.sensor_ready = True
        self.bumpers = [
            1 if d[0] >= 0.5 else 0,   # izquierdo
            1 if d[1] >= 0.5 else 0,   # central
            1 if d[2] >= 0.5 else 0,   # derecho
        ]
        ultra_cen = d[4]        # ultrasonico central (cm; <=0 = sin lectura)

        any_bumper = any(b == 1 for b in self.bumpers)
        if not any_bumper:
            self.bumpers_armed = True   # re-armar al soltar todos

        # Bandera de arranque: esperar el bumper DERECHO para largar la secuencia
        if self.state == 'WAIT_START':
            if self.bumpers[2] and self.bumpers_armed:
                self.bumpers_armed = False
                self.start_time_run = self.get_clock().now()
                self.get_logger().info('Bumper derecho → arranca la secuencia de movimiento')
                self.transition('FORWARDING')
            return

        if self.state != 'FORWARDING':
            return

        # Gracia inicial: los primeros START_GRACE_S ignorar disparadores
        if self.start_time_run is not None:
            elapsed = (self.get_clock().now() - self.start_time_run).nanoseconds / 1e9
            if elapsed < self.START_GRACE_S:
                return

        # Elegir el giro segun el disparador. Prioridad:
        #   central (180) > derecho (90 izq) > izquierdo (90 der) > ultrasonico (90 izq)
        trigger = None
        if any_bumper and self.bumpers_armed:
            if self.bumpers[1]:
                trigger = (MODE_GIRO_IZQ, self.TURN_DEGREES_CEN, 'bumper central')
            elif self.bumpers[2]:
                trigger = (MODE_GIRO_IZQ, self.TURN_DEGREES, 'bumper derecho')
            elif self.bumpers[0]:
                trigger = (MODE_GIRO_DER, self.TURN_DEGREES, 'bumper izquierdo')
        if trigger is None and 0 < ultra_cen < self.ULTRA_STOP_CM:
            trigger = (MODE_GIRO_IZQ, self.TURN_DEGREES,
                       f'ultrasonico central {ultra_cen:.0f}cm')

        if trigger is None:
            return

        if any_bumper:
            self.bumpers_armed = False
        self.pending_turn_modo, self.pending_turn_deg, razon = trigger
        lado = 'IZQ' if self.pending_turn_modo == MODE_GIRO_IZQ else 'DER'
        self.get_logger().warning(
            f'Obstaculo: {razon} → retroceso + giro {self.pending_turn_deg}° {lado}')
        self.transition('STOPPING')

    def status_cb(self, msg: Int32MultiArray):
        d = list(msg.data)
        if len(d) < 9:
            return
        self.motor_ready = True
        cmd_id = d[0]
        estado = d[1]
        self.imu_estado = d[7]

        imu_nombres = {0: 'FALLA', 1: 'INICIANDO', 2: 'LISTO', 3: 'RECALIBRANDO'}
        if not hasattr(self, '_last_imu_log') or self.imu_estado != self._last_imu_log:
            self.get_logger().info(
                f'Motor status: imu={imu_nombres.get(self.imu_estado, "?")}({self.imu_estado})')
            self._last_imu_log = self.imu_estado

        if self.pending_cmd_id is None or cmd_id != self.pending_cmd_id:
            return

        if estado == ST_DONE:
            self.on_cmd_done()
        elif estado == ST_ERROR:
            feedback = d[4]
            self.get_logger().error(f'Motor ERROR cmd #{cmd_id}, feedback={feedback}')
            self.on_cmd_error()

    # --------------------------------------------------------
    # Máquina de estados
    # --------------------------------------------------------
    def transition(self, new_state):
        self.get_logger().info(f'Estado: {self.state} → {new_state}')
        self.state = new_state

        if new_state == 'WAIT_START':
            self.pending_cmd_id = None
            self.get_logger().info(
                '>>> Listo. Tocá el BUMPER DERECHO para arrancar la secuencia <<<')

        elif new_state == 'CALIBRATING':
            self.send_cmd(MODE_CALIBRAR, 5)

        elif new_state == 'FORWARDING':
            self.pending_cmd_id = None
            self.send_cmd(MODE_ADELANTE, self.FORWARD_SPEED,
                          bordeadora=self.BORDEADORA, cortadora=self.CORTADORA)
            self.pending_cmd_id = None  # avance continuo, no esperamos DONE

        elif new_state == 'STOPPING':
            self.send_cmd(MODE_STOP,
                          bordeadora=self.BORDEADORA, cortadora=self.CORTADORA)

        elif new_state == 'REVERSING':
            self.send_cmd(MODE_ATRAS, self.REVERSE_SPEED,
                          bordeadora=self.BORDEADORA, cortadora=self.CORTADORA)
            self.reverse_timer = self.create_timer(
                self.REVERSE_TIME_S, self.reverse_timeout, callback_group=None)

        elif new_state == 'TURNING':
            self.send_cmd(self.pending_turn_modo, self.pending_turn_deg,
                          bordeadora=self.BORDEADORA, cortadora=self.CORTADORA)

    def on_cmd_done(self):
        self.pending_cmd_id = None

        if self.state == 'CALIBRATING':
            self.get_logger().info('Calibración IMU completada')
            self.transition('WAIT_START')

        elif self.state == 'STOPPING':
            self.transition('REVERSING')

        elif self.state == 'WAIT_REVERSE_STOP':
            self.transition('TURNING')

        elif self.state == 'TURNING':
            self.transition('FORWARDING')

    def on_cmd_error(self):
        self.pending_cmd_id = None
        if self.state == 'CALIBRATING':
            self.cal_attempts += 1
            if self.cal_attempts >= self.MAX_CAL_ATTEMPTS:
                self.get_logger().warning(
                    f'Calibración falló {self.cal_attempts} veces, sin calibrar')
                self.transition('WAIT_START')
            else:
                self.get_logger().warning(
                    f'Calibración falló (intento {self.cal_attempts}/{self.MAX_CAL_ATTEMPTS}), '
                    'reintentando en 5 s... ¡Robot debe estar QUIETO!')
                self._retry_timer = self.create_timer(5.0, self.retry_calibration)
        elif self.state == 'TURNING':
            self.get_logger().warning('Giro falló (IMU no calibrada), saltando giro → avanzar')
            self.transition('FORWARDING')
        else:
            self.get_logger().error(f'Error en estado {self.state}, enviando STOP')
            self.send_cmd(MODE_STOP)
            self.state = 'WAIT_READY'

    def retry_calibration(self):
        if hasattr(self, '_retry_timer') and self._retry_timer:
            self._retry_timer.destroy()
            self._retry_timer = None
        self.transition('CALIBRATING')

    def reverse_timeout(self):
        if self.reverse_timer:
            self.reverse_timer.destroy()
            self.reverse_timer = None
        if self.state == 'REVERSING':
            self.get_logger().info('Retroceso completado (timeout)')
            self.send_cmd(MODE_STOP,
                          bordeadora=self.BORDEADORA, cortadora=self.CORTADORA)
            self.state = 'WAIT_REVERSE_STOP'

    # --------------------------------------------------------
    # Tick principal
    # --------------------------------------------------------
    def tick(self):
        if self.state == 'WAIT_READY':
            if self.sensor_ready:
                elapsed = (self.get_clock().now() - self.startup_time).nanoseconds / 1e9
                if elapsed < self.STARTUP_DELAY:
                    return
                if self.imu_estado >= IMU_LISTO:
                    self.get_logger().info('IMU lista → calibrando')
                    self.transition('CALIBRATING')
                else:
                    self.get_logger().info(
                        f'IMU no lista (estado={self.imu_estado}), sin calibrar')
                    self.transition('WAIT_START')
            return

        # Timeout: si hay comando pendiente sin respuesta, reenviar
        if (self.pending_cmd_id is not None and self.cmd_sent_time is not None
                and self.state in ('CALIBRATING', 'STOPPING', 'WAIT_REVERSE_STOP', 'TURNING')):
            elapsed = (self.get_clock().now() - self.cmd_sent_time).nanoseconds / 1e9
            if elapsed > self.CMD_TIMEOUT:
                self.get_logger().warning(
                    f'Timeout ({self.CMD_TIMEOUT}s) en estado {self.state}, reenviando...')
                self.transition(self.state)

    # --------------------------------------------------------
    # Parada segura
    # --------------------------------------------------------
    def emergency_stop(self):
        try:
            msg = Int32MultiArray()
            msg.data = [9999, MODE_STOP, 0, 0, 0]
            self.cmd_pub.publish(msg)
        except Exception:
            pass


def main(args=None):
    rclpy.init(args=args)
    node = BrainNode()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, rclpy.executors.ExternalShutdownException):
        pass
    finally:
        try:
            node.emergency_stop()
            node.destroy_node()
            rclpy.try_shutdown()
        except Exception:
            pass


if __name__ == '__main__':
    main()
