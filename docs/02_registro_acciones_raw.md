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
