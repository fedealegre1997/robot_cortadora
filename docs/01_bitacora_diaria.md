# Bitácora Diaria

Este documento condensa el progreso general del proyecto a alto nivel día a día. Refleja objetivos concretos logrados, decisiones arquitectónicas o de diseño clave y cambios estructurales importantes.
**REGLA ESTRICTA:** NUNCA modificar ni borrar entradas pasadas. Este documento actúa como un diario de desarrollo. Las nuevas entradas deben añadirse siempre al final.

---

## [18 de Mayo de 2026]
- **Hito Principal:** Se logró integrar por completo el control del motor de la bordeadora (HANPOSE 775) con la placa Sabertooth 2x25 v2 desde el ESP32 maestro de motores y ROS 2.
- **Decisiones Arquitectónicas y Hallazgos Físicos:**
  - Se eligió el **Modo Serial Simplificado** del driver Sabertooth (vía el pin UART TX2 del ESP32). Esto aísla por completo el ruido PWM o análogo del motor y utiliza una señal digital pura y robusta que es vital para la seguridad.
  - Se desacopló conceptualmente la máquina de estados del motor de tracción (ruedas) respecto a la herramienta (cuchilla de corte). Ahora la bordeadora posee "memoria de estado" y funciona independientemente de si las ruedas paran o cambian de dirección temporalmente.
  - **Descubrimiento y Solución del Cogging Magnético (Par de Retención):** Durante las pruebas físicas de arranque con rampa suave (Soft-Start), se observó un comportamiento anómalo donde el motor 775 giraba en reversa unos ~200ms antes de avanzar. 
    * *La Física del Fenómeno:* Un motor con escobillas de alta potencia como el HANPOSE 775 posee imanes permanentes muy fuertes y un rotor con ranuras de hierro (armadura dentada). Cuando el ESP32 iniciaba la rampa desde 0 (byte 64) aplicando pasos muy bajos de PWM (ej. byte 66 que equivale a ~3% de potencia), el campo electromagnético inducido en las bobinas era extremadamente débil. Al no poder superar la atracción estática de los imanes permanentes contra los dientes del rotor (fuerza de detención o *cogging torque*), el rotor se alineaba bruscamente con el polo magnético pasivo más cercano, lo que causaba un "tirón" físico o retroceso de acomodo.
    * *La Solución de Ingeniería:* En lugar de arrancar linealmente desde 0%, se diseñó un arranque con **Salto Inicial (Kick-Start)** a un umbral seguro de potencia del 15% (`TRIMMER_SPEED_MIN_START = 74`). Este pulso instantáneo provee el torque electromagnético exacto para romper el par de retención magnético de manera limpia y silenciosa, permitiendo que la rampa continúe su aceleración progresiva de forma 100% directa y hacia adelante.
- **Seguridad Integrada:** Se instauró un mecanismo de apagado de emergencia (byte `64`) en caso de choque o frenado duro desde ROS 2.

## [31 de Mayo de 2026] — Sesión Tarde

- **Hito Principal:** Migración del firmware de motores (`esp32_motor`) a la placa **ESP32-S3** y cambio de driver a **MC33926** (puente H de 4 entradas).
- **Decisiones Arquitectónicas y Mapeo Físico:**
  - El driver original PWM+DIR fue reemplazado físicamente por el módulo MC33926 tras un incidente eléctrico con el convertidor buck.
  - Para controlar el MC33926 se utilizaron 4 canales LEDC independientes (2 canales por motor) para generar señales PWM en ambos sentidos en lugar de usar salidas digitales fijas para la dirección.
  - Se mapearon pines físicos seguros y libres de conflicto en el ESP32-S3: GPIO 4 y 5 para el Motor Izquierdo, GPIO 6 y 7 para el Motor Derecho.
  - La lógica de dirección física se adaptó en software (dentro de `apply_motor_command`) para que el nodo central de ROS 2 siga enviando la misma trama `/motion_cmd` sin necesidad de realizar modificaciones del lado del host.
  - Se reconfiguró el target de compilación a `esp32s3` de manera exitosa en el proyecto activo.

## [31 de Mayo de 2026] — Sesión Noche

