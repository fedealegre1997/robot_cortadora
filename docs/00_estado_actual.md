# Estado Actual del Proyecto

**NOTA:** Este es un documento **VIVO**. Siempre debe representar con exactitud milimétrica el estado actual del código, pruebas e integraciones. A diferencia de las bitácoras, este documento **SÍ se edita y sobrescribe** permanentemente. Antes de empezar cualquier tarea o después de terminarla, se debe revisar y actualizar este archivo.

---

## 1. Estado General de los Subsistemas

### 🧠 Cerebro ROS 2 (Host Raspberry Pi 4 — Ubuntu 26.04 + ROS 2 Lyrical)
- **Estado:** ⚠️ Desactualizado respecto al firmware del motor.
- **Detalle:** El nodo `bumper_decision_node.py` todavía despacha un **protocolo viejo de 7 campos** (`[cmd_id, l_dir, l_pwm, r_dir, r_pwm, duration_ms, bordeadora_on]`, sin `cortadora_on`; verificado en la línea 137 el 28/10/26). El firmware del motor v4.0 usa el **protocolo v4** (`motion_cmd` de 5 campos con velocidad en cm/s y `motion_status` de 9 campos, ver `docs/arquitectura.md`). El Brain debe reescribirse para enviar comandos de alto nivel (modo + parámetro) antes de la integración end-to-end.
- Se suscribe a `sensores` con QoS `BEST_EFFORT` y solo usa los índices 0–2 (bumpers) con `len >= 3` → es compatible con el array de 24 valores.

### 🔌 Firmware Sensores (ESP32 clásico) — v6.2
- **Estado:** ✅ Compilado (27/10/26, 285 KB, 73 % libre en la partición de 1 MB). ⚠️ **No hay registro de flasheo** (ni de v6.1 ni de v6.2) ni de prueba en hardware.
- **Detalle:**
  - Publica **un único topic**: `/sensores`, `Float32MultiArray` de **24 valores**, cada 50 ms, QoS reliable, por micro-ROS serial (UART0). No publica `/bumpers`, `/ultrasonicos_cm`, `/gps_fix` ni `/imu/data_raw`.
  - Índices 0–12 sin cambios; 13 `gps_sats`, 14 `gps_hdop`; 15–23 campos `app_*` para la E7 (tabla completa en `docs/arquitectura.md`).
  - Los `app_*` quedan en sus valores por defecto: **Bluetooth todavía no implementado**. Seguridad ya incluida: sin APP o con comando de más de 300 ms, `app_dir`, `app_cutter` y `app_trimmer` se publican en 0.
  - v6.2: parser GGA corregido (`strtok_r` salteaba campos vacíos; ahora separación manual) y lectura de satélites y HDOP.
  - v6.1: se eliminó un `printf` en `ultrasonic_task` que corrompía el transporte UART0 de micro-ROS.
  - Placa: ESP32 clásico, 2MB Flash. Puerto al flashear: `/dev/ttyUSB0`. **Intercambio decidido (02/11/26):** el sensor pasa al ESP32-S3 con el mapa de `docs/pines.md` §1 (no cableado ni portado todavía).
  - Backup de v6.1: `firmware/esp32_sensor/versions/2026_10_27_MainV6.1_pre_app.c.bak`.
  - El IMU (MPU-6500) queda como fuente **solo de monitoreo** en el Brain. El control de rumbo del robot NO depende del IMU.

