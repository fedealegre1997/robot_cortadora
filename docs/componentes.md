# Componentes del Sistema — Robot Cortadora

**NOTA:** Documento **VIVO** con la lista oficial de componentes, su justificación, el árbol de alimentación y el estado de integración. Las fichas técnicas detalladas están en `Datasheet/`. Los pines y protocolos están en `docs/arquitectura.md`.

**Última actualización:** 28/10/26.

---

## 1. Lista de componentes

### Cómputo y sensores

| Cant. | Componente | Función | Integración actual en el código |
|---|---|---|---|
| 1 | Raspberry Pi 5 | Nodo principal de decisión (ROS 2 Jazzy) | ✅ Host del Brain y de los agentes micro-ROS |
| 2 | Microcontroladores ESP32 | ESP32 motor y ESP32 sensor (micro-ROS) | ✅ Motor: **ESP32-S3-WROOM-1 N8R2** (8 MB flash, 2 MB PSRAM). Sensor: **ESP32 clásico** (2 MB flash). **Intercambio decidido (02/11/26):** S3 → sensor, clásico → motor; mapa en `docs/pines.md` (§5) |
| 3 | Sensores ultrasónicos HC-SR04 | Distancia a obstáculos | ✅ ESP32 sensor (izq, centro, der) |
| 3 (+1 previsto) | Finales de carrera | Protección mecánica ante choques (bumpers) | ✅ 3 en el ESP32 sensor (GPIO 18, 22, 19). ⬜ Se agregará un 4.º |
| 1 | IMU MPU-6500 (6 ejes) | Roll, pitch y yaw (yaw por integración del giróscopo) | ✅ ESP32 sensor, I2C GPIO 21/23. **Se queda ahí** como verificación de orientación para la Raspberry (decidido 28/10/26) |
| 1 | IMU "placa 3": serigrafía MPU-9250/6500/9255, chip marcado "MP92" — en realidad un **clon de 6 ejes** (WHO_AM_I 0x75, sin magnetómetro) | **Rumbo y giros del control de tracción** (reemplaza a los encoders) | ✅ **Elegida para el ESP32 motor (02/11/26)**: giróscopo ~3 veces más estable que el del LSM9DS1, validado en giros (`docs/pruebas.md` §3). No integrada en el firmware del motor todavía. I2C en 0x68, VCC a 3V3 |
| 1 | IMU LSM9DS1 (9 ejes, con magnetómetro) — placa SparkFun LSM9DS1 Breakout | **Respaldo** del IMU del motor | Probado el 02/11/26 (`docs/pruebas.md` §1–2): giróscopo aceptable; magnetómetro descartado por ahora. **Solo 1,9–3,6 V** (ficha en `Datasheet/IMU_LSM9DS1_SparkFun.txt`) |
| 1 | GPS FSTR2 | Posición global (NMEA GGA) | ✅ ESP32 sensor, UART2 GPIO 16/17, 9600 baud |
| 1 | LiDAR LD19 (youyeetoo) | Detección de obstáculos 360° | ⬜ No integrado en software |
| 1 | Cámara Raspberry CAM (CSI) | Visión artificial | ⬜ No integrada en software |
| 1 | Parlante JBL Charge 5 | Sonidos personalizados (batería propia) | ⬜ No integrado en software |

### Alimentación

| Cant. | Componente | Función |
|---|---|---|
| 2 | Batería LiPo Ovonic 7200 mAh 130C 4S | En serie → banco 8S (ver §3) |
| 1 | Powerbank Ecopower 12 000 mAh, 5 V / 3 A (USB-C) | Fuente independiente del sistema de procesamiento |
| 1 | Regulador DC-DC LM2596 | Línea de 5 V desde el banco 8S |

### Motores y drivers

| Cant. | Motor | Driver | Uso | Control desde el ESP32 motor |
|---|---|---|---|---|
| 2 | Pololu 37Dx57L mm, 12 V, 100:1, **sin encoder** | Dual MC33926 Motor Driver Carrier | Tracción (ruedas) | 4 canales LEDC, GPIO 4–7 |
| 1 | D57BL-04 BLDC, 24 V, 4000 rpm @ 54 oz·in, 6,72 A | Advanced Motion Controls CBE-12A1C | Cortadora principal | GPIO 18 → INHIBIT̄ (on/off) |
| 1 | HANPOSE 775-288W, 12 V, 6000 rpm (DC con escobillas) | Sabertooth 2x25 (dual 25 A) | Bordeadora (trimmer) | UART2 TX GPIO 17, rampa soft-start |

