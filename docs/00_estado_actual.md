# Estado Actual del Proyecto

**15/11/26: diagnóstico manual de tracción completo cargado.** `b` adelante, `r` atrás, `l` giro izquierdo (izquierda atrás/derecha adelante), `d` giro derecho (izquierda adelante/derecha atrás), `i` solo izquierda, todos+Enter; `s` parada inmediata. PWM100/255 máximo1s. Usuario confirma potencia apagada/ruedas levantadas/monitor cerrado. Compilación sin warnings, carga hashes verificados. Test sin potencia comprueba los cinco patrones exactos de cuatro canales, cada corte0/0 en1005ms y stop anticipado200ms, sin reinicio. Solo avance tiene confirmación física; retroceso/giros físicos pendientes. No controla ángulos con IMU ni prueba PIVOT/accesorios.

**15/11/26: prueba de retroceso preparada y cargada.** Main normal ya tiene modos ADELANTE/ATRAS. Se extiende MOTOR_PULSE_TEST: `b` ambos adelante (GPIO32/25 PWM), `r` ambos atrás (GPIO33/26 PWM), `i` izquierdo adelante; PWM100/255 durante1s y `s` parada. Antes de cada pulso todos LOW durante3ms. Usuario confirma potencia apagada/ruedas levantadas/monitor cerrado. Carga hashes verificados; con driver sin potencia se verifica avance y retroceso PWM100/100, corte0/0 en1005ms y parada anticipada en200ms, sin reinicios. Falta confirmación física de retroceso; avance ya confirmado por usuario.

**15/11/26: avance de ambas ruedas confirmado físicamente por el usuario.** Tras invertir la lógica derecha, ambas giran hacia adelante en la prueba manual `b` (PWM100/255,1s). Mapa confirmado: izquierda GPIO32 PWM/GPIO33 LOW; derecha GPIO25 PWM/GPIO26 LOW. El usuario confirma sentido, no informa explícitamente una nueva medición de duración/parada. Pendientes marcha atrás, giros, integración IMU/control y micro-ROS del motor. Firmware cargado sigue siendo MOTOR_PULSE_TEST; la corrección también está en fuente normal, aún no cargada.

**15/11/26: corrección de sentido derecho cargada.** Usuario confirma izquierda adelante/derecha atrás con prueba previa. Se cambia avance derecho a GPIO25 PWM/GPIO26 LOW tanto en MOTOR_PULSE_TEST como en apply_motor_command del firmware normal (reversa invertida en consecuencia). Izquierda GPIO32 PWM/GPIO33 LOW sin cambios. Usuario confirma potencia apagada, ruedas levantadas y monitor cerrado; diagnóstico recompilado/cargado con hashes verificados. Pendiente confirmar físicamente ambos hacia adelante con `b`+Enter (PWM100,1s). No se ejecutó movimiento desde el asistente.

**Corrección verificada del programa de pulsos (14/11/26):** prueba activa con potencia apagada confirma que `b` sí llegaba, pero `ledc_set_duty_and_update` fallaba por faltar `ledc_fade_func_install`, provocando abort/reinicio sin PWM. Error del diagnóstico corregido y cargado. Lectura de duty tras esperar latch PWM: ambos100 durante pulso, ambos0 después; corte automático1005ms y corte con `s`203ms, sin reinicios. Verificación con driver SIN potencia; movimiento físico y driver aún pendientes. Se conserva PWM100/255, duración1s y corte de ambos canales. Este resultado invalida la hipótesis de PWM insuficiente como explicación demostrada de las pruebas anteriores.

**Prueba de ambos motores cargada:** tras confirmar potencia apagada/ruedas levantadas y cerrar monitor, se carga MOTOR_PULSE_TEST con hashes verificados. Captura inicial: izquierda PWM0/derecha PWM0, `b`+Enter=ambos a100/255 durante1s, `i`+Enter=izquierdo, `s`=parada. Asistente no envió movimiento. Pendiente prueba física del usuario.

**Prueba de ambos motores preparada, sin cargar:** usuario pide probar ambos y confirma potencia apagada/ruedas levantadas. MOTOR_PULSE_TEST compilado: `b`+Enter activa izquierda GPIO32 y derecha GPIO26 a PWM100/255 durante máximo1s (GPIO33/25 LOW); corte automático y `s` detienen ambos canales. `i` conserva solo izquierda. Pendiente cerrar monitor serial que ocupa ttyUSB0; la placa aún tiene prueba solo izquierda. No se ha confirmado movimiento ni recepción de comandos.