### 🚜 Firmware Motores (ESP32 clásico + MC33926 + IMU placa 3) — v4.0 SIN ENCODERS
- **Estado:** ✅ Compilada (02/11/26) para `esp32` (robot, 0x4b7c0 bytes, sin warnings) y `esp32s3` (banco de prueba). ⬜ **Sin probar en hardware:** la primera carga en la S3 de prueba no conectó con el agente porque el cable estaba en el conector USB nativo (303a:1001) y micro-ROS sale por el **COM** (UART0). Prueba de banco en `docs/pruebas.md` §4.
- **Por qué:** los motores de tracción nuevos son **Pololu 37Dx57L 12 V 100:1 SIN encoder** (`docs/componentes.md`, `Datasheet/Motor_traccion_Pololu_37D.txt`); la v3.2 cerraba todo el lazo con encoders.
- **Detalle (protocolo y control completos en `docs/arquitectura.md`):**
  - **Velocidad y distancia en lazo abierto:** `PWM = PWM_ARRANQUE + v / CM_S_POR_PWM` (20 y 0,36 estimados de la hoja de datos; **a calibrar en piso**), tope 180/255, rampa 25 cm/s² y slew 600/s.
  - **Rumbo y giros con el giróscopo** de la placa 3 (I2C 0x68; GPIO 21/22 en el clásico, 6/7 en el banco). Tarea `imu_task` a 125 Hz que integra el giro alrededor de la vertical. Recta: PI de rumbo. Giro: PI sobre la velocidad angular (empuja más si la carga lo frena) y asentado de la inercia.
  - **`rumbo_obj` absoluto:** cada giro le suma exacto y la recta siguiente corrige el error del giro.
  - **Recalibración automática del bias en cada parada** (≥ 6 s quieto) con los criterios de `pruebas.md` §3, y modo **CALIBRAR** para pedirla.
  - **Protocolo v4:** `motion_cmd = [cmd_id, modo, param, bordeadora_on, cortadora_on]` (ADELANTE/ATRAS en **cm/s**; modos nuevos CALIBRAR = 6 y FIJAR_RUMBO = 7) / `motion_status = [cmd_id, estado, pwm_izq, pwm_der, feedback, rumbo, rumbo_obj, imu_estado, seg_desde_cal]`. Estado nuevo en uso: `ABORTED = 4`. Errores con código en `feedback`.
  - Se mantienen de la v3.2: "siempre atento", anti-hipo, accesorios en cada comando, PIVOT (ahora con distancias estimadas y swing medido con el giróscopo), Sabertooth y cortadora.
  - Compilar con `scripts/pc/build_motor.sh esp32|esp32s3`. `sdkconfig.defaults` con `CONFIG_FREERTOS_HZ=1000` (obligatorio para el IMU).
- **v3.2 (encoders, motores viejos):** respaldada en `firmware/esp32_motor/versions/2026_11_02_MainV3.2_encoders.c.bak` (+ `sdkconfig` del S3). Validada en piso con carga el 03/06/26 y PIVOT el 08/06/26.

---

## 2. Bloqueos Actuales o Advertencias

- **Motores de tracción sin encoder → firmware v4.0 (02/11/26):** rumbo y giros en lazo cerrado con el giróscopo de la **placa 3** (el LSM9DS1 quedó de respaldo); velocidad y distancias en lazo abierto. ⚠️ Mientras no se calibren `PWM_ARRANQUE` y `CM_S_POR_PWM` en piso, las velocidades en cm/s y las distancias del PIVOT son estimadas. El **MPU-6500 se queda en el ESP32 sensor** como verificación para la Raspberry.
- **Hardware y alimentación:** árbol de alimentación documentado en `docs/componentes.md` §3 (banco 8S para la cortadora y el LM2596; batería inferior 4S para la tracción y la bordeadora; powerbank para el procesamiento). ⛔ **El LSM9DS1 (SparkFun Breakout, 1,9–3,6 V, sin regulador) NO va a la línea de 5 V: se alimenta del 3V3 del ESP32.** Resuelto: los ECHO de los HC-SR04 tienen divisor a 3,3 V. Decidido: limitar el PWM de la tracción a ≈180/255. Acordado: medir el consumo USB de la Pi 5 y monitorear cada batería. Riesgo asumido por el equipo: capacitores del LM2596 con 33,6 V.
- **Intercambio de ESP32 decidido (02/11/26), sin ejecutar:**
  - El **S3 pasa a sensores** y el **clásico pasa a motores**. En consecuencia, el Bluetooth de la E7 es **BLE**.
  - Mapa de pines acordado en `docs/pines.md`. En el S3 se descartaron los GPIO 3 y 46 por ser strapping.
  - Antes de cablear hay que hacer las verificaciones físicas de `pines.md` §3.
  - Mientras no se porten los firmwares, ninguno de los dos funciona en la placa nueva.