---

## 2. Justificación de la selección

### Cómputo y sensores

- **Raspberry Pi 5:** se seleccionó por sus prestaciones; es una de las últimas versiones de la marca, y tanto su rendimiento como su tamaño y peso son ideales para este proyecto.
- **Microcontrolador ESP32-S3:** se eligió sobre el Arduino tradicional por su velocidad nominal y por su compatibilidad y velocidad con micro-ROS.
- **Sensores ultrasónicos HC-SR04:** sensores clásicos, confiables y conocidos, para detectar distancias seguras.
- **Finales de carrera:** genéricos, para protección mecánica ante cualquier choque.
- **IMU LSM9DS1:** IMU de 9 grados de libertad, seleccionado por su versatilidad y su capacidad de medir el yaw. Convive con el MPU-6500 (6 ejes), que es el que hoy está integrado; uno de los objetivos del proyecto era conseguir un IMU de 9 ejes.
- **Cámara Raspberry CAM:** elegida por su compatibilidad con la Raspberry Pi, para la visión artificial.
- **Parlante JBL Charge 5:** dispositivo para emitir sonidos personalizados.
- **Batería LiPo Ovonic:** seleccionada por su peso reducido y su capacidad.
- **Powerbank Ecopower 12 000 mAh 5 V / 3 A:** alimenta la Raspberry Pi por USB-C e independiza ese consumo, junto con el de los componentes que dependen de la Raspberry (ESP32, GPS, LiDAR), del resto del sistema.

### Motores

- **Pololu 37Dx57L mm (tracción):** seleccionados por su capacidad de torque, una reducción adecuada para la tarea, un voltaje nominal dentro del rango de las baterías y una velocidad teórica adecuada para el movimiento de la cortadora.
- **D57BL-04 BLDC (cortadora principal):** motor brushless seleccionado por su excelente torque, una velocidad ideal para la tarea, un voltaje dentro del rango de las baterías del sistema, y un acceso y funcionamiento simples para la tarea principal de la cortadora.
- **HANPOSE 775-288W (bordeadora):** motor DC con escobillas, seleccionado por su bajo costo y sus prestaciones, con voltaje nominal dentro del rango de las baterías y una velocidad ideal para la tarea.

### Drivers

- **Advanced Motion Controls CBE-12A1C (cortadora principal, D57BL-04):** driver para motor brushless, tomado del stock facilitado por el profesor de la materia. Es un driver industrial adecuado para alimentar el motor principal del sistema: entrada de 20–60 VDC y salida de 8 A pico y 4 A continuos, 230 W @ 60 VDC.
- **Sabertooth 2x25 (bordeadora, HANPOSE 775):** driver DC seleccionado por sus prestaciones y su versatilidad, tomado del stock disponible del profesor. Entrega 25 A continuos y 50 A pico por canal, con 2 canales independientes y entrada de 6–30 V nominal (33,6 V máximo absoluto).
- **Dual MC33926 Motor Driver Carrier (tracción, Pololu 37D):** driver de motor DC con entrada de 5–28 V y salida de unos 3 A continuos y 5 A pico por canal. Queda algo justo frente a la corriente de bloqueo del Pololu (5,5 A), pero es funcional para el sistema de tracción.

### General

- **Regulador LM2596:** regulador clásico a 5 V para habilitar una línea de 5 V para componentes en general.

> **Correcciones aplicadas al texto original (28/10/26):** (1) el HANPOSE 775 figuraba como "DC sin escobillas"; es **con escobillas**, según `Datasheet/Motor_bordeadora.txt`, y además el Sabertooth es un driver para motores con escobillas. (2) En el CBE-12A1C decía "8A de voltaje pico"; se interpretó como **8 A pico de corriente**. (3) El GPS de la lista original (UP-501) se reemplazó por el que está instalado, el **FSTR2**.

---

## 3. Árbol de alimentación

Dos baterías LiPo Ovonic 4S 7200 mAh 130C **en serie** forman un banco **8S**: 29,6 V nominales y 33,6 V a carga plena. El GND general del sistema es el negativo de la batería inferior.

