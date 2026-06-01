# Arquitectura y Protocolo de Comunicación — Robot Cortadora

---

## Visión General del Sistema

```
[ESP32 Sensor] --micro-ROS--> [Brain ROS 2] --micro-ROS--> [ESP32 Motor]
```

| Bloque | Rol | Dirección de datos |
|---|---|---|
| **ESP32 Sensor** | Adquiere y publica datos de sensores | Solo publica → Brain |
| **Brain** | Nodo central de decisión | Suscribe sensores, publica comandos |
| **ESP32 Motor** | Ejecuta comandos de movimiento y accesorios | Suscribe comandos, publica estado |

---

## ESP32 Sensor — Publicación de sensores

El nodo `esp32_sensor_node` **solo publica**. No recibe comandos ni suscribe a ningún topic. Su única función es leer los sensores y publicar los datos para que el Brain los consuma.

### Topic publicado

| Topic | Tipo | QoS |
|---|---|---|
| `/sensores` | `Float32MultiArray` | reliable, 50 ms |

### Formato del arreglo (13 valores)

```
[bumper_izq, bumper_centro, bumper_der,
 ultra_izq,  ultra_centro,  ultra_der,
 roll, pitch, yaw,
 gps_lat, gps_lon, gps_alt, gps_fix]
```

| Índice | Campo | Unidad | Valores especiales |
|---|---|---|---|
| 0 | `bumper_izq` | — | `0.0` = libre, `1.0` = presionado |
| 1 | `bumper_centro` | — | `0.0` = libre, `1.0` = presionado |
| 2 | `bumper_der` | — | `0.0` = libre, `1.0` = presionado |
| 3 | `ultra_izq` | cm | `-1.0` = sin dato / dato viejo (>500 ms) |
| 4 | `ultra_centro` | cm | `-1.0` = sin dato / dato viejo (>500 ms) |
| 5 | `ultra_der` | cm | `-1.0` = sin dato / dato viejo (>500 ms) |
| 6 | `roll` | grados | Filtro complementario accel+gyro (α=0.98) |
| 7 | `pitch` | grados | Filtro complementario accel+gyro (α=0.98) |
| 8 | `yaw` | grados | Solo integración de giroscopio (deriva con el tiempo) |
| 9 | `gps_lat` | grados decimales | `NaN` = sin fix o dato viejo (>3 s) |
| 10 | `gps_lon` | grados decimales | `NaN` = sin fix o dato viejo (>3 s) |
| 11 | `gps_alt` | metros | `NaN` = sin fix o dato viejo (>3 s) |
| 12 | `gps_fix` | — | `0` = sin fix, `1` = GPS, `2` = DGPS. `-1.0` = dato viejo |

### Hardware — Pines del ESP32 Sensor

| GPIO | Función |
|---|---|
| 18 | Bumper izquierdo (INPUT, pull-up) |
| 22 | Bumper centro (INPUT, pull-up) |
| 19 | Bumper derecho (INPUT, pull-up) |
| 25 | Ultrasónico izq — TRIG |
| 32 | Ultrasónico izq — ECHO |
| 26 | Ultrasónico centro — TRIG |
| 27 | Ultrasónico centro — ECHO |
| 33 | Ultrasónico der — TRIG |
| 35 | Ultrasónico der — ECHO |
| 21 | I2C SDA (MPU-6500) |
| 23 | I2C SCL (MPU-6500) |
| 16 | GPS RX (UART2, 9600 baud) |
| 17 | GPS TX (UART2, 9600 baud) |

### Arquitectura interna de tareas

| Tarea | Core | Período | Función |
|---|---|---|---|
| `bumper_task` | 1 | 10 ms | Lee los 3 finales de carrera |
| `imu_task` | 1 | 10 ms | Lee MPU-6500 por I2C, aplica filtro complementario |
| `micro_ros_task` | 1 | 50 ms | Publica el arreglo de 13 valores en `/sensores` |
| `ultrasonic_task` | 0 | ~180 ms | Dispara los 3 ultrasonidos secuencialmente |
| `gps_task` | 0 | continua | Lee y parsea tramas NMEA GGA por UART2 |

> Los datos entre tareas se comparten mediante variables globales protegidas con mutex.

### Observar los datos del sensor

```bash
source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /sensores --qos-reliability best_effort
```

### Flash del sensor

```bash
~/robot_cortadora/scripts/pc/build_sensor.sh
~/robot_cortadora/scripts/pc/flash_sensor.sh /dev/ttyUSB0
```

### Levantar el agente micro-ROS para el sensor

```bash
~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB0 -v6
```

---

## ESP32 Motor — Protocolo de Topics

El nodo `esp32_motor_node` se comunica con el Brain mediante dos topics ROS 2:

| Topic | Tipo | Dirección |
|---|---|---|
| `/motion_cmd` | `Int32MultiArray` | Brain → Motor (comandos) |
| `/motion_status` | `Int32MultiArray` | Motor → Brain (feedback) |

---

## Formato de motion_cmd

```
[cmd_id, L_dir, L_pwm, R_dir, R_pwm, T_ms, bordeadora_on, cortadora_on]
```

