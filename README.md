# robot_cortadora

Proyecto principal de integración ROS 2 + micro-ROS para la cortadora.

## Estructura general

- `ros2_ws/`: workspace ROS 2 del host
- `firmware/`: proyectos ESP32 motor y sensor
- `scripts/`: scripts de automatización
- `config/`: variables de entorno y configuración
- `docs/`: documentación técnica
- `snapshots/`: respaldos importantes del proyecto

## Flujo general

1. El ESP32 sensor publica datos de sensores.
2. El nodo principal en Python toma decisiones.
3. El ESP32 motor recibe comandos de movimiento.
4. El host puede ser la PC Linux o la Raspberry Pi 5.

## Carpetas importantes

### ROS 2 host
`ros2_ws/src/cortadora_brain/`

### Firmware motor
`firmware/esp32_motor/active/`

### Firmware sensor
`firmware/esp32_sensor/active/`

## Reglas del proyecto

- Solo se compila o ejecuta desde las carpetas activas.
- `versions/` contiene versiones anteriores.
- `snapshots/` contiene respaldos globales del proyecto.
- La PC Linux es la máquina principal de desarrollo.
- La Raspberry Pi 5 se usa como host de integración y pruebas.


# Guía rápida de uso — Robot Cortadora (PC Linux)

Este archivo sirve como ayuda rápida para copiar y pegar comandos en terminal.

## Convención actual de puertos

Si conectás primero el ESP32 sensor, normalmente toma:
/dev/ttyUSB0

Si conectás después el ESP32 motor, normalmente toma:
/dev/ttyUSB1

Importante: si cambiás el orden de conexión, los puertos pueden cambiar.

---

## Cargar entorno ROS 2 del proyecto

source ~/robot_cortadora/scripts/common/env.sh

---

## Build del workspace ROS 2

~/robot_cortadora/scripts/common/build_ros2.sh

---

## Ejecutar nodo principal (brain)

~/robot_cortadora/scripts/common/run_brain.sh

---

## Build del firmware del sensor

ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null

~/robot_cortadora/scripts/pc/build_sensor.sh
~/robot_cortadora/scripts/pc/flash_sensor.sh /dev/ttyUSB0
~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB0 -v6

ros2 topic echo /sensores --qos-reliability best_effort


---

## Build del firmware del motor

ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null

~/robot_cortadora/scripts/pc/build_motor.sh
~/robot_cortadora/scripts/pc/flash_motor.sh /dev/ttyUSB1
~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyACM0 -v6

ros2 topic echo /motion_status

---

## Flash del sensor

~/robot_cortadora/scripts/pc/flash_sensor.sh /dev/ttyUSB0

Si el puerto cambia, reemplazar /dev/ttyUSB0 por el correcto.

---

## Flash del motor

~/robot_cortadora/scripts/pc/flash_motor.sh /dev/ttyUSB1

Si el puerto cambia, reemplazar /dev/ttyUSB1 por el correcto.

---

## Monitor serial del sensor

No usar monitor serial y micro-ROS Agent al mismo tiempo en el mismo puerto.

~/robot_cortadora/scripts/pc/monitor_sensor.sh /dev/ttyUSB0

---

## Monitor serial del motor

No usar monitor serial y micro-ROS Agent al mismo tiempo en el mismo puerto.

~/robot_cortadora/scripts/pc/monitor_motor.sh /dev/ttyUSB1

---

## Ejecutar agent del sensor

~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB0 -v4

Si querés más detalle:

~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB0 -v6

---

## Ejecutar agent del motor

~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB1 -v4

Si querés más detalle:

~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB1 -v6

---

## Ver todos los topics

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic list

---

## Ver información detallada de /bumpers

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic info /bumpers -v

---

## Ver información detallada de /motion_status

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic info /motion_status -v

---

## Observar /bumpers

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /bumpers --qos-reliability best_effort

---

## Observar /ultrasonicos_cm

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /ultrasonicos_cm --qos-reliability best_effort

---

## Observar /gps_fix

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /gps_fix --qos-reliability best_effort

---

## Observar /imu/data_raw

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /imu/data_raw --qos-reliability best_effort

---

## Medir frecuencia de /bumpers

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic hz /bumpers --qos-reliability best_effort

---

## Medir frecuencia de /ultrasonicos_cm

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic hz /ultrasonicos_cm --qos-reliability best_effort

---

## Medir frecuencia de /gps_fix

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic hz /gps_fix --qos-reliability best_effort

---

## Medir frecuencia de /imu/data_raw

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic hz /imu/data_raw --qos-reliability best_effort

---

## Observar /motion_status

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /motion_status

---

## Medir frecuencia de /motion_status

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic hz /motion_status

---

## Observar /motion_cmd

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /motion_cmd

---

## Enviar comando manual al motor

Ejemplo: avance de ambos motores con PWM 80 durante 1000 ms

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [1, 1, 80, 1, 80, 1000]}"

---

## Flujo completo de integración

### Terminal 1 — Agent del sensor

~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB0 -v4

### Terminal 2 — Agent del motor

~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB1 -v4

### Terminal 3 — Ver todos los topics

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic list

### Terminal 4 — Ver bumpers

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /bumpers --qos-reliability best_effort

### Terminal 5 — Ver motion_status

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /motion_status

### Terminal 6 — Ejecutar brain

~/robot_cortadora/scripts/common/run_brain.sh

### Terminal 7 — Ver comandos del brain

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /motion_cmd

---

## Verificar puertos serie disponibles

ls /dev/ttyUSB*
ls /dev/ttyACM*

---

## Ver información reciente del kernel

dmesg | tail -n 30

---

## Ver qué proceso usa un puerto

Ejemplo:

lsof /dev/ttyUSB0

---

## Verificar si el paquete micro_ros_agent existe

source /opt/ros/jazzy/setup.bash
source ~/robot_cortadora/tools/microros_agent_ws/install/local_setup.bash
ros2 pkg list | grep micro_ros_agent

---

## Ejecutar agent manualmente

source /opt/ros/jazzy/setup.bash
source ~/robot_cortadora/tools/microros_agent_ws/install/local_setup.bash
ros2 run micro_ros_agent micro_ros_agent serial --dev /dev/ttyUSB0 -v6

---

## Secuencia rápida recomendada para una prueba completa

### 1. Build del sensor

~/robot_cortadora/scripts/pc/build_sensor.sh

### 2. Flash del sensor

~/robot_cortadora/scripts/pc/flash_sensor.sh /dev/ttyUSB0

### 3. Build del motor

~/robot_cortadora/scripts/pc/build_motor.sh

### 4. Flash del motor

~/robot_cortadora/scripts/pc/flash_motor.sh /dev/ttyUSB1

### 5. Agent del sensor

~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB0 -v4

### 6. Agent del motor

~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB1 -v4

### 7. Ejecutar brain

~/robot_cortadora/scripts/common/run_brain.sh

### 8. Ver topics

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic list

### 9. Ver bumpers

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /bumpers --qos-reliability best_effort

### 10. Ver estado del motor

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /motion_status

### 11. Ver comandos del brain

source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /motion_cmd
