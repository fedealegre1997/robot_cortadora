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

## Control local con encoders (v3.0)

Desde la versión 3.0 el motor **no recibe PWM crudo**: recibe comandos de **alto nivel** (modo + parámetro) y cierra el lazo de control localmente con los encoders. Los encoders son la fuente de verdad del movimiento; el IMU del sensor queda solo para monitoreo en el Brain.

- **ADELANTE / ATRAS:** PID de velocidad por rueda + corrección de rumbo por diferencia de **cuentas acumuladas** de encoder (mantiene la recta autocorrigiéndose).
- **GIRO_IZQ / GIRO_DER:** giro pivot por **velocidad regulada** (ruedas opuestas). Se regula la velocidad de giro (`GIRO_RPM`) con el PID de velocidad, midiendo el ángulo por encoders; al acercarse al objetivo desacelera (`GIRO_DECEL_DEG`, `GIRO_RPM_MIN`) y frena al llegar (`GIRO_TOL_DEG`). **Importante:** se regula la *velocidad*, no se capa el PWM → el lazo aplica todo el torque que haga falta (hasta 255) para girar bajo carga, pero a velocidad gentil y pareja.
- **Arranque suave:** slew de PWM (`PWM_SLEW_RATE`) en todos los modos + rampa de setpoint (`RPM_ACCEL`) en recta y en giro, para evitar el "patadón" inicial.

Constantes físicas: `CPR_OUT = 5760` cuentas/vuelta (16 × x4 × 90:1), radio de rueda `R = 0.075 m`, distancia entre ruedas `L = 0.50 m` → **~53.3 cuentas por grado** de rotación en giro pivot.

---

## Formato de motion_cmd

```
[cmd_id, modo, param, bordeadora_on, cortadora_on]
```

| Campo | Índice | Valores válidos | Descripción |
|---|---|---|---|
| `cmd_id` | 0 | Entero ≥ 0 | Identificador del comando. El status lo refleja de vuelta. |
| `modo` | 1 | `0`–`5` | Modo de movimiento (ver tabla abajo) |
| `param` | 2 | según modo | RPM (ADELANTE/ATRAS) o grados (GIRO_IZQ/GIRO_DER). Ignorado en STOP. |
| `bordeadora_on` | 3 | `0` = apagada, `1` = encendida | Activa/desactiva la bordeadora (Sabertooth, rampa soft-start) |
| `cortadora_on` | 4 | `0` = apagada, `1` = encendida | Habilita/inhibe la cortadora central brushless (GPIO 18 → P1-9 INHIBIT del driver AMC) |

### Modos de movimiento

| Valor | Nombre | `param` | Control |
|---|---|---|---|
| `0` | `STOP` | (ignorado) | Detiene la tracción |
| `1` | `ADELANTE` | RPM base | Velocidad + corrección de rumbo |
| `2` | `ATRAS` | RPM base | Velocidad + corrección de rumbo |
| `3` | `GIRO_IZQ` | grados | Posición (pivot: izq atrás, der adelante) |
| `4` | `GIRO_DER` | grados | Posición (pivot: izq adelante, der atrás) |
| `5` | `PIVOT` | (a definir) | Placeholder — por seguridad hace STOP |

> **Notas:**
> - `bordeadora_on` y `cortadora_on` se aplican **siempre**, sin importar si los motores se mueven o no.
> - **No existe `T_ms`:** los movimientos son continuos hasta recibir otro comando. El motor está **siempre atento**: cualquier comando nuevo reemplaza al activo de inmediato.
> - **Excepción anti-hipo:** si la nueva orden tiene el mismo `modo` y `param` que la activa, solo se actualizan los accesorios; la marcha no se reinicia (ver Reglas de comportamiento).

---

## Formato de motion_status

```
[cmd_id, estado, rpm_izq, rpm_der, feedback]
```

| Campo | Índice | Descripción |
|---|---|---|
| `cmd_id` | 0 | ID del comando al que responde |
| `estado` | 1 | Estado actual (ver tabla abajo) |
| `rpm_izq` | 2 | RPM medida rueda izquierda (con signo: + adelante, − atrás) |
| `rpm_der` | 3 | RPM medida rueda derecha (con signo) |
| `feedback` | 4 | En recta: `error_rumbo` (cuentas izq−der). En giro: grados completados. |