- **Hito Principal:** Integración del control de cortadora central (BLDC) al firmware de motores, resolución del acceso al ESP32-S3 por puerto COM, y cierre de documentación técnica.
- **Identificación del Puerto USB en ESP32-S3 N8R2:**
  - El ESP32-S3 N8R2 tiene dos conectores USB-C: **COM** (para programación/serial) y **USB** (OTG nativo). El conector a usar para flash y micro-ROS es siempre el **COM**.
  - El chip CH343 del puerto COM enumera en Linux como `/dev/ttyACM0` (CDC-ACM), no como `/dev/ttyUSBx`. Los scripts existentes se invocan pasando `/dev/ttyACM0` como argumento.
- **Fix de Flash Size (sdkconfig):**
  - El `sdkconfig` del proyecto motor tenía `CONFIG_ESPTOOLPY_FLASHSIZE="2MB"`, mientras que el ESP32-S3 N8R2 tiene 8 MB físicos. Se corrigió a `CONFIG_ESPTOOLPY_FLASHSIZE="8MB"` para que esptool no rechace el dispositivo por incompatibilidad.
- **Extensión del Protocolo `/motion_cmd` a 8 campos — Cortadora Central:**
  - Se agregó el campo `cortadora_on` en el índice 7: `[cmd_id, L_dir, L_pwm, R_dir, R_pwm, T_ms, bordeadora_on, cortadora_on]`.
  - La cortadora central es un BLDC controlado por el driver **AMC CBE12A1C**. El ESP32 la habilita/inhibe via **GPIO 18 → P1-9 (INHIBIT̄)**. HIGH = motor habilitado, LOW = inhibido. El 3.3 V del ESP32 es suficiente (VIH mínimo del driver = 2.2 V, sin level-shifter necesario).
  - El GND del ESP32 debe conectarse al **P1-11 (GND)** del driver para referencia común.
- **Bug Fix — Accesorios independientes del stop:**
  - Se detectó que al enviar un comando con `l_pwm = r_pwm = 0` y `cortadora_on = 1`, el firmware entraba al bloque de stop antes de aplicar el estado de la cortadora. El accesorio quedaba indeterminado.
  - Solución: se movió la aplicación de accesorios (`bordeadora_on`, `cortadora_on`) **antes** de la verificación de stop en `motion_cmd_callback`. Los accesorios se aplican siempre, sin importar si los motores se mueven o no.
- **Sensor ESP32 — Eliminación de printf corrupto:**
  - Se encontró y eliminó un `printf` en `ultrasonic_task` (v6.0) que enviaba datos a UART0, el mismo canal que usa micro-ROS. Esto podía corromper el transporte serial silenciosamente. Firmware actualizado a v6.1. Compilado exitosamente; no se flasheó porque el sensor estaba desconectado.
- **Documentación Técnica Cerrada:**
  - `docs/arquitectura.md` completado con las secciones de ESP32 Sensor y ESP32 Motor: formatos de topics, tablas de pines, ejemplos de comandos copy-paste, y reglas de comportamiento del sistema.

## [3 de Junio de 2026] — Firmware Motor v3.0: Control Local con Encoders

