# Pruebas de Hardware

**NOTA:** Documento **VIVO** con el procedimiento de cada prueba de hardware aislada, sus criterios y sus resultados. El detalle de cada sesión queda en `02_registro_acciones_raw.md`.

---

## 1. LSM9DS1 aislado — `firmware/esp32_motor/test_lsm9ds1` (v1.2)

**Objetivo:** verificar que el LSM9DS1 funciona (comunicación, acelerómetro, giróscopo y magnetómetro) y medir la deriva del giróscopo y la interferencia magnética antes de integrarlo al ESP32_motores.

**Estado:**
- ✅ Flasheado en la ESP32-S3 N16R8 (02/11/26).
- ✅ El LSM9DS1 responde (02/11/26, tras cambiar el cable del GPIO 6): AG 0x6B, M 0x1E, WHO_AM_I y configuración OK.
- ⚠️ **La deriva en reposo depende de cuánto tiempo lleva encendido el sensor** (02/11/26, ver Resultados):
  - 5,8 °/min recién encendido.
  - 1,25 °/min a los ~6–12 min.
  - 0,1–0,2 °/min después de horas encendido.
  - Hay un **calentamiento inicial**: el bias del giro cambia más durante los primeros ~5–15 min después del encendido. Después **sigue moviéndose** (±0,015 dps en ventanas de 2 min, en parte por la temperatura), así que una sola calibración no se sostiene durante decenas de minutos.
- ✅ **Con recalibración de 3 s en cada parada** (simulado con los datos de las 4 corridas, ver "Recalibración en cada parada"), el error de rumbo **60 s después** es de **~0,4° típico y 1,1–1,4° en el peor 5 %** con ≥ 6 min de encendido. Recién conectado: 0,54° típico y 2,5° en el peor 5 %.
- ⬜ Pendientes: giro de 90° a mano e interferencia magnética de la cortadora y la bordeadora, con el sensor en su ubicación de montaje.

### Conexión

El firmware compila para los dos targets y elige los pines I2C según la placa. La prueba se hace en una **ESP32-S3-WROOM-1 N16R8** de prueba (02/11/26); la integración final va en el ESP32 clásico (`docs/pines.md` §2).

| LSM9DS1 | ESP32-S3 N16R8 (prueba) | ESP32 clásico (motor) |
|---|---|---|
| VDD | **3V3** (nunca 5 V) | **3V3** (nunca 5 V) |
| GND | GND | GND |
| SDA | GPIO 6 | GPIO 21 |
| SCL | GPIO 7 | GPIO 22 |

El resto de los pines del LSM9DS1 queda sin conectar, con los jumpers como vienen. Conectar **solo** el LSM9DS1 a la placa de prueba.

> **N16R8 ≠ N8R2:** la N16R8 tiene PSRAM octal, que usa internamente los GPIO 35–37. Esta placa **no** puede reemplazar a la N8R2 como ESP32_sensores con el mapa de `pines.md` §1 (GPS en 35/36, bumper derecho en 37) sin remapear.

### Comandos

```bash
ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null                  # identificar el puerto
~/robot_cortadora/scripts/pc/build_test_lsm9ds1.sh esp32s3   # o: esp32 para el clásico
~/robot_cortadora/scripts/pc/flash_test_lsm9ds1.sh /dev/ttyACM0
~/robot_cortadora/scripts/pc/monitor_test_lsm9ds1.sh /dev/ttyACM0
```

- **S3:** usar el conector **COM**. El firmware también escribe por el USB nativo (consola secundaria), así que cualquiera de los dos muestra la salida. Si el S3 del motor también está conectado, la placa de prueba puede aparecer como `/dev/ttyACM1`.
- **Clásico:** el puerto suele ser `/dev/ttyUSB0`.
- El flash del S3 está configurado en 16 MB (`sdkconfig.defaults.esp32s3`), para no repetir el rechazo por tamaño de flash que ocurrió el 31/05/26 con el N8R2.

No puede haber un micro-ROS Agent abierto en ese puerto. Para salir del monitor: `Ctrl+]`. Para repetir la prueba: botón **EN** (o RST) de la placa.

### Etapas y qué mirar

1. **Detección:**
   - El escaneo I2C muestra `0x1E` y `0x6B`, o `0x1C` y `0x6A` (según los jumpers SDO).
   - `WHO_AM_I` da `OK` en AG (`0x68`) y M (`0x3D`).
   - `Configuracion: OK`.
   - **Si no responde nada**, el firmware corre un diagnóstico de cableado:
     - Pone cada GPIO libre como entrada con pull-down interno. Los que leen 1 tienen un pull-up externo, es decir, están conectados a SDA o SCL de un breakout alimentado (pull-ups de 10 kΩ, jumper "I2C PU").
     - Prueba también con SDA y SCL invertidos.
     - Si los dos pines esperados tienen pull-up, VDD y las dos líneas están bien. Si no aparece ningún pin, falta VDD o no llega ninguna línea. El diagnóstico **no prueba el GND**.
2. **Calibración (3 s, quieto):** se imprimen el bias y el ruido del giróscopo. Con la placa apoyada, `|A|` ≈ 1 g → `OK`.
3. **Deriva (5 min, quieto, sin tocar la mesa):** un resumen por minuto y, al final, el bloque `RESULTADO DE LA DERIVA` (deg acumulados y deg/min).
4. **Chequeos funcionales** (el programa sigue midiendo después del resultado):
   1. **Escala y signo del giróscopo:** girar la placa 90° a mano sobre la mesa. El `yaw` tiene que cambiar ≈ +90 en sentido antihorario o ≈ −90 en sentido horario.
   2. **Magnetómetro vivo:** al acercar un destornillador o un imán, `|B|` cambia claramente.
   3. **Interferencia de los motores:** con la placa en su ubicación de montaje, anotar `|B|` y `M(uT)` con todo apagado, con la cortadora, con la bordeadora y con ambas.
      - Mientras el S3 siga siendo el motor (v3.2), los accesorios se prenden desde ROS 2 (agent en `/dev/ttyACM0`):

        ```bash
        source ~/robot_cortadora/scripts/common/env.sh
        ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [1, 0, 0, 0, 1]}"   # cortadora
        ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [2, 0, 0, 1, 0]}"   # bordeadora
        ros2 topic pub --once /motion_cmd std_msgs/msg/Int32MultiArray "{data: [3, 0, 0, 0, 0]}"   # todo apagado
        ```

      - ⛔ **No mandar ADELANTE, ATRAS, GIRO ni PIVOT con la v3.2.** Sin encoders, el PID mide 0 RPM y sube el PWM al máximo: los giros nunca terminan y las rectas van a fondo.

### Criterios (estimación propia, a confirmar con la experiencia)

- **Deriva en reposo:** una recta de 10 m a ~0,16 m/s (20 RPM de rueda) dura ~1 min. Si el error de rumbo crece linealmente, el desvío lateral al final es ≈ L·θ/2.
  - **< 1 °/min:** bueno, ≈ 9 cm de desvío en 10 m.
  - **1–5 °/min:** usable si se recalibra el bias en cada parada; con 5 °/min el desvío es ≈ 44 cm.
  - **> 5 °/min:** revisar el montaje y la temperatura, o evaluar la placa de respaldo (MPU-9250).
  - La deriva en marcha (vibración, calor de los motores) va a ser mayor que en reposo; esto es una cota inferior.
- **Interferencia magnética:** con una componente horizontal del campo terrestre de ~20 µT (Paraguay), cada 1 µT de perturbación horizontal equivale a ≈ 3° de error de rumbo (atan(1/20)). Si la cortadora mueve el campo varios µT, el magnetómetro no sirve en ese lugar para corregir el rumbo, y el control queda solo con el giróscopo.
- **Errores I2C:** 0.

### Resultados

| Fecha | Placa / montaje | Direcciones | Bias z (dps) | Ruido z (dps RMS) | Deriva (°/min) | Giro 90° a mano | ΔB cortadora (µT) | ΔB bordeadora (µT) | Errores I2C |
|---|---|---|---|---|---|---|---|---|---|
| 02/11/26 madrugada (horas encendido) | ESP32-S3 N16R8, breakout suelto sobre la mesa, firmware v1.2 | AG 0x6B / M 0x1E | +0,023 (x +0,149; y +5,705) | 0,048 (x 0,050; y 0,078) | −0,11 total en 300 s; +0,18 sin los 3 s de movimiento (ver nota) | ⬜ | ⬜ | ⬜ | 0 |
| 02/11/26 mediodía (recién conectado) | Ídem, otra posición en la mesa | AG 0x6B / M 0x1E | −0,195 (x +0,425; y +4,281) | 0,052 (x 0,053; y 0,091) | **+5,84** (+29,2° en 300 s; creciente) | ⬜ | ⬜ | ⬜ | 0 |
| 02/11/26 mediodía (~6 min encendido) | Ídem, misma posición | AG 0x6B / M 0x1E | −0,119 (x +0,234; y +5,250) | 0,052 (x 0,053; y 0,083) | **+1,25** (+6,2° en 300 s) | ⬜ | ⬜ | ⬜ | 0 |