- **Brain desactualizado:** sigue enviando el protocolo viejo de 7 campos. Debe reescribirse al **protocolo v4** (orden de 5 campos, status de 9) antes de la integración completa.
- **Modo PIVOT (5):** en la v4 las distancias (30/28 cm) se estiman en lazo abierto; hay que medirlas con cinta después de calibrar la velocidad.
- **Calibración en piso pendiente (v4):** `PWM_ARRANQUE` y `CM_S_POR_PWM` (velocidad real contra PWM), ganancias de rumbo (`RUMBO_KP`/`KI`) y de giro (`GIRO_KP_W`/`KI_W`, empuje máximo), y si la vibración de la cortadora deja recalibrar con el robot parado. (El tuning pendiente de la v3.2, `VEL_KI`/`HEADING_KP`, ya no aplica.)
- **Conexión física cortadora:** GPIO 18 → P1-9 INHIBIT̄ del AMC y GND ESP32 → P1-11 GND del driver.
- **Sensor sin flashear:** firmware v6.2 compilado; no hay registro de flasheo.
- **Docs con topics viejos:** `README.md` y `firmware/esp32_sensor/README.md` todavía mencionan `/bumpers`, `/ultrasonicos_cm`, `/gps_fix` e `/imu/data_raw`, que el firmware no publica (`CLAUDE.md` y el SOP ya se corrigieron el 28/10/26).

---

## 3. Próximas Tareas y Pasos Naturales

### ▶ Para retomar (cierre del 02/11/26, madrugada)

1. ✅ **Intercambio de ESP32 confirmado** y mapa de pines acordado en `docs/pines.md` (02/11/26).
2. **Verificaciones físicas antes de cablear** (`pines.md` §3):
   - El módulo S3 dice **N8R2**.
   - En qué GPIO está el LED RGB de la placa S3 (38 o 48).
   - El módulo clásico dice **WROOM** (no WROVER).
   - Qué hace el INHIBIT̄ del CBE-12A1C con el pin flotante.
3. **Commit en una rama.** ✅ Respaldo de la v3.2 en `versions/` (02/11/26). Desde el 07/06 no hay nada commiteado: el PIVOT v3.2, el sensor v6.2, el motor v4.0 y todos los docs desde el 28/10 están solo en el disco.
4. ✅ **Estrategia del motor sin encoders implementada: firmware v4.0** (02/11/26; giróscopo de la placa 3, lazo abierto, PWM ≤ 180/255, protocolo v4 en `arquitectura.md`).
   - ⬜ **Prueba de banco** en la S3 con la placa 3 (`pruebas.md` §4): pasar el cable USB al conector **COM**.
   - ⬜ **Reescribir el Brain** al protocolo v4.
   - ⬜ Cablear el ESP32 clásico (`pines.md` §2), flashear con `build_motor.sh esp32` y calibrar en piso.
