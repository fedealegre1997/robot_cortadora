# Estado Actual del Proyecto

**NOTA:** Este es un documento **VIVO**. Siempre debe representar con exactitud milimétrica el estado actual del código, pruebas e integraciones. A diferencia de las bitácoras, este documento **SÍ se edita y sobrescribe** permanentemente. Antes de empezar cualquier tarea o después de terminarla, se debe revisar y actualizar este archivo.

---

## 1. Estado General de los Subsistemas

### 🧠 Cerebro ROS 2 (Host PC Linux)
- **Estado:** ⚠️ Parcialmente desactualizado.
- **Detalle:** El nodo `bumper_decision_node.py` aún despacha arreglos de **7 enteros** (`cmd_id`, `l_dir`, `l_pwm`, `r_dir`, `r_pwm`, `T_ms`, `bordeadora_on`). El protocolo del motor ya fue extendido a **8 campos** (agrega `cortadora_on` en índice 7). El Brain necesita actualizarse antes de la integración completa.

### 🔌 Firmware Sensores (ESP32 clásico)
- **Estado:** ✅ Compilado. Pendiente de flasheo (sensor desconectado al cierre de sesión).
- **Detalle:**
  - Publica `/sensores` como `Float32MultiArray` de 13 valores a 50 ms por micro-ROS serial (UART0).
  - Bug corregido (v6.1): se eliminó un `printf` en `ultrasonic_task` que corrompía el transporte UART0 de micro-ROS.
  - Placa: ESP32 clásico, 2MB Flash. Puerto al flashear: `/dev/ttyUSB0`.

### 🚜 Firmware Motores (ESP32-S3 + MC33926)
- **Estado:** ✅ Compilado y Flasheado. Pendiente de prueba de integración end-to-end.
- **Detalle:**
  - Placa: ESP32-S3-WROOM-1 N8R2 (8MB Flash, 2MB PSRAM). Puerto: `/dev/ttyACM0` (CH343 → CDC-ACM).
  - Driver de tracción: MC33926, 4 canales LEDC (GPIO 4, 5, 6, 7).
  - Bordeadora: Sabertooth 2x25 v2, serial simplificado, UART2 TX GPIO 17, 9600 baud, rampa soft-start anti-cogging.
  - Cortadora central (v2.2): GPIO 18 → AMC CBE12A1C P1-9 INHIBIT̄. HIGH = habilitado, LOW = inhibido. 3.3 V del ESP32 suficiente (VIH min del driver = 2.2 V).
  - Protocolo `motion_cmd` extendido a 8 campos: `[cmd_id, L_dir, L_pwm, R_dir, R_pwm, T_ms, bordeadora_on, cortadora_on]`.
  - Bug corregido: los accesorios (bordeadora y cortadora) se aplican **antes** de la verificación de stop, permitiendo control independiente con motores detenidos.

---

## 2. Bloqueos Actuales o Advertencias

- **Conexión física pendiente:** GPIO 18 → P1-9 INHIBIT̄ del AMC CBE12A1C y GND ESP32 → P1-11 GND del driver. Sin este cableado, la cortadora central no puede habilitarse por firmware.
- **Brain desactualizado:** El nodo Brain sigue enviando 7 campos. Debe actualizarse a 8 campos antes de la integración completa con el motor.
- **Sensor sin flashear:** El firmware del sensor (v6.1) fue compilado pero no flasheado porque el ESP32 sensor estaba desconectado.

---

## 3. Próximas Tareas y Pasos Naturales

1. **Flashear sensor:** Conectar el ESP32 sensor y ejecutar:
   ```bash
   ~/robot_cortadora/scripts/pc/flash_sensor.sh /dev/ttyUSB0
   ```
2. **Cablear GPIO 18 → AMC P1-9 (INHIBIT̄)** y GND ESP32 → AMC P1-11 para habilitar el control de la cortadora central.
3. **Actualizar el Brain** para enviar 8 campos en `motion_cmd` (agregar `cortadora_on` en índice 7).
4. **Prueba de integración end-to-end:** ambos ESP32 conectados, agentes micro-ROS activos, Brain leyendo `/sensores` y enviando `/motion_cmd`.
5. **Prueba física de accesorios:** verificar bordeadora y cortadora central desde comandos ROS 2 con el robot sobre la mesa.