**Actualización pulso izquierdo:** usuario confirma potencia desconectada y ruedas levantadas; se cargó PWM100/255 durante1s con hashes verificados. Captura inicial confirma cabecera PWM100/1000ms y PARADO/PWM0. No se enviaron comandos de movimiento; pendiente ejecución manual `i`+Enter y verificación de parada. Esta carga reemplaza PWM40/300ms.

**Cambio preparado, sin cargar:** el usuario solicita pulso izquierdo PWM100/255 durante1s tras no observar movimiento con40/255 durante300ms. Fuente y build MOTOR_PULSE_TEST actualizados, parada automática y `s` conservadas. Usuario confirma que todavía no apagó potencia/levantó ruedas; NO se flashea ni se envía movimiento hasta confirmar esas condiciones. El ESP conserva el firmware de pulso40/255–300ms previamente cargado. La captura aportada solo mostraba arranque, sin confirmación de recepción del comando `i`; no se atribuye aún la falta de movimiento a PWM insuficiente.

**Prueba vigente motores: pulso manual izquierdo (14/11/26).** Usuario confirma potencia apagada y ruedas levantadas. Firmware separado MOTOR_PULSE_TEST cargado con hashes verificados; PWM de arranque0, GPIO33/25/26/18 LOW. Solo `i`+Enter inicia GPIO32 a PWM40/255 durante máximo300ms, con esp_timer de corte y `s` como parada anticipada; comandos acumulados durante pulso se descartan. Sin ROS, sin pruebas de giro ejecutadas por el asistente. Captura inicial confirma PARADO/PWM0; pendiente primera activación física por usuario y confirmación de parada. La ausencia de arranque con el diagnóstico previo fue confirmada por el usuario, pero la causa del arranque con el firmware anterior no se determinó.

**Trabajo activo: ESP32 motores, 14/11/26.** Usuario reporta arranque del motor izquierdo al energizar driver; potencia desconectada y causa pendiente, no volver a energizar para esta prueba. PC detecta CP2102 ttyUSB0 / chip ESP32-D0WDQ6 rev1.1, MAC8c:4f:00:ab:66:98. Cabecera instalada antes de escribir: proyecto int32_publisher, versión1, compilado20/04/2026 22:24:30 (no se presume v4). Se cargó diagnóstico separado MOTOR_DIAGNOSTICS, sin ROS/PWM/comandos: GPIO32/33/25/26 y18 configurados LOW al entrar a app_main. No es garantía del estado durante reset ni prueba eléctrica del driver. IMU SDA27/SCL14 responde0x68 WHO0x75; captura5s:19 lecturas correctas,0errores, aceleración≈0,976g, giro RAW≈(+8,97,+1,60,-0,02)dps; sin calibración en este diagnóstico. Firmware normal también actualizado a SDA27/SCL14, aún no cargado en esta placa.

**Última verificación 14/11/26: Raspberry Pi 4 / ROS 2 Lyrical.** Sensor USB nativo detectado por su identificador estable; agente iniciado con `nohup` (PID10321), log `/tmp/cortadora-sensor-agent.log`. Captura de 18 s: 334 mensajes de 24 campos a 18,5167 Hz, intervalos 52,29–56,59 ms; sin errores de longitud, valores bumper/IMU o coherencia GPS. El usuario confirma que la línea de 5 V estaba apagada y la enciende. Segunda captura: 334 mensajes a 18,5204 Hz, intervalos 53,12–54,91 ms, sin errores de las comprobaciones; distancias I/C/D 54,74/68,58/57,71 cm. Telemetría conjunta comprobada también en Raspberry. GPS fix=0/sats=0, IMU finito, bumpers 0/0/0. No se ejecuta Brain. Agente activo sin configuración de arranque automático.