**Curva de 30 min (02/11/26, 13:04–13:34):**
- Captura de 1800 s con la calibración a los ~4 min del encendido en frío (el usuario desconectó y reconectó a las ~13:00). 0 errores I2C, ningún segundo con \|gz\| > 0,3 dps.
- **Residual de gz respecto de esa calibración (medias de 2 min):** +0,043 dps (4–6 min) → +0,055 (6–10) → +0,058 (12–14) → +0,085 (16–18) → entre +0,051 y +0,083 hasta los 34 min, sin tendencia clara.
- Deriva respecto de esa calibración: 2,3–5,5 °/min por minuto; +114° en 29 min.
- **Temperatura del chip:** 23,8 °C → 22,5 °C (minuto 20) → 22,8 °C. El ambiente se enfrió durante la corrida.
- gx y gy también cambiaron (gx −0,01 → +0,12; gy +0,19 → −0,16 dps).

**Recalibración en cada parada (simulación con los datos, script `recalibrar.py` del scratchpad de la sesión):** para cada instante se toma la media de 3 s como bias, igual que haría el robot al detenerse, y se integra el residual durante T segundos. Error de rumbo absoluto, mediana / p95 / máximo (grados):

| Corrida | T = 30 s | T = 60 s | T = 120 s |
|---|---|---|---|
| Madrugada, horas encendido | 0,17 / 0,53 / 0,69 | **0,40 / 1,06 / 1,28** | 0,74 / 2,45 / 2,84 |
| Mediodía, recién conectado | 0,24 / 0,73 / 1,49 | **0,54 / 2,48 / 3,55** | 1,61 / 6,41 / 9,31 |
| Mediodía, ~6 min | 0,21 / 0,56 / 0,78 | **0,36 / 1,05 / 1,36** | 0,95 / 2,23 / 3,02 |
| Curva de 4 a 34 min | 0,18 / 0,56 / 1,13 | **0,42 / 1,27 / 2,75** | 0,97 / 3,20 / 6,53 |

- **Lectura:** con ≥ 6 min de encendido y una recalibración en cada parada, una recta de 1 min termina con ~0,4° de error típico (≈ 3,5 cm en 10 m) y ~1,3° en el peor 5 % (≈ 11 cm en 10 m).
- **Recién encendido**, el peor 5 % llega a 2,5° (≈ 22 cm).
- **Con más de 2 min** sin recalibrar, el error crece rápido.
- La simulación es en reposo; en marcha, la vibración y el calor de los motores agregan error.

**Notas de las corridas del mediodía (02/11/26):**
- **Recién conectado** (el usuario lo conectó justo antes de la captura):
  - Por minuto: +2,88 / +5,85 / +6,27 / +6,83 / +7,39°.
  - Error residual de gz en ventanas de 30 s: +0,032 → +0,101 dps a los 90 s → +0,125 a los 5 min. En y: +0,30 → +1,20 dps.
  - Temperatura del chip: 22,6 → 23,0 °C.
  - El bias cambia rápido al principio y después más lento: forma típica de un calentamiento inicial.
- **Segunda corrida, ~6 min después:**
  - Por minuto: +0,59 / +1,55 / +1,50 / +1,51 / +1,08°.
  - Residual de gz: +0,006 → +0,028 dps (60–120 s) → +0,015 al final.
  - Temperatura estable (23,0–23,1 °C).
  - Mejor, pero el bias todavía se mueve.
- **Bias calibrado según la corrida:** y = 5,705 (ayer, horas encendido), 4,281 (frío) y 5,250 (~6 min). Su valor absoluto también cambia con el calentamiento.
- **\|B\|** = 11–15 µT en esta posición (ayer, 23–30 µT en otras): el entorno de la mesa influye.

**Nota (corrida de la madrugada del 02/11/26):**
- **Minuto a minuto:** +0,324 / +0,077 / −0,366 / −1,126 / +0,534°.
- **Primeros 3 min (sin perturbación):** yaw neto +0,035°.
- **Minuto 4:** en t = 218 s, giro de +7,2° y en t = 224–225 s de −8,4°. Al mismo tiempo, \|B\| pasó de ~29 a ~40 µT. El sensor fue movido y algo magnético se le acercó; no es deriva.
- **Rango de \|B\| en esta corrida:** 27,6–30 µT antes del evento y 38,5–40,6 después. En la corrida anterior, en otra posición: 22,5–23,2. El campo depende del entorno de la mesa.
- **Temperatura:** 23,2–23,9 °C.
- **Ruido blanco:** 0,05 dps RMS a 123 Hz, que da una caminata aleatoria de ≈ 0,035°/min. Las oscilaciones de ±0,3–0,5° por minuto vienen de la inestabilidad lenta del bias (≈ ±0,005 dps).

---

## 2. Versus giroscopio vs magnetómetro — `test_lsm9ds1` v1.5

**Objetivo:** comparar las dos formas de medir el rumbo en tres situaciones: (A) giros de ángulo conocido, (B) el paso del tiempo quieto y (C) una perturbación magnética. Con eso se decide cómo combinarlos en el ESP32_motores.

**Estado:**
- ⚠️ **Primer intento con la v1.3 (02/11/26, 14:04–14:09):**
  - Reveló el **signo invertido** del magnetómetro.
  - Errores de la brújula de hasta ~15° según la orientación (calibración simple insuficiente).
  - Campo propio de la placa de ~26 µT.
  - **Un reinicio del LSM9DS1 al girar la placa** (falso contacto).
  - Ver "Resultados".
- ✅ **v1.4 compilada** (signo corregido, ajuste de elipse, Bh calibrado, la referencia se vuelve a tomar siempre). El ajuste se verificó en la PC con datos sintéticos.
- ⚠️ **Segundo intento con la v1.5 (02/11/26, 14:38–14:40):**
  - El signo ya coincide.
  - **Giróscopo:** dentro de ~1° en todos los giros de ±90° y en los regresos a 0.
  - **Brújula:** se equivoca de 16 a 35° a ±90°, aunque es repetible (+105,4 / +105,5 / +105,9 en las tres visitas a +90°). Es un error sistemático: la calibración no coincide con el campo que ve el sensor durante la prueba (`Bh` de 14–16 µT a 0° y de 19–23 µT a ±90°).
  - **Campo horizontal de solo 13,8 µT** (en el primer intento eran ~26) y centro +34,1 µT (antes +26): algo cambió alrededor del sensor entre las dos sesiones.
  - Hipótesis: material ferromagnético cerca (protoboard, placa S3, notebook) y el sensor desplazándose al girar.
  - ⬜ Repetir con el sensor fuera de la protoboard, sobre un soporte no metálico, lejos de la notebook.

### Cómo funciona

- **Botón BOOT** (durante la medición): calibra el magnetómetro. Hay que girar la placa una vuelta completa, despacio y apoyada, en 20 s.
  - **v1.4:** con las ~400 muestras X/Y se hace un **ajuste de elipse por mínimos cuadrados**. Del ajuste salen el centro (hard iron) y una matriz 2×2 que lleva la elipse inclinada a un círculo (soft iron). Si el ajuste falla, se usan el mínimo y el máximo por eje (método de la v1.3).
  - Informa los semiejes, la relación, el ángulo del eje mayor y la **dispersión del campo calibrado** (bueno < 3 %).
  - El giróscopo verifica que la vuelta tenga ≥ 330°. Si no, la calibración falla y hay que repetirla (se conserva la calibración anterior).
  - Supone la placa horizontal, sin compensar inclinación.
  - **Verificación del ajuste en la PC** (funciones extraídas del `.c` con `awk`, scratchpad `test_elipse/`). Elipse sintética con centro (26, −6), relación 1,25 e inclinación 30°:
    - Sin ruido: recupera todo exacto, con error de rumbo de 0,00°.
    - Con 0,3 µT de ruido: centro 26,04 / −6,01, relación 1,255, ángulo 29,7°, dispersión 1,3 %, error de rumbo máximo de 2,8° (por el ruido).
    - Corrigiendo solo el centro, el error llegaría a 11,6–13,3°.
- **Botón BOOT (v1.5):** **1 toque** = calibrar el magnetómetro. **2 toques seguidos** (en menos de 0,4 s) = **nueva referencia** en la posición actual. El botón se lee sin frenar la medición.
- **Referencia:** se toma cuando la placa queda quieta 1,5 s, después de cada calibración (exitosa o no), de cada doble toque y de cada reinicio de la prueba. Pone **YAW GIRO = 0 y YAW MAG = 0** (`REFERENCIA`).
- **Con el magnetómetro calibrado, la línea por segundo cambia a la versión corta:**
  `[  25 s]  YAW GIRO =   +90.1  |  YAW MAG =   +89.4  |  diferencia =  +0.7  |  Bh = 26.1 uT`
  - **YAW GIRO:** grados girados desde la referencia según el giróscopo.
  - **YAW MAG:** grados girados desde la referencia según el magnetómetro (desenvuelto).
  - **diferencia:** YAW GIRO − YAW MAG.
  - **Bh:** campo horizontal calibrado; casi constante si todo anda bien.
  - Positivo = antihorario visto desde arriba. Antes de calibrar se sigue imprimiendo la línea completa de diagnóstico.
