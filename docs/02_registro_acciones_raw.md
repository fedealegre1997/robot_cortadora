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
