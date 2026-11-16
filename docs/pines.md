# Mapa de Pines — Intercambio de ESP32

**NOTA:** Documento **VIVO**. Contiene el mapa de pines **acordado el 02/11/26** para el intercambio de placas: el **ESP32-S3** pasa a sensores y el **ESP32 clásico** pasa a motores.

**Estado:** ⬜ todavía no se cableó ni se portó el firmware. Mientras tanto, los pines que usa el firmware actual son los de `docs/arquitectura.md`. Cuando el firmware nuevo esté validado, este mapa pasa a `arquitectura.md`.

---

## 1. ESP32-S3-WROOM-1 N16R8 → ESP32_sensores (confirmado 13/11/26)

Actualización: GPS RX4/TX5 ya recableado y diagnóstico cargado. GPIO35/36/37 están reservados internamente en este módulo. Bumper derecho trasladado a GPIO39 con firmware cargado; pendiente verificar accionamiento en el nuevo pin. Las referencias históricas posteriores al N8R2 o GPS35/36 no describen la placa actual.

Los pines de los ultrasónicos, los bumpers y el GPS (35/36) los eligió el usuario. El ECHO del centro (9), el 4.º bumper (39), el I2C y las reservas se propusieron y el usuario los aceptó.

| GPIO | Función | Se conecta a | Antes (clásico) |
|---|---|---|---|
| 17 | TRIG ultrasónico derecho | HC-SR04 der. — TRIG | 33 |
| 15 | ECHO ultrasónico derecho | HC-SR04 der. — ECHO **por el divisor a 3,3 V** | 35 |
| 18 | TRIG ultrasónico izquierdo | HC-SR04 izq. — TRIG | 25 |
| 16 | ECHO ultrasónico izquierdo | HC-SR04 izq. — ECHO **por el divisor a 3,3 V** | 32 |
| 8 | TRIG ultrasónico centro | HC-SR04 centro — TRIG | 26 |
| 9 | ECHO ultrasónico centro | HC-SR04 centro — ECHO **por el divisor a 3,3 V** | 27 |
| 38 | Bumper izquierdo | Final de carrera izq. | 18 |
| 2 | Bumper centro (adelante) | Final de carrera centro | 22 |
| 39 | Bumper derecho (activo LOW) | Final de carrera derecho, movido y firmware cargado 14/11/26 | 19 |
| — | 4.º bumper (sin pin asignado) | GPIO39 ahora utilizado por el derecho | — |
| 4 | UART2 RX (entra al ESP) | **TX** del GPS FSTR2 | 16 |
| 5 | UART2 TX (sale del ESP) | **RX** del GPS FSTR2 | 17 |
| 6 | I2C SDA | MPU-6500 SDA | 21 |
| 7 | I2C SCL | MPU-6500 SCL | 23 |
| 1, 10 | Reservados (ADC1) | Futuro monitoreo de tensión de cada batería (con divisor) | — |
| 43 / 44 | UART0 → micro-ROS | Interno: chip CH343 → conector **COM** → Raspberry. **No cablear** | 1 / 3 |

**Alimentación y masas:**
- **3V3 del ESP:** VCC del MPU-6500. **Actualización 13/11/26:** la prueba física detectó el IMU en `0x68` (WHO_AM_I `0x70`) y no en `0x69`; el firmware usa ahora `0x68`. AD0 bajo corresponde a esta dirección. La indicación anterior de AD0 a 3V3 / dirección 0x69 no coincide con la placa probada; no se verificó físicamente el cable de AD0.
- **5 V del LM2596:** VCC de los 3 HC-SR04 (no del ESP).
- **GND del ESP:** GND del MPU-6500, del GPS, de los HC-SR04 y un borne de cada final de carrera. Masa común con las baterías.
- **Finales de carrera:** el firmware usa pull-up interno y toma LOW como presionado → contacto **normalmente abierto** entre el GPIO y GND.
- **GPS (prueba 14/11/26):** VDD y VDD_B conectados a la fuente de 3,3 V, ≈3,18 V medidos respecto de GND en ambos. VDD_B había quedado libre; tras alimentarlo se recibió NMEA por TX GPS→GPIO4 a 9600 baud. RX GPS permanece desconectado en recepción pasiva. UP501.pdf §4.2 exige VDD_B junto a VDD salvo variante con batería interna; no extender este cableado a una variante distinta sin verificarla.

**No usar:**
- **0, 3, 45, 46:** strapping.
- **19 y 20:** USB nativo.
- **43 y 44:** UART0 del conector COM (micro-ROS).
- **22 a 34:** no están disponibles en el WROOM-1.
- **47 y 48:** en algunas placas uno de ellos maneja el LED RGB.

**Libres de reserva:** 4, 5, 11, 12, 13, 14, 21, 40, 41 y 42.

**Bluetooth:** el BLE usa la radio interna y no ocupa ningún GPIO, y todos estos pines se leen como digitales. El 39 es uno de los pines del JTAG externo, que viene desactivado de fábrica (el S3 usa el JTAG por USB).

⚠️ **Regla: nada analógico en ADC2.** En otro proyecto del usuario (ESP32 + BLE), `adc2_get_raw()` fallaba mientras el BLE estaba activo, no solo con Wi-Fi. Por eso las reservas de batería están en **ADC1** (GPIO 1 y 10).

## 2. ESP32 clásico → ESP32_motores

Actualización14/11/26: I2C elegido por usuario SDA27/SCL14, aplicado en fuente normal y diagnóstico. IMU detectado0x68/WHO0x75. GPIO14 compartido con JTAG; no usar JTAG simultáneamente. Potencia del driver apagada por arranque inesperado de tracción izquierda, causa pendiente.