- **Línea `PARADA`:** cada vez que la placa queda quieta 1,5 s después de girar más de 10°, se imprimen los mismos cuatro valores.
- **Alineación de ejes:** la v1.3 suponía X invertido (x_AG = −mx) y la prueba mostró el signo al revés. **La v1.4 toma los ejes X/Y del magnetómetro tal cual** (mismo sentido de giro que el acel/giro; puede quedar un desvío constante, que no afecta a `dMag`).
- **`|B|` crudo** (sin calibrar) varía mucho con la orientación por el campo propio de la placa (~26 µT, probablemente de las pinzas de acero de la protoboard). Para ver perturbaciones hay que mirar **`Bh`**, no `|B|`.

### Procedimiento

Usar una superficie con referencias de 90°, por ejemplo el borde de la mesa o una escuadra, a más de 30 cm de objetos metálicos, sin celular cerca. La placa ya tiene que estar caliente (≥ 30 min encendida). **Girar la placa sobre su propio centro**, sin desplazarla por la mesa, porque el campo no es uniforme sobre la mesa. **Los cables del LSM9DS1 tienen que estar firmes**: en el primer intento se reinició al girarla.

1. Abrir el monitor: `~/robot_cortadora/scripts/pc/monitor_test_lsm9ds1.sh /dev/ttyACM0`. Dejar la placa quieta 3 s para la calibración del giro.
2. Apretar **BOOT** y dar **una vuelta completa** en 20 s. Tiene que salir `OK` con el campo horizontal (~20 µT esperado sin perturbaciones) y la relación de radios (cerca de 1,0).
3. Volver a la posición inicial y dejarla quieta → `REFERENCIA`.
4. **A — Giros:** +90 → 0 → −90 → 0 → +180 → 0 → +360. En cada posición, alinear contra la referencia y esperar la línea `PARADA`.
5. **B — Tiempo:** dejarla quieta 10 min. `dif` crece por la deriva del giróscopo; `dMag` tiene que quedar estable.
6. **C — Perturbación:** sin mover la placa, acercar un destornillador o un celular a ~10 cm y después a ~5 cm. `dMag` y `|B|` cambian; `dGiro` no.
7. Salir con `Ctrl+]`.

### Criterios

- **A:** los dos dentro de ±3° del ángulo de referencia (la alineación a mano aporta ~1–2°), y con el mismo signo.
- **B:** `dMag` estable dentro de ±2°.
- **C:** cuantifica cuánto error de rumbo produce un objeto metálico. Anticipa lo que hará la cortadora.

### Resultados

| Fecha | Calibración (campo horiz. / relación) | +90 | 0 | −90 | 0 | +180 | 0 | +360 | B: dMag en 10 min | C: dMag a 10 / 5 cm |
|---|---|---|---|---|---|---|---|---|---|---|
| 02/11/26 (v1.3, intento parcial) | Mín/máx: radios 29,4 / 25,0 y 28,6 / 23,9 µT (relación 1,18–1,20); centro +26,1 / −5,4 y +26,4 / −6,2 µT (repetible) | giro +90,1 / mag −104,7 (signo invertido; corregido: error 14,6°). Repetición: +94,7 / +105,2 (10,5°) | giro 0 / mag +0,5…+1,8 | — | ~+5: giro +4,8 / mag +5,5 (0,7°) | — | — | giro −358,6 / mag +372,3 (corregido: 13,7°) | — | — |

**Segundo intento (v1.5, log `firmware/esp32_motor/test_lsm9ds1/log.test_lsm9ds1.20261102143842.txt`):**
- **Calibración:**
  - Vuelta de +359,6°, 409 muestras.
  - Elipse: centro +34,1 / −6,8 µT, semiejes 16,1 / 11,9 µT (relación 1,35), eje mayor a +130°.
  - Campo horizontal de 13,8 µT, dispersión del 3,2 % (apenas por encima del 3 %).
- **Paradas (YAW GIRO / YAW MAG / diferencia):**

| Posición | YAW GIRO | YAW MAG | Diferencia | Bh (µT) |
|---|---|---|---|---|
| −90 | −90,2 | −55,8 | −34,5 | 19,3 |
| 0 | −0,5 | −0,1 | −0,4 | 14,7 |
| +90 | +89,1 | +105,4 | −16,4 | 21,6 |
| 0 | −0,4 | −0,7 | +0,3 | 15,8 |
| (nueva referencia con doble toque) +90 | +89,8 | +105,5 | −15,7 | 23,1 |
| −90 | −89,5 | −62,8 | −26,7 | 21,8 |
| 0 | +0,3 | −5,3 | +5,6 | 17,8 |

- **Lectura:**
  - **Giróscopo:** ±1° respecto de ±90 y regresos a 0 dentro de 0,5°.
  - **Brújula:** bien cerca de 0, con errores de 16 a 35° a ±90°. Es **repetible**, o sea sistemático, no ruido.
  - `Bh` cambia con la orientación (14–16 µT a 0°, 19–23 a ±90°) cuando debería ser constante → la elipse de la calibración no representa el campo que ve el sensor durante la prueba.
  - En el último 0, la brújula marca −3 a −6° con `Bh` de 17,5 µT (en la referencia, 16,3): la placa no volvió exactamente al mismo lugar.
  - El giróscopo derivó +0,3 → +1,1° en 26 s (~1,8 °/min, sin recalibrar desde el arranque).
- **Causas probables:**
  - Campo local alterado por material ferromagnético cerca del sensor: el horizontal medido bajó a 13,8 µT, contra ~26 µT en el primer intento; el terrestre es ~20 µT.
  - El sensor se desplaza al girar en un campo no uniforme.
  - Inclinaciones distintas entre la calibración y la prueba.

**Notas del primer intento (logs `firmware/esp32_motor/test_lsm9ds1/log.test_lsm9ds1.20261102140425.txt` y `…140904.txt`, generados con Ctrl+T Ctrl+L en el monitor):**
- **Signo:** en las 3 comparaciones válidas con la placa quieta, dMag tuvo el signo opuesto a dGiro → el supuesto x_AG = −mx era incorrecto. Corregido en la v1.4.
- **Error de la brújula** (con el signo corregido, en reposo): 0,7–1,8° cerca de la referencia, 7,3° a +16°, 10,5–14,6° a +90° y 13,7° en la vuelta completa. Depende de la orientación, lo típico de una elipse inclinada que la calibración mín/máx no corrige. También influye que la placa se desplazaba sobre la mesa al girarla.
- **\|B\| crudo** de 4,4 a 55 µT según la orientación: es el campo propio de la placa (~26 µT) sumado al terrestre. No es una perturbación externa.
- **Reinicio del LSM9DS1** a los 241 s (`CTRL_REG1_G = 0x00`: perdió la configuración) mientras se giraba la placa → falso contacto en VDD o GND. Hay que asegurar el cableado antes de seguir. En el robot, con vibración, sería crítico.
- **Bug de la v1.3:** después del reinicio de la prueba, la referencia del versus no se volvía a tomar (la `PARADA 1` de +67,6 / −21,8 no vale). También fallaron 3 calibraciones (vueltas de +6, −88 y +20°). Corregido en la v1.4: la referencia se vuelve a tomar siempre.

### Conclusión de las pruebas del LSM9DS1 (02/11/26)

- **Giróscopo: aceptable para el control de rumbo, con recalibración en cada parada.**
  - Ruido de ~0,05 dps RMS. Giros de ±90° con ±1° de error.
  - El bias se mueve, más en los primeros 5–15 min después del encendido y después oscila ±0,015 dps, en parte por la temperatura. Al integrarlo, el ángulo se corre aunque el sensor esté quieto: de 3 a 5 °/min respecto de una calibración de 30 min antes.
  - Recalibrando 3 s en cada parada: ~0,4° típico y ~1,3° en el peor 5 % después de 1 min de recta (simulado con datos reales en reposo).
- **Magnetómetro: descartado por ahora** (decisión del usuario, 02/11/26).
  - En el banco dio errores sistemáticos de 16–35° a ±90°, incluso con calibración por ajuste de elipse.
  - El campo local medido es anormal: 13,8 µT horizontales, contra ~20 µT del terrestre, y cambió entre sesiones.
  - Se podría reevaluar con el sensor sobre un soporte no metálico y alejado (o en un mástil sobre el robot), pero no se sigue por ahora.
- **Pendiente para la integración:** asegurar el cableado. El sensor se reinició dos veces por falsos contactos al moverlo.

---

## 3. Placa 3 (MPU-9250/6500/9255, respaldo) — `firmware/esp32_motor/test_mpu9250` (v1.0)

**Objetivo:** identificar el chip real (la marca "MP92 U601A1 2048" sugiere un MPU-9250, sin verificar) y medir la deriva de su giróscopo con la **misma metodología y el mismo formato de salida** que el LSM9DS1, para comparar.

**Estado:** ✅ probado en la N16R8 (02/11/26), con la placa 3 sola en el bus (LSM9DS1 desconectado). Captura de 30 min desde el encendido en frío (15:10–15:40). **Su giróscopo resultó ~3 veces mejor que el del LSM9DS1** (ver Resultados). ⬜ Falta el giro de 90° a mano (escala).

