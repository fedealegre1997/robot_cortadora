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

### Formato del arreglo (24 valores, firmware v6.2)

```
[bumper_izq, bumper_centro, bumper_der,
 ultra_izq,  ultra_centro,  ultra_der,
 roll, pitch, yaw,
 gps_lat, gps_lon, gps_alt, gps_fix,
 gps_sats, gps_hdop,
 app_connected, app_state, app_dir, app_speed,
 app_cutter, app_trimmer, app_seq,
 app_cmd_age_ms, app_polygon_id]
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
| 13 | `gps_sats` | — | Satélites en uso. `-1.0` = sin dato / dato viejo |
| 14 | `gps_hdop` | — | Precisión horizontal (menor = mejor). `-1.0` = sin dato / dato viejo |
| 15 | `app_connected` | — | `0` / `1` — APP conectada por Bluetooth |
| 16 | `app_state` | — | `0` STOP, `1` MANUAL, `2` AUTO_RUN, `3` AUTO_PAUSE |
| 17 | `app_dir` | — | `0` nada, `1` adelante, `2` atrás, `3` izq, `4` der |
| 18 | `app_speed` | % | `0`–`100`; la Raspberry lo escala a RPM |
| 19 | `app_cutter` | — | `0` / `1` — pedido de cortadora principal |
| 20 | `app_trimmer` | — | `0` / `1` — pedido de bordeadora |
| 21 | `app_seq` | — | Secuencia del último comando (`0`–`65535`) |
| 22 | `app_cmd_age_ms` | ms | Antigüedad del último comando. `-1.0` = nunca llegó |
| 23 | `app_polygon_id` | — | Id del área de trabajo vigente. `0` = ninguna |

> Campos `app_*`: el ESP fuerza `app_dir`, `app_cutter` y `app_trimmer` a `0` si la APP no está conectada o el último comando tiene más de 300 ms. Mientras no esté implementado el Bluetooth, todos quedan en su valor por defecto.

### Hardware — Pines del ESP32 Sensor

> **Intercambio acordado (02/11/26):** el sensor pasa al ESP32-S3 con otro mapa de pines (ver `docs/pines.md`). Esta tabla describe el firmware v6.2 actual, sobre el ESP32 clásico, hasta que se porte.

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
| `micro_ros_task` | 1 | 50 ms | Publica el arreglo de 24 valores en `/sensores` |
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

## Firmware v4.0: sin encoders, rumbo con IMU (02/11/26)

> **Estado:** v4.0 compilada para el ESP32 clásico (`esp32`) y para el banco de prueba (`esp32s3`, ESP32-S3 N16R8 con la placa 3). **Falta validarla en hardware.** La v3.2, con encoders y PID de velocidad, quedó en `firmware/esp32_motor/versions/2026_11_02_MainV3.2_encoders.c.bak` (su `sdkconfig` del S3, al lado).

Los motores nuevos (Pololu 37D 100:1) no tienen encoder, así que el control se reparte así:

- **Velocidad y distancia: lazo abierto calibrado.** `PWM = PWM_ARRANQUE + v / CM_S_POR_PWM`, con tope de 180/255. Las dos constantes **hay que calibrarlas en piso** (valores iniciales estimados de la hoja de datos: 20 y 0,36 → máx. ≈ 57 cm/s). Las distancias del PIVOT se estiman integrando la velocidad comandada.
- **Rumbo y giros: lazo cerrado con el giróscopo** de la placa 3 (I2C 0x68, GPIO 21/22). Una tarea propia lee el IMU a 125 Hz e integra el giro alrededor de la vertical (`g·up`, compensa la inclinación del montaje y del terreno).
  - **Recta:** PI sobre el error de rumbo (`RUMBO_KP`, `RUMBO_KI`, `RUMBO_KD`), que corrige la diferencia de velocidad entre ruedas (tope `RUMBO_CORR_MAX_CM_S`).
  - **Giro:** PI sobre la velocidad angular medida (crucero 36 °/s en el lugar, 18 °/s en el swing, desaceleración en los últimos 15°). El PI empuja más PWM si la carga frena el giro, como en la v3.2. Al llegar corta los motores y sigue integrando la inercia hasta quedar quieto.
  - **Rumbo objetivo absoluto (`rumbo_obj`):** un giro completo deja `rumbo_obj` exacto en el objetivo, y la recta siguiente corrige el sobregiro, así los errores de giro no se acumulan entre pasadas. Si un giro se interrumpe o falla, `rumbo_obj` pasa a ser el rumbo actual. Si al arrancar un movimiento el error supera 10° (robot movido a mano), también.
- **Recalibración del bias en cada parada (automática):** con la tracción quieta 1 s y el giro sin bias < 1 dps, toma ventanas de 5 s y las rechaza por ruido, tendencia o salto de bias (criterios de `docs/pruebas.md` §3). Mientras el robot sigue quieto, encadena ventanas. Lo que el bias viejo integró durante una ventana aceptada se descuenta del rumbo, así que el rumbo no deriva con el robot parado. Primera calibración al encender: el robot tiene que estar quieto unos 6 s.
- **Arranque suave:** rampa de velocidad (`ACCEL_CM_S2`) y slew del PWM (`PWM_SLEW_RATE`) en todos los modos.

---

## Formato de motion_cmd (v4)

```
[cmd_id, modo, param, bordeadora_on, cortadora_on]
```

| Campo | Índice | Valores válidos | Descripción |
|---|---|---|---|
| `cmd_id` | 0 | Entero ≥ 0 | Identificador del comando. El status lo refleja de vuelta. |
| `modo` | 1 | `0`–`7` | Ver tabla abajo |
| `param` | 2 | según modo | Ver tabla abajo |
| `bordeadora_on` | 3 | `0` / `1` | Bordeadora (Sabertooth, rampa soft-start) |
| `cortadora_on` | 4 | `0` / `1` | Cortadora central (GPIO 18 → P1-9 INHIBIT̄ del AMC) |

### Modos

| Valor | Nombre | `param` | Qué hace | Termina con |
|---|---|---|---|---|
| `0` | `STOP` | ignorado | Corta la tracción de inmediato | `DONE` a los 0,5 s |
| `1` | `ADELANTE` | velocidad en **cm/s** (≥ 0; más de ≈ 57 se recorta) | Recta continua sosteniendo `rumbo_obj` | Otro comando |
| `2` | `ATRAS` | velocidad en **cm/s** | Ídem hacia atrás | Otro comando |
| `3` | `GIRO_IZQ` | grados (0–720) | `rumbo_obj += param`; gira en el lugar (izq atrás, der adelante) | `DONE` (feedback = grados girados) |
| `4` | `GIRO_DER` | grados (0–720) | `rumbo_obj -= param`; gira en el lugar | `DONE` |
| `5` | `PIVOT` | cm a avanzar (0–300; 0 → 30) | Accesorios ON forzados → adelante `param` cm → atrás 28 cm → swing 90° a la izquierda sobre la rueda izq (`rumbo_obj += 90`) | `DONE` |
| `6` | `CALIBRAR` | segundos de ventana (0–30; 0 → 5) | Tracción quieta, espera a que el robot quede quieto y calibra el bias | `DONE` (feedback = bias z en mdps) o `ERROR` (motivo) |
| `7` | `FIJAR_RUMBO` | grados (−360 a 360) | El rumbo actual pasa a valer `param` (`rumbo_obj` se corre lo mismo). **No corta el movimiento** | `DONE` inmediato |

Velocidades de referencia (equivalencias con la v3.2, rueda de 7,5 cm): 10 RPM = 7,9 cm/s · 20 RPM = 15,7 cm/s · 30 RPM = 23,6 cm/s.

> **Notas:**
> - Los accesorios se aplican **siempre** que el comando sea válido, incluso con STOP.
> - **No existe `T_ms`:** ADELANTE/ATRAS son continuos; el Brain decide cuándo parar. El motor está **siempre atento**: un comando nuevo reemplaza al activo de inmediato y el reemplazado recibe `ABORTED`.
> - **Anti-hipo:** si la orden nueva tiene el mismo `modo` y `param` que la activa, solo cambian los accesorios (no se reinicia la marcha ni se suma otro giro).
> - **GIRO, PIVOT y CALIBRAR necesitan el IMU** (`imu_estado` 2 o 3; CALIBRAR también acepta 1). Si no está, se rechazan con `ERROR` 2.
> - **Un comando rechazado corta la tracción** (los accesorios no cambian) y publica `ERROR` con el código en `feedback`.

---

## Formato de motion_status (v4)

```
[cmd_id, estado, pwm_izq, pwm_der, feedback, rumbo, rumbo_obj, imu_estado, seg_desde_cal]
```

| Campo | Índice | Descripción |
|---|---|---|
| `cmd_id` | 0 | ID del comando al que responde (0 en el heartbeat de IDLE) |
| `estado` | 1 | Ver tabla abajo |
| `pwm_izq` | 2 | PWM aplicado a la rueda izquierda, con signo (+ adelante), −180 a 180 |
| `pwm_der` | 3 | Ídem rueda derecha |
| `feedback` | 4 | Según el modo: recta → error de rumbo (`rumbo_obj − rumbo`, décimas de grado); giro → grados girados (décimas); PIVOT → cm recorridos estimados en las fases lineales y grados (décimas) en el swing; CALIBRAR → bias z en mdps; `ERROR` → código |
| `rumbo` | 5 | Rumbo integrado del giróscopo, en décimas de grado, −1800 a 1799 (positivo = antihorario/izquierda). 0 al encender |
| `rumbo_obj` | 6 | Rumbo objetivo, mismo formato |
| `imu_estado` | 7 | `0` falla · `1` iniciando (primera calibración) · `2` listo · `3` recalibrando (ventana en curso) |
| `seg_desde_cal` | 8 | Segundos desde la última calibración aceptada (−1 = nunca) |

### Estados del motor

| Valor | Nombre | Descripción |
|---|---|---|
| `0` | `IDLE` | Sin comando activo. Heartbeat cada 1 s (con rumbo y estado del IMU). |
| `1` | `ACCEPTED` | Comando recibido y validado (ACK inmediato). |
| `2` | `EXECUTING` | En ejecución. Status cada 200 ms. |
| `3` | `DONE` | Comando terminado (STOP, giro, PIVOT, CALIBRAR, FIJAR_RUMBO). |
| `4` | `ABORTED` | Reemplazado por otro comando antes de terminar. |
| `5` | `ERROR` | Código en `feedback` (tabla abajo). |

### Códigos de error (`feedback` con `estado = 5`)

| Código | Motivo |
|---|---|
| `1` | Comando mal formado o parámetro fuera de rango |
| `2` | IMU con falla o sin calibrar |
| `3` | El giro no llegó al objetivo a tiempo (3 s + grados a la mitad del crucero): robot trabado |
| `4` | CALIBRAR: el robot no quedó quieto a tiempo (ventana + 10 s) |
| `5` | CALIBRAR: ruido > 0,5 dps (se movió) |
| `6` | CALIBRAR: tendencia en la ventana (movimiento lento) |
| `7` | CALIBRAR: el bias saltó sin cambiar la inclinación (se acepta si se repite) |

### Uso recomendado desde el Brain

- **Al arrancar:** esperar `imu_estado = 2` con el robot quieto, y mandar `FIJAR_RUMBO 0` para fijar la referencia.
- **En cada parada:** el motor recalibra solo si el robot queda quieto ≥ 6 s. Para asegurarlo, mandar `CALIBRAR` y esperar `DONE`. Conviene **no superar ~60 s de marcha** entre calibraciones (`seg_desde_cal`).
- **Pasadas paralelas:** encadenar `ADELANTE` → `STOP` → `GIRO` 180 (o `PIVOT`) → `ADELANTE`. Cada giro suma exacto a `rumbo_obj`, así la pasada siguiente sale paralela aunque el giro haya quedado corto o largo.
- **Reaccionar a `DONE`** (estado 3) para encadenar sin huecos, y a `ERROR`/`ABORTED`.

---

## Hardware — Pines del ESP32_motores (v4.0)

Mapa de `docs/pines.md` §2 (ESP32 clásico). ⬜ Todavía no está cableado.

| GPIO | Función |
|---|---|
| 32 / 33 | MC33926 — M1 IN1 / IN2 (motor izquierdo) |
| 25 / 26 | MC33926 — M2 IN1 / IN2 (motor derecho) |
| 21 / 22 | I2C SDA / SCL — IMU placa 3 (0x68) |
| 17 | Sabertooth S1 (bordeadora, UART2 TX, 9600 baud) |
| 18 | AMC CBE12A1C INHIBIT̄ (cortadora central, P1-9) |
| 1 / 3 | UART0 (micro-ROS por el puente USB) |

**Banco de prueba (`esp32s3`, ESP32-S3 N16R8):** I2C en 6/7, PWM en 4/5/15/16 (sin motores), 17 y 18 iguales. micro-ROS sale por el **UART0 → conector COM** (CH343). El conector USB nativo (303a:1001) no sirve para el agente.

**Compilar:** `~/robot_cortadora/scripts/pc/build_motor.sh esp32` (robot) o `... esp32s3` (banco). Sin argumento usa el target actual. Cambiar de target recompila todo (unos minutos). El `sdkconfig.defaults` fija `CONFIG_FREERTOS_HZ=1000`, que el IMU necesita (sin eso, no compila).

---

## Ejemplos de uso (v4)

Antes de publicar comandos, cargar el entorno ROS 2:

```bash
source ~/robot_cortadora/scripts/common/env.sh
```

Para ver el feedback en tiempo real (terminal separada):

```bash
ros2 topic echo /motion_status
```

### Solo accesorios (motores parados → modo STOP)

```bash
# Cortadora central encendida, bordeadora apagada
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [1, 0, 0, 0, 1]}"
# Bordeadora encendida, cortadora apagada
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [2, 0, 0, 1, 0]}"
# Apagar todo
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [3, 0, 0, 0, 0]}"
```

### Recta (continua hasta nuevo comando, rumbo sostenido)

```bash
# Adelante a 15 cm/s (≈ 19 RPM), sin accesorios
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [4, 1, 15, 0, 0]}"
# Atrás a 10 cm/s, bordeadora encendida
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [5, 2, 10, 1, 0]}"
```

### Giro por ángulo (giróscopo)

```bash
# 90° a la izquierda
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [6, 3, 90, 0, 0]}"
# 90° a la derecha
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [7, 4, 90, 0, 0]}"
```

El motor publica `estado=3` (DONE) con los grados girados (décimas) en `feedback` y vuelve a `IDLE`.

### PIVOT, calibración y referencia

```bash
# PIVOT: adelante 30 cm, atrás 28 cm y swing 90° a la izquierda
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [8, 5, 0, 0, 0]}"
# Calibrar el bias del giróscopo con una ventana de 5 s (robot quieto)
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [9, 6, 5, 0, 0]}"
# El rumbo actual pasa a valer 0°
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [10, 7, 0, 0, 0]}"
```

### Stop

```bash
ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [11, 0, 0, 0, 0]}"
```

---

## Reglas de comportamiento

- El motor está **siempre atento**: un comando nuevo **reemplaza** al que esté en ejecución de inmediato, sin importar el modo (ya no rechaza comandos por estar ocupado).
- **Orden idéntica = no reinicia la marcha:** si la nueva orden tiene el **mismo `modo` y `param`** que la que ya se está ejecutando, el firmware **solo actualiza los accesorios** (bordeadora/cortadora) y NO reinicia el lazo de control. Así se puede prender/apagar una herramienta mientras el robot avanza, sin el "hipo" de re-arranque. Verificado en banco con cortadora y bordeadora.
- Los **movimientos son continuos** (sin `T_ms`): se mantienen hasta recibir otro comando. El flujo de tiempos lo maneja el Brain.
- Los **giros**, el PIVOT, CALIBRAR y STOP terminan solos (publican `DONE` y vuelven a `IDLE`).
- Un comando **reemplazado** recibe `ABORTED`; un comando **rechazado** corta la tracción y recibe `ERROR` con código.
- Los **accesorios se aplican siempre** al recibir cualquier comando, incluyendo STOP.
- El **cmd_id** debe ser único por operación para que el Brain pueda correlacionar el feedback.
- La **bordeadora** usa rampa de soft-start (kick-start anti-cogging); el apagado es inmediato.
- La **cortadora central** se habilita/inhibe directamente por GPIO (sin rampa); el driver AMC CBE12A1C maneja internamente el arranque del BLDC.
