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

## 4. Protocolo de Comandos al Motor

Formato de `motion_cmd`:
```
[cmd_id, L_dir, L_pwm, R_dir, R_pwm, T_ms, bordeadora_on, cortadora_on]
```

| Campo | Índice | Valores | Descripción |
|---|---|---|---|
| `cmd_id` | 0 | Entero ≥ 0 | ID único del comando |
| `L_dir` | 1 | `0`=reversa, `1`=adelante | Dirección motor izquierdo |
| `L_pwm` | 2 | 0–255 | Potencia motor izquierdo |
| `R_dir` | 3 | `0`=reversa, `1`=adelante | Dirección motor derecho |
| `R_pwm` | 4 | 0–255 | Potencia motor derecho |
| `T_ms` | 5 | `0`=continuo, `>0`=ms | Duración |
| `bordeadora_on` | 6 | `0`/`1` | Sabertooth (rampa soft-start) |
| `cortadora_on` | 7 | `0`/`1` | AMC CBE12A1C via GPIO 18 |

---

## 5. Comandos de Prueba — Solo Accesorios (Motores Parados)

```bash
# Encender solo la cortadora central
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [1, 0, 0, 0, 0, 0, 0, 1]}"

# Encender solo la bordeadora
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [2, 0, 0, 0, 0, 0, 1, 0]}"

# Encender ambos accesorios
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [3, 0, 0, 0, 0, 0, 1, 1]}"

# Apagar todo
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [4, 0, 0, 0, 0, 0, 0, 0]}"
```

---

## 6. Comandos de Prueba — Movimiento Temporizado

```bash
# Adelante 3 segundos, PWM=80, sin accesorios
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [5, 1, 80, 1, 80, 3000, 0, 0]}"

# Atrás 5 segundos, PWM=80, bordeadora encendida
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [6, 0, 80, 0, 80, 5000, 1, 0]}"

# Izquierda 5 segundos, PWM=80, bordeadora encendida
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [7, 0, 80, 1, 80, 5000, 1, 0]}"

# Derecha 10 segundos, PWM=80, sin accesorios
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [8, 1, 80, 0, 80, 10000, 0, 0]}"

# Adelante 5 segundos, ambos accesorios encendidos
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [9, 1, 80, 1, 80, 5000, 1, 1]}"
```

---

## 7. Comandos de Prueba — Movimiento Continuo

```bash
# Adelante continuo, cortadora encendida
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [10, 1, 80, 1, 80, 0, 0, 1]}"

# Stop (detiene motores, aplica estado de accesorios del mensaje)
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [11, 0, 0, 0, 0, 0, 0, 0]}"
```

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