- **Hito Principal:** Reescritura completa del firmware de motores a **control en lazo cerrado local con encoders** (los encoders pasan a ser la fuente de verdad del movimiento). Validado en banco con ruedas en el aire: STOP, ADELANTE, ATRAS, GIRO_IZQ y GIRO_DER funcionando.
- **Decisión Arquitectónica de Fondo:** Tras analizar las alternativas (PID independiente por rueda, sincronización de RPM, IMU solo, GPS, fusión Kalman IMU+encoders), se decidió que el control fino de rumbo y de giro se haga **localmente en el ESP32 del motor usando los encoders**, descartando Kalman y el puenteo del IMU entre ESPs por innecesarios para esta etapa. El IMU del ESP32 sensor queda solo como verificación/monitoreo en el Brain.
- **Nuevo Protocolo de Alto Nivel:** `motion_cmd` pasó de 8 a **5 campos**: `[cmd_id, modo, param, bordeadora_on, cortadora_on]`. El Brain ya no manda PWM crudo ni tiempos; manda intención (modo + parámetro). Modos: `0=STOP, 1=ADELANTE (param=RPM), 2=ATRAS (param=RPM), 3=GIRO_IZQ (param=grados), 4=GIRO_DER (param=grados), 5=PIVOT (placeholder)`. `motion_status` pasó a `[cmd_id, estado, rpm_izq, rpm_der, feedback]`. Se eliminó `T_ms`: los movimientos son continuos hasta el próximo comando y el motor está **siempre atento** (un comando nuevo reemplaza al activo).
- **Encoders por Hardware (PCNT):** se usó el periférico PCNT del ESP32-S3 (decodificación de cuadratura x4 por hardware, sin carga de CPU ni pérdida de cuentas a alta RPM) en vez de ISR por software. Pines: Izq GPIO 8/9, Der GPIO 10/11. Constantes físicas: CPR_OUT=5760, R=0.075 m, L=0.50 m → ~53.3 cuentas/grado pivot.
- **Hallazgo de Banco Clave — Encoder Derecho Invertido:** al probar ADELANTE, el motor izquierdo no giraba. El diagnóstico por telemetría mostró que el encoder derecho contaba en sentido negativo al ir hacia adelante; eso volvía positiva la realimentación de la corrección de rumbo y la dejaba descontrolada (el `error_rumbo` crecía sin límite), forzando el setpoint del motor izquierdo a 0. Se corrigió con `ENC_R_SIGN = -1` y se agregó un clamp de seguridad a la corrección (`HEADING_CORR_MAX`).
- **Diagnóstico y Solución del "Patadón" de Arranque:** el usuario notó un tirón al inicio de cada movimiento. La telemetría a alta resolución (25 ms) lo confirmó: en recta, sobrepico de 28 RPM con setpoint 10 (respuesta sub-amortiguada); en giros, salto directo a PWM 255. Solución: **slew de PWM universal** (`PWM_SLEW_RATE=600`, dejó los giros perfectos) + **rampa de setpoint** en recta (`RPM_ACCEL=30`). El patadón bajó de 28 → 16 RPM. El pulido fino del rebote residual y el offset de régimen se difiere al tuning en el piso (el banco/aire es el peor caso de oscilación).
- **Giros por Ángulo Validados:** GIRO_DER y GIRO_IZQ alcanzan el ángulo pedido con perfil de desaceleración suave y aterrizaje exacto (90° → feedback=90), publicando `DONE` y volviendo a `IDLE` limpio. Simetría perfecta entre ambos sentidos.
- **Mejora "Anti-Hipo" (orden idéntica):** se detectó que reenviar la misma orden de movimiento solo para cambiar un accesorio (p.ej. prender la cortadora avanzando recto) reiniciaba el lazo y causaba un tirón/dip de marcha. Se corrigió: si la nueva orden tiene el mismo `modo` y `param` que la activa, el callback solo actualiza accesorios y NO reinicia el control. Validado en banco con cortadora sola y con cortadora + bordeadora simultáneas: las RPM se mantienen continuas (sin caída) durante la transición.
- **Giro por velocidad regulada (reemplaza al PID de posición):** se detectó que el giro "pateaba" (giraba a fondo ~80 RPM al inicio y frenaba recién al final) porque el PID de posición saturaba el PWM mientras el error era grande. Capar el PWM lo suavizaba pero el usuario advirtió —con razón— que un tope bajo limita también el torque y bajo carga podría no completar el giro. Solución correcta: **regular la velocidad de giro** (reusando el PID de velocidad), midiendo el ángulo por encoders, con perfil trapezoidal (acelera → crucero `GIRO_RPM` → desacelera `GIRO_DECEL_DEG`/`GIRO_RPM_MIN` → frena en `GIRO_TOL_DEG`). Así la velocidad es gentil y pareja pero el lazo aplica todo el torque necesario (hasta 255) para girar bajo carga. Se eliminó el PID de posición.
- **Validación física en piso CON CARGA (03/06):** se bajó el robot al suelo y se probó: adelante, atrás, adelante 3s + atrás 3s de corrido, y giros de 90° a izquierda y derecha. Todo anduvo bien; los giros completaron los 90° (correctos a ojo en ambos sentidos) y la inversión de sentido adelante↔atrás resultó suave (sin tirón, gracias al slew). Bajo carga aparecieron dos puntos de tuning fino (no bloqueantes): la velocidad queda por debajo del setpoint (subir `VEL_KI`) y hay una deriva de rumbo leve ~0.8° (subir `HEADING_KP`).
- **Análisis de tiempos:** la cadencia de `/motion_status` es ~230 ms (config 200 ms + overhead). La latencia comando→reacción por `ros2 topic pub --once` es ~0.87 s (artefacto del CLI: crea un nodo y hace discovery cada vez), mientras que con un **nodo persistente** (como será el Brain) baja a ~20-30 ms. Reaccionando al feedback `DONE` (estado=3) las secuencias encadenan sin huecos. Un giro de 90° tarda ~3.5 s sin carga y ~4.3 s con carga.
- **Pendientes:** definir el modo PIVOT, tuning fino con carga (`VEL_KI`, `HEADING_KP`), y reescribir el Brain Python al protocolo de 5 campos.