**Identificación (02/11/26, 15:09):**
- Responde en **0x68**. **WHO_AM_I = 0x75**: no es un valor de InvenSense para el 6500 (0x70), el 9250 (0x71) ni el 9255 (0x73). En foros se reporta 0x75 en "MPU-9250" que resultaron ser clones → **probable clon o chip remarcado**.
- **AK8963: no responde en 0x0C → sin magnetómetro (6 ejes)**, a pesar de la marca "MP92".
- Configuración OK (todos los registros releídos): para lo que se usa, se comporta como un MPU-6500.
- **Calibración en frío:**
  - Bias (+8,978, +1,692, +0,097) dps; ruido (0,045, 0,044, 0,044) dps RMS.
  - \|A\| = 0,989 g (ax = −0,131 g: la placa está inclinada ~7,5° o es un offset del acelerómetro).
  - Temperatura del chip: 32,1 °C.
- **Comparación inicial con el LSM9DS1:** ruido algo menor (0,044 contra 0,05–0,08 dps). Bias en z chico (0,1 dps), aunque el de x es grande (9 dps; se descuenta).
- **Magnetómetro:** se la considera **de 6 ejes, sin magnetómetro**. No se hace la verificación extra por el maestro I2C interno, porque la brújula está descartada (acordado con el usuario).

### Resultados (02/11/26, 15:10–15:40, desde el encendido en frío)

- **Captura:** 1796 líneas en 1800 s, 0 errores I2C, ningún movimiento ni reinicio. Calibración a ~1,5 min del encendido: bias (+8,989, +1,729, +0,095) dps; ruido (0,038, 0,041, 0,040) dps RMS. Temperatura del chip: 32,1 → 31,2 °C.
- **Deriva de 5 min en frío:** −2,222° → **−0,444 °/min** (LSM9DS1 en frío: +5,844 °/min).
- **Respecto de una sola calibración, durante 30 min:**
  - −21,7° en 29 min (−0,1 a −1,1° por minuto). LSM9DS1: +114° en 29 min.
  - Residual de gz: −0,004 → −0,017 dps, con un cambio lento y monótono. LSM9DS1: +0,04 a +0,085 dps, con oscilaciones.
- **Recalibración en cada parada** (`recalibrar.py`; mediana / p95 / máximo, en grados):

| IMU / corrida | T = 30 s | T = 60 s | T = 120 s |
|---|---|---|---|
| **Placa 3, de 1,5 a 31 min (frío)** | **0,07 / 0,21 / 0,31** | **0,14 / 0,40 / 0,69** | **0,29 / 0,86 / 1,42** |
| LSM9DS1, madrugada (horas encendido) | 0,17 / 0,53 / 0,69 | 0,40 / 1,06 / 1,28 | 0,74 / 2,45 / 2,84 |
| LSM9DS1, ~6 min | 0,21 / 0,56 / 0,78 | 0,36 / 1,05 / 1,36 | 0,95 / 2,23 / 3,02 |
| LSM9DS1, de 4 a 34 min | 0,18 / 0,56 / 1,13 | 0,42 / 1,27 / 2,75 | 0,97 / 3,20 / 6,53 |
| LSM9DS1, recién conectado | 0,24 / 0,73 / 1,49 | 0,54 / 2,48 / 3,55 | 1,61 / 6,41 / 9,31 |

- **Lectura:** con recalibración en cada parada, la placa 3 da **~2,5–3 veces menos error que el LSM9DS1**, aun arrancando en frío.
  - En una recta de 10 m (~1 min), el desvío lateral (≈ L·θ/2) sería ~1,2 cm típico, ~3,5 cm en el peor 5 % y ~6 cm como máximo. LSM9DS1: ~3,5 / ~9–11 / ~11–24 cm.
  - Prácticamente no hace falta esperar el calentamiento.
- **Limitaciones:**
  - Un solo ejemplar de cada IMU, medidos en horarios y condiciones distintos.
  - **La placa 3 es un clon** (WHO_AM_I 0x75): otro ejemplar podría comportarse distinto.
  - Medición en reposo.
  - Falta verificar la escala con un giro de 90°.

### Conclusión (02/11/26)

**Recomendación: usar la placa 3 en el ESP32_motores** y dejar el LSM9DS1 de respaldo.
- Conviene conseguir un repuesto de la placa 3 y validarlo con esta misma prueba antes de montarlo, porque es un clon.
- **Ventaja adicional:** usa los mismos registros que el MPU-6500 del ESP32 sensor.
- Pendiente de confirmación del usuario.

### Prueba de giro a mano (02/11/26, 15:51–15:53, v1.1; log `firmware/esp32_motor/test_mpu9250/log.test_mpu9250.20261102155129.txt`)

- Recalibración con 1 toque de BOOT: bias (+9,032, +1,695, **+0,012**) dps, ruido (0,044, 0,047, 0,041).
- **Paradas** (YAW GIRO): +90,7 / +1,6 / −86,9 / +1,7 / +358,0 / +2,8 / +92,4 / +3,2 / −84,7 / +3,6.
- **Giros**, restando el valor de la parada anterior (en grados):

| Giro | Medido | Giro | Medido |
|---|---|---|---|
| +90 | +90,5 | +90 | +89,4 |
| vuelta a 0 | −89,5 | vuelta a 0 | −89,3 |
| −90 | −88,4 | −90 | −87,9 |
| vuelta a 0 | +88,6 | vuelta a 0 | +88,2 |
| **+360** | **+356,1** | **−360** | **−355,3** |

- **Lectura:**
  - **Los giros de 90° dan 87,9–90,5**, coherentes con la alineación a mano (±1–2°).
  - **Las vueltas completas dan ~1,2 % de menos.** Hay dos causas posibles:
    - (a) **saturación**: en las vueltas, la media por segundo llegó a 98–120 dps, con picos instantáneos que podrían superar el rango de ±250 dps;
    - (b) error de escala real de ~1,2 %, dentro de la tolerancia de ±3 % de la hoja de datos.
  - El robot gira a ~36 dps (no satura). Se distingue repitiendo la vuelta despacio (~10 s). Si fuera la (b), se corrige con un factor en el firmware.
  - **Deriva después de la recalibración:** con la placa quieta, "giro actual" quedó en +0,02…+0,08 dps → el YAW subía ~0,05 °/s (los regresos a 0 pasaron de +1,4 a +3,6 en ~1 min).
    - **Causa:** el bias recalibrado (0,012) quedó ~0,07 dps por debajo del real (~0,09, como en la calibración inicial y en la captura de 30 min). Al apretar BOOT, que está en la misma protoboard, la placa siguió acomodándose lentamente durante la ventana de 3 s.
    - Ese movimiento lento no lo detecta el control de ruido (umbral de 0,5 dps).
  - **Lección para el firmware del motor:**
    - esperar a que el robot quede realmente quieto antes de recalibrar en cada parada;
    - rechazar la ventana si la media tiene tendencia (por ejemplo, comparando la primera y la segunda mitad) o si el bias nuevo difiere mucho del anterior.
- ⬜ **Opcional, para cerrar la escala:** una vuelta completa lenta (2 toques de BOOT para el 0, vuelta de ~10 s, PARADA ≈ 360).

### Conexión (ESP32-S3 N16R8 de prueba)

| Placa 3 | ESP32-S3 |
|---|---|
| VCC | **3V3** |
| GND | GND |
| SDA | GPIO 6 |
| SCL | GPIO 7 |
| AD0 | Sin conectar o a GND → dirección 0x68 |
| NCS | Sin conectar. Si el chip no responde, a 3V3 (en bajo queda en modo SPI) |

El LSM9DS1 puede quedar conectado en el mismo bus, porque no hay choque de direcciones (LSM: 0x6B/0x1E; MPU: 0x68 y AK8963 en 0x0C). **Cablear con el USB desconectado.**

### Qué hace

1. **Identificación:**
   - WHO_AM_I (0x75): 0x70 MPU-6500, 0x71 MPU-9250, 0x73 MPU-9255, 0x68 familia MPU-6050/9150; otro valor = posible clon.
   - Magnetómetro: con el bypass I2C activo, el AK8963 tiene que aparecer en 0x0C con WIA = 0x48. Si no aparece, el chip es de 6 ejes aunque la marca diga 9250.
2. **Configuración:** 125 Hz, filtro de 41 Hz, ±250 dps (131 LSB/dps), ±4 g. Se relee cada registro.
3. **Deriva:** igual que `test_lsm9ds1` v1.2: calibración de 3 s (rechazada si el ruido supera 0,5 dps), 300 s quieto, línea por segundo, resumen por minuto y alerta si el sensor se reinicia. Si no encuentra el MPU, corre el diagnóstico de cableado.

### Comandos

```bash
~/robot_cortadora/scripts/pc/build_test_mpu9250.sh esp32s3
~/robot_cortadora/scripts/pc/flash_test_mpu9250.sh /dev/ttyACM0
~/robot_cortadora/scripts/pc/monitor_test_mpu9250.sh /dev/ttyACM0
```

Para comparar con el LSM9DS1, la deriva se mide recién encendido y después con ≥ 10 min de encendido (el LSM dio 5,8 °/min en frío y 1,25 °/min a los ~6 min).

### Afinado del giróscopo de la placa 3 (02/11/26, tarde; el usuario autorizó trabajar solo)

**1. Desviación de Allan** (script `afinado.py` del scratchpad, sobre las medias por segundo de gz):