**Verificación vigente 14/11/26: firmware normal micro-ROS cargado y agente activo en la PC.** Se reemplazó el diagnóstico solo bumpers por firmware normal (SENSOR_DIAGNOSTICS=OFF), con GPS RX4/TX5, IMU 0x68 y bumper derecho GPIO39. Carga con hashes verificados. `/sensores`: 334 mensajes de 24 campos en 18 s, 18,51 Hz, intervalos 52,74–55,00 ms; 0 errores en comprobaciones de longitud, bumpers 0/1, IMU finito y coherencia fix/coordenadas. **Ultrasónicos corregidos al encender línea de 5 V:** usuario confirma que estaba apagada; segunda captura de 18 s recibe 333 mensajes a 18,52 Hz, intervalos 53,36–54,59 ms, 0 errores de las comprobaciones anteriores. Últimas distancias: izquierda 45,65 cm, centro 67,95 cm, derecha 65,67 cm. Adquisición conjunta y transporte ROS comprobados en PC; la comparación contra referencia física pertenece a las pruebas individuales previas. Bumpers 0/0/0, IMU finito, GPS fix=0/sats=0 (sin posición), APP en valores por defecto. Brain no ejecutado. Prueba en Raspberry con este firmware todavía pendiente.

**Actualización de hardware:** el usuario confirma ESP32-S3 **N16R8**. GPIO35/36/37 reservados internamente: el GPS RX35/TX36 anterior no es válido y la validación previa del bumper derecho en GPIO37 no acredita compatibilidad eléctrica. GPS recableado por el usuario a RX4/TX5 y diagnóstico cargado con hashes verificados; captura de 10 s: solo 1 byte inicial, 0 líneas NMEA. No se resolvió aún la recepción. Bumper derecho movido por el usuario a GPIO39; código y diagnóstico cargados, pendiente prueba de accionamiento en el nuevo pin. No habilitar PSRAM para intentar resolver el conflicto.

**NOTA:** Este es un documento **VIVO**. Siempre debe representar con exactitud milimétrica el estado actual del código, pruebas e integraciones. A diferencia de las bitácoras, este documento **SÍ se edita y sobrescribe** permanentemente. Antes de empezar cualquier tarea o después de terminarla, se debe revisar y actualizar este archivo.

---

## 1. Estado General de los Subsistemas

### 🧠 Cerebro ROS 2 (Host Raspberry Pi 4 — Ubuntu 26.04 + ROS 2 Lyrical)
- **Estado:** ⚠️ Desactualizado respecto al firmware del motor.
- **Detalle:** El nodo `bumper_decision_node.py` todavía despacha un **protocolo viejo de 7 campos** (`[cmd_id, l_dir, l_pwm, r_dir, r_pwm, duration_ms, bordeadora_on]`, sin `cortadora_on`; verificado en la línea 137 el 28/10/26). El firmware del motor v4.0 usa el **protocolo v4** (`motion_cmd` de 5 campos con velocidad en cm/s y `motion_status` de 9 campos, ver `docs/arquitectura.md`). El Brain debe reescribirse para enviar comandos de alto nivel (modo + parámetro) antes de la integración end-to-end.
- Se suscribe a `sensores` con QoS `BEST_EFFORT` y solo usa los índices 0–2 (bumpers) con `len >= 3` → es compatible con el array de 24 valores.

### 🔌 Firmware Sensores (ESP32-S3) — v7.0
- **Estado:** compilado y flasheado en la PC el 13/11/26. Comunicación USB micro-ROS validada en la PC: sesión, participante, publicador y recepción de `/sensores` con 24 valores. También validado en Raspberry Pi 4 / ROS 2 Lyrical: mensaje de 24 campos y unos 18,5 Hz durante 15 s. Falta validar los sensores físicos.
- Publica `/sensores`, `Float32MultiArray`, QoS reliable, espera nominal de 50 ms entre publicaciones. Índices 0–14 para sensores/GPS y 15–23 para APP.
- Transporte por **USB-Serial-JTAG nativo**, exclusivo para micro-ROS. Se sustituyó el controlador con interrupciones por acceso al FIFO con esperas limitadas y cesión al scheduler; la consola USB debe permanecer deshabilitada. Resolución FreeRTOS configurada en 1000 Hz.
- Mapa S3: bumpers 38/2/37, ultrasonidos 18/16, 8/9, 17/15, IMU 6/7 (0x68, detectado en hardware), GPS RX35/TX36. Cableado y lecturas físicas aún por validar.
- Sin APP, los campos 15–23 son `0,0,0,0,0,0,0,-1,0`. Bluetooth pendiente; la protección por comando viejo (>300 ms) permanece activa.
- Se conservan el parser GGA con campos vacíos y los respaldos del sensor clásico en `firmware/esp32_sensor/versions/`.
- El IMU del sensor es de monitoreo; el motor controla el rumbo con su propio IMU.

