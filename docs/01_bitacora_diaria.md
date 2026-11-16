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

### Verificación nocturna del sensor S3 y agente

- PR #7 integrado y PC sincronizada en `main` (`9f29665`).
- SSH a la Pi operativo. Sensor por USB nativo; EN cambió ttyACM0 a ttyACM1. Se probó el identificador estable por `/dev/serial/by-id/`.
- Arranque desde flash y compilación del sensor de hoy confirmados mediante captura USB y prefijo SHA ELF del binario local.
- Sin sesión micro-ROS ni `/sensores` en pruebas directas y con el puente existente; DTR/RTS liberados tampoco resolvieron. Procesos de prueba cerrados.
- Se identificaron puente y parches del agente presentes solo en la Pi. Falta diagnosticar firmware/transporte desde la PC; no se probó movimiento.

- **Continuación en la PC:** se cargó temporalmente firmware con marcas USB; se verificó el arranque de todas las tareas y llegada a `rclc_support_init`. Marcas retiradas después de la captura.
- **Corrección validada:** transporte USB directo al FIFO, con timeout de escritura de 1 s y esperas que ceden al scheduler, reemplaza el controlador USB con interrupciones. FreeRTOS a 1000 Hz en `sdkconfig.defaults`. No se modificó el protocolo ni los pines.
- Agente local sin puente: sesión, participante, topic y publicador creados; `/sensores` recibido con 24 valores. Frecuencia final de unos **18,5 Hz** durante 15 s. Compilación sin warnings y hashes de flasheo verificados. Falta repetir en la Pi y validar sensores físicos.

- **Validación final en Raspberry Pi 4 / Lyrical:** sensor S3 reconectado por USB nativo; agente directo al identificador estable, sin puente. Sesión y publicador creados; `/sensores` de 24 campos recibido y frecuencia de unos 18,5 Hz durante 15 s. Agente dejado con `nohup` y log `/tmp/cortadora-sensor-agent.log`; no se configuró inicio automático al reiniciar. Los parches anteriores del agente siguen instalados; no se probó retirarlos. Lecturas físicas y adaptación del Brain todavía pendientes.

- Al pasar el agente a segundo plano, el sensor no recuperó automáticamente la sesión. Reinicio por RTS del sensor y mensaje de 24 campos confirmado con el agente definitivo (PID 30840). Pendiente implementar reconexión en firmware; por ahora reiniciar el sensor después de reiniciar el agente.

- A pedido del usuario, se preparó diagnóstico de adquisición del sensor sin micro-ROS, en compilación separada y con las mismas tareas. Se agregaron estados/counters IMU y GPS, validación NMEA, calibración por muestras válidas y timestamps por ultrasonido. Compilan diagnóstico y firmware normal; parser GPS probado con fix válido/sin fix, campos vacíos, hemisferios S/W y rechazos por truncamiento, coordenadas inválidas o checksum. Pendiente conectar a PC, cargar y hacer pruebas físicas.

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

## 14/11/26 — Continuación GPS aislado

- Usuario informa inscripción `FSTR2 C01020-09` y alimentación desde 3V3; no se identificó ficha técnica verificable para esa referencia exacta. No se presume que 3,3 V sea su alimentación nominal.
- GPS aislado conectado al ESP32 por RX4/TX5 y USB nativo a la PC. Captura inicial mantiene solo un byte 00 y ninguna línea NMEA. El diagnóstico existente ya incluye barrido 9600/4800/38400/57600/115200/19200; se captura un ciclo completo sin modificar ese código ni enviar comandos al GPS.

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