```
           ┌─ Batería SUPERIOR 4S ─┐
           │                       │
 8S ───────┤  (29,6 V nom / 33,6 V)├──► CBE-12A1C ──► D57BL-04 (cortadora principal)
           │                       ├──► LM2596 (5 V) ──► 3× HC-SR04 (ECHO con divisor a 3,3 V)
           ├─ Batería INFERIOR 4S ─┤
 4S ───────┤  (14,8 V nom / 16,8 V)├──► Sabertooth 2x25 ──► HANPOSE 775 (bordeadora)
           │                       ├──► Dual MC33926 ──► 2× Pololu 37D (tracción)
 GND ──────┴───────────────────────┘

 Powerbank 5 V / 3 A ──► Raspberry Pi 5 ──┬─ USB ──► ESP32 motor
                                          ├─ USB ──► ESP32 sensor ──► GPS FSTR2
                                          ├─ USB ──► LiDAR LD19
                                          └─ CSI ──► Cámara Raspberry

 JBL Charge 5: batería interna propia.
 Línea de 3,3 V = pin 3V3 del ESP32 (regulador de la placa, alimentada por USB desde la Pi 5)
   └──► LSM9DS1, en el 3V3 del ESP32 motor (decidido 28/10/26).
 NUNCA conectar el LSM9DS1 a la línea de 5 V.
```

> **Corrección del 28/10/26:** el árbol original alimentaba el LSM9DS1 desde el LM2596 (5 V). La placa (SparkFun LSM9DS1 Breakout) es de 1,9–3,6 V, sin regulador, así que se pasa al 3V3 del ESP32.

### Autonomía teórica estimada (cálculo del equipo, no medida)

| Escenario | Autonomía |
|---|---|
| Máxima exigencia | ≈ 11,4 min |
| Operación normal | ≈ 19 min |

Depende de los consumos supuestos, las pérdidas eléctricas y la protección de las baterías.

### Consideraciones del diseño (del equipo)

- La batería inferior se descarga más: alimenta los motores de 12 V y además forma parte del banco 8S → **desbalance energético** entre ambas baterías.
- Las tensiones de 8S y 4S **no son salidas reguladas** de 24 V y 12 V. Hay que verificar la compatibilidad de cada driver y regular donde haga falta.
- El powerbank es una fuente independiente para el sistema de procesamiento.

---

## 4. Compatibilidad eléctrica (verificación del 28/10/26)

Rangos de batería: 4S = 13,2–16,8 V y 8S = 26,4–33,6 V (de 3,3 V/celda descargada a 4,2 V/celda cargada).

| Carga | Fuente | Rango admitido | Estado |
|---|---|---|---|
| CBE-12A1C | 8S | 20–60 VDC | ✅ OK en todo el rango de descarga |
| D57BL-04 (nominal 24 V) | 8S vía CBE-12A1C | — | ⚠️ El driver recibe hasta 33,6 V. Verificar que la referencia de velocidad limite el motor a su régimen nominal. Corriente nominal del motor (6,72 A) > 4 A continuos del driver → no entrega en continuo el torque nominal |
| LM2596 | 8S | 4,5–40 V (LM2596 estándar) | ✅ OK, con margen reducido respecto de 40 V. La tensión de los capacitores de entrada del módulo no se verificó; el equipo asume el riesgo (28/10/26) |
| HC-SR04 | LM2596 (5 V) | 5 V | ✅ OK. El ECHO pasa por un **divisor resistivo a 3,3 V** antes del ESP32 (confirmado por el equipo, 28/10/26) |
| LSM9DS1 (SparkFun Breakout) | **3V3 del ESP32** | VDD 1,9–3,6 V (serigrafía), sin regulador | ⛔ **No a 5 V**: la placa no tiene regulador ni conversor de nivel. A 3,3 V, sus pull-ups de I2C quedan a 3,3 V → SDA/SCL compatibles directo con cualquiera de los dos ESP32. No choca en el bus con el MPU-6500 (`0x69` frente a `0x6A`/`0x6B` y `0x1C`/`0x1E`) |
| Sabertooth 2x25 | 4S | 6–30 V | ✅ OK |
| HANPOSE 775 (nominal 12 V) | 4S vía Sabertooth | — | ⚠️ Recibe hasta 16,8 V (+40 %). Hoy el firmware limita la bordeadora a ~33 % (`TRIMMER_SPEED_MAX = 85`) |
| Dual MC33926 | 4S | 5–28 V | ✅ OK |
| Pololu 37D (nominal 12 V) | 4S vía MC33926 | — | ⚠️ El PWM del firmware llega a 255 (100 %) → hasta 16,8 V (+40 %). La corriente de bloqueo sube a ≈ 7,7 A (5,5 A × 16,8/12), contra 5 A pico del MC33926. **Decidido (28/10/26): limitar el PWM máximo a ≈ 180/255** (≈ 12 V con batería llena) en el rediseño del firmware del motor |
| Raspberry Pi 5 + 2 ESP32 + LiDAR + cámara (+ GPS) | Powerbank 5 V / 3 A (15 W) | La Pi 5 recomienda 5 V / 5 A | ⚠️ Con una fuente que no anuncia 5 A, la Pi 5 limita los USB a **600 mA en total**. **Acordado: medir** el consumo de los 2 ESP32 y el LiDAR |
| MPU-6500 | No figura en el árbol | — | Completar: probablemente se alimenta desde el 3,3 V del ESP32 sensor |