| | LSM9DS1 (de 4 a 34 min) | **Placa 3 (frío, de 1,5 a 31 min)** |
|---|---|---|
| σ(τ = 1 s) | 0,0080 dps | **0,0052 dps** |
| Piso de Allan | 0,0048 dps en τ = 20 s | **0,0013 dps en τ = 50–70 s** |
| Inestabilidad del bias (piso / 0,664) | 0,0072 dps (25,9 °/h) | **0,0019 dps (6,8 °/h)** |
| ARW (σ(1 s)·60) | 0,48 °/√h | **0,31 °/√h** |

La placa 3 es ~4 veces más estable y su bias "aguanta" promedios más largos.

**2. Duración de la recalibración en cada parada** (T_cal) contra el tiempo hasta la siguiente (T_recta). Placa 3 en frío; error de rumbo mediana / p95 / máximo, en grados:

| T_cal | T_recta = 30 s | **T_recta = 60 s** | T_recta = 120 s |
|---|---|---|---|
| 1 s | 0,11 / 0,32 / 0,57 | 0,22 / 0,64 / 1,14 | 0,43 / 1,30 / 2,35 |
| 2 s | 0,08 / 0,24 / 0,42 | 0,16 / 0,47 / 0,86 | 0,33 / 0,97 / 1,84 |
| 3 s | 0,07 / 0,21 / 0,31 | 0,14 / 0,40 / 0,69 | 0,29 / 0,86 / 1,42 |
| **5 s** | 0,06 / 0,17 / 0,26 | **0,13 / 0,34 / 0,59** | 0,26 / 0,71 / 1,22 |
| 10 s | 0,05 / 0,14 / 0,23 | 0,10 / 0,28 / 0,48 | 0,21 / 0,62 / 0,99 |
| 20 s | 0,04 / 0,12 / 0,23 | 0,08 / 0,24 / 0,42 | 0,18 / 0,54 / 0,83 |

- Con T_recta = 60 s, pasar de 3 a 5 s mejora el p95 un 15 %; a 10 s, un 30 %; a 20 s, un 40 %. Las ganancias decrecen, y el piso de Allan está en ~50 s.
- El error crece casi en proporción a T_recta → conviene recalibrar al menos cada ~60 s.
- **Recomendado: T_cal = 5 s** (equilibrio entre precisión y tiempo parado). 10 s si las paradas lo permiten.

**3. Temperatura:**
- Pendiente de gz contra la temperatura del chip: +0,0136 dps/°C (R² = 0,79, medias de 60 s; 32,1 → 31,2 °C).
- En 60 s la temperatura cambia ~0,03 °C → efecto ~0,013° por minuto, 10 veces menos que el error de la recalibración.
- **No hace falta compensar por temperatura.** LSM9DS1: −0,022 dps/°C, R² = 0,66, efecto 0,05°/min.

**4. Inclinación (hipótesis del 02/11/26):**
- El acelerómetro mostraba la placa inclinada: ax = −0,131 g → 7,7°; después de la prueba de giro, ax = −0,191 g → 11,3°.
- Si el eje Z no está vertical, gz ve solo cos(inclinación) del giro: con 7,7° es 99,1 % → 360° se mide como ~356,7°. **Coincide con los 356–358° medidos.**
- Que ax cambie con la posición indica una inclinación real, no un offset del acelerómetro (que sería constante).
- **Durante la captura en caliente, el usuario niveló la placa con un soporte: 11,3° → 2,5°** (segundos 43–50 de la captura, descartados del análisis).
- **Corrección propuesta:** integrar la proyección del giro sobre la vertical medida por el acelerómetro en cada calibración (`g·up`) en lugar de gz solo. Compensa la inclinación del montaje y del terreno. Un error de 3° en `up` deja solo 0,14 % de error (coseno).

**5. `test_mpu9250` v1.2** (compilado sin warnings, 0x3ec10 bytes; se flashea al terminar la captura en caliente):
- **YAW VERTICAL** (con la inclinación compensada) junto a **YAW Z**.
- En cada PARADA: inclinación del eje de giro **medida con el giróscopo** (dirección del giro integrado desde la parada anterior) contra la del **acelerómetro**. Si coinciden, la inclinación es real.
- **Recalibración de parada robusta** (1 toque de BOOT):
  - espera a quedar quieto (< 1 dps en los 3 ejes durante 1 s, máximo 10 s);
  - ventana de **5 s**;
  - rechaza la ventana si la media de gz cambia > 0,015 dps entre mitades (movimiento lento) o si el bias z salta > 0,03 dps respecto del anterior (al segundo rechazo seguido por salto, lo acepta);
  - si falla, conserva el bias anterior.

**6. Captura en caliente** (16:01–16:31, placa encendida desde las 15:08; 1796 líneas, 0 errores I2C):
- **Respecto de la calibración del arranque (hecha con 11,3° de inclinación):** −8,9 °/min. **No es deriva.** Cuando el usuario puso el soporte (segundo 43; inclinación → 2,5°), **el bias cambió de golpe** y quedó estable 29 min:
  - Δ giro = (+0,041, +0,021, **−0,175**) dps para Δ acel = (+0,167, +0,003, +0,017) g.
  - Si es sensibilidad a la orientación: **dgz/dax ≈ −1,05 dps/g**, unas 10 veces lo que especifica el MPU-9250 original (~0,1 dps/g). Plausible en un clon.
  - **Sin confirmar:** también puede ser tensión mecánica del soporte.
  - Coherente con la calibración de la v1.2 (16:35, nivelada): bias z −0,048 dps contra +0,075 dps a 11,3°.
- **Estabilidad después del soporte** (minutos 1–30): Allan σ(1 s) = 0,0052, piso 0,0018 dps a 15 s (sube a 0,007 a 200 s); inestabilidad ~0,0027 dps. Temperatura estable (31,7–31,8 °C).
- **Recalibración** (T_cal = 5 s): 60 s → **0,15 / 0,46 / 0,77°**; 120 s → 0,34 / 1,46 / 2,06° (en frío: 0,13 / 0,34 y 0,26 / 0,71).
- **Implicancia para el robot:** en terreno con pendiente, la orientación respecto de la gravedad cambia entre paradas. Con ~1 dps/g, una inclinación de 5° (0,09 g) movería el bias ~0,09 dps → ~5° de error por minuto **si no se recalibra o compensa**. La recalibración en cada parada lo absorbe si la pendiente no cambia durante la recta.
  - **Si el efecto es reproducible**, se compensa con el acelerómetro: bias = b_cal + K·(a − a_cal).
  - ⬜ **Prueba de inclinación pendiente** para confirmarlo y medir K.

**7. `test_mpu9250` v1.2: flasheado (16:35)**, con lo del punto 5 más:
- **Métrica de huecos** en cada resumen por minuto (hueco máximo entre muestras y cantidad > 20 ms).
- Una línea `CAL_OK bias_x … acel_z … incl` en cada calibración aceptada (para el análisis de bias contra gravedad).
- El control de salto de bias **no se aplica si la gravedad medida cambió > 0,03 g** (≈ 1,7°), porque ahí el bias cambia de verdad.

**8. Control a las 19:10 (2 h 35 min después de flashear, misma posición):** lectura de 15 s; al abrir el puerto se reseteó el ESP y recalibró.
- **Misma orientación** (acel con diferencias ≤ 0,006 g, 2,3° contra 2,5°), pero el **bias z pasó de −0,048 a −0,140 dps** (Δ −0,092; x +0,13, y +0,09). Temperatura 31,8 → 30,6 °C. Con la pendiente del punto 3 (0,0136 dps/°C) la temperatura explica solo ~0,016. **El bias deambula a escala de horas** aunque la placa no se mueva. Refuerza recalibrar en cada parada; no cambia el diagnóstico del salto de 16:01, que fue instantáneo.
- **A los 4 s de calibrar, salto de +0,05 dps en z** (también −0,04 en x), sin cambio del acelerómetro, y quedó así (yaw +0,36° a los 11 s). En el arranque de las 16:35 no pasó. ⬜ Averiguar si alguien tocó la mesa; si no, es un salto espontáneo del bias y el motor v4 tendría que detectarlo (comparar con el bias de la parada siguiente).

### Pruebas pendientes con el usuario (v1.2)

Activar el log con Ctrl+T Ctrl+L al abrir el monitor.

**A. Giro con compensación de inclinación (~2 min):**
- 1 toque de BOOT (recalibración) y después +90 → 0 → −90 → 0 → vuelta completa **lenta**.
- En cada PARADA comparar **YAW VERTICAL** contra **YAW Z**, y la **inclinación del eje según el giróscopo** contra la **del acelerómetro**.
- Con la placa nivelada (2,5°), los dos YAW deberían dar casi igual (diferencia 0,1 %).
- Para ver el efecto: repetir la vuelta con la placa **inclinada a propósito ~10°** (algo debajo de un borde). YAW Z debería dar ~354,5° y YAW VERTICAL ~360°. Las dos inclinaciones deberían coincidir.

**B. Sensibilidad a la orientación (~3 min):** en cada posición, apoyar la placa, soltarla, dar **1 toque de BOOT** y esperar `CAL_OK`:
1. plana;
2. inclinada ~10° hacia adelante (algo debajo del borde de atrás);
3. inclinada ~10° hacia atrás;
4. inclinada ~10° a la izquierda;
5. inclinada ~10° a la derecha;
6. **plana otra vez**, para ver la repetibilidad.