| Campo | Índice | Valores válidos | Descripción |
|---|---|---|---|
| `cmd_id` | 0 | Entero ≥ 0 | Identificador del comando. El status lo refleja de vuelta. |
| `L_dir` | 1 | `0` = reversa, `1` = adelante | Dirección motor izquierdo |
| `L_pwm` | 2 | `0` a `255` | Potencia motor izquierdo |
| `R_dir` | 3 | `0` = reversa, `1` = adelante | Dirección motor derecho |
| `R_pwm` | 4 | `0` a `255` | Potencia motor derecho |
| `T_ms` | 5 | `0` = continuo, `>0` = ms | Duración del movimiento. Con 0 corre hasta recibir stop. |
| `bordeadora_on` | 6 | `0` = apagada, `1` = encendida | Activa/desactiva la bordeadora (Sabertooth, rampa soft-start) |
| `cortadora_on` | 7 | `0` = apagada, `1` = encendida | Habilita/inhibe la cortadora central brushless (GPIO 18 → P1-9 INHIBIT del driver AMC) |

> **Nota:** `bordeadora_on` y `cortadora_on` se aplican **siempre**, sin importar si los motores se mueven o no. Esto permite controlar los accesorios de forma independiente.

---

## Formato de motion_status

```
[cmd_id, state, L_dir, L_pwm, R_dir, R_pwm, remaining_ms]
```

| Campo | Índice | Descripción |
|---|---|---|
| `cmd_id` | 0 | ID del comando al que responde |
| `state` | 1 | Estado actual (ver tabla abajo) |
| `L_dir` | 2 | Dirección motor izquierdo activo |
| `L_pwm` | 3 | Potencia motor izquierdo activo |
| `R_dir` | 4 | Dirección motor derecho activo |
| `R_pwm` | 5 | Potencia motor derecho activo |
| `remaining_ms` | 6 | Tiempo restante en ms (0 si es continuo o idle) |

### Estados del motor

| Valor | Nombre | Descripción |
|---|---|---|
| `0` | `IDLE` | Sin comando activo. Heartbeat cada 1 segundo. |
| `1` | `ACCEPTED` | Comando recibido y validado. |
| `2` | `EXECUTING` | Comando en ejecución. Status cada 200 ms. |
| `3` | `DONE` | Comando finalizado (tiempo cumplido o stop recibido). |
| `4` | `ABORTED` | Comando anterior interrumpido por un stop. |
| `5` | `ERROR` | Comando inválido o motor ocupado. |

---

## Hardware — Pines del ESP32-S3

| GPIO | Función |
|---|---|
| 4 | MC33926 — M1 IN1 (motor izquierdo) |
| 5 | MC33926 — M1 IN2 (motor izquierdo) |
| 6 | MC33926 — M2 IN1 (motor derecho) |
| 7 | MC33926 — M2 IN2 (motor derecho) |
| 17 | Sabertooth TX (bordeadora, UART2, 9600 baud) |
| 18 | AMC CBE12A1C INHIBIT̄ (cortadora central, P1-9) |

---

## Ejemplos de uso

Antes de publicar comandos, cargar el entorno ROS 2:

```bash
source ~/robot_cortadora/scripts/common/env.sh
```

Para ver el feedback en tiempo real (terminal separada):

```bash
ros2 topic echo /motion_status
```

---

### Solo accesorios (motores parados)

**Encender cortadora central, bordeadora apagada:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [1, 0, 0, 0, 0, 0, 0, 1]}"
```

**Encender bordeadora, cortadora apagada:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [2, 0, 0, 0, 0, 0, 1, 0]}"
```

**Encender ambos accesorios, motores parados:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [3, 0, 0, 0, 0, 0, 1, 1]}"
```

**Apagar todo:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [4, 0, 0, 0, 0, 0, 0, 0]}"
```

---

### Movimiento temporizado

**Adelante 3 segundos, PWM=80, sin accesorios:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [5, 1, 80, 1, 80, 3000, 0, 0]}"
```

**Atrás 5 segundos, PWM=80, bordeadora encendida:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [6, 0, 80, 0, 80, 5000, 1, 0]}"
```

**Adelante 5 segundos, ambos accesorios encendidos:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [7, 1, 80, 1, 80, 5000, 1, 1]}"
```

**Giro izquierda 3 segundos (M. izq. reversa, M. der. adelante):**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [8, 0, 80, 1, 80, 3000, 0, 0]}"
```

**Giro derecha 3 segundos (M. izq. adelante, M. der. reversa):**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [9, 1, 80, 0, 80, 3000, 0, 0]}"
```

---

### Movimiento continuo (T_ms = 0)

**Adelante continuo, cortadora encendida:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [10, 1, 80, 1, 80, 0, 0, 1]}"
```

**Stop (detiene motores y aplica estado de accesorios):**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [11, 0, 0, 0, 0, 0, 0, 0]}"
```

---

## Reglas de comportamiento

- El motor **no acepta un nuevo comando de movimiento** mientras está ejecutando uno. Responde con `STATE_ERROR`. Para interrumpir, enviar primero un stop (`L_pwm=0, R_pwm=0`).
- Los **accesorios se aplican siempre** al recibir cualquier comando, incluyendo stop.
- El **cmd_id** debe ser distinto por cada comando para que el Brain pueda correlacionar el feedback. No es obligatorio que sea secuencial, pero sí único por operación.
- La **bordeadora** usa una rampa de soft-start para evitar el cogging del motor brushless de la bordeadora. El apagado es inmediato.
- La **cortadora central** se habilita/inhibe directamente por GPIO (sin rampa). El driver AMC CBE12A1C maneja internamente el arranque del BLDC.
