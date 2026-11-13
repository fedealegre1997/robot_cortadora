# Registro de Acciones RAW

Este documento es un registro inmutable (append-only) de cada acción, experimento, diagnóstico, pensamiento, bloqueos y errores abordados durante el desarrollo del proyecto.
**REGLA ESTRICTA:** NUNCA se deben modificar, resumir ni borrar entradas anteriores. Este documento sirve como "fuente de la verdad" para recordar caminos fallidos y diagnósticos previos. Añadir SIEMPRE al final del archivo.

## [18/05/26 Sesión Madrugada] - Debugging Físico del Motor y Lógica de Rampa
- **Hipótesis y Diagnóstico Profundo:** 
  - El usuario reportó que el motor gira en reversa por ~200ms antes de ir hacia adelante al mandarle el comando de encendido. 
  - **Primer pensamiento:** Creí que podía ser una configuración errónea de los DIP Switches de la Sabertooth (ej. Modo RC leyendo ruido). Pero el usuario confirmó que los cambió a Serial Simplificado.
  - **Segundo pensamiento:** Analicé el arranque del UART en ESP32. Al inicializar, el pin TX sufre un glitch que la Sabertooth guarda en su buffer, corrompiendo el primer byte de arranque (`66`). Implementé enviar un `64` forzado en el boot para limpiar el buffer serial. Aún así el usuario reportó que el glitch continuaba.
  - **Conclusión Definitiva (Cogging Magnético / Par de Retención):** Comprendí a fondo la física e interacción electromagnética del motor HANPOSE 775. Este motor es una máquina síncrona de imanes permanentes con escobillas de muy alta potencia (288W). 
    * *La raíz física:* El par de retención (o *cogging torque*) ocurre debido a la atracción magnética entre los imanes permanentes del estator y los dientes de hierro dulce del núcleo del rotor. Este par es independiente de la corriente en las bobinas; es una fuerza estática puramente física causada por la variación de la reluctancia magnética en el entrehierro a medida que el rotor gira.
    * *Por qué giraba al revés:* Al arrancar desde el byte `64` (Stop) de forma lineal, el primer paso de rampa mandaba `66` (aproximadamente un 3% de PWM de voltaje promedio). A esta tensión tan baja, la corriente generada en los devanados del rotor produce un par electromagnético muy inferior al *cogging torque* máximo del motor. El rotor no podía avanzar sobre el "diente" magnético siguiente. En su lugar, el débil campo magnético del inducido actuaba como un resorte elástico, y la atracción de los imanes permanentes jalaba el diente del rotor de regreso al punto de mínima reluctancia más cercano (que físicamente significaba un retroceso o "tirón" hacia atrás).
    * *Por qué duraba 200ms:* Ese "juego" o vibración hacia atrás persistía durante las primeras iteraciones de la rampa (de byte 66 a 72). Recién en el paso del byte `74` (aproximadamente 15% de ciclo de trabajo), el voltaje promedio de inducción vencía la barrera del par de retención estático y obligaba al rotor a saltar magnéticamente hacia adelante de forma continua.
    * *La solución de control:* Diseñar un perfil de velocidad no lineal. Introducir un **Kick-Start** (Salto Inicial a 74) que inyecte de golpe la corriente necesaria para saltar la barrera de reluctancia inicial, y luego continuar con la rampa progresiva fina para el resto del aceleramiento dinámico.
- **Acciones Implementadas:** 
  1. **Flush UART:** Añadí `uart_write_bytes` enviando un `64` en el `sabertooth_hw_init()` con delays de 50ms para prevenir framing errors reales en la placa.
  2. **Memoria de Estado:** Modifiqué `motion_cmd_callback` para que guarde `target_trimmer_state = bordeadora_on` aislando el encendido de la cuchilla del timer de tracción.
  3. **Salto Antifricción:** Creé `#define TRIMMER_SPEED_MIN_START 74`. Ahora, la rampa salta de 64 a 74 directo, aplicando un ~15% de potencia instantánea para romper el cogging, eliminando el retroceso, y luego sigue rampando hasta el 33% de prueba segura.
- **Resultado RAW:** Código compilado limpio al 100%. Teóricamente sólido y a la espera del testeo de Hardware del usuario.

## [20/05/26 Sesión Noche] - Inicio de Pruebas Físicas de la Bordeadora
- **Pensamientos y Objetivos:**
  - El usuario ha levantado con éxito el agente de micro-ROS para los motores.
  - El objetivo de esta sesión de noche es validar físicamente el firmware en el robot enviando comandos de encendido y apagado de la bordeadora por consola ROS 2.
  - Queremos comprobar en el hardware real que el "Kick-Start" inicial (byte 74) elimina por completo el cogging magnético y si el apagado (byte 64) detiene la cuchilla al instante de forma segura.
- **Acciones Realizadas:**
  1. Preparación de los comandos específicos de ROS 2 para publicar en el topic `/motion_cmd` simulando el accionamiento de la bordeadora sin mover las ruedas de tracción.

## [27/05/26 Sesión Tarde] - Pruebas Físicas de Encendido/Apagado de la Bordeadora
- **Objetivos de la Sesión:**
  - Ayudar al usuario a levantar el agente de micro-ROS para los motores.
  - Probar físicamente el encendido de la bordeadora enviando comandos al topic `/motion_cmd` con la bordeadora activada (`bordeadora_on = 1`) y las ruedas detenidas (`l_pwm = r_pwm = 0`).
  - Probar el apagado inmediato de la bordeadora (`bordeadora_on = 0`) para verificar la seguridad del sistema.
  - Dejar documentados los comandos exactos de ROS 2 en `docs/comandos.md` para facilitar las pruebas repetibles.
- **Cambio de Rumbo por Quema de Hardware (ESP32):**
  - El usuario informó que el ESP32 original se quemó y lo reemplazó por un módulo **ESP32-S3-WROOM-1**.
  - Decisión de diseño: Para no alterar la base de código del firmware principal `main.c` en `esp32_motor/active/active` y mantenerla intacta, se acordó crear un **proyecto de prueba de hardware completamente aislado** en `firmware/esp32_motor/test_s3_motor`.
  - Este test independiente no requiere micro-ROS y solo implementa control digital directo de un motor (LEDC PWM y GPIO) para verificar el pinout y el correcto funcionamiento físico antes de migrar todo el firmware.
  - Se mapeó el motor de propulsión izquierdo a los pines físicos:
    * `PWM` -> `GPIO_NUM_4`
    * `DIR` -> `GPIO_NUM_5`
  - Se crearon scripts automáticos de build y flash (`scripts/pc/build_test_s3.sh` y `scripts/pc/flash_test_s3.sh`) y se compiló exitosamente el firmware de prueba con target `esp32s3`.

## [31/05/26 Sesión Tarde] — Migración a ESP32-S3 y Driver MC33926 en Firmware Principal
- **Objetivos de la Sesión:**
  - Migrar el firmware principal (`esp32_motor/active/active/main/main.c`) para usar la placa ESP32-S3 en reemplazo de la ESP32 quemada.
  - Adaptar la lógica del driver de motores de PWM+DIR al nuevo driver MC33926 de 4 canales de control PWM utilizando el código de prueba validado `versions/2026_04_16_test_mc33926.cpp`.
  - Configurar el target del proyecto principal a `esp32s3` para su compilación y flasheo.
- **Acciones Realizadas:**
  1. **Análisis de Mapeo de Pines:** Se constató que en el ESP32-S3 no existen los pines 25 ni se pueden usar libremente el 26 y 27. Se realizó un mapeo físico seguro para el MC33926:
     - Canal M1 (Izquierda): M1_IN1 (GPIO 4), M1_IN2 (GPIO 5).
     - Canal M2 (Derecha): M2_IN1 (GPIO 6), M2_IN2 (GPIO 7).
  2. **Refactorización de main.c:**
     - Se eliminaron las definiciones de `PWM1_PIN`, `DIR1_PIN`, `PWM2_PIN` y `DIR2_PIN`.
     - Se introdujeron las definiciones de `M1_IN1_PIN`, `M1_IN2_PIN`, `M2_IN1_PIN` y `M2_IN2_PIN`.
     - Se definieron 4 canales LEDC: `CH_M1_IN1` (Channel 0), `CH_M1_IN2` (Channel 1), `CH_M2_IN1` (Channel 2), `CH_M2_IN2` (Channel 3).
     - Se reescribió `apply_motor_command` para traducir los comandos `/motion_cmd` a la lógica del puente en H del MC33926:
       * Motor Izquierdo (M1): Forward -> M1_IN1 = PWM, M1_IN2 = 0; Reverse -> M1_IN1 = 0, M1_IN2 = PWM; Stop -> M1_IN1 = 0, M1_IN2 = 0.
       * Motor Derecho (M2): Forward -> M2_IN1 = 0, M2_IN2 = PWM; Reverse -> M2_IN1 = PWM, M2_IN2 = 0; Stop -> M2_IN1 = 0, M2_IN2 = 0. (Sabiendo que el motor derecho está invertido mecánicamente en la estructura).
     - Se actualizó `stop_all_motors` para apagar los 4 canales LEDC.
     - Se actualizó `motor_hw_init` agregando la función auxiliar `ledc_init_channel` e inicializando los 4 canales necesarios.
  3. **Configuración de Target:** Se configuró con éxito el target de compilación a `esp32s3` mediante `idf.py set-target esp32s3` en la carpeta `active/active`.
- **Resultado RAW:** Código refactorizado limpiamente en la rama activa. La arquitectura micro-ROS del motor ahora corre nativamente sobre el ESP32-S3 controlando el puente H MC33926.

## [31/05/26 Sesión Noche] — Puerto COM, Cortadora Central, Bug Fix Accesorios y Cierre de Docs

- **Problema inicial — dos puertos USB-C en el ESP32-S3 N8R2:**
  - El usuario tenía el ESP32-S3 N8R2 con dos conectores tipo C: uno marcado **COM** y otro **USB**. No sabía cuál usar.
  - Diagnóstico: el puerto COM tiene un chip bridge CH343 que presenta la UART del ESP32 como CDC-ACM. En Linux enumera como `/dev/ttyACM0`, no como `/dev/ttyUSBx`. El puerto USB es OTG nativo (DFU, JTAG) y NO sirve para micro-ROS.
  - Acción: indicar al usuario que conecte únicamente el puerto **COM**. Confirmado con `ls /dev/ttyACM*`.

- **Fix de sdkconfig — Flash size:**
  - `idf.py flash` fallaba o el dispositivo era rechazado porque el sdkconfig tenía `CONFIG_ESPTOOLPY_FLASHSIZE="2MB"`, pero el chip físico N8R2 tiene 8 MB.
  - Se editó directamente el `sdkconfig` para setear `CONFIG_ESPTOOLPY_FLASHSIZE_8MB=y` y `CONFIG_ESPTOOLPY_FLASHSIZE="8MB"`.
  - Flash exitoso después de la corrección.

- **Extensión de protocolo — cortadora_on (índice 7):**
  - El usuario quería control independiente de la cortadora central (motor BLDC) desde ROS 2.
  - Se agregó el campo `cortadora_on` al final de `motion_cmd`: `[cmd_id, L_dir, L_pwm, R_dir, R_pwm, T_ms, bordeadora_on, cortadora_on]`.
  - `CMD_LEN` pasó de 7 a 8. Se reusó el validador `is_valid_bordeadora()` para el campo `cortadora_on` (mismos valores: 0 o 1).

- **Análisis de hardware — AMC CBE12A1C y GPIO 18:**
  - Se identificó que el driver BLDC AMC CBE12A1C tiene el pin P1-9 (INHIBIT̄) para habilitar/inhibir el puente.
  - Se verificó en el datasheet: VIH mínimo = 2.2 V → 3.3 V del ESP32 es suficiente. No requiere level-shifter.
  - GPIO asignado: GPIO 18 (libre en el ESP32-S3 motor, todos los demás pines ya están en uso).
  - GND del ESP32 → P1-11 (GND) del driver para referencia común.
  - Configuración: GPIO 18 como salida push-pull sin pull-up/pull-down. Estado inicial = LOW (inhibido) en `motor_hw_init`.

- **Bug — accesorios no se aplicaban cuando l_pwm = r_pwm = 0:**
  - El usuario reportó que el comando `[1, 0, 0, 0, 0, 0, 0, 1]` (motores quietos, cortadora ON) se "bugeaba" y el firmware quedaba en estado indeterminado.
  - Causa raíz: en `motion_cmd_callback`, la verificación de stop (`if (is_stop_command(...))`) retornaba antes de que se asignara `target_trimmer_state` ni `gpio_set_level(CORTADORA_ENABLE_PIN, ...)`.
  - Fix: mover las dos líneas de control de accesorios **antes** del bloque de stop check. Ahora los accesorios se aplican primero en cualquier path del callback.
  - Resultado: `[id, 0, 0, 0, 0, 0, 0, 1]` = motores parados, cortadora habilitada. Funciona correctamente.

- **Firmware motor v2.2 — build y flash exitosos:**
  - `~/robot_cortadora/scripts/pc/build_motor.sh` completó sin errores.
  - `~/robot_cortadora/scripts/pc/flash_motor.sh /dev/ttyACM0` flasheó correctamente.
  - Encabezado actualizado a v2.2, fecha 31/05/2026.

- **Sensor ESP32 — análisis de v6.0:**
  - Revisión de `firmware/esp32_sensor/active/active/main/main.c` para detectar posibles problemas.
  - Se encontró un `printf("ULTRA -> IZQ=%.2f  CEN=%.2f  DER=%.2f\n", ...)` en `ultrasonic_task`.
  - Este `printf` escribe a UART0, el mismo canal que usa el transporte serial de micro-ROS. Puede corromper tramas silenciosamente.
  - Se eliminó la línea. Firmware actualizado a v6.1.
  - Build exitoso (`chip=esp32, 2MB flash`). NO se flasheó porque el sensor estaba desconectado.