### Estados del motor

| Valor | Nombre | Descripción |
|---|---|---|
| `0` | `IDLE` | Sin comando activo. Heartbeat cada 1 segundo. |
| `1` | `ACCEPTED` | Comando recibido y validado (ACK inmediato). |
| `2` | `EXECUTING` | Comando en ejecución. Status cada 200 ms. |
| `3` | `DONE` | Giro completado (ambas ruedas en tolerancia) o comando finalizado. |
| `5` | `ERROR` | Comando inválido (modo o flags fuera de rango). |

---

## Hardware — Pines del ESP32-S3

| GPIO | Función |
|---|---|
| 4 | MC33926 — M1 IN1 (motor izquierdo) |
| 5 | MC33926 — M1 IN2 (motor izquierdo) |
| 6 | MC33926 — M2 IN1 (motor derecho) |
| 7 | MC33926 — M2 IN2 (motor derecho) |
| 8 | Encoder izquierdo — canal A (PCNT) |
| 9 | Encoder izquierdo — canal B (PCNT) |
| 10 | Encoder derecho — canal A (PCNT) |
| 11 | Encoder derecho — canal B (PCNT) |
| 17 | Sabertooth TX (bordeadora, UART2, 9600 baud) |
| 18 | AMC CBE12A1C INHIBIT̄ (cortadora central, P1-9) |
| 43/44 | UART0 (micro-ROS + consola) |

> **Encoder derecho invertido:** verificado en banco, el encoder derecho cuenta al revés respecto al sentido del motor. Se compensa en firmware con `ENC_R_SIGN = -1` (izquierdo `+1`). Pull-up interno activado en los 4 pines (encoders push-pull).

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

### Solo accesorios (motores parados → modo STOP)

**Encender cortadora central, bordeadora apagada:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [1, 0, 0, 0, 1]}"
```

**Encender bordeadora, cortadora apagada:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [2, 0, 0, 1, 0]}"
```

**Encender ambos accesorios, motores parados:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [3, 0, 0, 1, 1]}"
```

**Apagar todo:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [4, 0, 0, 0, 0]}"
```

---

### Movimiento por velocidad (continuo hasta nuevo comando)

**Adelante a 10 RPM, sin accesorios:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [5, 1, 10, 0, 0]}"
```

**Atrás a 10 RPM, bordeadora encendida:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [6, 2, 10, 1, 0]}"
```

**Adelante a 20 RPM, ambos accesorios encendidos:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [7, 1, 20, 1, 1]}"
```

---

### Giro por ángulo (control de posición)

**Girar 90° a la izquierda:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [8, 3, 90, 0, 0]}"
```

**Girar 90° a la derecha:**
```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [9, 4, 90, 0, 0]}"
```

El motor publica `estado=3` (DONE) cuando completa el ángulo y vuelve a `IDLE`.

---

### Stop

```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [10, 0, 0, 0, 0]}"
```

---

## Reglas de comportamiento

- El motor está **siempre atento**: un comando nuevo **reemplaza** al que esté en ejecución de inmediato, sin importar el modo (ya no rechaza comandos por estar ocupado).
- **Orden idéntica = no reinicia la marcha:** si la nueva orden tiene el **mismo `modo` y `param`** que la que ya se está ejecutando, el firmware **solo actualiza los accesorios** (bordeadora/cortadora) y NO reinicia el lazo de control. Así se puede prender/apagar una herramienta mientras el robot avanza, sin el "hipo" de re-arranque. Verificado en banco con cortadora y bordeadora.
- Los **movimientos son continuos** (sin `T_ms`): se mantienen hasta recibir otro comando. El flujo de tiempos lo maneja el Brain.
- Los **giros** terminan solos al alcanzar el ángulo (publican `DONE` y vuelven a `IDLE`).
- Los **accesorios se aplican siempre** al recibir cualquier comando, incluyendo STOP.
- El **cmd_id** debe ser único por operación para que el Brain pueda correlacionar el feedback.
- La **bordeadora** usa rampa de soft-start (kick-start anti-cogging); el apagado es inmediato.
- La **cortadora central** se habilita/inhibe directamente por GPIO (sin rampa); el driver AMC CBE12A1C maneja internamente el arranque del BLDC.
