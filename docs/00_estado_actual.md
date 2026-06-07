# Estado Actual del Proyecto

**NOTA:** Este es un documento **VIVO**. Siempre debe representar con exactitud milimétrica el estado actual del código, pruebas e integraciones. A diferencia de las bitácoras, este documento **SÍ se edita y sobrescribe** permanentemente. Antes de empezar cualquier tarea o después de terminarla, se debe revisar y actualizar este archivo.

---

## 1. Estado General de los Subsistemas

### 🧠 Cerebro ROS 2 (Host PC Linux)
- **Estado:** ⚠️ Desactualizado respecto al firmware del motor.
- **Detalle:** El nodo `bumper_decision_node.py` todavía despacha el **protocolo viejo** (`[cmd_id, L_dir, L_pwm, R_dir, R_pwm, T_ms, bordeadora_on, cortadora_on]`). El firmware del motor pasó al **protocolo nuevo de 5 campos** (`[cmd_id, modo, param, bordeadora_on, cortadora_on]`). El Brain debe reescribirse para enviar comandos de alto nivel (modo + parámetro) antes de la integración end-to-end.

### 🔌 Firmware Sensores (ESP32 clásico)
- **Estado:** ✅ Compilado. Pendiente de flasheo (sensor desconectado al cierre de sesión).
- **Detalle:**
  - Publica `/sensores` como `Float32MultiArray` de 13 valores a 50 ms por micro-ROS serial (UART0).
  - Bug corregido (v6.1): se eliminó un `printf` en `ultrasonic_task` que corrompía el transporte UART0 de micro-ROS.
  - Placa: ESP32 clásico, 2MB Flash. Puerto al flashear: `/dev/ttyUSB0`.
  - El IMU (MPU-6500) queda como fuente **solo de monitoreo** en el Brain. El control de rumbo del robot NO depende del IMU.

### 🚜 Firmware Motores (ESP32-S3 + MC33926) — v3.0 CONTROL LOCAL
- **Estado:** ✅ Reescrito, compilado, flasheado y **validado en banco (aire) y en piso con carga** (03/06/26). Todos los modos andan; los giros completan el ángulo bajo carga.
- **Detalle:**
  - Placa: ESP32-S3-WROOM-1 N8R2 (8MB Flash, 2MB PSRAM). Puerto: `/dev/ttyACM0` (CH343 → CDC-ACM, conector **COM**).
  - **Cambio de paradigma:** el control pasó de PWM directo desde el Brain a **lazo cerrado local con encoders**. Los encoders son la fuente de verdad. Sin Kalman, sin UART entre ESPs.
  - **Encoders por PCNT hardware** (cuadratura x4): Izq GPIO 8/9, Der GPIO 10/11. `CPR_OUT = 5760`. Físico: R=0.075 m, L=0.50 m → ~53.3 cuentas/grado en giro pivot.
  - **Hallazgo verificado:** el encoder derecho está cableado invertido → `ENC_R_SIGN = -1` (izq `+1`). Sin esto, la corrección de rumbo se retroalimenta positiva y starva el motor izquierdo.
  - **Control:** PID de velocidad incremental + corrección de rumbo por diferencia de cuentas acumuladas (ADELANTE/ATRAS); **giro pivot por velocidad regulada** (GIRO_IZQ/GIRO_DER) — regula la velocidad de giro con perfil trapezoidal (acelera/crucero/desacelera) y mide el ángulo por encoders; aplica todo el torque que haga falta para girar bajo carga sin capar PWM.
  - **Anti-patada (arranque suave):** slew de PWM universal (`PWM_SLEW_RATE = 600`) + rampa de setpoint en recta (`RPM_ACCEL = 30`).
  - Driver tracción: MC33926, 4 canales LEDC (GPIO 4, 5, 6, 7). Bordeadora: Sabertooth 2x25 v2 (UART2 TX GPIO 17, rampa soft-start). Cortadora central: AMC CBE12A1C, GPIO 18 (HIGH = habilitado).
  - **Protocolo nuevo:** `motion_cmd = [cmd_id, modo, param, bordeadora_on, cortadora_on]` / `motion_status = [cmd_id, estado, rpm_izq, rpm_der, feedback]`.
  - **Comportamiento "siempre atento":** cualquier comando nuevo reemplaza al activo de inmediato (ya NO rechaza comandos mientras ejecuta). Sin `T_ms`: los movimientos son continuos hasta recibir otro comando.
  - **Anti-hipo (verificado en banco):** si la nueva orden tiene el mismo `modo` y `param` que la activa, solo se actualizan accesorios sin reiniciar el lazo → se puede prender/apagar bordeadora y/o cortadora en plena marcha sin que el robot frene ni dé tirones.

---

## 2. Bloqueos Actuales o Advertencias

- **Brain desactualizado:** sigue enviando el protocolo viejo. Debe reescribirse al protocolo de 5 campos (modo + param) antes de la integración completa.
- **Modo PIVOT (5) sin definir:** es un placeholder que por seguridad hace STOP.
- **Tuning fino pendiente (con carga):** las pruebas en piso (03/06/26) mostraron dos cosas a afinar: (1) **offset de velocidad** — pidiendo 15 RPM da ~10-11 bajo carga, falta subir `VEL_KI` (0.2 → ~0.5) para alcanzar el setpoint; (2) **deriva de rumbo leve** — en recta el `error_rumbo` crece a ~40 cuentas (~0.8°, curva suave a la derecha yendo, a la izquierda volviendo: asimetría mecánica real), conviene subir `HEADING_KP` (0.02 → ~0.05) para cerrarla mejor. Ninguna es bloqueante; el robot anda bien.
- **Conexión física cortadora:** GPIO 18 → P1-9 INHIBIT̄ del AMC y GND ESP32 → P1-11 GND del driver.
- **Sensor sin flashear:** firmware v6.1 compilado, no flasheado (sensor desconectado).

---

## 3. Próximas Tareas y Pasos Naturales

1. **Tuning fino con carga:** subir `VEL_KI` (~0.5) para cerrar el offset de RPM y `HEADING_KP` (~0.05) para la deriva de rumbo. Validar en una recta más larga.
2. **Definir e implementar el modo PIVOT (5).**
3. **Reescribir el Brain** al protocolo nuevo de 5 campos: enviar `[cmd_id, modo, param, bordeadora_on, cortadora_on]` y leer el nuevo `motion_status`. Aprovechar el feedback `DONE` (estado=3) para encadenar comandos sin huecos.
4. **Flashear sensor:** `~/robot_cortadora/scripts/pc/flash_sensor.sh /dev/ttyUSB0`.
5. **Prueba de integración end-to-end:** ambos ESP32 conectados, agentes micro-ROS activos, Brain leyendo `/sensores` y enviando `/motion_cmd` con el nuevo protocolo.
6. **Calibrar el ángulo de giro** si hiciera falta (ajustar `L`/`CUENTAS_POR_GRADO_PIVOT`): en piso los 90° dieron correctos a ojo, confirmar con medición fina.