- **Documentación — docs/arquitectura.md:**
  - Se completaron ambas secciones: ESP32 Sensor y ESP32 Motor.
  - Incluye: formato de topics, tablas de campos con índices y unidades, mapa de pines GPIO, arquitectura de tareas FreeRTOS, comandos de flash/agente y ejemplos copy-paste de todos los casos de uso.

## [03/06/26 Sesión Madrugada] - Rediseño a Control Local con Encoders (Firmware Motor v3.0)

- **Discusión de Arquitectura (por qué se eligió este camino):**
  - El usuario planteó el problema de fondo: avanzar recto de forma estable. Se analizaron y descartaron alternativas: (a) dos PID de RPM independientes — no garantizan recta porque los motores nunca son idénticos (diámetro efectivo, fricción, desgaste, carga); (b) sincronizar RPM — el robot puede seguir avanzando inclinado aunque las RPM sean iguales; (c) IMU MPU6500 solo — sin magnetómetro, el yaw se obtiene integrando el giroscopio y deriva; (d) GPS — error de 1-3 m, inútil para rumbo fino; (e) fusión Kalman IMU+encoders.
  - Se llegó a que el Kalman para corregir el drift de yaw **necesita una medición independiente de rotación**, y la única disponible sin magnetómetro son los **encoders** (`RPM_izq - RPM_der`). Por eso el filtro tendría que correr donde están los encoders (ESP motor).
  - **Decisión final del usuario:** simplificar. Nada de Kalman ni de puentear el IMU entre ESPs. Control de rumbo por **diferencia de cuentas acumuladas de encoder** (no RPM instantáneas: las cuentas acumuladas actúan como memoria de trayectoria y autocorrigen aunque ya se haya desviado). Los encoders son "los dioses". El IMU queda solo para verificación en el Brain.
- **Definición del Protocolo Nuevo:**
  - `motion_cmd = [cmd_id, modo, param, bordeadora_on, cortadora_on]`. Se eliminó `T_ms` (los movimientos quedan continuos hasta nuevo comando; ya estaba "parcheado" con T_ms=0). Los accesorios (bordeadora/cortadora) quedan idénticos al protocolo viejo, solo cambian de índice (3 y 4).
  - Modos: 0=STOP, 1=ADELANTE(RPM), 2=ATRAS(RPM), 3=GIRO_IZQ(grados), 4=GIRO_DER(grados), 5=PIVOT(a definir). Dos familias de control: por velocidad (recta) y por posición (giros).
  - El usuario pidió que el ESP esté **siempre atento**: cualquier comando nuevo interrumpe/reemplaza al actual sin importar el modo en curso.
- **Base de Código Reutilizada:** el usuario aportó dos sketches Arduino probados el semestre pasado con el mismo motor (otro driver): un PID de velocidad incremental (con doble filtro pasa-bajos, banda muerta con histéresis, Tm dinámico) y un PID de posición posicional (anti-windup, tolerancia, zona muerta de dirección). Se adaptaron al MC33926 (2 canales PWM por motor en vez de PWM+DIR) y a ESP-IDF (sin `delay()` bloqueante, PCNT en vez de ISR por software).
- **Pines y PCNT:** se mapearon los encoders a GPIO 8/9 (izq) y 10/11 (der), libres y sin conflicto con motores (4-7), Sabertooth (17), cortadora (18) ni UART0 (43/44). Se eligió PCNT hardware sobre ISR software por robustez a alta RPM (5760 cuentas/vuelta). ESP-IDF v5.2 → API nueva `driver/pulse_cnt.h`. Pull-up interno activado (los encoders resultaron push-pull, dato deducido de que el sketch Arduino usaba `pinMode INPUT` pelado sin resistencias). El componente `main` hereda todos los componentes, así que PCNT compila sin tocar CMakeLists.
- **Primera Prueba en Banco — Motor Izquierdo Muerto:**
  - Síntoma: al mandar ADELANTE, el motor derecho giraba pero el izquierdo no.
  - Telemetría: `rpm_izq=0`, `rpm_der=-53` (¡negativo yendo adelante!), `feedback` (error_rumbo) creciendo sin parar (983 → 69000+).
  - Diagnóstico: el encoder derecho cuenta invertido. Como la corrección de rumbo usa ese signo, `error_rumbo = dist_izq - dist_der` con dist_der negativo enorme → corrección descomunal → `sp_izq = base - corr` recortado a 0 → el motor izquierdo quedaba comandado a CERO. El motor izquierdo NO estaba roto; la corrección de rumbo descontrolada lo apagaba.
  - Fix de bring-up: `HEADING_KP=0` temporal para probar cada rueda aislada + se agregaron `ENC_L_SIGN/ENC_R_SIGN` configurables + clamp `HEADING_CORR_MAX` de seguridad.
- **Segunda Prueba — Signos Confirmados:** con rumbo desactivado, ambas ruedas giraron adelante; `rpm_izq=+10` (OK), `rpm_der=-10` (invertido). Se fijó `ENC_R_SIGN=-1` y se reactivó `HEADING_KP=0.02`.
- **Tercera Prueba — Recta OK:** ambas RPM positivas y parejas (~8), `error_rumbo` acotado y estable (~-19 cuentas ≈ 0.36°). Corrección de rumbo cerrando el lazo. ATRAS validado igual (ambas RPM negativas, rumbo acotado — el `dir_sign` maneja bien la reversa). Giros validados: GIRO_DER y GIRO_IZQ llegan exactos a 90° con desaceleración suave, `DONE` y vuelta a `IDLE`.
- **"Patadón" de Arranque — Diagnóstico con Telemetría a 25 ms:**
  - Recta: pico de 28 RPM con setpoint 10 (sobrepico ~180%), valle a 4, asiento en 8. Respuesta sub-amortiguada, agravada por el retardo de fase del doble filtro de RPM y el escalón instantáneo del setpoint.
  - Giros: primera muestra ya en 86 RPM (PWM 255 directo porque el error inicial es enorme).
  - **Dead-end registrado:** primer intento de slew de PWM con writeback de anti-windup (`cv1 = out·(500/255)`) — ANULÓ el PID incremental (el writeback borra el salto inicial de `kp·error` que el incremental necesita; solo quedaba el `ki` minúsculo) → la recta se arrastró a 3 RPM en vez de 10. Se quitó el writeback: el incremental no integra error sostenido (solo reacciona a cambios), así que no genera windup real.
  - Solución final: slew de PWM SIN writeback (universal, `PWM_SLEW_RATE=600`) + rampa de setpoint en recta (`RPM_ACCEL=30`). Evolución del pico: 28 → 21 (slew solo) → 16 (slew + rampa). Giros: arranque perfecto (rampa 3→14→27→...→80 en ~0.35 s en vez de slam a 86). El usuario decidió dejar el pulido fino del rebote residual y el offset de régimen para el tuning en el piso (el aire es el peor caso de oscilación).
- **Cierre:** telemetría restaurada a 200 ms, firmware v3.0 final compilado y flasheado. Modos 0-4 validados en banco. Pendiente: modo PIVOT, tuning en piso, Brain a 5 campos. (Nota operativa: el firmware solo intenta conectar al agent una vez al arranque; si el agent se reinicia hay que resetear el ESP — por eso conviene flashear y luego levantar el agent.)

- **Mejora Anti-Hipo (orden idéntica):** el usuario preguntó qué pasa si, yendo adelante sin accesorios, llega la misma orden de adelante pero prendiendo la cortadora. Diagnóstico: el callback llamaba `start_command()` siempre, reiniciando el lazo (rampa a 0, `last_pwm_signed` a 0, PID a 0, referencia de rumbo a 0) → la cortadora prendía bien pero la marcha daba un dip/hipo de ~0.3-0.5 s. Fix: en `motion_cmd_callback`, si `mode == g_mode && param == g_param && g_state == EXECUTING`, se actualizan accesorios y se sale sin reiniciar el control (solo se refresca `g_cmd_id` y se publica EXECUTING). Validado en banco: (a) reenvío idéntico sin accesorios → RPM continuas en 8; (b) adelante + cortadora ON en marcha → continuas (la primera vez no se vio el efecto físico porque el switch de alimentación de la cortadora estaba apagado; se repitió con el switch ON); (c) adelante + bordeadora ON + cortadora ON → continuas, ni siquiera la rampa anti-cogging de la bordeadora perturbó la marcha (lazos independientes). Docs y memoria actualizados.

## [03/06/26 Sesión Madrugada] - Giro por velocidad regulada + pruebas físicas en piso

- **Síntoma reportado:** al girar (desde la marcha o no), el robot "pateaba y giraba mucho al inicio" y se estabilizaba al final. Verificado con telemetría a 200 ms: el giro arrancaba a ~52 RPM y llegaba a ~80 RPM, cubriendo casi la mitad del ángulo (42° de 90) a fondo, y recién ahí frenaba bruscamente. Causa: el PID de posición (P-dominante, `POS_KP=2.5`, `POS_PWM_MAX=255`) satura el PWM mientras el error es grande → gira a la máxima velocidad posible hasta acercarse al objetivo.
- **Intento 1 (cap de PWM):** se bajó `POS_PWM_MAX` 255 → 110. Mejoró (pico 80 → 50 RPM, más uniforme) pero **el usuario advirtió un riesgo real**: capar el PWM limita el torque además de la velocidad; con carga, un tope bajo (ej. 60) podría no vencer la fricción del giro pivot y dejar el giro sin completar. Dead-end conceptual: un cap de PWM acopla velocidad y torque.
- **Solución (giro por velocidad regulada):** se reemplazó el PID de posición por control de velocidad. El giro ahora regula la VELOCIDAD de rotación con el PID de velocidad (que aplica el PWM que haga falta, hasta 255, para mantener la velocidad contra la carga), midiendo el progreso angular por el promedio de cuentas de ambas ruedas, con perfil trapezoidal: rampa de arranque (`RPM_ACCEL`), crucero `GIRO_RPM=20`, taper de desaceleración en los últimos `GIRO_DECEL_DEG=12` hasta `GIRO_RPM_MIN=5`, y freno al llegar a `GIRO_TOL_DEG=1`. Se eliminó `pos_pid_step` y los campos/defines de posición (`POS_*`, `pos_integral`, `pos_error_prev`, `target_deg`, `pos_done`). Se agregó `g_giro_dir_l/r`, `g_feedback` (limpia el cálculo de feedback del status). Resultado en banco: arranque suave, crucero parejo ~15 RPM, desaceleración progresiva, aterrizaje exacto en el ángulo; simétrico izq/der.
- **Análisis de tiempos (telemetría con timestamps):** cadencia de status ~230 ms. Latencia comando→ACK por `ros2 topic pub --once` ≈ 0.87 s constante (el CLI crea un nodo y hace discovery en cada invocación). Con nodo persistente (rclpy, /tmp/seq.py) la latencia baja a ~20-30 ms. Se demostró que el "hueco" de varios segundos entre el giro y el atrás era doble artefacto: (1) `sleep` fijo del script de prueba mayor que la duración real del giro, y (2) latencia del CLI. Reaccionando al feedback `estado=3` (DONE) con nodo persistente, las secuencias encadenan sin huecos (atrás arranca en el mismo instante que llega el DONE del giro). Un giro de 90° tarda ~3.5 s sin carga.
- **Pruebas físicas en piso CON CARGA (scripts rclpy persistentes /tmp/fwd.py, giro.py, back.py, fwdback.py):**
  - Adelante 10 RPM / 1.5 s y 15 RPM / 3 s: el robot avanza; las RPM quedan por debajo del setpoint (10-11 con 15 pedido) → offset por `VEL_KI` bajo. El `error_rumbo` deriva a ~+40 cuentas (~0.8°, curva leve a la derecha) → `HEADING_KP=0.02` débil para cerrar bajo carga.
  - Giro 90° izq y der: completan el ángulo bajo carga (correcto a ojo en ambos sentidos), perfil trapezoidal limpio, ~4.3 s c/u. Confirma que el giro por velocidad SÍ aplica torque suficiente bajo carga (la preocupación del usuario quedó resuelta).
  - Atrás 15 RPM / 3 s: retrocede parejo (~-11/-13 RPM), rumbo más oscilante que adelante pero acotado (±35 cuentas).
  - Adelante 3 s + atrás 3 s de corrido: inversión de sentido suave (sin tirón, slew), vuelve cerca del punto de partida; la deriva de rumbo es de signo opuesto adelante vs atrás (misma asimetría mecánica real).
  - Usuario conforme con el comportamiento general. Tuning fino (subir `VEL_KI` y `HEADING_KP`) queda pendiente, no bloqueante.
- **Cierre de sesión.** Docs (`00`, `01`, `02`, `arquitectura.md`) y memoria actualizados.

## [08/06/26 Sesión Tarde] - Firmware motor v3.2: implementación del modo PIVOT (5)

> Registro retroactivo, reconstruido el 28/10/26 desde el código de `active/`, `git diff` y fechas de archivos. En su momento no se registró en `docs/`.