5. **Prueba aislada del LSM9DS1** en el ESP32 clásico (SDA → GPIO 21, SCL → GPIO 22): escaneo I2C, deriva del giróscopo con el robot quieto durante 5 min, y campo magnético con la cortadora prendida y apagada.
   - ✅ Firmware de prueba listo y compilado (02/11/26): `firmware/esp32_motor/test_lsm9ds1`, scripts `scripts/pc/{build,flash,monitor}_test_lsm9ds1.sh`. Se corre en una **ESP32-S3 N16R8 de prueba** (I2C en los GPIO 6/7); también compila para el clásico (21/22).
   - Procedimiento, criterios y tabla de resultados en `docs/pruebas.md` §1.
   - Flasheado en la N16R8 (02/11/26), v1.2. ✅ El LSM9DS1 responde (AG 0x6B, M 0x1E) y lee valores coherentes: ruido del giro ~0,05 dps RMS, |A| 0,967 g y |B| ~23–30 µT según el lugar.
   - ⚠️ **El bias del giro se mueve:** cambia más en los primeros ~5–15 min después del encendido y después sigue oscilando (±0,015 dps, en parte por la temperatura). Una sola calibración no se sostiene: de 3 a 5 °/min respecto de una calibración de 30 min antes.
   - ✅ **Con recalibración de 3 s en cada parada** (simulado con los datos de las 4 corridas), el error de rumbo **a los 60 s** es de **~0,4° típico y ~1,3° en el peor 5 %** con ≥ 6 min de encendido (recién encendido: 2,5°). A los 120 s, peor 5 % de 2,2–3,2°.
   - **Parámetros propuestos para el firmware del motor** (sin decidir):
     - esperar ≥ 5–10 min después del encendido;
     - recalibrar en cada parada;
     - rectas de ≤ ~1 min entre recalibraciones;
     - corregir con el magnetómetro, si pasa el versus.
   - ⚠️ **Primer versus giroscopio vs magnetómetro (v1.3, 02/11/26):**
     - El giróscopo midió bien los giros.
     - La brújula tenía el **signo invertido** y errores de hasta ~15° según la orientación (calibración simple insuficiente).
     - La placa tiene un campo propio de ~26 µT.
     - **El LSM9DS1 se reinició al girarla (falso contacto): hay que asegurar el cableado.**
   - **Versus giroscopio vs magnetómetro (v1.5):** giróscopo con ±1° en giros de ±90°; brújula con error sistemático de 16–35° (campo local anormal cerca del sensor).
   - ✅ **Decisión del usuario (02/11/26):** **se descarta el magnetómetro por ahora.** El rumbo del motor se controla con el **giróscopo**, recalibrando el bias en cada parada. Conclusiones en `pruebas.md` §2.
   - ✅ **Placa 3 probada (02/11/26, `test_mpu9250`, `pruebas.md` §3):**
     - Es un **clon de 6 ejes, sin magnetómetro** (WHO_AM_I 0x75, sin AK8963).
     - **Su giróscopo es ~3 veces mejor que el del LSM9DS1:** con recalibración en cada parada, a los 60 s da 0,14° típico y 0,40° en el peor 5 % (LSM: 0,40 / 1,06–1,27°), aun arrancando en frío. Deriva de 5 min en frío: −0,44 °/min (LSM: 5,8).
   - ✅ **Prueba de giro de la placa 3:** 90° con ±1–2° de error; vuelta completa lenta de 358° (−0,6 %, dentro de la alineación a mano). En giros queda empatada con el LSM9DS1.
   - ✅ **DECISIÓN DEL USUARIO (02/11/26): la placa 3 es el IMU del ESP32_motores**; el LSM9DS1 queda de respaldo. Conviene conseguir un repuesto de la placa 3 y validarlo con la misma prueba (es un clon). Montaje: cuidar la vibración y el calor, no el magnetismo (`docs/pines.md` §2).
   - **Lecciones para el firmware del motor v4:**
     - recalibrar solo con el robot realmente quieto (ventana sin tendencia; comparar con el bias anterior);
     - descartar mediciones con huecos de lectura;
     - contemplar la inercia al frenar;
     - ±250 dps y DLPF de 41 Hz.
   - ✅ **Afinado (02/11/26, tarde):**
     - Allan y barrido → **recalibración de 5 s** en cada parada (p95 de 0,34–0,46° a los 60 s), máximo ~60 s entre recalibraciones, sin compensación de temperatura.
     - Los 356–358° de las vueltas se explican por la **inclinación de la placa** (7,7–11°) → yaw compensado con el acelerómetro (`g·up`).
     - Borrador de parámetros en `pruebas.md` §3.
   - ⚠️ **Hallazgo:** el bias cambió −0,175 dps al nivelar la placa (≈ −1 dps/g si depende de la orientación; 10 veces lo del MPU original). Si se confirma, hay que compensarlo con el acelerómetro, porque en pendientes cambiaría el bias entre paradas.
   - ✅ **`test_mpu9250` v1.2 flasheada:** YAW VERTICAL, recalibración robusta de 5 s, línea `CAL_OK` y huecos de lectura.
   - ⬜ **Pruebas A (giro con inclinación) y B (bias contra orientación, 6 posiciones)** con el usuario (`pruebas.md` §3).
   - ⬜ Pendientes: giro de 90° a mano e interferencia de la cortadora/bordeadora en el lugar de montaje (`pruebas.md` §1).
   - **Respaldo:** si el LSM9DS1 falla, hay una placa MPU-9250/6500/9255 (chip marcado "MP92 U601A1 2048", sin verificar por WHO_AM_I).