### Riesgos a tener en cuenta

- **Desbalance de baterías:** con la carga actual, la batería inferior puede llegar al corte mientras el banco 8S todavía marca una tensión "sana". Conviene medir **cada batería por separado** (alarma LiPo por batería, o divisor resistivo + ADC) y cargarlas individualmente con balanceo. **Acordado (28/10/26):** monitorear cada batería.
- **GND común:** el dominio del powerbank (Raspberry Pi y ESP32) y el de las baterías tienen que compartir GND para que las señales de control sean válidas: entradas del MC33926, serie del Sabertooth e INHIBIT̄ del CBE-12A1C (P1-11). Verificar en los tres drivers.

---

## 5. Intercambio de los ESP32 — decidido

> **Decisión (02/11/26):** el **ESP32-S3 pasa a sensores** y el **ESP32 clásico pasa a motores**. En consecuencia, el Bluetooth de la E7 es **BLE**. Mapa de pines acordado en `docs/pines.md`. Lo que sigue es el análisis que llevó a la decisión.

El ESP32 sensor tendrá que manejar el Bluetooth de la APP (E7). Datos para decidir:

| Aspecto | ESP32 clásico (hoy: sensor) | ESP32-S3 N8R2 (hoy: motor) |
|---|---|---|
| Bluetooth | BLE **y** Classic (SPP) | **Solo BLE** (no tiene Classic/SPP) |
| Flash | 2 MB (app de 1 MB; v6.2 usa 285 KB) | 8 MB |
| RAM | 520 KB SRAM | 512 KB SRAM + 2 MB PSRAM |
| USB en Linux | `/dev/ttyUSB0` | `/dev/ttyACM0` (CH343) |

- **Si se elige BLE:** el S3 da más margen de RAM y flash para Bluetooth + micro-ROS. Si se elige **SPP**, el Bluetooth **tiene que quedar en el ESP32 clásico** (el S3 no tiene Classic).
- **Pines:** intercambiar obliga a remapear ambos firmwares. En el ESP32 clásico, los GPIO 6–11 son de la flash SPI, y el motor usa 6–11. En el S3 no existen los GPIO 22–25 y los 26–32 son de la flash/PSRAM; el sensor usa 22, 23, 25, 26, 27 y 32. Además, en el S3 los GPIO 19/20 son el USB nativo, y el bumper derecho está en el 19.
- **Momento:** el firmware del motor ya hay que modificarlo y revalidarlo por el cambio a motores sin encoder, así que este es el mejor momento si se decide intercambiar.
- **Alternativa:** conseguir un segundo ESP32-S3 para el sensor y dejar el motor como está.

---

## 6. Pendientes de hardware

1. Confirmar la estrategia para los motores de tracción sin encoder (ver `00_estado_actual.md`). La versión con encoder (#4755) está descartada porque no se consigue (28/10/26); detalle en `Datasheet/Motor_traccion_Pololu_37D.txt`.
2. ~~Decidir el intercambio de ESP32~~ → decidido el 02/11/26 (§5). Falta cablear según `docs/pines.md`, después de las verificaciones de su §3.
3. Integrar el LSM9DS1 en el **ESP32 motor**: **alimentarlo a 3,3 V**, montarlo lejos del brushless (placa plana, eje X hacia adelante, fijación rígida, tornillos no magnéticos, cable I2C corto y alejado de la potencia), escanear el bus I2C y medir la deriva del giróscopo y la interferencia sobre el magnetómetro.
4. Agregar el 4.º final de carrera. Hoy `/sensores` tiene 3 bumpers (índices 0–2); un 4.º iría al final del array (índice 24) para no correr los índices existentes.
5. Limitar el PWM de la tracción a ≈ 180/255 (en el rediseño del firmware del motor).
6. Medir el consumo USB de la Raspberry Pi 5 (2 ESP32 + LiDAR).
7. Agregar el monitoreo de tensión por batería.
8. Verificar el GND común entre el powerbank y las baterías en los 3 drivers.