- **Objetivo:** reemplazar el placeholder de `MODE_PIVOT` (que hacía STOP por seguridad) por una secuencia automática de cambio de franja.
- **Archivos modificados:** `firmware/esp32_motor/active/active/main/main.c` (v3.0 → v3.2, guardado 08/06/26 14:53) y `CLAUDE.md` (protocolo PIVOT, 15:20).
- **Secuencia implementada** (`enum PivotStep`, sub-estado `g_pivot_step`):
  1. `start_command`: fuerza accesorios ON (`target_trimmer_state = 1`, `CORTADORA_ENABLE_PIN` en HIGH) sin importar lo que mande el Brain; arranca en `PIVOT_STEP_ADELANTE` con estado `EXECUTING`.
  2. **Adelante** `param` cm (`param=0` → `PIVOT_ADELANTE_DIST_DEFAULT = 0.30 m`) a `PIVOT_RPM = 30`. La distancia sale del promedio de cuentas de ambas ruedas (`CUENTAS_POR_METRO = CPR_OUT / (2π·R)`). Desacelera de forma lineal en los últimos `PIVOT_DECEL_DIST_M = 0.05 m` hasta `GIRO_RPM_MIN`. Reusa la rampa (`RPM_ACCEL`), la corrección de rumbo (`HEADING_KP`, clamp `HEADING_CORR_MAX`), el PID de velocidad y el slew de la recta.
  3. **Atrás** `PIVOT_ATRAS_DIST_M = 0.28 m` fijo, mismo control con PWM negado.
  4. **Swing** `PIVOT_GIRO_DEG = 90°` a la izquierda: rueda izquierda con PWM 0; solo la derecha avanza con el PID de velocidad a `GIRO_RPM`, con el taper `GIRO_DECEL_DEG`/`GIRO_RPM_MIN`. El progreso se calcula como cuentas de la rueda derecha / `CUENTAS_POR_GRADO_SWING` (radio = L completo → el doble que en el pivot). Termina en `GIRO_TOL_DEG`, publica `STATE_DONE` con feedback 90 y vuelve a `IDLE`.
  - Entre fases: `stop_all_motors()`, re-referencia de cuentas, `reset_wheel_ctrl` en ambas ruedas y `g_base_ramp = 0`.
- **Justificación geométrica de los 28 cm de retroceso:** H = 40 cm (eje → frente), L = 50 cm. Al girar 90° sobre la rueda izquierda, la esquina delantera derecha traza un arco de radio √(50² + 40²) ≈ 64 cm → d_min = 64 − 40 = 24 cm para no invadir el borde; se agregan 4 cm de margen.
- **Feedback en `motion_status`:** en las fases lineales = error de rumbo (cuentas izq − der); en el swing = grados completados.
- **Build:** el `build/int32_publisher.bin` del motor tiene fecha 08/06/26 14:53 (el mismo minuto que `main.c`) → compilado.
- **Validación:** según la memoria de trabajo de la sesión del 08/06, el PIVOT se **validó en físico**: publicó `STATE_DONE` con feedback = 90° y la secuencia completa se observó en `/motion_status`. El encabezado del firmware dice "Ultima verificacion: 08/06/2026". No quedó telemetría guardada, ni mediciones de las distancias reales (30/28 cm), ni constancia de si fue en banco o en piso con carga.

## [27/10/26 Sesión Noche] - Firmware sensor v6.2: `/sensores` ampliado a 24 valores (E7 APP Android, fase 1)

> Registro retroactivo, reconstruido el 28/10/26 desde `git diff`, fechas de archivos y el resumen de cierre de la sesión del 27/10.

- **Contexto E7:** APP Android (Flutter) ↔ Bluetooth ↔ ESP32 sensor → micro-ROS → Raspberry Pi 5. Requisitos: control manual (velocidad, cortadora, bordeadora, stop), iniciar/detener el modo autónomo, GPS en mapa offline y área de trabajo como polígono. La Raspberry conserva la autoridad final sobre movimiento y herramientas.
- **Relevamiento del firmware sensor:** ESP32 clásico (target `esp32`), 2 MB de flash, partición de app de 1 MB, soporta BT Classic y BLE. micro-ROS (`app-colcon.meta`): `MAX_PUBLISHERS=4` (se usa 1), `MAX_SUBSCRIPTIONS=0`, `MAX_HISTORY=8`. Tareas: Core 0 con ultrasonidos y GPS (UART2 9600, GPIO 16/17); Core 1 con bumpers, IMU y micro-ROS; un solo mutex compartido.
- **Backup previo:** `firmware/esp32_sensor/versions/2026_10_27_MainV6.1_pre_app.c.bak` (23:53). El 28/10 se verificó que es idéntico al `main.c` v6.1 del último commit.
- **Archivos modificados:** `firmware/esp32_sensor/active/active/main/main.c` (v6.1 → v6.2, 23:54) y `docs/arquitectura.md` (tabla de índices 13–23, 23:54).
- **Cambios:**
  - `SENSORES_SIZE` 13 → 24. Índices nuevos: 13 `gps_sats` (−1 sin dato), 14 `gps_hdop` (−1 sin dato), 15 `app_connected`, 16 `app_state` (0 STOP, 1 MANUAL, 2 AUTO_RUN, 3 AUTO_PAUSE), 17 `app_dir` (0 nada, 1 adelante, 2 atrás, 3 izq, 4 der), 18 `app_speed` (0–100 %), 19 `app_cutter`, 20 `app_trimmer`, 21 `app_seq` (0–65535), 22 `app_cmd_age_ms` (−1 = nunca llegó comando), 23 `app_polygon_id` (0 = ninguno).
  - GPS: `parse_gga_line` ahora extrae satélites (campo 7) y HDOP (campo 8). Se publican con el mismo criterio de dato viejo que `gps_fix` (−1 si tiene más de 3 s).
  - **Bug corregido en el parser GGA:** `strtok_r` saltea los campos vacíos (`,,`) y corre los índices; pasa por ejemplo con una GGA sin fix, que trae lat/lon vacíos. Se reemplazó por separación manual con `strpbrk(token, ",*")`, que respeta los campos vacíos y corta en el `*` del checksum. Según el resumen de la sesión, se probó en la PC con tramas con fix, sin fix y vacía: OK.
  - **Seguridad APP:** `APP_CMD_TIMEOUT_US = 300 ms`. En `micro_ros_task`, si `app_connected = 0`, si nunca llegó comando o si el último tiene más de 300 ms → `app_dir`, `app_cutter` y `app_trimmer` se publican en 0.
  - Las variables `g_app_*` quedan en sus valores por defecto: **la tarea Bluetooth todavía no está implementada.**
- **Compatibilidad con el Brain:** `sensores_callback` en `bumper_decision_node.py` solo exige `len(data) >= 3` y usa los índices 0–2 → acepta 24 valores sin cambios.
- **Build:** `build_sensor.sh` OK, binario de 285 KB (73 % libre en la partición de 1 MB), con fecha 27/10/26 23:54.
- **Diseño acordado para las fases siguientes (sin implementar):** la APP manda el comando a 10 Hz mientras está conectada (dir=0 si no se aprieta nada); watchdog en la Raspberry (MANUAL y age > 300 ms o desconectado → STOP); botones discretos que mapean a los modos de `motion_cmd`, con giro continuo por reenvío de GIRO ~15° y STOP al soltar. Área de trabajo: máximo 10 vértices int32 en 1e-7°, JSON por línea `{"t":"POLY","id":N,"p":[[lat,lon],...]}` → `POK`/`PERR`, `PCLR` para borrar; el ESP usa doble buffer y publica `/app/working_area` (Int32MultiArray `[id, n, lat0, lon0, ...]`) cada ~2 s. En la Raspberry, nodo nuevo `working_area_node` (no se toca `bumper_decision_node`): valida la geometría, guarda en JSON, convierte a metros locales con margen de 1–2 m, y sin polígono válido no hay AUTO_RUN.
- **Pendiente:** flashear y verificar con `ros2 topic echo /sensores`. Sin APP, los índices 15–23 tienen que dar `0, 0, 0, 0, 0, 0, 0, -1, 0`. Verificar también que el Brain sigue reaccionando a los bumpers.

## [28/10/26 Sesión Madrugada] - Puesta al día de docs/ y corrección de topics del sensor

- **Objetivo:** cumplir el SOP §7. Al revisar `docs/` se encontró que la última entrada era del 03/06/26 y que había dos trabajos sin registrar (motor v3.2 del 08/06 y sensor v6.2 del 27/10); se registraron arriba.
- **Discrepancia de topics verificada:** el firmware sensor activo crea un único publisher (`rclc_publisher_init_default(..., "sensores")` → QoS **reliable**, 50 ms). No publica `/bumpers`, `/ultrasonicos_cm`, `/gps_fix` ni `/imu/data_raw`, que seguían listados en `CLAUDE.md` y en `SOP_Seguimiento_Y_Operacion.md` §4 como best_effort. El Brain se suscribe a `sensores` con `BEST_EFFORT`; publisher reliable + suscriptor best_effort es compatible en DDS, así que funciona.
- **Corrección:** se actualizaron `CLAUDE.md` (tabla Sensor → Brain y ejemplo de `ros2 topic echo`) y el SOP §4 al topic único `/sensores` de 24 valores.
- **Corrección en `00_estado_actual.md`:** decía que el Brain envía el protocolo viejo de 8 campos; en realidad `bumper_decision_node.py:137` publica **7** (`[cmd_id, l_dir, l_pwm, r_dir, r_pwm, duration_ms, bordeadora_on]`, sin `cortadora_on`).
- **No modificados (quedan con los topics viejos):** `README.md` (secciones "Observar/Medir frecuencia de /ultrasonicos_cm" e "/imu/data_raw") y `firmware/esp32_sensor/README.md` (sección "Publica").
- **Documento de diseño E7:** el diseño de la APP estaba repartido en la entrada del 27/10 (append-only, no se puede actualizar) y faltaban varios puntos: UI del editor de área, enclavamientos de herramientas por roll/pitch, que el ESP valida solo integridad, ausencia de canal de retorno, entorno Flutter y formato exacto de `POK`. Se creó `docs/e7_app_android.md` como documento vivo que concentra todo el diseño; `00_estado_actual.md` lo enlaza.
- **Observación técnica para la fase 4 (giro continuo):** el diseño prevé reenviar GIRO ~15° mientras se mantiene apretado el botón. El anti-hipo del motor (`main.c:1055`: `mode == g_mode && param == g_param && g_state == STATE_EXECUTING` → solo actualiza accesorios y sale) hace que un reenvío idéntico durante el giro **no lo extienda**. El giro completa sus 15°, desacelerando en los últimos `GIRO_DECEL_DEG = 12°`, para, y el siguiente reenvío arranca otro desde cero → giro a tirones. Queda como decisión pendiente #5 en `e7_app_android.md`.

## [28/10/26 Sesión Madrugada] - Cambio de motores de tracción (sin encoder) y documento de componentes