**Análisis:** regresión de bias_z contra (acel_x, acel_y).
- Si el bias vuelve al mismo valor en las dos posiciones planas y el ajuste es lineal → sensibilidad a la orientación reproducible → se compensa en el firmware del motor.
- Si no → efecto mecánico o histéresis → recalibrar en cada parada sin cambiar la inclinación.

### Parámetros recomendados para el IMU del firmware del motor v4 (borrador, 02/11/26)

| Parámetro | Valor | Base |
|---|---|---|
| Escala / filtro / muestreo | ±250 dps, DLPF 41 Hz, 125 Hz | Ruido y resolución; el robot gira a ~36 °/s |
| Yaw | Integrar `g·up` (vertical del acelerómetro en cada calibración), no solo gz | Compensa la inclinación del montaje y del terreno (punto 4) |
| Recalibración | En **cada parada**: esperar quieto ≥ 1 s, ventana de **5 s** (10 s si se puede) | Barrido del punto 2 |
| Rechazo de ventana | Tendencia > 0,015 dps entre mitades; salto > 0,03 dps sin cambio de inclinación | Prueba de giro del 02/11/26 (recalibración arruinada por el toque) |
| Tiempo máximo entre recalibraciones | ~60 s | El error crece con T_recta |
| Huecos de lectura | Vigilar dt; marcar o descartar huecos > 20 ms | Proyecto sumo del usuario; métrica de la v1.2 |
| Inercia al frenar | Integrar hasta quedar quieto, no solo hasta cortar los motores | Proyecto sumo del usuario |
| Temperatura | No compensar | Punto 3 |
| Sensibilidad a la orientación | Pendiente de la prueba B: compensar si es reproducible | Punto 6 |

> **Aplicado en el firmware del motor v4.0 (02/11/26):** todos los parámetros de esta tabla, salvo la sensibilidad a la orientación (pruebas A y B todavía pendientes). Ver §4.

---

## 4. Firmware del motor v4.0 en banco — `firmware/esp32_motor/active` (target `esp32s3`)

Prueba del protocolo v4 completo (micro-ROS + IMU) en la ESP32-S3 N16R8 de prueba, con la placa 3 en el I2C 6/7 y **sin motores**: los "motores" son los valores `pwm_izq`/`pwm_der` del status, y el robot se simula girando la placa a mano. Protocolo en `docs/arquitectura.md`.

### Conexión

- **El cable USB va al conector COM** (puente CH343 → UART0, donde está micro-ROS). El conector USB nativo (`303a:1001`, USB-Serial-JTAG) no sirve: el agente no ve nada. Comprobar con `lsusb | grep -i -E "1a86|303a"`: tiene que aparecer `1a86` (QinHeng).
- Placa 3: VCC 3V3, GND, SDA 6, SCL 7 (igual que con `test_mpu9250`).

### Comandos

```bash
# Compilar y flashear (el puerto del COM puede ser /dev/ttyACM0 o /dev/ttyUSB0)
~/robot_cortadora/scripts/pc/build_motor.sh esp32s3
~/robot_cortadora/scripts/pc/flash_motor.sh /dev/ttyACM0
# Terminal 1: agente
~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyACM0 -v4
# Terminal 2: status
source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /motion_status --field data
```

Si el agente no muestra `create_client` en unos segundos, apretar el botón **RST** de la placa con el agente corriendo.

### Secuencia y qué mirar

| # | Comando (`motion_cmd`) | Esperado |
|---|---|---|
| 1 | — (placa quieta al encender) | Heartbeat `[0, 0, 0, 0, 0, rumbo, 0, imu, -1]`: `imu_estado` 1 → 2/3 a los ~6 s; `seg_desde_cal` pasa de −1 a 0 y vuelve a 0 cada ~5 s mientras sigue quieta; `rumbo` quieto en ~0 |
| 2 | `[1, 7, 0, 0, 0]` FIJAR_RUMBO 0 | `DONE` con feedback 0 |
| 3 | `[2, 1, 15, 0, 0]` ADELANTE 15 cm/s | `pwm` sube con la rampa hasta ~62 en las dos ruedas. Girar la placa ~10° a la izquierda: `rumbo` +100, feedback −100, `pwm_izq` > `pwm_der` (corrige hacia la derecha). Volverla: se iguala |
| 4 | `[3, 0, 0, 0, 0]` STOP | PWM 0 enseguida, `DONE` a los 0,5 s |
| 5 | `[4, 3, 90, 0, 0]` GIRO_IZQ 90 | `rumbo_obj` +900; `pwm_izq` negativo y `pwm_der` positivo. **Sin girar la placa**, el PI va subiendo el PWM (empuje) (adelanto ~64 + empuje hasta +80) y a los ~8 s (3 s + 90° a 18 °/s) da `ERROR` 3 (giro trabado). Repetir girando la placa a mano a la izquierda: el PWM baja al acercarse a 90°, corta en ~89° y da `DONE` con los grados girados (~900) |
| 6 | `[5, 6, 5, 0, 0]` CALIBRAR 5 s | `imu_estado` 3, `DONE` a los ~6 s con el bias z en mdps (≈ −50 a −140 con esta placa). Moverla durante la ventana: tarda más o da `ERROR` 4/5/6 |
| 7 | `[6, 5, 0, 0, 0]` PIVOT | Accesorios ON forzados; PWM adelante ~2 s (30 cm estimados, con rampa a 23,6 cm/s), después atrás ~2 s, después solo `pwm_der` positivo (swing). Girar la placa 90° a la izquierda a mano: `DONE` |
| 8 | `[7, 9, 0, 0, 0]` modo inválido | `ERROR` 1 y tracción en 0 |

### Resultados

⬜ Pendiente (02/11/26: la primera carga no conectó porque el cable estaba en el conector USB nativo).

## Verificación USB del sensor S3 — 13/11/26

- Host: PC Linux, ROS 2 Jazzy, agente local del proyecto. Sensor por USB nativo (`303a:1001`, serie `7C:E8:B1:A2:8E:24`).
- Controlador USB con interrupciones: no completaba la comunicación; el diagnóstico temporal confirmó inicio de tareas y llegada a la inicialización micro-ROS.
- Transporte corregido: FIFO USB exclusivo, timeout TX de 1 s, lectura con timeout y esperas de al menos un tick. `CONFIG_FREERTOS_HZ=1000`. Sin consola USB ni marcas temporales.
- Resultado: creación de sesión/participante/topic/publicador; `ros2 topic echo /sensores std_msgs/msg/Float32MultiArray --once` recibió 24 valores. `ros2 topic hz /sensores --window 100` midió unos 18,5 Hz durante 15 s, intervalos 53–55 ms. La espera de publicación de 50 ms se suma al tiempo de envío.
- Se verificó la comunicación; los valores de IMU/GPS/ultrasonidos no constituyen validación de esos sensores físicos. No se enviaron comandos al motor.
- Pendiente: repetir con el mismo firmware en la Raspberry Pi y comprobar lecturas físicas. Los parches y el puente antiguos de la Pi no son necesarios en la prueba local; su necesidad en la Pi aún no se determinó.

- **Repetición en Raspberry Pi 4 / Lyrical:** exitosa con el firmware corregido y agente directo, sin puente. Recepción de 24 valores; frecuencia 18,52 Hz aproximadamente durante 15 s, intervalos 53–55 ms. El agente de la Pi conserva los parches de la sesión anterior; su necesidad no se determinó. Pendiente: validar los sensores físicos.

- Al pasar el agente a segundo plano, el sensor no recuperó automáticamente la sesión. Reinicio por RTS del sensor y mensaje de 24 campos confirmado con el agente definitivo (PID 30840). Pendiente implementar reconexión en firmware; por ahora reiniciar el sensor después de reiniciar el agente.

## Diagnóstico de adquisición sin micro-ROS

Estado: preparado y compilado; pendiente de carga y prueba física. Esta prueba reemplaza temporalmente el firmware micro-ROS del sensor, sin cambiar el motor.

Desde la PC, con el sensor en el conector USB nativo:

```bash
~/robot_cortadora/scripts/pc/build_sensor_diagnostics.sh
~/robot_cortadora/scripts/pc/flash_sensor_diagnostics.sh /dev/ttyACM0
```

Para leerlo en la Raspberry, cerrar primero únicamente el agente del sensor que ocupa ese puerto. Luego, sin iniciar ROS ni el Brain:

```bash
python3 -m serial.tools.miniterm /dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_7C:E8:B1:A2:8E:24-if00 115200 --raw --dtr 0 --rts 0
```

Salir con Ctrl+]. Mantener la placa quieta al arrancar durante la calibración (aproximadamente 3 s con IMU presente).

| Prueba | Acción | Evidencia esperada |
|---|---|---|
| Bumpers | Presionar y mantener 1 s cada uno, individualmente | Solo I, C o D cambia de 0 a 1 y vuelve a 0 al soltar |
| Ultrasonidos | Objeto plano frente a cada uno, a 20/50/100 cm medidos | Distancia positiva coherente con la referencia; registrar error y dispersión |
| IMU presente | Placa quieta | init OK; WHO en 0x69; contador de lecturas aumenta, errores no; aceleración total cerca de 1 g |
| IMU movimiento | Inclinar alrededor de cada eje y girar sobre la mesa | A/G cambian según el eje, roll/pitch responden; yaw cambia al girar (relativo, con deriva) |
| GPS UART | Observar sin mover el cable | Bytes y líneas aumentan; checksum incorrecto no aumenta en condiciones normales |
| GPS posición | Al aire libre con cielo visible | GGA reciente, fix positivo, satélites/HDOP y coordenadas coherentes |

