# Comandos de Operación y Prueba

Este documento contiene los comandos de consola exactos para operar y probar el **Robot Cortadora**.

---

## 1. Levantar el Agente de micro-ROS (Serial)

```bash
# Motor — ESP32-S3 (CH343 → /dev/ttyACM0)
~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyACM0 -v4

# Sensor — ESP32 clásico (CH340/CP210x → /dev/ttyUSB0)
~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB0 -v4
```

> No usar monitor serial y micro-ROS Agent al mismo tiempo en el mismo puerto.

---

## 2. Cargar entorno ROS 2

```bash
source ~/robot_cortadora/scripts/common/env.sh
```

---

## 3. Monitorear Topics

```bash
# Estado del motor (feedback cada 200 ms en ejecución, 1 s en idle)
ros2 topic echo /motion_status

# Datos del sensor (50 ms)
ros2 topic echo /sensores --qos-reliability best_effort

# Ver todos los topics activos
ros2 topic list
```

---

## 4. Protocolo de Comandos al Motor (v3.0 — control local)

Formato de `motion_cmd`:
```
[cmd_id, modo, param, bordeadora_on, cortadora_on]
```

| Campo | Índice | Valores | Descripción |
|---|---|---|---|
| `cmd_id` | 0 | Entero ≥ 0 | ID único del comando |
| `modo` | 1 | `0`–`5` | Modo de movimiento (ver tabla) |
| `param` | 2 | según modo | RPM (ADELANTE/ATRAS) o grados (GIRO_IZQ/GIRO_DER) |
| `bordeadora_on` | 3 | `0`/`1` | Sabertooth (rampa soft-start) |
| `cortadora_on` | 4 | `0`/`1` | AMC CBE12A1C via GPIO 18 |

| modo | Nombre | param | |
|---|---|---|---|
| `0` | STOP | (ignorado) | Detiene la tracción |
| `1` | ADELANTE | RPM | Control por velocidad + rumbo |
| `2` | ATRAS | RPM | Control por velocidad + rumbo |
| `3` | GIRO_IZQ | grados | Giro pivot por ángulo |
| `4` | GIRO_DER | grados | Giro pivot por ángulo |
| `5` | PIVOT | (a definir) | Placeholder (hace STOP) |

`motion_status` = `[cmd_id, estado, rpm_izq, rpm_der, feedback]`.
Estados: `0=IDLE, 1=ACCEPTED, 2=EXECUTING, 3=DONE, 5=ERROR`.
`feedback`: en recta = error de rumbo (cuentas); en giro = grados completados.

> Sin `T_ms`: los movimientos son continuos hasta el próximo comando. El motor está **siempre atento** (un comando nuevo reemplaza al activo).

---

## 5. Comandos de Prueba — Solo Accesorios (modo STOP)

```bash
# Encender solo la cortadora central
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [1, 0, 0, 0, 1]}"

# Encender solo la bordeadora
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [2, 0, 0, 1, 0]}"

# Encender ambos accesorios
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [3, 0, 0, 1, 1]}"

# Apagar todo
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [4, 0, 0, 0, 0]}"
```

---

## 6. Comandos de Prueba — Movimiento por Velocidad

```bash
# Adelante a 10 RPM, sin accesorios
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [5, 1, 10, 0, 0]}"

# Atrás a 10 RPM, bordeadora encendida
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [6, 2, 10, 1, 0]}"

# Adelante a 20 RPM, ambos accesorios encendidos
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [7, 1, 20, 1, 1]}"

# Stop
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [8, 0, 0, 0, 0]}"
```

---

## 7. Comandos de Prueba — Giro por Ángulo

```bash
# Girar 90° a la izquierda
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [9, 3, 90, 0, 0]}"

# Girar 90° a la derecha
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [10, 4, 90, 0, 0]}"

# Girar 45° a la derecha
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [11, 4, 45, 0, 0]}"
```

> El motor publica `estado=3` (DONE) al completar el ángulo y vuelve a `IDLE`.

---

## 8. Build y Flash de Firmware

```bash
# Motor (ESP32-S3, puerto COM → /dev/ttyACM0)
~/robot_cortadora/scripts/pc/build_motor.sh
~/robot_cortadora/scripts/pc/flash_motor.sh /dev/ttyACM0

# Sensor (ESP32 clásico → /dev/ttyUSB0)
~/robot_cortadora/scripts/pc/build_sensor.sh
~/robot_cortadora/scripts/pc/flash_sensor.sh /dev/ttyUSB0
```

---

## 9. Monitorear Serial (sin micro-ROS Agent)

```bash
~/robot_cortadora/scripts/pc/monitor_motor.sh /dev/ttyACM0
```