### Diagnóstico local de adquisición del sensor — cargado, validación física en curso

- **Prueba vigente 14/11/26: bumpers, derecho trasladado a GPIO39.** Usuario mueve cable 37→39; se actualiza `PIN_B_R` y se carga diagnóstico con hashes verificados. Captura inicial: izquierdo GPIO38=1 LIBRE, central GPIO2=0 LIBRE (activo HIGH), derecho GPIO39=1 LIBRE (activo LOW). Pendiente presionar/soltar el derecho en su nuevo pin. GPS en protoboard validado previamente; este firmware inicia solo bumpers.

- **GPS en protoboard: recepción recuperada al conectar VDD_B (14/11/26).** Usuario identifica VDD_B omitido al trasladarlo y lo conecta. Sin modificar firmware, captura de 10 s: 1297 bytes, 36 líneas, GGA válidos continuos; checksum_mal=1 inicial sin incrementos. fix=0/sats=0: posición pendiente al aire libre. Este resultado reemplaza la falla de recepción del traslado anterior.

- **Última prueba: GPS trasladado al protoboard (14/11/26), recepción perdida.** Con el mismo firmware pasivo (ELF 0e1f16581…), captura de 12 s: solo 00 inicial, 1 byte total y 0 líneas NMEA. Antes del traslado, con RX conectado, se recibían 2864 bytes/64 líneas. Pendiente revisar tensiones VDD/VDD_B respecto de GND del módulo en el nuevo montaje, masa común y continuidad TX GPS→GPIO4. No se atribuye todavía causa específica.

- **GPS con RX conectado a GPIO5 (14/11/26):** usuario conecta RX GPS←GPIO5 manteniendo TX GPS→GPIO4 y VDD/VDD_B. Recepción pasiva de 12 s: 2864 bytes y 64 líneas en último resumen; GGA continuo, checksum_mal=1 inicial sin aumentos. Conectar RX no interfiere con NMEA. No se enviaron comandos: capacidad del GPS para recibir/responder todavía sin validar. fix=0/sats=0; posición al aire libre pendiente.

- **GPS: recepción UART validada el 14/11/26 tras alimentar VDD_B.** Usuario midió VDD y VDD_B ≈3,18 V respecto de GND, retiró jumper y conectó TX GPS→GPIO4, RX GPS desconectado. Se restauró diagnóstico pasivo fijo a 9600 baud (sin loopback ni barrido), con hashes verificados. Captura de 12 s: 1523 bytes / 43 líneas en último resumen, GGA válidos continuos; 1 checksum malo inicial que no aumentó. Estado fix=0, satélites=0, coordenadas NaN: comunicación comprobada, posición pendiente de validar al aire libre. El requisito VDD_B está documentado en UP501.pdf sección 4.2; identificación exacta de la variante no confirmada visualmente.

- **Prueba vigente 14/11/26: loopback físico UART2 GPIO5→jumper→GPIO4, GPS desconectado.** Usuario midió 3,1 V en alimentación GPS. Se cargó diagnóstico sin tarea GPS; 8/8 mensajes distintos de 43 bytes regresaron idénticos, 0 fallos a 9600 baud. UART2, TX5 y RX4 funcionan en esta prueba. GPS sigue sin validarse; falta medir TX del módulo e identificar sus requisitos. El firmware actual transmite texto de prueba por GPIO5: restaurar diagnóstico pasivo antes de reconectar RX del GPS.

- **GPS 14/11/26:** usuario informa alimentación desde 3V3, módulo aislado con inscripción FSTR2 C01020-09. Captura completa del barrido UART existente (33 s, seis velocidades) sin NMEA ni tráfico continuo: solo 00 inicial. Falta medir tensión real y comprobar señal TX/entrada RX; no se identificó documentación de alimentación nominal del módulo.