## [8 de Junio de 2026] — Firmware Motor v3.2: Modo PIVOT

> Entrada retroactiva, reconstruida el 28/10/26 desde el código y git.

- **Hito Principal:** se implementó el modo **PIVOT (5)**, que antes era un placeholder. Es una secuencia automática de cambio de franja: accesorios ON forzados → adelante `param` cm (0 → 30 cm) a 30 RPM → atrás 28 cm fijos → swing de 90° a la izquierda sobre la rueda izquierda fija → `DONE`.
- **Criterio geométrico:** con H = 40 cm y L = 50 cm, la esquina delantera derecha barre un radio de ~64 cm en el swing; hace falta retroceder al menos 24 cm para no invadir el borde, y se usan 28 cm.
- **Control:** las fases lineales usan el mismo lazo que la recta (rampa, rumbo, PID de velocidad, slew) con distancia medida por encoders y desaceleración en los últimos 5 cm; el swing usa el PID de velocidad solo en la rueda derecha, con el perfil trapezoidal de los giros.
- **Estado:** compilado (08/06 14:53) y validado en físico: `DONE` con feedback = 90° y secuencia completa observada en `/motion_status`. Falta medir las distancias reales y confirmarlo en piso con carga.

## [27 de Octubre de 2026] — E7 APP Android: Fase 1, ampliación de `/sensores`

> Entrada retroactiva, reconstruida el 28/10/26 desde git y el resumen de la sesión.

- **Hito Principal:** arranque de la entrega E7 (APP Flutter ↔ Bluetooth ↔ ESP32 sensor → micro-ROS → Raspberry). Se definió el diseño completo (control manual, modo autónomo, mapa offline, área de trabajo como polígono de hasta 10 vértices) y se completó la **fase 1**.
- **Firmware Sensor v6.2:** `/sensores` pasó de 13 a **24 valores**: satélites y HDOP del GPS (13–14) más 9 campos de la APP (15–23: conexión, estado, dirección, velocidad, cortadora, bordeadora, secuencia, antigüedad del comando, id de polígono). Por seguridad, el ESP pone dirección y herramientas en 0 si la APP está desconectada o el comando tiene más de 300 ms. Backup previo en `versions/2026_10_27_MainV6.1_pre_app.c.bak`.
- **Bug corregido:** el parser GGA del GPS usaba `strtok_r`, que saltea los campos vacíos y corre los índices (por ejemplo, con tramas sin fix). Se reemplazó por separación manual.
- **Compatibilidad:** el Brain solo lee los índices 0–2, así que no se rompe.
- **Estado:** compilado OK (285 KB, 73 % libre). El Bluetooth todavía no está implementado (los `app_*` quedan en sus valores por defecto). **Falta flashear y validar en hardware.**
- **Pendientes de decisión:** BLE (NimBLE, recomendado) o Classic SPP; comportamiento sin APP conectada (quieto, recomendado, o el comportamiento actual); tamaño del cuadrado inicial del área (propuesto 10 × 10 m).

## [28 de Octubre de 2026] — Puesta al día de la documentación