Ultrasonidos: -1 = no llegó subida ECHO; -2 = ECHO no bajó en 30 ms; -3 = distancia fuera de 2–400 cm; -4 = ECHO estaba alto antes del disparo. No equivalen a una distancia real.

IMU: WHO se muestra en decimal; -1 significa que esa dirección no respondió. `NaN`, errores que aumentan o edad creciente no validan la lectura. La calibración requiere al menos 270 lecturas exitosas sobre 300; el conteo no acredita que la placa haya estado quieta. La dirección de trabajo sigue siendo 0x69; la consulta a 0x68 sirve para detectar un AD0 distinto.

GPS: bytes sin GGA válido separan un problema de recepción/parseo de la falta de posición. Un GGA reciente con fix=0 significa recepción sin solución. Edad -1 significa que nunca hubo ese dato. Los campos APP son valores por defecto porque BLE no está implementado; el 4.º bumper no se lee todavía.

Para restaurar micro-ROS, usar los scripts normales de build y flash del sensor (build separado); cerrar antes el monitor USB. Las modificaciones recientes de adquisición también requieren cargar nuevamente el firmware normal para estar presentes en él.

- **Carga y primera captura del diagnóstico (13/11/26):** sensor S3 en la PC por USB nativo; flasheo con hashes verificados. Durante 7 s: bumpers 0/0/0 sin accionamiento, ultras -4/-4/-4 (ECHO alto antes de TRIG), IMU sin respuesta en 0x68 ni 0x69 (0 lecturas exitosas, sin calibración), GPS 1 byte y ninguna línea NMEA. Pendiente confirmar alimentación/cableado y ejecutar pruebas físicas; no se validó ningún sensor todavía.

- **Diagnóstico enfocado en bumpers:** se compiló y cargó una versión que inicia solo las tareas de bumpers y salida USB (sin iniciar IMU/GPS/ultras/micro-ROS). Muestra IZQUIERDO GPIO38, CENTRAL GPIO2 y DERECHO GPIO37; GPIO=0 presionado, GPIO=1 libre; cambios y contadores sin antirrebote. Resumen cada 2 s. Compilación sin warnings y hashes de carga verificados. Pendiente accionar y verificar cada contacto individualmente.

- **Prueba de polaridad central:** según el usuario, incluye un circuito y aparece presionado sin accionarlo. Se cambia solamente el central (GPIO2) a activo HIGH, manteniendo pull-up e izquierdos/derechos activos LOW. Diagnóstico actualizado para mostrar el nivel correspondiente. Es una hipótesis pendiente de presionar/soltar físicamente; módulo y alimentación todavía sin identificar.

- **Resultado de prueba central activo HIGH:** el usuario reporta que al presionar marca LIBRE. Se rechaza la inversión y se restaura el código y diagnóstico a activo LOW para los tres bumpers. Compilado; flasheo pendiente de liberar el monitor serial. Falta confirmar ciclo completo en reposo/presionado/soltado.

- Monitor cerrado por el usuario; diagnóstico con los tres bumpers activos LOW cargado correctamente, hashes verificados. Pendiente confirmar central en reposo/presionado/soltado.

- Nueva observación explícita del usuario con firmware activo LOW: central en reposo marca PRESIONADO y al accionarlo marca LIBRE. Se configura nuevamente solo el central como activo HIGH y se carga con hashes verificados; cabecera serial actualizada. La interpretación anterior como activo LOW queda descartada para este circuito según este reporte. Pendiente ciclo de confirmación con esta carga.

- El usuario confirma central correcto con activo HIGH y derecho correcto con activo LOW; junto con izquierdo, los tres bumpers quedan validados por accionamiento. Se prepara diagnóstico exclusivo del ultrasonido izquierdo TRIG18/ECHO16, medición cada 250 ms, distancia o error con niveles ECHO. Pendiente liberar monitor serial y cargar.

- Ultrasonido izquierdo: diagnóstico exclusivo cargado con hashes verificados al liberar el monitor. Captura inicial de 3 s con lecturas 46,9–69,6 cm y sin códigos de error. Pendiente referencia física a 20/50/100 cm; estas lecturas solo confirman recepción de pulsos, no precisión.

- El usuario acepta la prueba del ultrasonido izquierdo y solicita seguir. Se carga diagnóstico exclusivo del central TRIG8/ECHO9, hashes verificados. Captura de 3 s con 56,9 cm inicial y luego aproximadamente 75 cm sin errores; pendiente verificar referencia física. El usuario no proporcionó valores de referencia del izquierdo.

- Usuario acepta ultrasonido central y solicita derecho para cerrar la prueba. Diagnóstico derecho TRIG17/ECHO15 cargado, hashes verificados. Captura inicial: 11 lecturas de 63,9 cm en 3 s sin errores. Pendiente prueba del usuario; no se recibió referencia de distancia medida.

- **IMU aislado:** usuario confirma los tres ultrasónicos. Diagnóstico solo IMU en GPIO6/7: primera captura detectó WHO=112 en 0x68 y nada en 0x69, por lo que se corrige la dirección del firmware a 0x68. Nueva carga con hashes verificados y captura de 15 s: init OK, 300/300 muestras de calibración, 930 lecturas correctas y 0 errores al final. Bias (4,7323; -4,1215; -0,5998) dps; giro corregido cerca de cero, roll≈4,18° / pitch≈-3,06° y yaw estable. Aceleración total alrededor de 0,93 g; pendiente verificar escala/offset y prueba física de inclinación y giro. Captura en /tmp/cortadora-imu-verified.txt (temporal).

- El usuario confirma respuesta física correcta del IMU. Se carga diagnóstico exclusivo GPS RX35/TX36, 9600 baud, hashes verificados. Captura de 10 s: 1 byte inicial, 0 líneas NMEA y ningún GGA; no hay recepción UART continua. GPS pendiente de validación y revisión física de alimentación/cableado.

- Usuario confirma módulo N16R8. GPIO35/36/37 reservados a memoria interna según documentación Espressif. Se cambia fuente y diagnóstico GPS a RX4/TX5; pendiente recablear y cargar. Bumper derecho GPIO37 también requiere reasignación; no se modifica todavía su pin.

- Usuario confirma recableado GPS RX4/TX5. Diagnóstico cargado con hashes verificados; captura de 10 s sigue con solo 1 byte inicial y 0 líneas NMEA. El cambio elimina el uso de pines reservados, pero no resuelve por sí solo la falta de recepción GPS. Pendiente identificar alimentación/modelo y señal TX antes de dar el GPS por validado.

- 14/11/26: captura completa de 33 s del barrido existente 9600/4800/38400/57600/115200/19200. Solo 00 inicial a 9600; después 0 bytes y 0 líneas en todas las ventanas de 5 s. No se cambió alimentación ni se enviaron comandos. Esto no identifica una avería: falta comprobar tensión real en el módulo y señal TX/entrada RX, o hacer loopback UART.

- **Loopback físico 14/11/26:** usuario mide 3,1 V en alimentación GPS y conecta jumper GPIO5–GPIO4 con TX/RX GPS desconectados. Se carga diagnóstico UART2 sin tarea GPS. Resultado en 8 s: 8 mensajes únicos, 43 bytes cada uno, TX/RX idénticos y 0 fallos a 9600 baud. Verifica UART/pines del ESP, no estado ni alimentación nominal del GPS. Captura temporal /tmp/cortadora-loopback-result.txt. Firmware activo es loopback; restaurar recepción pasiva antes de reconectar RX GPS.

- **GPS recupera comunicación tras alimentar VDD_B:** referencia del usuario https://cdn.sparkfun.com/datasheets/Sensors/GPS/UP501.pdf, sección 4.2. Usuario indica sin batería visible y mide ≈3,18 V en VDD y VDD_B contra GND. Con TX GPS→GPIO4, RX GPS desconectado y sin jumper, se carga recepción pasiva fija 9600 baud. Captura de 12 s: último resumen 1523 bytes y 43 líneas, GGA válidos con fix=0/sats=0, checksum_mal=1 inicial sin nuevos incrementos. Comunicación UART validada; posición geográfica todavía pendiente de prueba con cielo visible. Captura temporal /tmp/cortadora-gps-vddb-capture.txt.

- 14/11/26, verificación antes de protoboard: RX GPS conectado por usuario a GPIO5, TX GPS a GPIO4, VDD y VDD_B alimentados. Captura pasiva de 12 s: 2864 bytes, 64 líneas, GGA frescos; 1 checksum inicial que no aumenta, sin pérdida de tráfico. No se enviaron consultas, por lo que no se valida respuesta del GPS por RX. Posición pendiente (fix=0/sats=0). Captura /tmp/cortadora-gps-rx-connected.txt (temporal).