- **Prueba vigente: solo GPS RX35/TX36 a 9600 baud.** El usuario confirmó respuesta física del IMU (inclinación/giro); calibración del acelerómetro sigue pendiente. Diagnóstico GPS cargado con hashes verificados: captura de 10 s con solo 1 byte inicial, 0 líneas NMEA y sin GGA/posición. GPS todavía no validado; revisar alimentación, masa común y TX del GPS hacia RX35.

- **Prueba vigente: solo IMU.** Los tres ultrasónicos fueron aceptados por el usuario. IMU detectado en 0x68 con WHO_AM_I=112 (0x70), sin respuesta en 0x69. Se corrige `MPU_ADDR` a 0x68 y se carga diagnóstico exclusivo con hashes verificados. Captura de 15 s: init OK, calibración 300/300, 930 lecturas exitosas / 0 errores al final, giro corregido cercano a cero, ángulos estables (roll≈4,18°, pitch≈−3,06°). Módulo del acelerómetro ≈0,93 g: lectura disponible, escala/offset pendientes de validación/calibración. Falta prueba física de inclinación/giro; no se declara precisión validada.

- **Prueba vigente: ultrasonido derecho TRIG17/ECHO15.** El usuario acepta izquierdo y central; no aportó mediciones de referencia. Diagnóstico derecho compilado y cargado con hashes verificados, solo dispara ese sensor. Captura inicial de 3 s: 11 lecturas de 63,9 cm sin errores. Pendiente confirmación física del derecho y comparación con distancias conocidas.

- **Prueba vigente: ultrasonido central TRIG8/ECHO9.** El usuario dio por correcta la prueba del izquierdo (sin aportar lecturas de referencia). Diagnóstico central compilado y cargado con hashes verificados; captura inicial de 3 s: 56,9–75,3 cm, luego alrededor de 74,9–75,3 cm, sin errores en esa captura. Pendiente comparación física con distancias conocidas. Solo se dispara el central; otros sensores y micro-ROS no se inician.

- **Bumpers validados por el usuario:** izquierdo y derecho activos LOW; central con circuito activo HIGH. El usuario confirmó funcionamiento correcto del central y del derecho después de haber probado el izquierdo.
- **Prueba activa cargada:** solo ultrasonido izquierdo (TRIG18/ECHO16), usando `medirDistancia` del firmware; salida cada 250 ms con cm o código/error y niveles ECHO. Diagnóstico cargado con hashes verificados. Primera captura de 3 s: lecturas positivas entre 46,9 y 69,6 cm, sin errores en esa captura. Pendiente comparar con distancias medidas de 20/50/100 cm; todavía no se valida precisión.

- **Polaridad central actual: activo HIGH.** Con el diagnóstico activo LOW, el usuario confirmó explícitamente reposo=PRESIONADO y accionado=LIBRE. Se volvió a cargar el central HIGH=presionado / LOW=libre, con hashes verificados. Laterales activos LOW y pull-up sin cambios. La cabecera serial identifica esta configuración. Pendiente confirmar ciclo completo con esta nueva carga; el módulo y su alimentación aún no están identificados.
- **Prueba activa: SOLO BUMPERS.** Por pedido del usuario se cargó una nueva compilación que inicia únicamente `bumper_task` y el diagnóstico USB. No inicia IMU, GPS, ultrasonidos ni micro-ROS. Muestra estado por nombre/GPIO, cambios y contadores, con resumen cada 2 s. Las pulsaciones cuentan flancos muestreados, sin antirrebote; no constituyen por sí solas prueba de contactos correctos. Pendiente accionar físicamente izquierdo, central y derecho por separado.

- El agente del sensor en la Pi (PID 30840) está detenido. El diagnóstico sin micro-ROS se cargó desde la PC al sensor S3 el 13/11/26, con hashes verificados. La salida USB se capturó durante 7 s.