6. **Portar el sensor v6.2 al S3** (`pines.md` §5) y validarlo ahí. Reemplaza al flasheo del v6.2 en el clásico, que ya no aplica.
7. Después del cambio físico, actualizar la convención de puertos en `CLAUDE.md`: sensor → `/dev/ttyACM0`, motor → `/dev/ttyUSB0`.

### Lista general

1. **Validar el sensor v6.2 (E7 fase 1) ya portado al S3:** flashear por el conector COM (`/dev/ttyACM0`), después `ros2 topic echo /sensores`. Sin APP, los índices 15–23 deben dar `0, 0, 0, 0, 0, 0, 0, -1, 0`. Confirmar que el Brain sigue reaccionando a los bumpers.
2. **Calibrar el motor v4 en piso con carga:** velocidad real contra PWM (`PWM_ARRANQUE`, `CM_S_POR_PWM`: ADELANTE 5 s y medir con cinta), rectas largas (ganancias de rumbo) y giros de 90°/180° (ganancias de giro).
3. **Confirmar el modo PIVOT (5) en piso**, midiendo con cinta las distancias de avance (30 cm) y retroceso (28 cm) y el ángulo del swing.
4. **Reescribir el Brain** al protocolo v4: enviar `[cmd_id, modo, param, bordeadora_on, cortadora_on]` (velocidad en cm/s) y leer el `motion_status` de 9 campos. Al arrancar, esperar `imu_estado = 2` y mandar `FIJAR_RUMBO 0`; `CALIBRAR` en las paradas; reaccionar a `DONE`/`ABORTED`/`ERROR` (uso recomendado en `arquitectura.md`).
5. **Prueba de integración end-to-end:** ambos ESP32 conectados, agentes micro-ROS activos, Brain leyendo `/sensores` y enviando `/motion_cmd` con el nuevo protocolo.
6. **Pruebas A y B de la placa 3** (`pruebas.md` §3): giro con inclinación y bias contra orientación. Si el bias depende de la orientación de forma reproducible, agregar la compensación al motor v4.

### Hoja de ruta E7 (APP Android)

Diseño completo, protocolo y decisiones en **[`docs/e7_app_android.md`](e7_app_android.md)**.

1. Ampliar `/sensores` a 24 valores — ✅ compilado, falta la prueba en hardware.
2. Bluetooth básico en el ESP sensor (GPS en JSON + ACK), probado con la app nRF Connect. **Desbloqueado (02/11/26): BLE** (NimBLE recomendado). Requiere portar antes el sensor al S3.
3. ESP: comandos hacia los índices 15–23, recepción del polígono y topic `/app/working_area`.
4. Raspberry: Brain al protocolo de 5 campos + estados/watchdog + nodo nuevo `working_area_node`.
5. Flutter: conexión BT y control manual.
6. Flutter: mapa offline (`flutter_map`, tiles z19–20) y editor de área.
7. Integración y APK final.

Decisiones pendientes del usuario: (a) ~~BLE o SPP~~ → BLE, por el intercambio (02/11/26); (b) sin APP conectada: A = el robot queda quieto (recomendado) / B = comportamiento actual; (c) tamaño del cuadrado inicial del área (propuesto 10 × 10 m); (d) ~~confirmar el SO de la Raspberry~~ → ✅ **Raspberry Pi 4, Ubuntu 26.04 "Resolute", ROS 2 Lyrical** (13/11/26).