Propuesto el 02/11/26; el usuario no pidió cambios.

| GPIO | Función | Se conecta a | Antes (S3) |
|---|---|---|---|
| 32 | PWM M1 IN1 (rueda izquierda) | MC33926 **M1IN1** | 4 |
| 33 | PWM M1 IN2 (rueda izquierda) | MC33926 **M1IN2** | 5 |
| 25 | PWM M2 IN1 (rueda derecha) | MC33926 **M2IN1** | 6 |
| 26 | PWM M2 IN2 (rueda derecha) | MC33926 **M2IN2** | 7 |
| 17 | UART2 TX → bordeadora | Sabertooth **S1** | 17 |
| 18 | Habilitación de la cortadora | CBE-12A1C **P1-9** (INHIBIT̄) | 18 |
| 27 | I2C SDA | IMU placa 3 (MPU, 0x68) SDA. Respaldo: LSM9DS1 | nuevo |
| 14 | I2C SCL | IMU placa 3 (MPU, 0x68) SCL. Respaldo: LSM9DS1 | nuevo |
| 34, 35 | Reservados (ADC1, solo entrada) | Opcional: MC33926 M1FB / M2FB (corriente, para detectar una rueda trabada) | — |
| 1 / 3 | UART0 → micro-ROS | Interno: puente USB → Raspberry. **No cablear** | 43 / 44 |
| — | Encoders | **Se eliminan** (motores sin encoder) | 8, 9, 10, 11 |

**Alimentación y masas:**
- **3V3 del ESP:** VCC del IMU (placa 3; elegida el 02/11/26) y VDD de lógica del MC33926. Si se usa el LSM9DS1 de respaldo: VDD a 3V3, **nunca a 5 V**.
- **GND del ESP:** GND del IMU, GND del MC33926, **0V** del Sabertooth y **P1-11** del CBE-12A1C.
- **Montaje del IMU:** el giróscopo no se ve afectado por imanes ni metal, pero sí por la **vibración** (cuchilla, bordeadora) y el **calor**. Montaje rígido sobre un amortiguador, lejos del soporte del motor de la cortadora y de drivers y motores calientes, plano y con el eje Z vertical. Cable I2C corto, lejos de los cables de potencia y PWM, con contactos firmes.
- **MC33926:**
  - Habilitación: **EN → 3V3, D1 → GND, D2 → 3V3** (niveles que el driver necesita para entregar salida).
  - VIN a la batería inferior 4S.
  - M1OUT a la rueda izquierda y M2OUT a la derecha.
- **Sabertooth:** su borne **5V no se conecta al ESP**; es una salida de su fuente interna.

**No usar:**
- **6 a 11:** flash.
- **0, 2, 5, 12, 15:** strapping.
- **5, 14 y 15:** sacan pulsos PWM al arrancar; conectados al MC33926, las ruedas darían un tirón en cada reset o flasheo.
- **12:** en alto al arrancar impide que bootee.
- **34 a 39:** solo entrada.

## 3. Verificar antes de cablear

1. **Módulo S3:** la tapa metálica tiene que decir **N8R2**. En N8R8 o N16R8, los GPIO 35–37 los usa la PSRAM interna: te quedarías sin GPS (35/36) ni bumper derecho (37). Al portar el firmware, la PSRAM no se activa en modo octal.
2. **LED RGB de la placa S3:** ver en la serigrafía si está en el GPIO 38 o en el 48. Si está en el 38, el bumper izquierdo lee igual, pero el LED puede parpadear cuando rebota el contacto (inofensivo).
3. **Módulo clásico:** tiene que decir **WROOM**. En WROVER, los GPIO 16 y 17 los usa la PSRAM, y el Sabertooth necesitaría otro pin.
4. **INHIBIT̄ del CBE-12A1C con el pin flotante** (ESP reseteándose, flasheándose o desconectado): ver en su hoja de datos qué pull interno tiene. Si con el pin flotante queda habilitado, agregar un pull-down dimensionado para ese pull, para que la cortadora no arranque durante un flasheo.
5. ✅ **LSM9DS1:** confirmado por escaneo I2C el 02/11/26: **AG 0x6B y M 0x1E** (jumpers SDO en 1).

## 4. Pines descartados

| GPIO (S3) | Propuesto para | Motivo |
|---|---|---|
| 3 | ECHO ultrasónico centro | Strapping (fuente del JTAG). Solo afecta con un eFuse quemado, pero se descartó por ser strapping |
| 46 | ECHO ultrasónico centro | Strapping (modo de arranque junto con el GPIO 0). Si está en HIGH cuando el auto-reset baja el GPIO 0, el ESP no entra en modo descarga y el flasheo falla. El ECHO podría estar en HIGH si el sensor dispara durante el reset → fallas intermitentes |

## 5. Impacto en firmware y scripts (pendiente)

- **Sensor:**
  - Cambiar el target del proyecto a `esp32s3` (flash de 8 MB).
  - Actualizar los `#define` de pines según §1.
  - El Bluetooth es **BLE** obligatoriamente, porque el S3 no tiene Classic/SPP.
- **Motor:**
  - Cambiar el target a `esp32`.
  - Sacar PCNT y encoders, actualizar los `#define` según §2 y agregar el LSM9DS1. El control se reescribe igual por los motores sin encoder.
- **Puertos:** el sensor pasa a `/dev/ttyACM0` (COM del S3) y el motor a `/dev/ttyUSB0`. Actualizar la convención de `CLAUDE.md` cuando se haga el cambio físico.
