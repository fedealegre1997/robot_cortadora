# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Idioma

Toda comunicación debe ser en **español**. Comandos exactos, listos para copiar y pegar.

---

## Arquitectura del sistema

El sistema tiene tres bloques que se comunican por ROS 2 + micro-ROS:

```
[ESP32 Sensor] --micro-ROS Agent--> [Brain (Python / ROS 2)] --micro-ROS Agent--> [ESP32 Motor]
```

| Bloque | Lenguaje | Ubicación del código activo |
|--------|----------|-----------------------------|
| **Brain** | Python / ROS 2 Jazzy | `ros2_ws/src/cortadora_brain/cortadora_brain/bumper_decision_node.py` |
| **ESP32 Motor** | C / ESP-IDF + micro-ROS | `firmware/esp32_motor/active/active/main/main.c` |
| **ESP32 Sensor** | C / ESP-IDF + micro-ROS | `firmware/esp32_sensor/active/active/main/main.c` |
| **micro-ROS Agent** | Precompilado | `tools/microros_agent_ws/install/` |

El host puede ser la **PC Linux** (desarrollo) o la **Raspberry Pi 5** (integración real). La PC es siempre la fuente de verdad.

---

## Protocolo de topics y mensajes

### Sensor → Brain
| Topic | Tipo | QoS |
|-------|------|-----|
| `/bumpers` | `Float32MultiArray` | best_effort |
| `/ultrasonicos_cm` | `Float32MultiArray` | best_effort |
| `/gps_fix` | `Float32MultiArray` | best_effort |
| `/imu/data_raw` | `Float32MultiArray` | best_effort |
| `/sensores` | `Float32MultiArray` | best_effort (legacy combinado) |

### Brain → Motor
| Topic | Tipo | Dirección |
|-------|------|-----------|
| `/motion_cmd` | `Int32MultiArray` | Brain publica, Motor suscribe |
| `/motion_status` | `Int32MultiArray` | Motor publica, Brain suscribe |

**Formato de mensajes (v3.0 — control local con encoders):**
- `motion_cmd = [cmd_id, modo, param, bordeadora_on, cortadora_on]`
- `motion_status = [cmd_id, estado, rpm_izq, rpm_der, feedback]`

**Modos:** `STOP=0, ADELANTE=1 (param=RPM), ATRAS=2 (param=RPM), GIRO_IZQ=3 (param=grados), GIRO_DER=4 (param=grados), PIVOT=5 (placeholder)`

**Estados del motor:** `IDLE=0, ACCEPTED=1, EXECUTING=2, DONE=3, ERROR=5`

**feedback:** en recta = error de rumbo (cuentas izq−der); en giro = grados completados.

> El motor cierra el lazo localmente con encoders (PCNT: Izq GPIO 8/9, Der GPIO 10/11; `ENC_R_SIGN=-1`). Sin `T_ms`: movimientos continuos hasta nuevo comando; el motor está siempre atento (un comando nuevo reemplaza al activo). El Brain manda intención de alto nivel, no PWM crudo.

---

## Comandos de desarrollo

### Cargar entorno ROS 2

```bash
source ~/robot_cortadora/scripts/common/env.sh
```

### Build y ejecución del Brain

```bash
# Build workspace ROS 2
~/robot_cortadora/scripts/common/build_ros2.sh

# Ejecutar nodo principal
~/robot_cortadora/scripts/common/run_brain.sh
```

### Build y flash de firmware ESP32

```bash
# Sensor
~/robot_cortadora/scripts/pc/build_sensor.sh
~/robot_cortadora/scripts/pc/flash_sensor.sh /dev/ttyUSB0

# Motor
~/robot_cortadora/scripts/pc/build_motor.sh
~/robot_cortadora/scripts/pc/flash_motor.sh /dev/ttyUSB1
```

### Ejecutar micro-ROS Agent

```bash
# Un agent por ESP32 (en terminales separadas)
~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB0 -v4   # sensor
~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB1 -v4   # motor
```

> No usar monitor serial y micro-ROS Agent al mismo tiempo en el mismo puerto.

### Observar topics

```bash
source ~/robot_cortadora/scripts/common/env.sh
ros2 topic list
ros2 topic echo /bumpers --qos-reliability best_effort
ros2 topic echo /motion_status
ros2 topic echo /motion_cmd
```

### Enviar comando manual al motor

```bash
source ~/robot_cortadora/scripts/common/env.sh
# Adelante a 10 RPM (modo=1), sin accesorios
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [1, 1, 10, 0, 0]}"
# Girar 90° a la derecha (modo=4)
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [2, 4, 90, 0, 0]}"
# Stop
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [3, 0, 0, 0, 0]}"
```

### Activar versión anterior de firmware

```bash
~/robot_cortadora/scripts/pc/activate_motor_version.sh NOMBRE_ARCHIVO.bak
~/robot_cortadora/scripts/pc/activate_sensor_version.sh NOMBRE_ARCHIVO.bak
```

---

## Convención de puertos USB

Si se conecta primero el sensor y luego el motor:
- Sensor → `/dev/ttyUSB0`
- Motor → `/dev/ttyUSB1`

Verificar con: `ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null`

---

## Reglas de estructura

- **`active/`**: único lugar donde se compila y ejecuta. Todo cambio va aquí.
- **`versions/`**: respaldos de versiones anteriores. No se compila desde aquí.
- **`snapshots/`**: congelaciones de estados estables completos. Solo lectura / recuperación.
- Siempre usar los scripts de `~/robot_cortadora/scripts/` para build, flash y ejecución.

### Recuperar estado estable desde snapshot

```bash
# Brain
rsync -a ~/robot_cortadora/snapshots/2026_04_pc_linux_integracion_estable/ros2_ws_src/cortadora_brain/ \
  ~/robot_cortadora/ros2_ws/src/cortadora_brain/

# Firmware motor
rsync -a ~/robot_cortadora/snapshots/2026_04_pc_linux_integracion_estable/firmware/esp32_motor_active/ \
  ~/robot_cortadora/firmware/esp32_motor/active/

# Firmware sensor
rsync -a ~/robot_cortadora/snapshots/2026_04_pc_linux_integracion_estable/firmware/esp32_sensor_active/ \
  ~/robot_cortadora/firmware/esp32_sensor/active/
```

---

## Restricciones para asistencia IA

1. No proponer cambios en la estructura de carpetas ni refactors innecesarios.
2. No sugerir usar la Raspberry Pi como estación de build/flash.
3. Si algo funciona y está estable, no proponer rehacerlo.
4. Cualquier cambio definitivo debe quedar en la PC Linux.
