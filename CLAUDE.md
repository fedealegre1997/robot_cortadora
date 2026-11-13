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
| **Brain** | Python / ROS 2 Lyrical | `ros2_ws/src/cortadora_brain/cortadora_brain/bumper_decision_node.py` |
| **ESP32 Motor** | C / ESP-IDF + micro-ROS | `firmware/esp32_motor/active/active/main/main.c` |
| **ESP32 Sensor** | C / ESP-IDF + micro-ROS | `firmware/esp32_sensor/active/active/main/main.c` |
| **micro-ROS Agent** | Compilado en la Pi | `~/microros_agent_ws/install/` (en la Raspberry Pi 4) |

El host puede ser la **PC Linux** (desarrollo / build / flash) o la **Raspberry Pi 4** (integración real, Ubuntu 26.04 + ROS 2 Lyrical). La PC es siempre la fuente de verdad.

> **PC:** Ubuntu 24.04 + ROS 2 Jazzy (solo para firmware; no corre el Brain en producción).
> **Pi 4:** Ubuntu 26.04 "Resolute" + ROS 2 Lyrical. El Brain y los agentes corren aquí.

---

## Protocolo de topics y mensajes

### Sensor → Brain
| Topic | Tipo | QoS |
|-------|------|-----|
| `/sensores` | `Float32MultiArray` (24 valores, 50 ms) | reliable (el Brain se suscribe best_effort, compatible) |

El firmware sensor v6.2 publica **solo** `/sensores`; no existen `/bumpers`, `/ultrasonicos_cm`, `/gps_fix` ni `/imu/data_raw`. Índices: 0-2 bumpers, 3-5 ultrasonidos, 6-8 IMU, 9-14 GPS, 15-23 APP. Tabla completa en `docs/arquitectura.md`.

### Brain → Motor
| Topic | Tipo | Dirección |
|-------|------|-----------|
| `/motion_cmd` | `Int32MultiArray` | Brain publica, Motor suscribe |
| `/motion_status` | `Int32MultiArray` | Motor publica, Brain suscribe |

**Formato de mensajes (v4.0 — sin encoders, rumbo con el IMU; detalle en `docs/arquitectura.md`):**
- `motion_cmd = [cmd_id, modo, param, bordeadora_on, cortadora_on]`
- `motion_status = [cmd_id, estado, pwm_izq, pwm_der, feedback, rumbo, rumbo_obj, imu_estado, seg_desde_cal]` (rumbo en décimas de grado, + = izquierda)

**Modos:** `STOP=0, ADELANTE=1 (param=cm/s), ATRAS=2 (param=cm/s), GIRO_IZQ=3 (param=grados), GIRO_DER=4 (param=grados), PIVOT=5 (param=cm a avanzar; 0→30 cm), CALIBRAR=6 (param=s de ventana; 0→5), FIJAR_RUMBO=7 (param=grados)`

**PIVOT (v4):** accesorios ON forzados → adelante `param` cm a 23,6 cm/s → atrás 28 cm (distancias estimadas en lazo abierto) → swing 90° izq sobre la rueda izquierda fija, medido con el giróscopo → `DONE`.

**Estados del motor:** `IDLE=0, ACCEPTED=1, EXECUTING=2, DONE=3, ABORTED=4, ERROR=5` (código del error en `feedback`). **imu_estado:** `0` falla, `1` iniciando, `2` listo, `3` recalibrando.

> Los motores Pololu 37D no tienen encoder: velocidad y distancia en lazo abierto calibrado (`PWM_ARRANQUE`, `CM_S_POR_PWM`, tope 180/255); rumbo y giros en lazo cerrado con el giróscopo de la placa 3 (I2C 0x68). El motor recalibra el bias solo en cada parada (≥ 6 s quieto) o con `CALIBRAR`. `rumbo_obj` es absoluto: cada giro le suma exacto y la recta siguiente corrige el error del giro. Sin `T_ms`: movimientos continuos hasta nuevo comando; el motor está siempre atento (un comando nuevo reemplaza al activo). La v3.2 con encoders está en `firmware/esp32_motor/versions/2026_11_02_MainV3.2_encoders.c.bak`.

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

# Motor (target opcional: esp32 = robot, esp32s3 = banco de prueba; sin argumento usa el actual)
~/robot_cortadora/scripts/pc/build_motor.sh esp32
~/robot_cortadora/scripts/pc/flash_motor.sh /dev/ttyUSB1
```

### Ejecutar micro-ROS Agent (en la Raspberry Pi 4)

```bash
# Un agent por ESP32 (en terminales separadas, via SSH o directo en la Pi)
~/robot_cortadora/scripts/pi/run_agent_serial.sh /dev/ttyUSB0 -v4   # sensor
~/robot_cortadora/scripts/pi/run_agent_serial.sh /dev/ttyUSB1 -v4   # motor
```

> No usar monitor serial y micro-ROS Agent al mismo tiempo en el mismo puerto.

### Ejecutar el Brain (en la Raspberry Pi 4)

```bash
~/robot_cortadora/scripts/pi/run_brain.sh
```

### Observar topics (en la Raspberry Pi 4)

```bash
source ~/robot_cortadora/scripts/pi/env.sh
ros2 topic list
ros2 topic echo /sensores
ros2 topic echo /motion_status
ros2 topic echo /motion_cmd
```

### Enviar comando manual al motor (en la Raspberry Pi 4)

```bash
source ~/robot_cortadora/scripts/pi/env.sh
# Adelante a 15 cm/s (modo=1), sin accesorios
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [1, 1, 15, 0, 0]}"
# Girar 90° a la derecha (modo=4)
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [2, 4, 90, 0, 0]}"
# Calibrar el giróscopo, ventana de 5 s (modo=6, robot quieto)
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [3, 6, 5, 0, 0]}"
# Stop
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [4, 0, 0, 0, 0]}"
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