- **Hallazgo informado por el usuario:** los motores de tracción nuevos son **Pololu 37Dx57L mm 12 V 100:1 sin encoder**.
- **Impacto verificado en el código:** el firmware del motor v3.0–v3.2 usa los encoders (PCNT, GPIO 8–11, `ENC_R_SIGN=-1`, `CPR_OUT = 16×4×90 = 5760`) para el PID de velocidad de cada rueda, la corrección de rumbo, el ángulo de GIRO_IZQ/GIRO_DER, las distancias del PIVOT y los campos `rpm_izq`, `rpm_der` y `feedback` de `/motion_status`. Sin encoders, todo eso queda sin realimentación. Los backups en `versions/` y el snapshot de abril no usan encoders (lazo abierto con PWM + `T_ms` desde el Brain).
- **Datos del motor nuevo (Pololu #4745, consultado en pololu.com):** 100 rpm sin carga, 0,2 A sin carga, 5,5 A de bloqueo y 34 kg·cm de torque de bloqueo (extrapolados), carga continua recomendada ≤10 kg·cm, reducción exacta ≈102,083:1, eje de 6 mm. La página no menciona eje trasero extendido. Versión equivalente con encoder: **#4755** (37Dx73L, 64 CPR en el eje del motor → ≈6533 cuentas por vuelta de salida). Usa el mismo esquema de cuentas que el firmware (`CPR_MOTOR × QUAD_X4 = 64`), así que con #4755 solo cambiaría `GEAR` 90 → 102,083.
- **Alternativas sin encoders evaluadas (sin decidir):** (B) un IMU en el ESP32-S3 del motor (rumbo y giros en lazo cerrado; velocidad y distancias por tiempo); (C) el Brain cierra el lazo con el yaw de `/sensores`. Limitaciones: dos saltos de micro-ROS, cambio de protocolo, y el yaw actual sale de integrar `gz` (`main.c:678` del sensor; el MPU-6500 no tiene magnetómetro → deriva). (D) lazo abierto puro. Descartado: estimar la velocidad por corriente o back-EMF (el firmware no lee el pin FB del MC33926, y es impreciso). El GPS no sirve para distancias de 30 cm.
- **Documentación de componentes:** el usuario pasó la lista oficial de componentes y su justificación. Se creó `docs/componentes.md` (lista, justificación, estado de integración, observaciones técnicas y discrepancias) y `Datasheet/Motor_traccion_Pololu_37D.txt`, con el mismo formato que las fichas existentes.
- **Correcciones al texto del usuario:** el HANPOSE 775 figuraba como "sin escobillas"; es con escobillas (`Datasheet/Motor_bordeadora.txt`, y el Sabertooth es un driver para motores con escobillas). En el CBE-12A1C, "8A de voltaje pico" se interpretó como 8 A pico de corriente.
- **Discrepancias detectadas (a confirmar con el usuario):**
  1. IMU LSM9DS1 en la lista frente a MPU-6500 en el firmware.
  2. GPS UP-501 frente a FSTR2.
  3. 4 finales de carrera frente a 3 en el firmware (GPIO 18/22/19).
  4. Sensor ESP32 clásico frente a "ESP32-S3" en la justificación.
  5. Powerbank "12mAh".
  6. Corriente del CBE-12A1C: 4 A continuos / 8 A pico en la justificación, frente a la referencia B12A6 de `Datasheet/Motor_brushless.txt`.
  7. Árbol de alimentación: una LiPo 4S (≤16,8 V) no llega a los 20 V mínimos del CBE-12A1C, y dos en serie (≤33,6 V) superan los 28 V del MC33926.
- **Otros:** se corrigió en `arquitectura.md` la tabla de tareas, que todavía decía "13 valores" en `micro_ros_task` (ahora 24). `00_estado_actual.md` marca el cambio de motores como bloqueo.
- **Respuestas del usuario a las discrepancias (28/10/26):**
  1. Hay **2 IMU**: MPU-6500 (integrado) y LSM9DS1 (de 9 ejes, objetivo del proyecto; no integrado).
  2. El GPS real es el **FSTR2**; se corrigió la lista (decía UP-501).
  3. Hoy hay 3 finales de carrera; se agregará un 4.º.
  4. Se confirma: sensor = ESP32 clásico, motor = ESP32-S3. El usuario propone analizar intercambiarlos porque el sensor tendrá Bluetooth.
  5. Powerbank de 12 000 mAh.
  6. CBE-12A1C: valen los datos de la justificación (20–60 VDC, 8 A pico, 4 A continuos, 230 W @ 60 VDC).
  7. Árbol de alimentación: 2 LiPo 4S en serie (8S). El 8S alimenta el CBE-12A1C y el LM2596 (5 V para los HC-SR04 y el LSM9DS1). La batería inferior 4S (GND general) alimenta el Sabertooth y el MC33926. El powerbank alimenta la Pi 5, y de ella cuelgan los 2 ESP32 por USB, el LiDAR, la cámara y el GPS (vía ESP32). Autonomía estimada por el equipo: 11,4 min a máxima exigencia y 19 min en operación normal.
- **Verificación de compatibilidad eléctrica** (rangos 4S = 13,2–16,8 V, 8S = 26,4–33,6 V):
  - OK: CBE-12A1C, LM2596 (con poco margen respecto de 40 V; revisar los capacitores de entrada del módulo), Sabertooth y MC33926.
  - Observaciones:
    - **Tracción:** el PWM del firmware llega a 255 → el motor de 12 V puede ver hasta 16,8 V, y la corriente de bloqueo sube a ≈7,7 A contra 5 A pico del MC33926. Sugerencia: limitar el PWM a ≈180/255.
    - **Bordeadora:** hoy limitada a ~33 % por `TRIMMER_SPEED_MAX = 85`.
    - **HC-SR04:** el ECHO sale a 5 V y el ESP32 no lo tolera → verificar divisor.
    - **LSM9DS1:** el chip trabaja a 1,9–3,6 V → a 5 V solo sirve si la placa trae regulador y conversión de nivel.
    - **Raspberry Pi 5:** con una fuente de 3 A limita los USB a 600 mA en total.
    - El MPU-6500 no figura en el árbol de alimentación.
    - Riesgo de desbalance de baterías: medir cada una por separado. Verificar GND común entre el powerbank y las baterías en los 3 drivers.
- **Análisis preliminar del intercambio de ESP32** (datos de `sdkconfig`: sensor `esp32`/2 MB, motor `esp32s3`/8 MB):
  - El S3 solo tiene BLE, sin Classic/SPP → con SPP no conviene intercambiar.
  - El intercambio obliga a remapear pines en ambos firmwares: en el clásico, GPIO 6–11 son de la flash (el motor usa 6–11); en el S3 no existen 22–25, 26–32 son de la flash/PSRAM y 19/20 son el USB nativo (el sensor usa 19, 22, 23, 25, 26, 27, 32).
  - Si se intercambia, conviene hacerlo ahora, aprovechando que el firmware del motor ya tiene que revalidarse. Alternativa: un segundo ESP32-S3 para el sensor.
- **Archivos:** se reescribió `docs/componentes.md`: lista corregida, §3 árbol de alimentación, §4 compatibilidad, §5 intercambio de ESP32, §6 pendientes. También se actualizaron `00_estado_actual.md` y la decisión 1 de `e7_app_android.md`.
- **Seguimiento de la verificación eléctrica (respuestas del usuario):**
  1. **HC-SR04:** los ECHO ya tienen divisor resistivo a 3,3 V antes del ESP32 → resuelto.
  2. **LSM9DS1:** el usuario mandó fotos de la placa: **SparkFun LSM9DS1 Breakout**, con la serigrafía posterior "1.9-3.6V". No tiene regulador ni conversor de nivel (frente: chip, resistencias y jumpers). Conclusión: **no puede ir a la línea de 5 V del LM2596**, como figuraba en el árbol de alimentación; se alimenta desde el 3V3 del ESP32. Los pull-ups de I2C de la placa (jumper "I2C PU") van a VDD, así que a 3,3 V SDA/SCL son compatibles directamente con el ESP32 clásico y con el S3. Direcciones impresas en la placa: SDO=0 → M 0x1C / AG 0x6A; SDO=1 → M 0x1E / AG 0x6B (estado de los jumpers a confirmar con un escaneo I2C). No hay conflicto con el MPU-6500 (`MPU_ADDR = 0x69` en el firmware del sensor; bus GPIO 21/23 a 100 kHz) → pueden compartir el bus.
  3. **Capacitores del LM2596:** el usuario asume el riesgo sin verificarlos.
  4. **Límite de PWM de la tracción ≈180/255:** aprobado; se aplica en el rediseño del firmware del motor.
  5. **Consumo USB de la Pi 5:** se va a medir.
  6. **Monitoreo por batería:** aprobado.
- **Archivos:** nueva ficha `Datasheet/IMU_LSM9DS1_SparkFun.txt`. En `docs/componentes.md` se corrigió el árbol (LSM9DS1 al 3V3) y se actualizaron §4 y §6. También se actualizó `00_estado_actual.md`.
- **Decisión del usuario:** el LSM9DS1 se alimenta desde el **pin 3V3 del ESP32**, que el equipo usa como su línea de 3,3 V. Su consumo es de pocos mA, despreciable para el regulador de la placa ESP32. Falta definir si va en el ESP32 del sensor o en el del motor (depende de la estrategia para la tracción sin encoder).
- **Decisión del usuario:** se **descarta** la versión del Pololu con encoder (#4755) porque es casi imposible de conseguir. La tracción queda definitivamente **sin encoders**.
- **Estrategia propuesta (pendiente de confirmación):** LSM9DS1 en el ESP32 motor (S3), por I2C en los GPIO 8/9, que quedan libres al sacar los encoders.
  - Rumbo y giros en lazo cerrado local con el **giróscopo**.
  - Magnetómetro solo como corrección lenta, si resiste la interferencia de los motores.
  - Velocidad en lazo abierto con modelo calibrado (opcional: compensar la tensión de la batería 4S con ADC1 en GPIO 10).
  - Distancias del PIVOT por tiempo a velocidad calibrada.
  - PWM máximo de 180/255.
  - Protocolo de 5 campos sin cambios.
  - Descartado: integrar dos veces el acelerómetro para estimar distancia (deriva).
- **Ubicación física del LSM9DS1:** el usuario planteó que el punto ideal (entre los dos Pololu) está cerca del motor brushless de la cortadora.
  - **Análisis:** el giróscopo mide la velocidad angular del cuerpo rígido, que es la misma en cualquier punto del chasis → no necesita estar en el centro de giro. La aceleración centrípeta fuera del centro (~0,4 rad/s, r = 0,2 m → ~0,03 m/s²) es despreciable para roll y pitch.
  - Lo que importa: orientación (Z vertical, X hacia adelante) y montaje rígido.
  - El magnetómetro sí es sensible al brushless (imanes y corriente variable según la carga, no calibrable como desvío fijo; campo terrestre débil en Paraguay, ~23 µT; la interferencia cae con 1/r³).
  - **Recomendación:** alejarlo del brushless lo más posible, con tornillos y separadores no magnéticos y un cable I2C corto, trenzado con GND y alejado de la potencia. Elegir el lugar midiendo la intensidad del campo con la cortadora prendida y apagada. Si el magnetómetro sale perturbado en todos lados, el control se apoya solo en el giróscopo.
- **Decisión del usuario:** el **LSM9DS1 va en el ESP32 motor** (control de rumbo y giros), alejado lo más posible del brushless. El **MPU-6500 se queda en el ESP32 sensor** como verificación de orientación para la Raspberry. Son dos buses I2C distintos.
- **Pregunta del usuario: ¿alcanza para que el robot vaya recto?** Análisis:
  - El lazo de rumbo con giróscopo compensa las diferencias entre motores, la fricción y el terreno.
  - A diferencia de los encoders, mide la rotación real del cuerpo y no lo engaña el patinamiento de las ruedas en el pasto.
  - Límite principal: la deriva lenta del bias del giróscopo, que se mitiga con calibración en reposo al arrancar, recalibración automática cada vez que el robot está detenido y, si el montaje lo permite, corrección lenta con el magnetómetro.
  - Ninguna cifra se midió todavía. Antes de reescribir el control se propone un experimento: medir la deriva con el robot quieto durante 5 min y la desviación lateral en una recta de 10 m.
- **Asignación de ESP32 (propuesta, pendiente de confirmación):** según los `sdkconfig`, hoy el motor es `esp32s3` (8 MB) y el sensor es `esp32` (2 MB).
  - **Propuesta:** intercambiarlos. El S3 pasa a sensores, porque Bluetooth + micro-ROS + JSON y polígono de la APP necesitan memoria. El clásico pasa a motores, que sin encoders solo necesita LEDC, UART, I2C y ADC.
  - **Justificación del momento:** ambos firmwares se reescriben igual (motor v4.0 con IMU; sensor con Bluetooth en la fase 2 de la E7).
  - **Implica:** BLE obligatorio, y los puertos pasan a sensor `/dev/ttyACM0` y motor `/dev/ttyUSB0`.
  - El usuario indica que el cableado está en protoboard (cambio físico sencillo) y que prefiere conservar la misma disposición de pines; lo confirma al retomar.
  - **Restricción técnica informada:** no se pueden conservar todos los pines.
    - En el ESP32-S3-WROOM-1 no están disponibles los GPIO 22, 23, 25, 26, 27, 32 ni 33 (los usa el sensor), y el 19 es el USB D−.
    - En el clásico, los GPIO 6 y 7 son de la flash SPI (los usa el motor) y el 5 emite PWM al arrancar, lo que haría patear las ruedas.
- **Cierre de sesión.** `docs/00_estado_actual.md` tiene una sección "Para retomar" con los 4 pasos pendientes: confirmar el intercambio y los pines, confirmar la estrategia del motor, hacer el respaldo de la v3.2 con la prueba aislada del LSM9DS1, y flashear el sensor según lo que se decida.

## [02/11/26 Sesión Madrugada] - Intercambio de ESP32 confirmado y mapa de pines

- **Objetivo:** verificar todos los pines de ambos ESP32 y armar el listado de conexiones para el intercambio: S3 → sensores, clásico → motores.
- **Verificación previa (código frente a docs):** los `#define` de `firmware/esp32_sensor/active/active/main/main.c` (bumpers 18/22/19; TRIG/ECHO 25/32, 26/27, 33/35; GPS UART2 TX 17 / RX 16; I2C 21/23) y de `firmware/esp32_motor/active/active/main/main.c` (LEDC 4–7; PCNT 8–11; Sabertooth UART2 TX 17; cortadora 18) coinciden con las tablas de `docs/arquitectura.md`.
- **Datos de los `sdkconfig`:**
  - Sensor: `esp32`, 2 MB, sin `CONFIG_SPIRAM`.
  - Motor: `esp32s3`, 8 MB.
  - Ambos: `CONFIG_MICROROS_UART_TXD/RXD = -1` → micro-ROS en los pines por defecto del UART0 (clásico 1/3, S3 43/44 → CH343 → conector COM). No hay que cambiar el transporte.
- **Bumpers:** pull-up interno; el firmware toma `gpio_get_level == 0` como presionado → contacto normalmente abierto entre el GPIO y GND.
- **Criterios de selección:**
  - **S3:**
    - Strapping: 0, 3, 45 y 46.
    - USB nativo: 19 y 20. UART0/COM: 43 y 44.
    - El WROOM-1 no tiene GPIO 22–34.
    - 35–37 solo están libres con PSRAM quad (N8R2).
    - 38/48: LED RGB en algunas placas.
  - **Clásico:**
    - Flash: 6–11.
    - Strapping: 0, 2, 5, 12 y 15. El 5, el 14 y el 15 sacan PWM al arrancar (tirón de ruedas en el MC33926).
    - 34–39: solo entrada.
    - En WROVER, el 16 y el 17 los usa la PSRAM.
  - **BLE:** no ocupa GPIO; el único conflicto conocido es ADC2 con Wi-Fi (no se usa).
- **Primera propuesta (S3):** bumpers 4–7, ultrasónicos 9–14, GPS 16/17, I2C 8/18. El usuario la cambió por su propia elección:
  - Ultrasónico der.: TRIG 17 / ECHO 15. Izq.: TRIG 18 / ECHO 16. Centro: TRIG 8 / ECHO 3.
  - Bumpers: der. 37, centro 2, izq. 38.
- **Verificación de la elección del usuario:**
  - ✅ 17, 15, 18, 16, 8 y 2. El 2 no es strapping en el S3; sí lo es en el clásico.
  - ✅ 37, condicionado a que el módulo sea N8R2.
  - ✅ 38, con la advertencia del LED RGB.
  - ⛔ **3:** strapping (fuente del JTAG; solo pesa con el eFuse `STRAP_JTAG_SEL` quemado, pero se descartó por el criterio del usuario).
  - Los ultrasónicos ocupan 16/17 (GPS) y 8/18 (I2C propuesto) → se reubicaron.
- **Dead-end:** el usuario propuso el **GPIO 46** para el ECHO del centro. Se descartó: es strapping del modo de arranque junto con el GPIO 0. Con el GPIO 0 en LOW (auto-reset para flashear) y el 46 en HIGH, la combinación es inválida y no entra en modo descarga. Si el HC-SR04 dispara durante el reset, el ECHO puede estar en HIGH → flasheos que fallan de forma intermitente.
- **Mapa final acordado del S3 (sensores):**
  - Ultrasónicos (TRIG/ECHO): der. 17/15, izq. 18/16, centro 8/**9**. El usuario eligió el 9 para el ECHO del centro.
  - Bumpers: izq. 38, centro 2, der. 37; 4.º reservado en 36.
  - GPS: RX 4 (← TX del GPS), TX 5 (→ RX del GPS).
  - I2C (MPU-6500): SDA 6, SCL 7.
  - Reservas ADC1 para baterías: 1 y 10.
- **Mapa del clásico (motores), sin cambios pedidos por el usuario:**
  - MC33926: M1IN1 32, M1IN2 33, M2IN1 25, M2IN2 26 (no sacan pulsos al arrancar y quedan juntos en el header).
  - Sabertooth S1: 17. CBE P1-9: 18.
  - LSM9DS1: SDA 21, SCL 22.
  - Reservas: 34/35 para M1FB/M2FB (opcional).
  - Se eliminan los encoders.
- **Verificaciones físicas pendientes antes de cablear:**
  1. El módulo S3 dice N8R2.
  2. Pin del LED RGB de la placa S3 (38 o 48).
  3. El módulo clásico dice WROOM (no WROVER).
  4. Qué hace el INHIBIT̄ del CBE-12A1C con el pin flotante (riesgo de que la cortadora arranque durante un flasheo; si hace falta, un pull-down dimensionado para su pull interno).
  5. Jumpers SDO del LSM9DS1 (se confirman con un escaneo I2C).
- **Consecuencia:** el Bluetooth de la E7 queda en **BLE** (el S3 no tiene Classic/SPP).
- **Archivos:**
  - Nuevo contenido en `docs/pines.md` (estaba vacío).
  - Notas de intercambio en `docs/arquitectura.md` (las dos tablas de pines siguen describiendo el firmware actual).
  - `docs/componentes.md`: §1, §5 y §6.
  - `docs/e7_app_android.md`: §2, §9 fase 2 y §10 decisión 1.
  - `docs/00_estado_actual.md`.
  - **Sin cambios de firmware.**

## [02/11/26 Sesión Madrugada] - IMU de respaldo y firmware de prueba del LSM9DS1

- **IMU disponibles (informado por el usuario):**
  1. Placa del ESP32 sensor, serigrafía "MPU-9250/6500". Chip marcado "767LA1 / L1605", **sin la línea de modelo** ("MP65"/"MP92") → por la marca no se puede saber si es 6500 o 9250. El firmware nunca lee WHO_AM_I ni el magnetómetro (verificado con grep en `main.c` del sensor: sin `0x75`, `0x0C` ni bypass). El usuario cree que es de 6 ejes; sin evidencia.
  2. LSM9DS1 (SparkFun), el previsto para el ESP32 motor.
  3. Placa de otro proyecto, serigrafía "MPU-9250/6500/9255". Chip marcado "MP92 / U601A1 / 2048", con el formato de InvenSense para el MPU-9250 (lote, fecha 2020-semana 48). Puede ser stock tardío o un clon, porque el 9250 está discontinuado y los clones copian la marca. **Decisión del usuario:** queda como **respaldo** si el LSM9DS1 no funciona.
- **Diferencia técnica explicada:**
  - El MPU-9250 y el MPU-9255 son un MPU-6500 más el magnetómetro AK8963 en el mismo encapsulado: acelerómetro y giróscopo idénticos.
  - WHO_AM_I (0x75): 6500 = `0x70`, 9250 = `0x71`, 9255 = `0x73`. El AK8963 aparece en `0x0C` con bypass (`0x37` = `0x02`) y su ID (reg `0x00`) = `0x48`.
  - Procedimiento propuesto con `i2c-tools` en la Raspberry; no se ejecutó.
- **Ventaja del respaldo:** mismo cableado (3V3, SDA 21, SCL 22). Sus direcciones (`0x68`/`0x69`, `0x0C`) no chocan con las del LSM9DS1, y los registros de acelerómetro y giróscopo son los que ya lee el firmware del sensor.
- **Firmware de prueba del LSM9DS1:**
  - **Ubicación:** `firmware/esp32_motor/test_lsm9ds1/` (`CMakeLists.txt`, `sdkconfig.defaults`, `main/test_lsm9ds1.c`). Sigue el precedente de `test_s3_motor/`: proyecto aislado que no toca `active/`.
  - **Scripts:** `scripts/pc/build_test_lsm9ds1.sh` (`set-target esp32` + build), `flash_test_lsm9ds1.sh` y `monitor_test_lsm9ds1.sh` (puerto por defecto `/dev/ttyUSB0`). Se agregaron a `scripts/pc/README.md`.
  - **Sin micro-ROS:** imprime por UART0 para verlo con el monitor. Driver I2C legado (`driver/i2c.h`), como el firmware del sensor. I2C a 100 kHz en los GPIO 21/22 (mapa del motor, `pines.md` §2).
  - **`sdkconfig.defaults`:** `CONFIG_FREERTOS_HZ=1000` (para sondear cada 2 ms) y `CONFIG_ESP_MAIN_TASK_STACK_SIZE=6144` (printf con floats).
  - **Detección:** escaneo del bus 0x08–0x77; busca AG en `0x6B`/`0x6A` (WHO_AM_I `0x0F` = `0x68`) y M en `0x1E`/`0x1C` (WHO_AM_I `0x0F` = `0x3D`). Si falla, reintenta cada 3 s.
  - **Reset y configuración:** reset por software (`CTRL_REG8` = `0x05`; `CTRL_REG2_M` = `0x0C`) y configuración con relectura de cada registro:
    - AG: `CTRL_REG8` = `0x44` (BDU + IF_ADD_INC); `CTRL_REG1_G` = `0x60` (119 Hz, 245 dps); `CTRL_REG4` y `CTRL_REG5_XL` = `0x38`; `CTRL_REG6_XL` = `0x70` (±4 g).
    - M: `CTRL_REG1_M` = `0xF4` (compensación de temperatura, XY ultra alto rendimiento, 20 Hz); `CTRL_REG2_M` = `0x00` (±4 gauss); `CTRL_REG3_M` = `0x00` (continuo); `CTRL_REG4_M` = `0x0C`; `CTRL_REG5_M` = `0x40` (BDU).
    - Lectura multibyte del magnetómetro con el MSB de la subdirección en 1 (`0x28 | 0x80`).
  - **Sensibilidades:** 8,75 mdps/LSB, 0,122 mg/LSB y 0,014 µT/LSB. Temperatura = raw/16 + 25 °C (aproximada).
  - **Calibración:** 3 s quieto → bias y ruido RMS del giróscopo por eje, y `|A|` en reposo (OK entre 0,95 y 1,05 g).
  - **Deriva:** integra gz sin bias con el dt real de `esp_timer` en cada muestra nueva (bit GDA). Imprime una línea por segundo (giro medio, acel, mag, `|B|`, temperatura, yaw) y un resumen por minuto (deriva del minuto, yaw total, `|B|` mín/máx, errores I2C). A los 300 s imprime el resultado y sigue midiendo.
  - **Compilación:** `build_test_lsm9ds1.sh` OK, sin warnings. Binario de 0x32360 bytes (80 % libre en la partición de 1 MB). `sdkconfig` generado: `esp32`, 2 MB, `FREERTOS_HZ=1000`.
  - **No se flasheó ni se probó en hardware.**
- **Advertencia de seguridad registrada:** para la prueba de interferencia, los accesorios se prenden con la v3.2 del S3 en modo STOP (`[id, 0, 0, bordeadora, cortadora]`). No mandar ADELANTE/ATRAS/GIRO/PIVOT con la v3.2 sin encoders: el PID mide 0 RPM y satura el PWM.
- **Archivos:** `docs/pruebas.md` (estaba vacío: procedimiento, criterios y tabla de resultados) y `docs/00_estado_actual.md`.
- **Cambio de placa para la prueba (informado por el usuario):** la prueba del LSM9DS1 se hace en una **ESP32-S3-WROOM-1 N16R8** (16 MB de flash, 8 MB de PSRAM octal), no en el clásico.
  - `main/test_lsm9ds1.c`: pines I2C según el target (`CONFIG_IDF_TARGET_ESP32S3` → SDA 6 / SCL 7, porque el S3 no tiene GPIO 22; el clásico sigue en 21/22).
  - Nuevo `sdkconfig.defaults.esp32s3`: `CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y`. Así no se repite el rechazo por tamaño de flash del 31/05/26 con el N8R2.
  - `build_test_lsm9ds1.sh` recibe el target como parámetro (por defecto `esp32s3`).
  - Compilado para `esp32s3`: OK, sin warnings. Binario de 0x3be50 bytes (77 % libre). `sdkconfig`: 16 MB, `FREERTOS_HZ=1000`, consola UART0 + USB-Serial-JTAG secundaria (la salida se ve por los dos conectores).
  - La compilación para `esp32` se verificó antes del cambio; la rama del clásico quedó con los mismos pines y no se recompiló.
  - **Observación:** la N16R8 tiene PSRAM octal (GPIO 35–37 internos) → no puede reemplazar a la N8R2 como sensor con el mapa de `pines.md` §1 sin remapear.
- **Primera corrida en hardware (ESP32-S3 N16R8, `/dev/ttyACM0`, CH343 1a86:55d3):**
  - Placa verificada antes de flashear con `esptool.py flash_id`: ESP32-S3 rev v0.2, Embedded PSRAM 8 MB, flash detectada de 16 MB. No es la N8R2 del motor.
  - Flasheo v1.0 OK (3 hashes verificados). La salida serie se leyó con un script de pyserial (reset por RTS) en el scratchpad de la sesión.
  - El firmware arranca bien. El aviso `W i2c: This driver is an old driver` es esperado (driver legado, igual que en el sensor).
  - **Escaneo I2C en SDA 6 / SCL 7: ningún dispositivo**, 10 de 10 intentos en 30 s. Se repitió después de que el usuario revisara: igual.
- **v1.1, diagnóstico de cableado:** si no responde nada, pone cada GPIO libre (S3: 1, 2, 4–18, 21, 38–42, 47, 48) como entrada con pull-down interno y reporta los que leen 1 (pull-up externo de 10 kΩ del breakout alimentado). Después prueba con SDA y SCL invertidos. Se silenció el log de `gpio` (`esp_log_level_set("gpio", ESP_LOG_WARN)`), que se intercalaba con la salida.
  - **Resultado (3 de 3 intentos):** pull-up externo **solo en el GPIO 7**. Invertido: tampoco responde.
  - **Conclusión:** el breakout tiene VDD y la línea del GPIO 7 llega. **La línea que debería ir al GPIO 6 no llega** a ningún pin revisado (cable suelto, fila equivocada de la protoboard o un pin fuera de la lista).
  - El diagnóstico no prueba el GND: con VDD conectado y sin GND, el pull-up igual se ve.
- **Segunda corrida, después de que el usuario cambiara el cable del GPIO 6 (v1.1):**
  - Detecta **AG en 0x6B y M en 0x1E** (jumpers SDO = 1). WHO_AM_I 0x68 / 0x3D OK y configuración OK.
  - Calibración: ruido z de 1,95 dps RMS (x/y 0,14/0,17) y gz de +14,9 dps en el primer segundo → el sensor se movía.
  - **A los 3 s:** acel exactamente 0, giro sin datos (GDA nunca en 1) y magnetómetro congelado (ZYXDA en 0). Es compatible con un **reinicio del LSM9DS1**, que tras el power-on queda en power-down con los registros de fábrica. Hipótesis: falso contacto en VDD o GND mientras se acomodaba el cable. No se confirmó con el registro, porque la v1.1 no lo vigilaba.
- **v1.2:**
  - La calibración se rechaza si el ruido de algún eje supera 0,5 dps (`CALIB_RUIDO_MAX_DPS`).
  - Si no llegan muestras del giro durante 250 ms (`GIRO_TIMEOUT_US`), se relee `CTRL_REG1_G` para distinguir entre "no responde por I2C", "se reinició y perdió la configuración" y "configuración intacta". Después se reinicia la prueba completa (detección, configuración y calibración).
  - Compilado sin warnings y flasheado (placa verificada de nuevo con `flash_id`: 16 MB).
- **Corrida v1.2:**
  - Tres calibraciones rechazadas por movimiento (ruido z de 42,6, 30,4 y 17,8 dps RMS). La cuarta fue aceptada:
    - Ruido 0,055 / 0,081 / 0,058 dps RMS.
    - Bias x = +0,037, y = +5,948, z = −0,084 dps.
    - Acel (−0,012, −0,013, +0,968) g, \|A\| = 0,968 g.
  - **El bias en y es estable entre corridas:** 5,797 / 5,882 / 5,824 / 5,956 / 5,948 dps.
  - **Magnetómetro:** \|B\| = 22,5–23,2 µT, coherente con el campo terrestre local (~23 µT). Temperatura ~25 °C.
  - En el segundo 2 de la medición, gz medio = +1,12 dps (yaw +1,1°): golpe o movimiento. La captura terminó ahí, así que falta la corrida de 5 min sin tocar.
- **Archivos:** `docs/pines.md` §3.5 (direcciones confirmadas), `Datasheet/IMU_LSM9DS1_SparkFun.txt` (línea agregada al final), `docs/pruebas.md` y `docs/00_estado_actual.md`.

## [02/11/26 Sesión Tarde] - LSM9DS1: deriva según el tiempo de encendido (calentamiento inicial)

- **Contexto:** el usuario pidió repetir la prueba de deriva de 5 min. Antes de capturar se verificó la placa con `esptool.py flash_id` (ESP32-S3, PSRAM 8 MB, 16 MB: la N16R8) y que el puerto `/dev/ttyACM0` estuviera libre. Firmware v1.2, sin reflashear.
- **Corrida A (12:2x, recién conectado):** durante la captura, el usuario avisó "Ahora lo conecté", es decir, la placa se había conectado justo antes.
  - Calibración: bias (+0,425, +4,281, −0,195) dps; ruido (0,053, 0,091, 0,052) dps RMS; \|A\| = 0,967 g.
  - Por minuto: +2,878 / +5,848 / +6,274 / +6,828 / +7,393° → **+29,221° en 300 s = +5,844 °/min**. Errores I2C: 0.
  - **Tendencia** (script `tendencia.py` en el scratchpad, medias de 30 s del residual sin bias): gz +0,032 → +0,101 (60–90 s) → +0,125 dps (300 s); gy +0,30 → +1,20 dps; gx −0,05 → −0,24 dps. Temperatura 22,6 → 23,0 °C.
  - Cambio rápido al principio y después más lento → **calentamiento inicial** (bias del MEMS estabilizándose tras el encendido). No hubo movimientos: ningún segundo con \|gz\| > 0,15 dps.
  - \|B\| bajó de 23,6 a ~12–13 µT en los primeros 10 s (el entorno cambió al empezar) y después quedó estable en 11–15 µT.
- **Corrida B (inmediatamente después, ~6 min de encendido):**
  - Calibración: bias (+0,234, +5,250, −0,119) dps; ruido (0,053, 0,083, 0,052) dps RMS.
  - Por minuto: +0,593 / +1,550 / +1,499 / +1,509 / +1,084° → **+6,236° en 300 s = +1,247 °/min**. Errores I2C: 0.
  - Residual de gz: +0,006 → +0,028 dps (60–120 s) → +0,015 dps (300 s); gy +0,02 → +0,17 → +0,05 dps. Temperatura 23,0–23,1 °C.
  - Mejoró, pero el bias todavía se mueve.
- **Comparación con la madrugada** (horas encendido): residual de gz dentro de ±0,03 dps, deriva de 0,1–0,2 °/min.
  - Bias de y según el estado: 5,705 (caliente, madrugada), 4,281 (frío) y 5,250 (~6 min) → también el valor absoluto cambia durante el calentamiento.
  - Un cambio de 0,1 dps con +0,4 °C en el sensor de temperatura del chip es demasiado grande para explicarlo solo por la temperatura medida. Se atribuye al transitorio de encendido. Sin evidencia adicional.
- **Implicancias para el control del motor (propuestas, sin decidir):**
  1. Esperar a que el IMU se estabilice después de encenderlo antes de trabajar. Hay que medir cuánto.
  2. Recalibrar el bias en cada parada (ya previsto).
  3. Opcional: estimar el bias de forma continua con el robot detenido, o compensarlo por temperatura.
- **Pendiente:** medir la curva de calentamiento (bias en función del tiempo desde el encendido en frío, ~30 min) para saber cuánto esperar.
- **Archivos:** `docs/pruebas.md` (estado, 2 filas nuevas y notas) y `docs/00_estado_actual.md`.
- **Observación de 20 min con una sola calibración** (monitor del usuario abierto a las ~12:38, con ~16 min de encendido; sensor quieto todo el tiempo, confirmado por el usuario):
  - En t = 1191–1200 s, gz residual +0,025…+0,049 dps; gy residual ≈ +0,35 dps; T = 23,4–23,8 °C (23,0 a las 12:30).
  - **Yaw total +33,584° en 20 min** (media 1,7 °/min). El minuto 20 ya iba a +2,196°.
  - **Conclusión:** incluso después de más de 30 min encendido, el bias se sigue moviendo (≈ +0,04 dps en z en 20 min). Una calibración no se sostiene durante 20 min → refuerza recalibrar en cada parada (rectas de ~1 min).
  - No se hizo el giro de 90°.
- **Intento de cerrar el monitor del usuario desde la sesión (`pkill`): denegado por el sistema de permisos** (interferir con un proceso del usuario). Queda como regla: el monitor lo cierra el usuario con `Ctrl+]`.
- **~13:00: el usuario desconectó y volvió a conectar la placa** → nuevo encendido en frío. Se dejó en segundo plano una captura de 30 min que arranca sola al cerrarse el monitor, sin pulso de reset (opción `sin_reset` agregada a `leer_serie.py`), para medir la **curva de calentamiento** (residual del bias minuto a minuto desde el encendido).
- **Dead-end de la captura en espera:** el bucle `while pgrep -f "esp_idf_monitor"` se detectaba a sí mismo, porque la cadena aparece en la línea de comando del propio `bash -c`. Por eso nunca terminaba, aunque el usuario ya había cerrado el monitor. Se verificó con `fuser -v /dev/ttyACM0` (puerto libre) y `pgrep -af "[e]sp_idf_monitor"` (solo aparecía el propio bucle). Se detuvo la tarea. **Para verificar si el puerto está ocupado, usar `fuser`, o un patrón con corchetes en `pgrep -f`.**
- **Captura de la curva de calentamiento:** iniciada a las 13:04:3x, de 1800 s. Aunque se usó `sin_reset`, al abrir el puerto la placa se reseteó (apareció el banner) → calibración a los ~4 min de encendido (bias +0,097, +5,611, −0,140 dps; aceptada). Cubre de los ~4 a los ~34 min desde el encendido.
- **Resultado de la curva de 30 min** (13:04:33–13:34:34, 1748 líneas por segundo; falta el resumen del minuto 18, se perdió una línea; 0 errores I2C; sin movimientos):
  - Calibración a los ~4 min del encendido: bias (+0,097, +5,611, −0,140) dps; ruido (0,047, 0,084, 0,055).
  - Residual de gz en medias de 2 min (script `tendencia60.py`): +0,043 → +0,055 → +0,058 → +0,071 → +0,085 dps (16–18 min) → después entre +0,051 y +0,083 hasta los 34 min.
  - T: 23,8 → 22,5 → 22,8 °C (el ambiente se enfrió). gx −0,011 → +0,128 dps; gy +0,19 → −0,21 dps.
  - Deriva por minuto respecto de la calibración: 2,26–5,53°; +114,38° en 29 min.
  - **Conclusión:** no es una curva de calentamiento que converge. El bias cambia más en los primeros minutos y después sigue oscilando ±0,015 dps (escala de minutos), en parte por la temperatura. No se puede extraer un "tiempo de estabilización" limpio.
- **Simulación de recalibración en cada parada** (`recalibrar.py`): para cada t0, bias = media de 3 s y error = \|Σ(residual − bias)\| durante T s. Se aplicó a las 4 corridas, excluyendo en la de la madrugada los segundos 214–229 del movimiento. Mediana / p95 / máximo:
  - Madrugada: T = 60 s → 0,40 / 1,06 / 1,28°.
  - Recién conectado: T = 60 s → 0,54 / 2,48 / 3,55°.
  - ~6 min: T = 60 s → 0,36 / 1,05 / 1,36°.
  - Curva de 4 a 34 min: T = 60 s → 0,42 / 1,27 / 2,75°.
  - T = 30 s: medianas 0,17–0,24°. T = 120 s: p95 2,2–3,2° (6,4° recién conectado).
  - **Lectura:** con ≥ 6 min de encendido y una recalibración en cada parada, 1 min de recta da ~0,4° típico y ~1,3° en el peor 5 %. Es aceptable. Es un análisis en reposo.
- **v1.3 del firmware de prueba (versus giroscopio vs magnetómetro):**
  - **Calibración del magnetómetro con el botón BOOT (GPIO 0)** durante la medición: 1 vuelta en `MAG_CAL_S` = 20 s.
    - Offset y escala X/Y por mínimo y máximo.
    - El giróscopo verifica que la vuelta tenga ≥ 330° (`MAG_CAL_GIRO_MIN`) y que los radios sean ≥ 5 µT.
  - **Rumbo magnético** con la placa horizontal, sin compensar inclinación.
    - Mapeo supuesto: x_AG = −mx, y_AG = my, por referencia de uso habitual del LSM9DS1 (reflejo en x entre el magnetómetro y el AG). Fórmula: `atan2(-y_AG, x_AG)`, con signo antihorario como el yaw.
    - **Se verifica empíricamente en la prueba A** (mismo signo de dGiro y dMag).
  - **Referencia** al quedar quieto 1,5 s (\|gz\| < 2 dps). Línea `PARADA` al quedar quieto después de girar > 10°. El rumbo magnético se desenvuelve (`mag_unw`). Cada línea por segundo agrega `rumbo_mag`, `dGiro`, `dMag` y `dif`.
  - Si se aprieta BOOT antes del resultado, la prueba de deriva queda invalidada. Después de la calibración se reinicia `t_ult_giro`, para no integrar el hueco.
  - **Compilación:** sin warnings, 0x3e060 bytes. **Flasheo:** placa verificada con `flash_id`, 3 hashes OK. Arranque OK: aviso del BOOT, bias (+0,199, +5,475, −0,079) dps.
  - **Procedimiento:** `docs/pruebas.md` §2. Requiere al usuario en la mesa.
- **El usuario quiere usar el magnetómetro** ("para eso compramos este IMU") y pidió un versus entre los dos sistemas.
  - Se explicó: el giróscopo siempre (control fino); el magnetómetro como corrección lenta si la interferencia lo permite.
  - Mejoras posibles: montaje alejado o en mástil (la perturbación cae con ~1/r³), calibración arriba del robot y rechazo de lecturas fuera de rango.
- **Archivos:** `docs/pruebas.md` (§1: estado, curva, tabla de recalibración; §2 nuevo: versus) y `docs/00_estado_actual.md`.
- **Primer intento del versus (v1.3, 14:04–14:09)**, con el usuario en la mesa. Logs del monitor (Ctrl+T Ctrl+L) en `firmware/esp32_motor/test_lsm9ds1/log.test_lsm9ds1.20261102140425.txt` (38,5 KB) y `…140904.txt` (4,5 KB):
  - **Calibraciones OK:** vuelta +355,8°, radios 29,4/25,0 µT, centro +26,1/−5,4 µT, relación 1,18; y vuelta −359,4°, radios 28,6/23,9, centro +26,4/−6,2, relación 1,20 → **hard iron de la placa repetible, ~26 µT**. Tres calibraciones fallidas: vueltas de +6,3°, −88,3° y +20,0°.
  - **Comparaciones válidas en reposo:**
    - dGiro −358,6 / dMag +372,3.
    - +90,1 / −104,7 (repetido en el log 2: +94,7 / −105,2).
    - +16,2 / −23,8.
    - Cerca de 0: +4,8 / −5,5 (el log 2 da dMag = −5,5 a +4,8).
    - **Signo de dMag opuesto en todos los casos** → el supuesto x_AG = −mx (reflejo) era incorrecto; con los ejes tal cual coincide el sentido. Error de magnitud con el signo corregido: 0,7–14,6°, dependiente de la orientación.
  - **\|B\| crudo** 4,4–55 µT según la orientación: campo propio de la placa (~26 µT) sumado al terrestre (~26–27 µT horizontal según los radios de la calibración). No es una perturbación externa. Causa probable del hard iron: las pinzas de acero de la protoboard y la placa S3 cercana (sin verificar).
  - **ALERTA a los 241 s:** `CTRL_REG1_G = 0x00 (esperado 0x60)` → el LSM9DS1 se reinició (falso contacto en VDD/GND al girar la placa). La prueba se reinició sola. Calibración siguiente rechazada por movimiento (ruido z 3,4 dps) y después aceptada.
  - **Bug:** al reiniciarse `medir()` con `mag_cal = true`, `ref_pendiente` arrancaba en false → `mag_unw` arrancaba desde `rumbo_ant = 0` (PARADA de +67,6 / −21,8 inválida). Además, después de una calibración fallida no se volvía a tomar la referencia.
- **v1.4 del firmware de prueba:**
  - Ejes X/Y del magnetómetro tal cual: `bx = W·(m − c)`, rumbo `atan2(−by, bx)`.
  - **Ajuste de elipse por mínimos cuadrados** (cónica A u² + B uv + C v² + D u + E v = 1 sobre datos normalizados por media y desvío; sistema 5×5 por Gauss con pivoteo). Centro → hard iron; W = R·N^½ (N = matriz de la elipse centrada; R = media geométrica de los semiejes) → soft iron. Respaldo: mín/máx por eje. Informa la dispersión del campo calibrado (bueno < 3 %).
  - `Bh` (campo horizontal calibrado) en cada línea y en PARADA.
  - `ref_pendiente = mag_cal` al iniciar `medir()` y después de cada BOOT.
  - **Verificación en la PC** (gcc, funciones extraídas del `.c` con `awk`): elipse sintética con centro (26, −6), relación 1,25 y ángulo 30°.
    - Sin ruido: exacto, error de rumbo de 0,00°.
    - Con 0,3 µT de ruido: centro 26,04 / −6,01, relación 1,255, ángulo 29,7°, dispersión 1,32 %, error máximo de 2,76°.
    - Solo centro: 11,6–13,3°.
  - **Compilación:** primer intento con error (variable `s` duplicada en `calibrar_mag`, renombrada a `suma`). Después OK sin warnings, 0x408e0 bytes. **No flasheada todavía:** el monitor del usuario (PID 96222) ocupa el puerto.
- **v1.5 del firmware de prueba (pedido del usuario: identificar claro los dos yaw y poder fijar la referencia):**
  - Con el magnetómetro calibrado, la línea por segundo pasa a ser corta: `YAW GIRO`, `YAW MAG`, `diferencia` y `Bh`. La línea `PARADA` usa los mismos nombres.
  - **Botón BOOT sin bloqueo** (`leer_boton`: antirrebote de 30 ms, ventana de 400 ms para el segundo toque): 1 toque = calibrar el magnetómetro; 2 toques = nueva referencia (`ref_pendiente`, se toma al quedar quieto 1,5 s). Si no hay calibración, el doble toque avisa que primero hay que calibrar.
  - Compilado sin warnings (0x40aa0 bytes). Flasheado (placa verificada con `flash_id`). Arranque OK con el aviso nuevo del botón.
  - **Dead-end en la verificación del puerto:** `fuser -v … | tail -n +2 && …` siempre daba "ocupado" (tail termina con 0). Usar `fuser -s /dev/ttyACM0` y su código de salida.
- **Segundo intento del versus (v1.5)**, log `log.test_lsm9ds1.20261102143842.txt` (14:38:42–14:40:20; el usuario apagó el log con Ctrl+T Ctrl+L; el monitor quedó abierto).
  - **Calibración:** +359,6°, 409 muestras, elipse con centro +34,1/−6,8 µT, semiejes 16,1/11,9 (relación 1,35, eje a +130°), Bh medio de 13,8 µT, dispersión 3,2 %.
  - **Paradas:** −90,2/−55,8; −0,5/−0,1; +89,1/+105,4; −0,4/−0,7. Tras la nueva referencia por doble toque (funcionó): +89,8/+105,5; −89,5/−62,8; +0,3/−5,3.
  - **Giróscopo:** ±1°. **Brújula:** error sistemático y repetible de 16–35° a ±90° (las visitas a +90 dan 105,4 / 105,5 / 105,9). `Bh` depende de la orientación (14–16 µT a 0°, 19–23 a ±90°).
  - **Cambio respecto del primer intento:** centro de +26 a +34 µT y radio horizontal de ~26 a 13,8 µT → cambió el entorno o el montaje del sensor (sin confirmar con el usuario).
  - **Hipótesis:** material ferromagnético cercano (pinzas de la protoboard, placa S3, notebook), desplazamiento del sensor al girar en un campo no uniforme e inclinación distinta entre la calibración y la prueba. Sin compensación de inclinación ni calibración 3D.
  - **Propuesta:** repetir con el sensor fuera de la protoboard, sobre un soporte no metálico, con cables de 20–30 cm hacia el S3, en una mesa de madera lejos de la notebook y girando sobre el propio sensor. Esperado: Bh ≈ 20 µT constante (±1) y error ≤ 3°.
- **Decisión del usuario (02/11/26):** "la brújula es relativamente mala, dejemos esta prueba". **Se descarta el magnetómetro por ahora.** El rumbo se controla con el giróscopo y la recalibración en cada parada. Conclusiones en `pruebas.md` §2 ("Conclusión de las pruebas del LSM9DS1").
  - El usuario atribuyó la deriva al "integrativo o derivativo". Se aclaró que es la **integración** del bias residual (rate → ángulo), no un término de PID.
- **Siguiente prueba:** placa 3 (MPU-9250/6500/9255, chip "MP92 U601A1 2048"), identificación y deriva del giróscopo con la misma metodología.
- **Firmware de prueba de la placa 3:** `firmware/esp32_motor/test_mpu9250/` (`CMakeLists.txt`, `sdkconfig.defaults`, `sdkconfig.defaults.esp32s3` copiados del test del LSM, `main/test_mpu9250.c`) y scripts `scripts/pc/{build,flash,monitor}_test_mpu9250.sh` (generados con sed desde los del LSM, agregados al README).
  - **Identificación:** WHO_AM_I 0x75 (0x70 / 0x71 / 0x73 / 0x68 / otro) y AK8963 por bypass (`INT_PIN_CFG = 0x02`, `USER_CTRL = 0x00`; 0x0C, WIA = 0x48; `CNTL2 = 0x01` reset; `CNTL1 = 0x16`: 16 bits, continuo a 100 Hz).
  - **MPU:** reset con `PWR_MGMT_1 = 0x80` y después 0x01 (PLL); `SMPLRT_DIV = 7` (125 Hz); `CONFIG = 0x03` (41 Hz); `GYRO_CONFIG = 0x00` (±250 dps, 131 LSB/dps); `ACCEL_CONFIG = 0x08` (±4 g); `ACCEL_CONFIG2 = 0x03`; `INT_ENABLE = 0x01`. Relectura de cada registro.
  - **Lectura:** 14 bytes big-endian desde 0x3B al haber dato nuevo (`INT_STATUS` bit 0). Temperatura = raw/333,87 + 21 °C. Magnetómetro: ST1 bit DRDY → 7 bytes desde HXL (incluye ST2; HOFL descarta), 0,15 µT/LSB sin ASA.
  - **Alerta de reinicio:** se releen `SMPLRT_DIV` y `CONFIG` (vuelven a 0 tras un reset).
  - Mismo formato de salida que `test_lsm9ds1` → sirven los mismos scripts de análisis.
  - **Compilado para esp32s3** sin warnings (0x3d440 bytes). No flasheado: el monitor del usuario ocupaba el puerto.
- **Referencia: otro proyecto del usuario** (robot sumo "MBARETECH", Arduino/PlatformIO, ESP32 + BLE) en el que ya se había usado la placa 3 (MPU) para autocalibrar giros. El usuario pasó el código solo como referencia. Se compararon:
  - **Su configuración:** `PWR_MGMT_1 = 0x01`, `CONFIG = 0x01` (DLPF de 184 Hz), `GYRO_CONFIG = 0x18` (±2000 dps, 16,4 LSB/dps), `SMPLRT_DIV` sin configurar (1 kHz). Lee solo `GYRO_ZOUT` (0x47) en un bucle sin dato listo. No revisa el valor de WHO_AM_I.
  - **Su método:** bias de 300 × 2 ms (0,6 s) **antes de cada giro**; integración con el dt real; **la medición se descarta si hay un hueco > 10 ms** entre lecturas; mide la inercia después de frenar (\|dps\| < 5 durante 30 ms, con un tope de 600 ms). Integra < 1 s por maniobra → la deriva no se nota.
  - **Para llevar al firmware del motor:** recalibrar antes de cada maniobra, descartar o marcar mediciones con huecos de lectura y contemplar la inercia al frenar. Para la cortadora se mantienen ±250 dps (8× más resolución) y el DLPF de 41 Hz (robot lento, ~36 °/s).
  - **Hallazgo documentado en ese código:** `adc2_get_raw()` falla con BLE activo, no solo con Wi-Fi → regla en `docs/pines.md`: nada analógico en ADC2 (las reservas de batería ya estaban en ADC1).
- **`test_mpu9250` flasheado** en la N16R8 (3 hashes OK). Primera corrida: escaneo con solo 0x1E y 0x6B (el LSM9DS1) → **la placa 3 no responde en 0x68/0x69**; lo más probable es que todavía no esté cableada. El diagnóstico de pull-ups ve los GPIO 6 y 7, pero con el LSM9DS1 en el bus esos pull-ups pueden ser del LSM: con dos placas conectadas el diagnóstico no es concluyente.
- **Placa 3 conectada sola** (LSM9DS1 desconectado; VCC → 3V3, GND, SDA → 6, SCL → 7, el resto sin conectar), 15:08–15:09:
  - Escaneo: solo 0x68. **WHO_AM_I = 0x75** (no es 0x70/0x71/0x73; el valor coincide con reportes de foros sobre clones de "MPU-9250"). Configuración OK.
  - **AK8963 no responde en 0x0C → 6 ejes, sin magnetómetro.**
  - Calibración: bias (+8,978, +1,692, +0,097) dps, ruido (0,045, 0,044, 0,044) dps RMS, \|A\| = 0,989 g, T = 32,1 °C. Yaw estable en ±0,02° durante los primeros 11 s.
  - **Captura de 1800 s** en segundo plano desde las 15:10, con reset → calibración a ~1–2 min del encendido: bias (+8,989, +1,729, +0,095), ruido (0,038, 0,041, 0,040). Objetivo: curva de calentamiento y simulación de recalibración comparables con el LSM9DS1.
- **Conclusión sobre el magnetómetro de la placa 3 (acordada con el usuario):** se la considera un **IMU de 6 ejes, sin magnetómetro** (AK8963 ausente con el bypass activo y verificado, más WHO_AM_I 0x75 de clon). No se hace la verificación extra por el maestro I2C interno (SLV0): no cambia la decisión, porque el magnetómetro ya estaba descartado.
- **Resultado parcial a los 17 min (15:27):**
  - Deriva respecto de una sola calibración: −0,11 a −0,87 °/min; residual de gz −0,004 → −0,014 dps; T 32,1 → 31,3 °C; 0 errores I2C.
  - Simulación de recalibración (`recalibrar.py`): T = 30 s → 0,07 / 0,21 / 0,31°; **T = 60 s → 0,14 / 0,41 / 0,69°**; T = 120 s → 0,29 / 0,90 / 1,42° (mediana / p95 / máx.). Es ~3 veces mejor que el LSM9DS1 incluso arrancando en frío.
- **Resultado completo de la placa 3** (15:10:06–15:40:06, 1796 líneas, 0 errores I2C, sin movimiento):
  - 5 min: −2,222° (−0,444 °/min). 29 min respecto de una sola calibración: −21,722°.
  - Residual de gz en medias de 2 min: −0,0037 → −0,0174 dps (27,5 min) → −0,0132 dps; T 32,1 → 31,2 °C.
  - **Simulación de recalibración:** T = 30 s → 0,07 / 0,21 / 0,31°; **T = 60 s → 0,14 / 0,40 / 0,69°**; T = 120 s → 0,29 / 0,86 / 1,42°. ~2,5–3 veces mejor que todas las corridas del LSM9DS1.
  - **Recomendación:** placa 3 en el ESP32_motores y LSM9DS1 de respaldo; repuesto validado con la misma prueba (es un clon). Pendiente de confirmación del usuario. Falta el giro de 90° a mano (escala).
- **`test_mpu9250` v1.1 (modo giro):**
  - Botón BOOT sin bloqueo: 2 toques = YAW 0 al quedar quieto; 1 toque = recalibrar el bias (3 s, después de 1 s de espera) y YAW 0, como en cada parada del robot.
  - Línea corta `YAW GIRO` y líneas `PARADA` (quieto 1,5 s después de girar > 10°).
  - **Corrección:** `calibrar_giro()` ahora conserva el bias anterior si la calibración falla por movimiento (antes lo pisaba).
  - Compilado sin warnings (0x3da40 bytes). La primera compilación + flasheo la canceló el usuario; después la pidió de nuevo ("compilalo y alzalo"). Flasheado OK (placa verificada, 3 hashes). Arranque: WHO_AM_I 0x75, configuración OK, bias (+9,013, +1,744, +0,088) dps.
- **Prueba de giro a mano de la placa 3** (v1.1, log `log.test_mpu9250.20261102155129.txt`; detalle en `pruebas.md` §3):
  - Giros de 90° en 87,9–90,5° (relativos a la parada anterior).
  - Vueltas completas: +356,1 / −355,3 → −1,2 %. Causa posible: saturación en ±250 dps (medias por segundo de 98–120 dps al girar rápido a mano) o error de escala real (dentro de ±3 %).
  - **Bias recalibrado mal por el propio toque de BOOT** (0,012 contra ~0,09 real) → creep de +0,05 °/s quieto. El control de ruido no detecta un movimiento lento.
  - **Lección para el firmware del motor:** esperar a quedar quieto, chequear la tendencia de la ventana y comparar con el bias previo.
  - **Veredicto:** pasa la validación de giro. Se propuso, como opcional, una vuelta lenta para cerrar la duda de escala.
- **Vuelta completa lenta de la placa 3** (informada por el usuario, sin log): **358°** → −0,6 %, dentro de la alineación a mano. El 356 de la prueba rápida era en buena parte saturación o la velocidad de giro. El LSM9DS1 había dado −358,6° en el versus → **en giros quedan empatados; en deriva la placa 3 es ~3 veces mejor**. Recomendación reiterada: placa 3 para el ESP32_motores, LSM9DS1 de respaldo (pendiente de la aprobación del usuario).
- **DECISIÓN DEL USUARIO (02/11/26):** "optaremos por esta placa 3" → **la placa 3 (clon de MPU, 6 ejes) es el IMU del ESP32_motores**; el LSM9DS1 queda de respaldo. Se actualizaron `docs/componentes.md` (tabla de IMU), `docs/pines.md` §2 (I2C 21/22 → placa 3 en 0x68, más una nota de montaje) y `docs/00_estado_actual.md`.
- **Pregunta del usuario:** ¿afectan los campos magnéticos, el metal o los imanes al giróscopo? → **No**: el giróscopo MEMS mide la fuerza de Coriolis sobre una masa vibrante (efecto mecánico), sin sensibilidad apreciable a campos estáticos ni al acero.
  - **Lo que sí lo afecta:** la vibración (puede correr el bias), la temperatura, la interferencia eléctrica en los cables I2C (lecturas corruptas o reinicios), un montaje flojo y, en menor medida, las aceleraciones.
  - **Recomendaciones de montaje:** rígido sobre un amortiguador, lejos del soporte de la cortadora y de las fuentes de calor, plano con Z vertical, cable I2C corto y lejos de la potencia.
- **Afinado de la placa 3, con el usuario ausente** (autorizado: "te dejaré afinando este IMU"; detalle en `pruebas.md` §3 "Afinado"):
  - **Captura en caliente** de 1800 s en segundo plano desde las 16:00:30 (placa encendida desde las 15:08). El usuario puso un soporte para nivelarla mientras corría (movimiento en los segundos 43–50; inclinación 11,3° → 2,5°).
  - **`afinado.py` sobre los datos en frío** (Allan, barrido de T_cal × T_recta, temperatura): placa 3 con inestabilidad del bias de 0,0019 dps (piso 0,0013 a 50–70 s) contra 0,0072 del LSM; ARW 0,31 contra 0,48 °/√h.
  - **Barrido:** T_cal = 5 s → p95 de 0,34° a 60 s (−15 % respecto de 3 s); 10 s → 0,28°. Temperatura: efecto 0,013°/min → no se compensa.
  - **Hipótesis de la inclinación:** 7,7° → cos = 0,991 → 360° se miden como 356,7°, coherente con los 356–358°. ax cambió de −0,131 a −0,191 g con la posición → inclinación real.
  - **v1.2 de `test_mpu9250`:** `calibrar_giro_ventana(segundos, robusta)` con `esperar_quieto`, tendencia entre mitades, salto de bias con un rechazo y vector `up` del acelerómetro; integración de `g·up` (YAW VERTICAL) y de `eje_seg` (inclinación del eje de giro según el giróscopo). Compilado OK; se flashea al terminar la captura.
- **Resultado de la captura en caliente** (16:01:02–16:31:03):
  - Respecto de la calibración del arranque, −8,9 °/min por un **salto de bias al poner el soporte**: Δ giro (+0,041, +0,021, −0,175) dps con Δ acel (+0,167, +0,003, +0,017) g → ~−1,05 dps/g si es sensibilidad a la orientación (la hoja del original da ~0,1 dps/g). Sin confirmar contra la hipótesis de tensión mecánica.
  - Después del soporte: Allan con piso de 0,0018 dps a 15 s; recalibración de 5 s → 60 s: 0,15 / 0,46 / 0,77°. Temperatura estable.
- **v1.2 ampliada:** métrica de huecos (`HUECO_LARGO_MS = 20`) en los resúmenes, línea `CAL_OK` y control de salto omitido si la gravedad cambió > 0,03 g. Compilada sin warnings (0x3ee30 bytes) y **flasheada a las 16:35** (placa verificada). Arranque: bias z −0,048 dps con 2,5° (a 11,3° había sido +0,075).
- **Pendiente con el usuario:** prueba A (giro con compensación de inclinación) y prueba B (bias contra orientación en 6 posiciones). Parámetros borrador del IMU para el motor v4 en `pruebas.md` §3.
- **Corrección de `docs/pines.md` §1 (mapa del S3):** había quedado con el GPS en el 4/5 y el 4.º bumper en el 36, aunque en la sesión se acordó el **GPS en el 35 (RX) / 36 (TX)** (elegido por el usuario) y el **4.º bumper en el 39** (propuesto y aceptado). Se corrigieron la tabla, la línea de autoría, la lista "No usar" (se sacó "35: no hace falta"), los libres de reserva (4, 5, 11–14, 21, 40–42), una nota del JTAG en el 39 y el punto 1 de "Verificar antes de cablear" (con N8R8/N16R8 se pierden el GPS y el bumper derecho; la PSRAM no se activa en modo octal).
- **Control a las 19:10** (placa 3, v1.2, sin tocar desde las 16:35; captura de 15 s en `scratchpad/v12_largo.txt`): al abrir el puerto, el CH343 reseteó el ESP (`rst:0x15 USB_UART_CHIP_RESET`) y se recalibró.
  - Misma orientación que a las 16:35 (acel ≤ 0,006 g de diferencia), pero bias z **−0,048 → −0,140 dps** (x +9,081 → +9,214, y +1,705 → +1,796), con T 31,8 → 30,6 °C. La temperatura explica ~0,016 dps → el bias deambula a escala de horas.
  - A los 4 s de calibrar, **salto de +0,05 dps en z** (−0,04 en x) sin cambio del acelerómetro, persistente. En el arranque de las 16:35 no ocurrió. Falta saber si se tocó la mesa. Anotado en `pruebas.md` §3 punto 8.
- **Pedido del usuario:** "añadamos [el IMU] a nuestro esp32_motores y redefinamos el protocolo y las órdenes como deben ser ahora con la nueva implementación". Las pruebas A y B quedan pendientes (no se corrieron).
- **Respaldo de la v3.2:** `firmware/esp32_motor/versions/2026_11_02_MainV3.2_encoders.c.bak` y `2026_11_02_sdkconfig_V3.2_esp32s3.bak` (target S3, flash 8 MB).
- **Firmware del motor v4.0** (`active/active/main/main.c`, reescrito; Sabertooth, cortadora, capa física del MC33926, anti-hipo y bucle micro-ROS iguales a la v3.2):
  - **Se eliminan** PCNT, encoders y PID de velocidad.
  - **Pines** con `#if CONFIG_IDF_TARGET_ESP32S3`: clásico según `pines.md` §2 (PWM 32/33/25/26, I2C 21/22); banco S3 N16R8 (PWM 4/5/15/16, I2C 6/7). 17 y 18 iguales.
  - **Lazo abierto:** `PWM = PWM_ARRANQUE (20) + v / CM_S_POR_PWM (0,36)`, tope 180, rampa 25 cm/s², slew 600/s. Constantes estimadas de la hoja de datos (100 rpm a 12 V, 4S, −15 % por carga); **a calibrar en piso**.
  - **Tarea `imu_task`** (prioridad app+1, núcleo 1): detecta el MPU en 0x68/0x69, configuración de `test_mpu9250` (125 Hz, DLPF 41 Hz, ±250 dps, ±4 g), reintento cada 1 s si falla o no da datos en 250 ms. Integra `w = (g − bias)·up` en `yaw` (double), con estado compartido bajo `portMUX`.
  - **Recalibración automática en las paradas:** con la tracción quieta y los 3 ejes < 1 dps durante 1 s, ventanas de 5 s encadenadas mientras sigue quieto; rechazo por ruido > 0,5 dps, tendencia > 0,015 dps y salto > 0,03 dps sin cambio de gravedad > 0,03 g (se acepta al segundo); al aceptar, se descuenta del yaw lo integrado en la ventana. La primera es solo por ruido.
  - **Recta:** PI de rumbo (KP 0,45 cm/s/°, KI 0,10, KD 0,05 sobre `w`, tope 8 cm/s y nunca mayor a la velocidad base).
  - **Giro:** perfil de velocidad angular (36 °/s en el lugar, 18 °/s en el swing, mínimo 8, desaceleración en 15°, rampa 60 °/s²), adelanto por el modelo + PI sobre `w` (KP 1, KI 2, empuje máximo +80 PWM), corte a 1° del objetivo y asentado hasta |w| < 2 dps durante 300 ms (máx. 1,5 s). Timeout de 3 s + grados a la mitad del crucero → `ERROR` 3.
  - **`rumbo_obj` absoluto:** los giros le suman exacto; si se interrumpen o fallan, pasa al rumbo actual; reanclaje si el error al arrancar supera 10°.
  - **Protocolo v4:** `motion_cmd` igual (5 campos); ADELANTE/ATRAS en cm/s; modos nuevos **CALIBRAR (6)** y **FIJAR_RUMBO (7)** (este último no corta el movimiento). `motion_status` de 9 campos: `[cmd_id, estado, pwm_izq, pwm_der, feedback, rumbo, rumbo_obj, imu_estado, seg_desde_cal]`. STOP publica `DONE` a los 0,5 s; el comando reemplazado recibe `ABORTED`; el rechazado corta la tracción y da `ERROR` con código (1–7).
  - `esp_log_level_set("*", ESP_LOG_NONE)` al arrancar (UART0 es de micro-ROS). `#error` si `CONFIG_FREERTOS_HZ < 1000`.
- **Configuración:** `sdkconfig.defaults` + `CONFIG_FREERTOS_HZ=1000`. `scripts/pc/build_motor.sh` acepta un target opcional (`esp32` / `esp32s3`) y corre `set-target` solo si cambia. README de scripts actualizado.
- **Compilación:** `esp32` OK, sin warnings, 0x4b7c0 bytes (71 % libre); `esp32s3` OK, 0x54ff0 bytes. La librería de micro-ROS compartida (`~/esp/micro_ros_espidf_component/libmicroros.a`, toolchain esp32) no se recompiló. Watchdog de tareas igual que la v3.2 (`CONFIG_ESP_TASK_WDT_INIT` sin activar).
- **Flasheo en la S3 de prueba** (`/dev/ttyACM0`, hashes verificados) y agente micro-ROS: **no hubo sesión**. Al leer el puerto, la placa arrancaba en modo descarga (`boot:0x3`) y con DTR/RTS fijos no salía ningún byte. **Causa:** `/dev/ttyACM0` es el **USB-Serial-JTAG nativo del S3 (`303a:1001`)**, no el CH343. micro-ROS está en el UART0 (conector COM). **Corrección:** el control de las 19:10 lo atribuí al CH343; el reset lo hizo el USB-Serial-JTAG. `test_mpu9250` funcionaba por ese puerto porque la consola secundaria del S3 también saca el `printf` por el USB nativo. GPIO 0 leído en alto desde el ROM (`GPIO_IN` bit 0 = 1): no hay nada que lo mantenga en bajo.
- **Docs:** `arquitectura.md` (sección del motor reescrita para la v4: control, formatos, modos, estados, códigos de error, uso recomendado desde el Brain, pines, ejemplos), `CLAUDE.md` (protocolo v4 y ejemplos), `pruebas.md` §4 (procedimiento de banco de la v4) y nota al final de §3.
- **Pendiente:** pasar el cable al conector COM y correr `pruebas.md` §4; el Brain sigue en el protocolo viejo de 7 campos.

## [13/11/26 Sesión 1] - Configuración Raspberry Pi 4 (Ubuntu 26.04 + ROS 2 Lyrical)
- **Situación:** La Raspberry Pi 5 original se perdió. Se tiene una Raspberry Pi 4 con Ubuntu 26.04 LTS "Resolute Raccoon" (aarch64, kernel 7.0.0-1017-raspi, 7,6 GB RAM) compartida con el proyecto `cabeza_social`. No es viable reflashear.
- **Decisión:** Instalar ROS 2 Lyrical (versión L, 2026, oficial para Ubuntu 26.04) en la Pi 4 en lugar de Jazzy (que es para Ubuntu 24.04). El tráfico ROS 2 es local a la Pi en producción; la PC queda en Jazzy solo para firmware.
- **Verificación previa:** `packages.ros.org/ros2/ubuntu` tiene paquetes `resolute` arm64. `apt-cache search "^ros-lyrical"` retorna paquetes. `ros-lyrical-micro-ros-agent` NO existe como paquete precompilado → hay que compilar desde source.
- **Instalación ROS 2 Lyrical:**
  - Locale configurado: `en_US.UTF-8`.
  - Clave GPG descargada a `/tmp/ros.asc` (2490 bytes) y convertida a `/usr/share/keyrings/ros-archive-keyring.gpg`.
  - Sources list: `deb [arch=arm64 ...] http://packages.ros.org/ros2/ubuntu resolute main`.
  - Paquetes instalados: `ros-lyrical-ros-base python3-argcomplete python3-rosdep python3-colcon-common-extensions build-essential`.
  - Verificado: `ros2` responde, `import rclpy` OK.
- **Compilación del micro-ROS agent:**
  - Clonado `micro-ROS/micro-ROS-Agent` branch `lyrical` en `~/microros_agent_ws/src/micro-ROS-Agent`.
  - `micro_ros_msgs` ya viene en `/opt/ros/lyrical`, ignorado en la compilación.
  - Dependencias: `ros-lyrical-micro-ros-msgs`, `ros-lyrical-rmw-fastrtps-cpp`, etc. instalados vía apt.
  - `microxrcedds_agent` NO está en apt; el agente usa un **SuperBuild** (CMake ExternalProject) que lo descarga y compila automáticamente.
  - Problema: cmake encontraba `~/.local/bin/python3.12` (de uv, del proyecto cabeza_social) antes que el Python del sistema. Solución: `PATH` sin `~/.local/bin` + `-DPython3_EXECUTABLE=/usr/bin/python3`.
  - Resultado: `Finished <<< micro_ros_agent [6min 20s]` (exit 0, solo warnings inofensivos de spdlog). Binario en `~/microros_agent_ws/install/micro_ros_agent/lib/micro_ros_agent/micro_ros_agent`.
  - Verificado: `micro_ros_agent --help` responde con la sintaxis de transportes.
- **Build del Brain:**
  - Copiado `ros2_ws/src/cortadora_brain/` desde la PC vía rsync.
  - Compilado con colcon en la Pi: `Finished <<< cortadora_brain [4.50s]`. Solo warning inofensivo de `tests_require` en setuptools.
  - Verificado: `ros2 pkg list | grep cortadora` → `cortadora_brain` visible.
- **Scripts nuevos en `scripts/pi/`:**
  - `env.sh`: source de lyrical + microros_agent_ws + ros2_ws, `MICROROS_AGENT` y `HOST_ROLE=pi`.
  - `run_brain.sh`: lanza `ros2 run cortadora_brain bumper_decision_node`.
  - `run_agent_serial.sh`: lanza el agente con `serial --dev $1 $2`.
  - Copiados a la Pi vía rsync. Verificado que `cortadora_brain` aparece en `ros2 pkg list`.
- **Docs actualizados:**
  - `CLAUDE.md`: tabla de bloques con "ROS 2 Lyrical" y "Pi 4 Ubuntu 26.04"; comandos de agente/Brain/topics ahora apuntan a `scripts/pi/`; nota distinguiendo PC (Jazzy, firmware) de Pi (Lyrical, producción).
  - `docs/00_estado_actual.md`: header del Brain actualizado a "Host Raspberry Pi 4 — Ubuntu 26.04 + ROS 2 Lyrical"; punto (d) de la hoja de ruta E7 marcado como resuelto.