- 14/11/26: tras pasar GPS al protoboard de sensores, captura de 12 s con el mismo firmware pasivo arroja únicamente 00 inicial (1 byte, 0 líneas NMEA), frente a recepción correcta previa. Pendiente verificar alimentación principal/backup, masa común y continuidad de TX hacia GPIO4 en el montaje nuevo. Captura /tmp/cortadora-gps-protoboard.txt (temporal).

- 14/11/26: usuario detecta que omitió conectar VDD_B al trasladar GPS al protoboard. Tras conectarlo, sin cambios de firmware, captura de 10 s recibe 1297 bytes y 36 líneas; GGA frescos con fix=0/sats=0, checksum_mal=1 inicial sin nuevos errores. Recepción UART del GPS en protoboard validada; posición al aire libre pendiente. Captura temporal /tmp/cortadora-gps-protoboard-vddb.txt.

- 14/11/26: usuario traslada bumper derecho de GPIO37 a GPIO39. Se actualiza PIN_B_R y se carga diagnóstico solo bumpers con hashes verificados; se conserva central activo HIGH y laterales activos LOW. Captura inicial derecho GPIO39=1 LIBRE; pendiente prueba física de presionar/soltar. GPIO39 deja de estar reservado para un cuarto bumper.

- **14/11/26 integración micro-ROS en PC:** se compila y carga firmware normal con SENSOR_DIAGNOSTICS=OFF, GPIO39 derecho, central activo HIGH, IMU0x68, GPS RX4/TX5; hashes verificados. Agente local establece sesión y crea `/sensores`. Captura de 18 s: 334 mensajes, 18,5096 Hz, intervalos 52,74–55,00 ms, 24 campos; sin errores de formato/bumpers/IMU/coherencia fix. Últimos ultras -1/-1/-1 (pendiente revisar alimentación/recepción de eco), IMU R/P/Y≈3,24/-1,50/-0,11°, GPS fix=0/sats=0, APP por defecto. No se ejecutó Brain ni comandos de motor. Agente queda activo en la sesión de prueba; pendiente Raspberry. Resultado temporal /tmp/cortadora-telemetry-result.json.

- Usuario confirma línea 5 V de ultrasonidos apagada y la enciende. Nueva captura de 18 s con todos los sensores: 333 mensajes / 18,5188 Hz, intervalos 53,36–54,59 ms; 0 errores de longitud/bumpers/IMU/coherencia GPS. Últimas distancias I/C/D 45,65/67,95/65,67 cm; IMU finito, GPS fix=0/sats=0, APP por defecto. Todos los grupos presentes en `/sensores`; pendiente posición GPS, acelerómetro y réplica en Raspberry. Resultado /tmp/cortadora-telemetry-powered-result.json.

- **14/11/26 réplica micro-ROS en Raspberry:** SSH operativo, mismo sensor detectado como ttyACM0. Agente iniciado con nohup (PID10321, log /tmp/cortadora-sensor-agent.log); sesión y publicador creados. Captura 18 s: 334 mensajes de 24 campos, 18,5167 Hz, intervalos52,29–56,59 ms, 0 errores de longitud/bumpers/IMU/coherencia GPS. Últimos ultrasonidos -1/-1/-1; se consulta alimentación5V y masa común. GPS comunica sinfix; Brain no iniciado. Agente queda activo sin inicio automático al reiniciar.

- 14/11/26, Raspberry: usuario enciende línea de 5 V que había apagado. Captura final de 18 s: 334 mensajes, 18,5204 Hz, intervalos 53,12–54,91 ms, 24 campos y 0 errores de las comprobaciones. Distancias I/C/D 54,74/68,58/57,71 cm; IMU finito y bumpers 0/0/0, GPS fix=0/sats=0. Telemetría conjunta validada en Pi; quedan posición GPS al aire libre/calibración de acelerómetro, no se ejecuta Brain. Agente sigue activo.

- **14/11/26, inicio ESP32 motores:** usuario reporta arranque izquierdo al alimentar driver con ESP por USB. Desconecta potencia. CP2102 ttyUSB0, ESP32-D0WDQ6 rev1.1; lectura de cabecera flash con ROM (primera lectura con stub falló digest, repetida sin stub OK) identifica compilación20/04/2026 22:24:30. Se prepara y carga diagnóstico separado MOTOR_DIAGNOSTICS, sin micro-ROS ni PWM; salidas32/33/25/26/18 LOW desde app_main. IMU en SDA27/SCL14 detectado0x68/WHO0x75,19 lecturas/0errores en5s, módulo acel≈0,976g, giro crudo≈9/1,6/0dps. Sin calibración; prueba de movimiento y causa del arranque pendientes. No se energizó potencia ni se enviaron comandos de movimiento. Build sin warnings, flasheo hashes verificados.

- **14/11/26 pulso manual izquierdo:** usuario confirma que con diagnóstico previo y driver energizado no gira; luego apaga potencia y levanta ruedas. Se compila/carga MOTOR_PULSE_TEST por scripts separados, sin warnings y con hashes verificados. Arranque PWM0, derecha/cortadora LOW; `i`+Enter da PWM40/255 en GPIO32 con GPIO33LOW, corte por esp_timer300ms y parada `s`. Captura serial inicial PARADO/PWM0; asistente no envió comandos de movimiento. Pendiente que usuario energice tras comprobar PARADO y ejecute un pulso.

- Usuario solicita aumentar solo prueba izquierda a PWM100/255 y duración1s. Cambio compilado sin warnings; corte automático/stop `s` permanecen. NO se cargó: usuario responde «Todavía no» a potencia apagada/ruedas levantadas. Antes no se confirmó línea PULSO en terminal; falta verificar recepción serial antes de atribuir ausencia de movimiento a potencia.

- Usuario confirma potencia desconectada y ruedas levantadas. Se carga prueba izquierda PWM100/255 durante1s; hashes verificados y arranque PARADO/PWM0 confirmado por lectura serial. No se envió movimiento; pendiente prueba manual y observación física.

- Se solicita prueba simultánea. Usuario confirma potencia apagada y ruedas levantadas. Se compila sin warnings extensión `b`+Enter para ambos motores (PWM100/255,1s; GPIO32/26 PWM y GPIO33/25 LOW), corte de ambos por temporizador y `s`; `i` conserva izquierda. Carga pendiente de cerrar monitor serial; no se ejecutó movimiento desde el asistente.

- Monitor cerrado por usuario; prueba simultánea cargada con hashes verificados. Arranque PWM0 en ambos canales confirmado, sin órdenes de movimiento. Pendiente `b`+Enter por usuario y observación de ambas ruedas/parada.

- **Fallo de programación confirmado y corregido:** con potencia apagada/ruedas levantadas/monitor cerrado por usuario, se envía `s` y `b`. `b` era recibido, pero la prueba abortaba por «Fade service not installed» en ledc_set_duty_and_update. Se agrega ledc_fade_func_install, respaldo ledc_stop si falla parada y lectura de duty tras3ms para esperar latch del siguiente periodo. Carga con hashes verificados. Test hardware sin potencia: dos PWM100/100 aplicados, parada0/0 a1005ms automática y203ms por `s`, sin abort/reinicio. Captura /tmp/cortadora-pwm-fixed-test.txt y verificador /tmp/cortadora-test-pwm.py. Movimiento físico pendiente; no atribuir falta de movimiento previa a driver/PWM bajo.

- **15/11/26:** usuario confirma movimiento izquierdo adelante y derecho atrás. Se corrige avance derecho a GPIO25 PWM/GPIO26 LOW en prueba y firmware normal; marcha atrás queda GPIO26 PWM/GPIO25 LOW. Con potencia apagada y ruedas levantadas confirmadas, se compila/carga diagnóstico con hashes verificados. Pulso se mantiene100/255 durante1s; parada automática y `s` conservadas. Pendiente confirmar movimiento físico ambos adelante.

- **15/11/26 validación física:** usuario confirma «ambos están hacia adelante» tras corregir la derecha a GPIO25 PWM/GPIO26 LOW. Avance de ambas ruedas validado en prueba manual PWM100/255,1s; retroceso y giros aún pendientes. Corrección replicada en fuente normal, pero firmware cargado permanece prueba manual.

- **15/11/26 retroceso:** main ya implementa modos adelante/atrás; diagnóstico manual agrega `r`+Enter, usando GPIO33/26 para retroceso (32/25LOW), y conserva `b` avance. Todos LOW3ms antes de aplicar dirección. PWM100/255,1s, corte cuatro canales y `s`. Compilación sin warnings, carga hashes verificados. Con potencia apagada confirmada, test por serial verifica retroceso, avance y stop anticipado: PWM100/100 y parada0/0 a1005/1005/200ms, sin abort/reinicio. Prueba física de retroceso pendiente. Captura temporal /tmp/cortadora-reverse-results.txt.

- **15/11/26 prueba completa de sentidos:** se agregan `l` giro izq y `d` giro der; permanecen `b` adelante/`r` atrás/`i` izquierda/`s`stop. PWM100,1s. Con potencia apagada y ruedas levantadas confirmadas se carga y prueba por serial: cinco patronesGPIO32/25/33/26 exactos; todos cortan0/0 en1005ms; `s`en200ms; sin abort/reinicio. Movimiento físico de giros/retroceso pendiente. Son pulsos de sentido, no giros con ángulo ni PIVOT/accesorios. Captura temporal /tmp/cortadora-turns-results.txt.