- A pedido del usuario se prioriza validar los sensores sin micro-ROS. `scripts/pc/build_sensor_diagnostics.sh` genera un firmware separado en `build_diagnostics/`, sin biblioteca ni tarea micro-ROS; `flash_sensor_diagnostics.sh PUERTO` lo carga desde la PC.
- Comparte las tareas y pines del firmware normal. Salida USB legible cada 500 ms: bumpers, distancias/códigos de error y edad, presencia/WHO_AM_I en 0x68/0x69, muestras de calibración, aceleración/giro/ángulos y fallos de lectura, bytes y líneas NMEA, checksum, fix y antigüedad GPS. APP/BLE y 4.º bumper se indican como no implementado/reservado.
- Correcciones de adquisición en el código fuente: IMU inválido como `NaN`, configuración explícita de escalas, calibración dividida por muestras exitosas (mínimo 270/300), timestamps de cada ultrasonido, validación de checksum/estructura/coordenadas GGA y descarte de líneas desbordadas.
- Compilación del diagnóstico y del firmware normal verificadas. Pruebas C del parser GPS verificadas. **Diagnóstico ya cargado; falta validar físicamente cada sensor.** El sensor está en la PC, ejecutando diagnóstico sin micro-ROS. Primera captura: bumpers 0/0/0 (todavía sin accionarlos), tres ultras en -4 (ECHO alto previo a TRIG), IMU sin respuesta en 0x68/0x69, GPS con solo 1 byte y sin líneas NMEA. Falta confirmar alimentación y cableado; estos resultados no prueban sensores correctos.
- Procedimiento y criterios de prueba en `docs/pruebas.md`, sección «Diagnóstico de adquisición sin micro-ROS».

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

### Verificación del agente y sensor S3 — 13/11/26, sesión nocturna

- Acceso SSH a la Pi verificado. Sensor S3 conectado por el conector **USB nativo**, VID:PID `303a:1001`, identificado como `7C:E8:B1:A2:8E:24`.
- El transporte actual del sensor es `usb_serial_jtag`, no UART0. Las referencias anteriores a cargar el sensor clásico o usar COM no describen esta prueba.
- Reiniciar con EN cambió el puerto de `/dev/ttyACM0` a `/dev/ttyACM1`. Usar `/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_7C:E8:B1:A2:8E:24-if00` al lanzar el agente; si el dispositivo se reenumera, el agente debe reabrirlo.
- Captura de arranque: `SPI_FAST_FLASH_BOOT`, aplicación `int32_publisher`, ESP-IDF v5.2, compilación del 13/11/26 a las 18:47, prefijo SHA ELF `a99c3e1a6…` compatible con el binario local. Esto acredita una carga del sensor S3, pero no valida su publicación.
- **Resultado inicial en la Pi (antes de corregir el firmware):** no se establecía sesión micro-ROS ni aparecía `/sensores`, incluso con `-v6`, liberando DTR/RTS y probando el puente USB existente. Solo aparecen `/parameter_events` y `/rosout`. No se enviaron comandos de movimiento ni se ejecutó el Brain.
- Se encontraron cambios de la sesión anterior solo en la Pi: `scripts/pi/usb_jtag_bridge.py` y parches a `TermiosAgentLinux.cpp` / `SerialAgentLinux.cpp` del agente. No se consideran solución validada ni están incluidos en el commit `3d617df`.
- **Corrección en la PC:** las marcas temporales confirmaron el arranque de las tareas. Con el controlador USB anterior no se completaba la comunicación; al sustituirlo por acceso al FIFO se obtuvo `/sensores` con 24 valores, sin puente ni parches del agente local. Las marcas se retiraron. Primera medición: 11,11 Hz con ticks de 10 ms. Con FreeRTOS a 1000 Hz, la compilación final publicó a unos **18,5 Hz** durante 15 s (intervalos de 53–55 ms); mensaje de 24 campos confirmado. Compilación sin warnings y carga con hashes verificados. **Validación posterior en la Pi:** con el firmware corregido, conexión directa sin puente, `/sensores` recibido con 24 campos y frecuencia de unos 18,5 Hz durante 15 s. Se usó el agente instalado con los parches preexistentes; no se evaluó si esos parches siguen siendo necesarios. Agente dejado en segundo plano con `nohup`, log `/tmp/cortadora-sensor-agent.log` (sin arranque automático tras reiniciar la Pi).
- **Reconexión pendiente en firmware:** al reiniciar el agente, el sensor no restableció por sí solo la sesión. Se reinició el sensor por RTS y se confirmó un mensaje de 24 campos con el agente definitivo en segundo plano. Por ahora, reiniciar también el sensor si se reinicia el agente.

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