- Se registraron en `docs/` los dos trabajos que faltaban (PIVOT del 08/06 y sensor v6.2 del 27/10).
- Se corrigió en `CLAUDE.md` y en el SOP la lista de topics del sensor: el firmware publica **solo `/sensores`** (reliable), no `/bumpers`, `/ultrasonicos_cm`, `/gps_fix` ni `/imu/data_raw`.
- Se corrigió en el estado actual el protocolo que manda hoy el Brain (7 campos, no 8).
- Se creó `docs/e7_app_android.md`, el documento vivo con todo el diseño de la APP (requisitos, protocolo Bluetooth, seguridad, área de trabajo, UI del editor, entorno, hoja de ruta y decisiones pendientes).
- Se detectó que el "giro continuo" previsto (reenviar GIRO ~15°) choca con el anti-hipo del motor y daría un giro a tirones; queda como decisión pendiente antes de la fase 4.
- **Cambio de hardware de tracción:** los motores nuevos (Pololu 37Dx57L 12 V 100:1) **no tienen encoder**, y el firmware del motor v3.2 depende de los encoders para todo su control. Se documentó el impacto y las opciones; la más directa es la versión con encoder del mismo motor (Pololu #4755), que conserva el firmware cambiando solo una constante. Decisión pendiente.
- Se creó `docs/componentes.md` con la lista oficial de componentes, su justificación y las discrepancias con el firmware (IMU, GPS, cantidad de finales de carrera, alimentación), más la ficha `Datasheet/Motor_traccion_Pololu_37D.txt`.
- **Componentes y alimentación documentados:**
  - Se corrigió el GPS (FSTR2).
  - Hay dos IMU (MPU-6500 integrado y LSM9DS1 por integrar), y se agregará un 4.º final de carrera.
  - Se documentó el árbol de alimentación: banco 8S para la cortadora y el LM2596, batería inferior 4S para la tracción y la bordeadora, y powerbank para el procesamiento.
  - La verificación eléctrica dejó puntos a revisar: divisor en los ECHO, placa del LSM9DS1 a 5 V, motores de 12 V con hasta 16,8 V, límite USB de la Pi 5 y desbalance de baterías.
  - Queda en análisis intercambiar los ESP32: el S3 solo tiene BLE, por lo que la decisión está atada a elegir BLE o SPP.
- **LSM9DS1 identificado:** es una SparkFun LSM9DS1 Breakout de 1,9–3,6 V, sin regulador → **no se conecta a 5 V**; va al 3V3 del ESP32, y con eso el I2C queda a 3,3 V, compatible con cualquier ESP32. Puede compartir el bus con el MPU-6500 sin choque de direcciones.
- Confirmado que los ECHO de los ultrasónicos ya tienen divisor a 3,3 V.
- Aprobado limitar el PWM de la tracción a ≈180/255; se acordó medir el consumo USB de la Pi 5 y monitorear cada batería.
- Decidido: el LSM9DS1 se alimenta del 3V3 del ESP32 (la línea de 3,3 V del equipo). Falta definir en qué ESP32 va.
- **Descartado el motor con encoder (#4755):** no se consigue. La tracción queda sin encoders. Se propuso pasar el LSM9DS1 al ESP32 del motor para controlar rumbo y giros con el giróscopo, con velocidad y distancias en lazo abierto calibrado (pendiente de confirmación).
- **Ubicación de los IMU decidida:** el LSM9DS1 va en el ESP32 motor, lejos del brushless; el giróscopo no necesita estar en el centro del robot. El MPU-6500 se queda en el ESP32 sensor como verificación para la Raspberry.
- Análisis de "¿irá recto?": el lazo de rumbo con giróscopo compensa motores desparejos y terreno, y no lo engaña el patinamiento; el límite es la deriva lenta del giróscopo. Se propuso medirla antes de reescribir el control.
- Se propuso intercambiar los ESP32: el S3 pasa a sensores (por el Bluetooth) y el clásico a motores. El usuario lo ve sencillo (protoboard) y confirma al retomar, junto con los mapas de pines, que no pueden ser idénticos.
- **Cierre de la sesión de madrugada.** Pasos para retomar en `00_estado_actual.md` §3.

## [2 de Noviembre de 2026] — Intercambio de ESP32 y mapa de pines

- **Decisión:** se confirma el intercambio de placas. El **ESP32-S3 pasa a sensores** y el **ESP32 clásico pasa a motores**. En consecuencia, el Bluetooth de la APP (E7) es **BLE**, porque el S3 no tiene Bluetooth Classic.
- **Mapa de pines acordado** en `docs/pines.md`. En el S3, el usuario eligió los pines de los ultrasónicos y los bumpers; el GPS y el I2C del MPU-6500 se reubicaron en los GPIO 4–7. Se descartaron los GPIO 3 y 46 para el ECHO del centro por ser strapping (el 46 puede hacer fallar el flasheo) y se usó el 9.
- **Motor en el clásico:** el PWM de las ruedas pasa a los GPIO 32, 33, 25 y 26, que no sacan pulsos al arrancar. El Sabertooth (17) y la cortadora (18) conservan sus pines, el LSM9DS1 va al I2C 21/22 y se eliminan los encoders.
- **Pendientes antes de cablear:**
  - Confirmar N8R2 en el S3 y WROOM en el clásico.
  - Ver en qué pin está el LED RGB de la placa S3.
  - Revisar el comportamiento del INHIBIT̄ de la cortadora con el pin flotante.
- Todavía no se tocó el firmware ni el cableado.
- **IMU de respaldo:** una placa MPU-9250 (chip "MP92", con magnetómetro, sin verificar) queda como seguro por si el LSM9DS1 no funciona. Se usa con el mismo cableado.
- **Firmware de prueba del LSM9DS1** (`firmware/esp32_motor/test_lsm9ds1`, para el ESP32 clásico): detecta el sensor, verifica la configuración, calibra el giróscopo, mide la deriva durante 5 min y muestra el magnetómetro para la prueba con la cortadora. Compilado OK; falta correrlo en hardware. Procedimiento en `docs/pruebas.md`.
- La prueba del LSM9DS1 se hace en una ESP32-S3 N16R8 de prueba (I2C en los GPIO 6/7); el firmware compila para los dos targets.
- **LSM9DS1 funcionando** en la placa de prueba (tras cambiar un cable suelto): direcciones 0x6B/0x1E confirmadas, ruido del giro ~0,06 dps, acelerómetro ~1 g y magnetómetro ~23 µT (campo terrestre local). El firmware de prueba (v1.2) ahora rechaza calibraciones con movimiento y detecta si el sensor se reinicia. Falta la corrida de deriva de 5 min sin tocar.
- **Deriva del giróscopo del LSM9DS1 medida en reposo: ≈ 0,1–0,2 °/min** (5 min, 0 errores I2C), muy por debajo del umbral de 1 °/min. Alcanza para controlar el rumbo con el giróscopo. La corrida tuvo un movimiento externo en el minuto 4, que se identificó y se excluyó en el análisis.
- **Tarde:** se repitió la prueba de deriva del LSM9DS1. Recién conectado dio **5,8 °/min**, y a los ~6 min, **1,25 °/min**, contra 0,1–0,2 °/min con horas de encendido. El giróscopo tiene un **calentamiento inicial**: su bias cambia durante varios minutos después de encenderlo. Para el robot implica esperar a que se estabilice y recalibrar en cada parada. Falta medir cuánto dura el calentamiento.
- **Curva de 30 min del giróscopo:** el bias cambia más en los primeros minutos y después sigue oscilando un poco (también por la temperatura). Con los datos se simuló **recalibrar 3 s en cada parada**: el error de rumbo tras 1 min de recta queda en ~0,4° típico y ~1,3° en el peor caso (con ≥ 6 min de encendido). El giróscopo sirve, con recalibración frecuente.
- **El usuario quiere usar el magnetómetro.** Se cargó la v1.3 del firmware de prueba, con un versus giroscopio vs magnetómetro (calibración con el botón BOOT, comparación en giros, en el tiempo y con perturbaciones). Falta correrlo con el usuario en la mesa.
- **Primer versus giroscopio vs magnetómetro:** el giróscopo midió bien los giros. La brújula tenía el **signo invertido** (supuesto de ejes incorrecto) y errores de hasta ~15° según hacia dónde apunte, porque la calibración era demasiado simple. La placa tiene un campo magnético propio de ~26 µT. El sensor volvió a reiniciarse al girarlo: **falta asegurar el cableado**. Se preparó la **v1.4** con el signo corregido y una calibración por ajuste de elipse (verificada en la PC con datos sintéticos).
- **Segundo versus (v1.5):** el **giróscopo midió todos los giros de ±90° con ±1°**. La brújula, ya con el signo correcto, se equivocó **16–35°** a ±90°, de forma repetible. El campo medido cerca del sensor es anormal (13,8 µT horizontal), así que lo más probable es que el entorno o el montaje la perturben (protoboard, placa, notebook). Falta repetirlo con el sensor sobre un soporte no metálico, lejos de todo.
- **Decisión:** se descarta la brújula por ahora. El robot controla el rumbo con el **giróscopo**, recalibrando en cada parada. Siguiente: probar la placa 3 (MPU-9250) para comparar.
- **Placa 3 (clon de MPU, 6 ejes):** en 30 min desde frío, su giróscopo resultó **~3 veces mejor que el del LSM9DS1**. Recalibrando en cada parada, el error tras 1 min es de 0,14° típico y 0,4° en el peor caso, y casi no necesita calentamiento. Recomendación: usarla en el ESP32_motores y dejar el LSM9DS1 de respaldo (falta confirmar y hacer el giro de 90°).
- **Prueba de giro de la placa 3:** los giros de 90° dan entre 87,9 y 90,5° y las vueltas completas ~356° (girando rápido a mano; puede ser saturación o un error de escala de ~1 %, corregible). Pasa la validación. Lección: el robot tiene que esperar a estar bien quieto antes de recalibrar.
- **Decisión: la placa 3 es el IMU del ESP32_motores** (LSM9DS1 de respaldo). Al giróscopo no le afectan los imanes ni el metal; para montarlo hay que cuidar la vibración, el calor y el cableado.
- **Afinado de la placa 3 (el usuario ausente):**
  - Allan y barrido de la recalibración: **5 s en cada parada** da el mejor equilibrio. La temperatura no hace falta compensarla.
  - Los 356–358° de las vueltas se explican por la **inclinación de la placa**; la v1.2 lo compensa con el acelerómetro.
  - Hallazgo: **el bias cambió al nivelar la placa** (~1 dps/g si depende de la orientación). Falta una prueba de inclinación para ver si se puede compensar.
  - Se cargó la v1.2 (recalibración robusta, yaw vertical) y quedó un borrador de parámetros para el firmware del motor v4.
- Se corrigió el mapa de pines del S3 en `pines.md`: **GPS en el 35/36** y **4.º bumper en el 39**, como se había acordado.
- **Firmware del motor v4.0 (sin encoders):** el rumbo y los giros se controlan con el giróscopo de la placa 3, y la velocidad y las distancias en lazo abierto (constantes a calibrar en piso). El motor recalibra el giróscopo solo en cada parada. **Protocolo nuevo:** misma orden de 5 campos, velocidad en cm/s, modos nuevos CALIBRAR (6) y FIJAR_RUMBO (7), y un status de 9 campos con el rumbo y el estado del IMU (detalle en `arquitectura.md`). La v3.2 quedó respaldada en `versions/`. Compila para el ESP32 clásico y para la S3 de prueba. Se cargó en la S3, pero no conectó con el agente porque el cable estaba en el conector USB nativo y no en el COM; falta repetir la prueba (`pruebas.md` §4).

## 13/11/26

- **Raspberry Pi 4 configurada** como el nuevo host de producción (la Pi 5 se perdió). OS: Ubuntu 26.04 "Resolute", arm64, 7,6 GB RAM. Se decidió no reflashear por coexistir con el proyecto `cabeza_social`.
- Instalado **ROS 2 Lyrical** (versión oficial para Ubuntu 26.04) vía `packages.ros.org/ros2/ubuntu resolute`. El Brain compila y `ros2 pkg list` muestra `cortadora_brain`.
- **micro-ROS agent compilado desde source** (branch `lyrical` del repo oficial). El agente usa un SuperBuild que descarga `microxrcedds_agent` automáticamente. Se resolvió un conflicto con Python 3.12 de `uv` forzando el Python del sistema (`/usr/bin/python3`). Binario operativo en `~/microros_agent_ws/`.
- Creados `scripts/pi/{env.sh,run_brain.sh,run_agent_serial.sh}` y copiados a la Pi.
- `CLAUDE.md` y `docs/00_estado_actual.md` actualizados: PC = Jazzy/firmware, Pi 4 = Lyrical/producción.
