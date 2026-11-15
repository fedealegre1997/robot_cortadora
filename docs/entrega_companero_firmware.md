# Entrega para el compañero de firmware — recomendaciones para BLE, Brain v4, watchdog del motor y seguridad

**Estado: borrador para revisión de la usuaria y de su compañero.** No es un diseño cerrado. Son recomendaciones, y nada de lo que sigue está implementado, compilado ni probado en el robot.

Convenciones del documento:
- **PREGUNTA:** algo que solo se resuelve con información que no tenemos (hardware, estado de la PC Linux).
- **SUPUESTO:** valor o hecho que asumí para poder recomendar; hay que confirmarlo.
- **PROPUESTA:** una recomendación mía, sin decidir.
- Las citas `archivo:línea` son de la lectura del código en este repositorio (solo lectura, sin compilar).

**Alcance de esta entrega.** La usuaria hace toda la app (en la PC Windows). El compañero se encarga del firmware BLE del ESP32, del Brain v4, del watchdog del motor y de las pruebas físicas. Ni la usuaria ni quien escribió este borrador tocaron firmware, scripts, `CMakeLists`, `ros2_ws/` ni nada de la PC Linux.

Documentos relacionados: `docs/protocolo_ble_app_esp.md` (contrato BLE, v1.0, pendiente de revisión), `docs/e7_app_android.md`, `docs/arquitectura.md`, `docs/pines.md`, `docs/componentes.md`, `docs/pruebas.md`, `docs/00_estado_actual.md`.

---

## 1. Resumen y mapa de responsabilidades

### 1.1 Quién hace qué

| Responsable | Qué hace |
|---|---|
| **La usuaria** (PC Windows) | App Android "Gramanova": control manual, heartbeat de 10 Hz, STOP, selector de estado, banner de modo simulado. APK de prueba con robot simulado. Mantiene el contrato BLE del lado de la app. Más adelante: mapa y editor de área (fase 6) |
| **El compañero** (PC Linux) | Firmware BLE del ESP32 sensor · reescritura del Brain a protocolo v4 y nodo `working_area_node` · watchdog de 500 ms del firmware del motor · cableado y pruebas físicas · calibración en piso |
| **Ambos** | Revisión del contrato BLE (`protocolo_ble_app_esp.md`) antes de congelarlo; decisiones abiertas de la sección 9 |

### 1.2 Cadena completa y tiempos

```
[APP Android] --BLE--> [ESP32-S3 sensor] --micro-ROS--> [Raspberry Pi] --micro-ROS--> [ESP32 motor]
  heartbeat 10 Hz        corte > 300 ms      /sensores 50 ms      Brain               watchdog 500 ms
```

| Tramo | Tiempo | Origen |
|---|---|---|
| App → ESP (heartbeat) | **100 ms** (10 Hz) | `AppConfig.heartbeatPeriod` en la app |
| Enlace BLE | intervalo de conexión 15–30 ms (propuesta, a calibrar) | `protocolo_ble_app_esp.md` §2.2 |
| ESP sensor: corte de seguridad | **> 300 ms** sin comando válido → dir/cutter/trimmer = 0 (300 vale, 301 corta) | contrato; `APP_CMD_TIMEOUT_US` en el sensor |
| ESP sensor → Brain | `/sensores` cada **50 ms**, reliable | `arquitectura.md`; `ROS_PUBLISH_MS` |
| Brain: ciclo de decisión | recomendado **≥ 20 Hz (50 ms)**. El nodo actual corre a 5 Hz (timer de 0,20 s) | `bumper_decision_node.py:114` |
| Brain → motor (latido) | recomendado **5 Hz (200 ms)** | sección 4.5 |
| Motor: ejecución | executor de 10 ms, lazo de control ~100 Hz | `main.c:1395`, `:1424` |
| Motor: watchdog propuesto | **500 ms** sin `motion_cmd` válido | sección 5 |
| Transporte micro-ROS | UART a 115200 baud (motor) | `esp32_serial_transport.c:18` del motor |

**Mensajes ESP → app que se agregaron al contrato original (14/11/26, de la usuaria):** `AREA` (`{"t":"AREA","id":N}`, 20–24 B: informa el área activa al conectarse y cada vez que cambia; es un **requisito**) y `ESTOP` (`{"t":"ESTOP","why":"T"}`, 24 B: avisa que el ESP quedó en STOP retenido; el aviso es requisito, **el formato es propuesta**). La app todavía no decodifica ninguno de los dos (segunda APK). Detalle en `protocolo_ble_app_esp.md` §5.8 y §5.9.

**Presupuesto de peor caso** (app congelada pero con el enlace BLE vivo, hasta que las ruedas se detienen):

| Paso | Hasta |
|---|---|
| El ESP detecta antigüedad > 300 ms | 300 ms |
| Siguiente publicación de `/sensores` | +50 ms |
| Siguiente ciclo del Brain | +50 ms |
| Brain → motor y ejecución en el motor | +~30 ms |
| **Total, sin contar latencia de DDS/agente (PREGUNTA: medirla)** | **~430 ms** |

A 10 cm/s son ~4 cm de recorrido; a 25 cm/s, ~11 cm; a la velocidad máxima estimada del firmware (~57 cm/s), ~25 cm. Por eso las primeras pruebas van con tope bajo (sección 4.6).

Si lo que falla es el Brain o el agente micro-ROS, no hay nadie que mande STOP: ahí solo protege el watchdog del motor (500 ms, sección 5).

---

## 2. Preguntas para el compañero (bloquean algo de la cadena)

### 2.1 Sensor v7.0 y estado de las placas

1. **¿El firmware v7.0 del sensor se compiló? ¿Se flasheó?** El código (`firmware/esp32_sensor/active/active/main/main.c`, "Version: 7.0 — port a ESP32-S3 N8R2", 13/11/26) está portado, pero `docs/00_estado_actual.md` §1 todavía lo da como v6.2 sobre el ESP32 clásico y dice que no hay registro de flasheo.
2. **¿El micro-ROS del sensor sale por el USB nativo o por el conector COM (UART0)?** Los textos se contradicen:
   - **Código:** `esp32_serial_transport.c` usa el driver `usb_serial_jtag` (USB nativo) y `sdkconfig.defaults` del sensor dice "micro-ROS por USB-Serial-JTAG nativo".
   - **Pero** la cabecera del mismo `main.c` dice "La UART0 es exclusiva de micro-ROS", y `app_main` pasa `uart_port = UART_NUM_0`.
   - **Docs:** `docs/pines.md` §1 dice que micro-ROS va por UART0 → conector COM (pines 43/44, "No cablear"). `docs/arquitectura.md` (banco del motor) y `docs/pruebas.md` §4 dicen que el USB nativo `303a:1001` **no sirve** para el agente.

   Hay que unificar. Afecta qué cable se usa, cuál es el puerto en Linux (`/dev/ttyACM0` en ambos casos) y dónde va la consola de logs. No afecta el protocolo BLE, pero sí el diseño del firmware del paso 3.
3. **¿Ya se hizo el intercambio físico de placas** (S3 al sensor, ESP32 clásico al motor)? ¿Qué placa tiene hoy cada firmware?
4. **¿El disco de la PC Linux tiene cambios sin subir** respecto de `main` en GitHub? (pendiente (a) de `00_estado_actual.md` §2). Hasta que se sepa, esta PC no puede asumir qué versiones del firmware y del Brain están realmente en el repositorio.

### 2.2 Otras preguntas

5. **Raspberry Pi 4 o Pi 5, y ROS 2 Lyrical o Jazzy.** `00_estado_actual.md` §1 y su lista de decisiones dicen Pi 4 + Ubuntu 26.04 + ROS 2 Lyrical (confirmado el 13/11/26). `componentes.md` y `e7_app_android.md` dicen Pi 5 y Jazzy. Hay que corregir el que esté mal.
6. **Hoja de datos del driver CBE-12A1C:** no está en `Datasheet/`. ¿La tenés? La necesitamos para la sección 6.1 (pull interno de INHIBIT̄, umbrales lógicos).
7. **Modo del Sabertooth:** ¿cómo están los DIP? El firmware habla en modo serial simplificado a 9600 baud.
8. **¿Qué pasa en el firmware del motor si el agente micro-ROS se cae con el robot en marcha?** La publicación de estado es reliable y podría bloquear el lazo (`rcl_publish`). No lo revisé en ejecución.
9. **Estado de los pines del motor durante un reset o flasheo:** ¿las entradas del MC33926 (GPIO 32/33/25/26 en el clásico) tienen pull-down? Si quedan flotantes, las ruedas podrían moverse. `pines.md` §2 ya advierte de 5/14/15 por pulsos PWM al arrancar.
10. **Corte físico de emergencia:** ¿qué contactor o interruptor DC tenemos o podemos conseguir, y de qué capacidad? (sección 6.2).
11. **Velocidad de línea del agente y volumen de tráfico** con el latido del Brain (115200 baud): ¿está bien con status a 200 ms + latido a 5 Hz + `/sensores` a 20 Hz?
12. **Enclavamientos por roll/pitch:** ¿qué inclinación máxima tolera la cuchilla? No hay ningún valor en los docs.

---

## 3. Firmware BLE del ESP32 sensor (recomendaciones de diseño)

Es una guía: **nada se compila ni se flashea desde esta entrega.** El contrato exacto (mensajes, rangos, ejemplos, seguridad) está en `docs/protocolo_ble_app_esp.md`; no se repite acá.

### 3.1 Plataforma

- **NimBLE** sobre el **ESP32-S3-WROOM-1 N8R2** (8 MB de flash, 2 MB de PSRAM, solo BLE). Decisión ya tomada (`e7_app_android.md` §10).
- **Partición de aplicación:** `e7_app_android.md` §2 habla de 1 MB (placa clásica de 2 MB de flash). El S3 tiene 8 MB, así que conviene una tabla de particiones propia. **PREGUNTA:** ¿qué tabla de particiones usa hoy el sensor v7.0? El v6.2 ocupaba 285 KB.
- La PSRAM no se debe usar para el stack BLE ni para los búferes del transporte micro-ROS (SUPUESTO: quedan en RAM interna). Verificar contra `pines.md` §3.1 (con N8R2, la PSRAM es de 2 MB en modo quad; no activar el modo octal).

### 3.2 Tareas y núcleos

Tareas actuales del sensor (`main.c:228-234`):

| Tarea | Core | Prioridad | Stack | Período |
|---|---|---|---|---|
| `ultra_task` | 0 | 6 | 4096 | ~180 ms |
| `gps_task` | 0 | 5 | 6144 | continua |
| `bumper_task` | 1 | 7 | 4096 | 10 ms |
| `imu_task` | 1 | 6 | 8192 | 10 ms |
| `uros_task` | 1 | 4 | 16384 | 50 ms |

Recomendaciones:
- La tarea de NimBLE (host) agrega una tarea más, y el controlador BLE usa interrupciones de radio. **PROPUESTA:** probar primero el host y el controlador en el **core 0** (con las tareas lentas), para no tocar los 10 ms de bumpers/IMU ni los 50 ms de micro-ROS del core 1. Los nombres de opciones de Kconfig (por ejemplo, `CONFIG_BT_NIMBLE_PINNED_TO_CORE`) hay que verificarlos contra la versión de ESP-IDF usada.
- **Riesgo para medir:** la medición de los ultrasónicos (`ultrasonic_task`, en core 0) depende de tiempos de microsegundos. Las interrupciones del radio BLE podrían meter jitter (58 µs ≈ 1 cm). **Comparar la medición de distancia con y sin BLE conectado** (sección 3.9). Si hay error visible, probar el BLE en el core 1.
- Los callbacks de GATT **no deben bloquear** ni tomar el mutex por tiempo largo. Idea: el callback de escritura solo acumula bytes en un búfer estático de 512 B hasta `\n` y empuja la línea completa a una cola de FreeRTOS; una tarea aparte la interpreta.

### 3.3 Presupuesto de RAM junto con micro-ROS

- **No tengo cifras medidas.** Cualquier número que se estime acá sería inventado. Se debe **medir**: heap libre y mínimo histórico (`esp_get_free_heap_size`, `esp_get_minimum_free_heap_size`) con (a) v7.0 sin BLE, (b) con NimBLE iniciado y anunciando, (c) con una conexión emparejada y 10 Hz de tráfico durante 30 min.
- Zonas de consumo a vigilar: stack de `uros_task` (16 KB, ya grande), búfers de micro-ROS y XRCE, el búfer de recepción de BLE (512 B más una línea en cola), el polígono (hasta 10 vértices = 80 B por búfer, dos búferes), la tabla de bonds en NVS.
- **Criterio propuesto:** un margen de heap mínimo histórico que decida el compañero (SUPUESTO: al menos varias decenas de KB libres, a confirmar con la medición) y cero reinicios en 30 min.
- Mantener el logging apagado: `esp_log_level_set("*", ESP_LOG_NONE)` (`main.c`, `app_main`). Cualquier `printf` puede corromper el transporte de micro-ROS. La clave de emparejamiento **nunca** se loguea.

### 3.4 Publicadores y topics

- `MAX_PUBLISHERS=4` en `app-colcon.meta`; hoy se usa 1 (`/sensores`). Con `/app/working_area` se usan 2, dentro del límite. `MAX_SUBSCRIPTIONS=0` sigue igual: **el ESP no recibe nada de la Raspberry.**
- **`/sensores`** (`Float32MultiArray`, 24 valores): los índices 15–23 se completan según `protocolo_ble_app_esp.md` §8.3 (tabla por caso). Puntos importantes:
  - El corte de 300 ms se calcula **en un solo lugar**, en el publicador: `edad_us = ahora − t_último_cmd_válido`; corta si `edad_us > 300000` (300 vale, 301 corta). Esa edad también es el índice 22.
  - Los callbacks BLE solo actualizan `g_app_*` y el instante de recepción bajo el mutex existente (`g_data_mutex`), de forma breve.
  - Todos los enteros hasta 65535 son exactos en Float32.
- **`/app/working_area`** (`Int32MultiArray`): `[id, n, lat0, lon0, …]`, hasta `2 + 2×10 = 22` int32 (88 B). Se republica cada ~2 s y de inmediato al aceptar un POLY. **PROPUESTA:** QoS reliable (un suscriptor reliable o best_effort lo recibe). **PREGUNTA:** ¿qué publica el ESP tras un `PCLR`? El doc no lo define. Propuesta: `[0, 0]` (id 0 = "ninguna") durante unos ciclos, además del índice 23 = 0.
- **REQUISITOS nuevos (14/11/26), detalle en `protocolo_ble_app_esp.md` §5.4, §5.8 y §8.1; podés objetarlos por memoria o seguridad:**
  - **`app_state` → 0** si la app se desconecta o el último comando tiene > 300 ms (**la usuaria**, 14/11/26). El índice 16 se publica así; no se restaura al reconectar. **Requisito pendiente de implementar en el firmware:** el v7.0 fuerza solo dir/cutter/trimmer (`main.c` ~773-777).
  - **STOP retenido en AUTO (la usuaria, 14/11/26):** tras un corte > 300 ms en AUTO_RUN o AUTO_PAUSE el ESP queda en `app_state=0` y **no reanuda con comandos frescos `state:2/3`** hasta un comando `state:0` y uno posterior que pida AUTO (también con el enlace vivo). Avisa a la app con **`ESTOP`** (`{"t":"ESTOP","why":"T"}`, 24 B): el requisito de avisar está decidido, **el formato es PROPUESTA** pendiente de la usuaria (`protocolo_ble_app_esp.md` §5.9). **Pregunta para ustedes:** ¿también en MANUAL? (recomendación: no; §11, pregunta 9)
  - **El polígono vigente se conserva** al desconectar y en el corte de 300 ms. Solo lo cambia un `POLY` aceptado o un `PCLR`. `/app/working_area` sigue republicándose cada ~2 s sin app (usuaria).
  - **Mensaje `AREA` (ESP → app):** `{"t":"AREA","id":N}` (`id` 0 = sin área). Se manda **al activar las notificaciones** (CCCD, conexión cifrada) y **cada vez que cambia el área** (después del `POK`; tras un `PCLR` con `id:0`); no tras un `POLY` inválido (usuaria). La app no recibe `/sensores`, por eso el ESP tiene que informárselo por BLE.
  - **PREGUNTA para vos:** ¿el polígono sobrevive a un reinicio o corte de energía del ESP (solo RAM o NVS)? Si es RAM, tras reiniciar manda `AREA id:0`; si es NVS, manda el id guardado. Guardar en NVS solo un polígono completo y válido, y vigilar el desgaste de la flash.
- **Doble búfer del polígono:** búfer de recepción (se parsea y valida ahí) y búfer vigente. Solo un polígono completo y válido se copia al vigente, bajo mutex y de una vez. Un inválido no toca el vigente. `PCLR` pone el vigente en vacío e índice 23 = 0. La geometría **no** se valida en el ESP.

### 3.5 Parser y reglas del ESP

- Seguir al pie de la letra las reglas del contrato (`protocolo_ble_app_esp.md` §5, §6 y §10). Los casos CMD-1 … POLY-22 son la especificación ejecutable.
- **Claves duplicadas: comparar las claves ya decodificadas.** `"cutter"` y `"cut\u0074er"` son la MISMA clave; si un comando repite una clave de primer nivel (decodificada), el firmware rechaza el mensaje **completo, sin ninguna respuesta** (ni ACK ni cambio de estado). Ejemplo (`protocolo_ble_app_esp.md` §5.1, caso CMD-15b): `{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"cut\u0074er":1}` → ninguna respuesta. **Este fue exactamente el defecto que tuvo el parser de referencia de la app (AUD-25), que comparaba el texto crudo de las claves y aceptaba `cutter = 1`; ya está corregido en la app.**
- JSON: si se usa cJSON, **detectar claves duplicadas recorriendo la lista de hijos** (y comparando los nombres ya decodificados, no el texto): `cJSON_GetObjectItem` devuelve solo la primera, y un duplicado `"cutter":1` posterior no se vería. Alternativa: un parser propio estricto, de una sola pasada, sin memoria dinámica. Los dos son decisión del compañero.
- Líneas inválidas: sin ACK, sin tocar el instante de último comando, sin cambiar el comando vigente.

### 3.6 Emparejamiento con clave de 6 dígitos

Todo el esquema está en `protocolo_ble_app_esp.md` §3. Resumen de qué implementar y verificar:
- Passkey Entry con LE Secure Connections, IO capability DisplayOnly, MITM y bonding obligatorios; rechazar Just Works. **Verificar** que se pueda exigir "solo Secure Connections" (no aceptar el emparejamiento legacy).
- Clave estática leída de NVS (nunca del repositorio, nunca de `sdkconfig.defaults`); sin clave → no se acepta ningún emparejamiento (falla cerrada).
- Contador de fallos persistente con bloqueo (3 fallos → 5 min, duplicando hasta 1 h; a los 10 acumulados, bloqueo hasta desbloqueo físico). El bloqueo solo afecta emparejamientos nuevos.
- Una sola conexión: no anunciar mientras haya una activa.
- Los nombres de API de NimBLE (inyección de la clave, re-emparejamiento) están marcados "verificar" en ese documento; son una guía, no una receta probada.
- **Riesgo honesto:** con clave estática, las 10^6 combinaciones **no** son una cota fiable ante un atacante activo (`protocolo_ble_app_esp.md` §3.5): cada emparejamiento fallido puede revelar información de la clave, y con una clave estática se acumula. Estimación prudente: decenas de intentos, no un millón (verificar contra la especificación Core, Vol. 3, Part H).

**Ventana de emparejamiento con botón físico — RECOMENDACIÓN FUERTE, pero la decisión es tuya.** El ESP acepta emparejamientos **nuevos** solo durante una ventana corta (por ejemplo, 2 min) tras apretar un botón; fuera de la ventana los rechaza.
- **Ventajas:** un atacante en alcance de radio **no puede intentar nada** salvo durante la ventana, cuando el dueño está presente. Sin botón, el atacante puede probar a cualquier hora mientras el ESP anuncia. Cambia el problema de "adivinar 6 dígitos" a "estar ahí en el momento justo". Los teléfonos ya emparejados no se ven afectados.
- **Costo:** un botón y un pin del ESP (**PENDIENTE: cuál; no inventado acá**; hay libres de reserva en `pines.md` §1: 4, 5, 11, 12, 13, 14, 21, 40, 41, 42, verificando que no sea strapping), anti-rebote, y que el dueño tenga que estar físicamente junto al robot para emparejar un teléfono nuevo.
- **Si decidís no hacerla**, quedan estas mitigaciones y su límite: (1) el bloqueo por intentos fallidos (3.3, 3 fallos → 5 min, duplicando hasta 1 h, y bloqueo a los 10 acumulados) y que solo afecte emparejamientos nuevos; (2) la conexión única (sin anuncio mientras haya un teléfono conectado); (3) la tabla de bonds llena (máx. 3) que impide emparejar más; (4) NVS cifrada. **Ninguna cierra el riesgo:** un atacante paciente en alcance, con el robot encendido y sin teléfono conectado, sigue pudiendo intentar. Y el robot lleva una cuchilla (6.2).

### 3.7 Notificaciones y recuperación

- Cola de notificaciones saliente: ACK por cada CMD válido (10 por segundo) y GPS a ~1 Hz. Si hay congestión, **descartar GPS antes que ACK.**
- Al desconectar: vaciar el búfer parcial, `app_connected = 0`, volver a anunciar. Al conectar: estado inicial STOP (`protocolo_ble_app_esp.md` §8.2).
- Descartar una línea parcial tras 2 s sin bytes (propuesta del contrato).

### 3.8 Qué publica en el arranque

Antes de cualquier conexión, índices 15–23 = `0, 0, 0, 0, 0, 0, 0, -1, 0` (valor esperado sin app, `e7_app_android.md` §3).

### 3.9 Qué verificar con nRF Connect (sin la app)

1. Todos los casos de `protocolo_ble_app_esp.md` §6 y §7 (A-1 … A-22, incluidas A-13 … A-22 de STOP retenido, `AREA` y `ESTOP`, y S-1 … S-11), con `ros2 topic echo /sensores` al lado.
2. Heap mínimo histórico estable tras 30 min a 10 Hz, sin reinicios.
3. Período de `/sensores` (`ros2 topic hz`): sigue en ~50 ms con BLE conectado y con tráfico.
4. Precisión de los ultrasónicos con y sin BLE (sección 3.2).
5. El agente micro-ROS no se desconecta mientras hay tráfico BLE.
6. Reconexión repetida (20 ciclos) sin pérdida de memoria.
7. El teléfono con el bond borrado puede volver a emparejar (y suma al contador de intentos).

---

## 4. Brain a protocolo v4 (recomendaciones)

### 4.1 Punto de partida

El nodo actual (`ros2_ws/src/cortadora_brain/cortadora_brain/bumper_decision_node.py`, v2.0):
- Publica el protocolo viejo de **7 campos** (`:137`: `[cmd_id, l_dir, l_pwm, r_dir, r_pwm, duration_ms, bordeadora_on]`).
- Lee `motion_status` como si el índice 6 fuera "restante en ms" (`:232`); el v4 tiene 9 campos y ese índice es `rumbo_obj`.
- Usa solo los bumpers (índices 0–2) y avanza solo con la bordeadora prendida en el arranque (`send_forward_continuous`, `:141-152`).
- No lee los índices 15–23.
- No hay carpeta de tests en el paquete.

Hay que reescribirlo, no parchearlo.

### 4.2 Formato v4

```
motion_cmd    = [cmd_id, modo, param, bordeadora_on, cortadora_on]
motion_status = [cmd_id, estado, pwm_izq, pwm_der, feedback, rumbo, rumbo_obj, imu_estado, seg_desde_cal]
```

Modos: 0 STOP, 1 ADELANTE (cm/s), 2 ATRAS (cm/s), 3 GIRO_IZQ (grados 0–720), 4 GIRO_DER, 5 PIVOT, 6 CALIBRAR, 7 FIJAR_RUMBO (`arquitectura.md`).

Reglas del firmware que el Brain debe respetar (verificadas en `main.c:1242-1306`):
1. **Los accesorios se aplican con cada comando válido, incluso STOP.** Un STOP del Brain **siempre debe llevar `bordeadora_on=0` y `cortadora_on=0`** (explícito), si no, el STOP deja una herramienta encendida.
2. **Anti-hipo** (`:1288`): una orden con el mismo `modo` y `param` que la activa solo actualiza accesorios y no reinicia la marcha. Sirve como latido, pero con una trampa: ver 4.5.
3. **PIVOT enciende la cortadora y la bordeadora aunque el comando diga 0** (`:1062-1065`, "Accesorios ON forzados"). **El Brain no debe enviar PIVOT** mientras las herramientas estén deshabilitadas o haya cualquier prueba sin cuchilla (propuesta: no usar PIVOT en la E7).
4. Un rechazo por `ERR_COMANDO` ocurre **antes** de aplicar accesorios (`:1257-1260`); un rechazo por `ERR_IMU` ocurre **después** (`:1263-1264` y `:1297`), así que los accesorios sí cambian. `arquitectura.md` dice que "los accesorios no cambian" en un rechazo: **discrepancia doc–código** (sección 9.3).
5. GIRO, PIVOT y CALIBRAR necesitan IMU listo (`imu_estado` 2 o 3). Si no, `ERROR` 2.
6. El `cmd_id` debe ser único por operación (el status lo refleja).

### 4.3 Secuencia de arranque

1. Esperar un `motion_status` y un `/sensores` frescos.
2. Esperar **`imu_estado = 2`** con el robot quieto (primera calibración ~6 s).
3. Enviar **`FIJAR_RUMBO 0`** (`[id, 7, 0, 0, 0]`) y esperar `DONE`.
4. Recién entonces aceptar movimiento. Mientras tanto: STOP con herramientas en 0.
5. En cada parada larga, `CALIBRAR` y esperar `DONE`; no superar ~60 s de marcha entre calibraciones (`seg_desde_cal`). **PREGUNTA:** ¿en MANUAL, quién decide recalibrar? El motor recalibra solo si queda quieto ≥ 6 s.
6. **Mientras `imu_estado` sea 0 (falla) o 1 (iniciando): sin movimiento.** (SUPUESTO: ADELANTE sostiene el rumbo con el IMU; sin IMU no hay lazo de rumbo.)

### 4.4 Máquina de estados (propuesta)

Entradas: índices 15–23 y 0–2, 6–7 de `/sensores`; `motion_status`; frescura de ambos; parámetros del Brain.

| Prioridad | Condición | Acción del Brain |
|---|---|---|
| 1 | `/sensores` viejo (sin mensaje en > 300 ms, SUPUESTO a confirmar), `motion_status` viejo (> 2 s; el IDLE publica cada 1 s), `imu_estado` 0/1, o arranque sin terminar | STOP, herramientas 0 |
| 2 | Algún bumper presionado | STOP, herramientas 0 (ver 4.9) |
| 3 | `app_connected = 0`, o `app_cmd_age_ms > 300` (o −1), o `app_state = 0` | **STOP, herramientas 0** (robot quieto: decisión del usuario, opción A). Tras una caída de la app **ya le llega `app_state = 0`** (el ESP lo fuerza, 14/11/26): el Brain no tiene que decidir nada sobre AUTO_RUN, y su propio watchdog en MANUAL sigue valiendo |
| 4 | `app_state = 1` MANUAL | mapeo de la sección 4.6 y herramientas de 4.7 |
| 5 | `app_state = 2` AUTO_RUN | decisión abierta (4.8) |
| 6 | `app_state = 3` AUTO_PAUSE | STOP, herramientas 0; recuerda que había una misión |

- El Brain **toma un STOP de la app como orden de máxima prioridad**: nunca espera un `DONE` ni la rampa de un comando anterior.
- Al pasar a cualquier condición de prioridad 1–3, el STOP sale **en el mismo ciclo**, no en el siguiente.
- La app arranca cada conexión en STOP; el Brain no debe asumir nada de la conexión anterior (`app_seq` puede retroceder).

### 4.5 Latido hacia el motor y el problema del "comando idéntico"

Para que el watchdog de 500 ms del motor (sección 5) no corte la marcha, el Brain debe mandar algo al motor **al menos cada ~200 ms (5 Hz)** mientras el robot esté activo, y también en reposo con herramientas encendidas (si las hubiera).

Problema: repetir el último comando funciona para ADELANTE/ATRAS (anti-hipo, no reinicia) y para un giro mientras sigue en `EXECUTING`. Pero un giro finito que ya terminó (`DONE`, vuelve a IDLE) **se volvería a ejecutar** si se repite idéntico: sumaría otro giro de 90°. Hay una carrera entre el Brain y el `DONE`.

Dos opciones:
- **PROPUESTA A (recomendada):** un modo nuevo `8 = LATIDO` en el firmware del motor: no cambia movimiento ni accesorios, solo resetea el watchdog. Es un cambio de protocolo (hoy un modo 8 se rechaza con `ERROR` 1 y corta la tracción, que es seguro).
- **Opción B, sin cambio de protocolo:** repetir el comando idéntico solo mientras el status indique `EXECUTING` con el mismo `cmd_id` y `modo`; si ya está en IDLE/DONE, mandar un STOP con herramientas en 0. Evita el re-giro, pero depende de la lectura del status.

La decisión es del compañero.

### 4.6 MANUAL: conversión de `app_speed` y tope de las primeras pruebas

Mapeo de dirección (`app_dir`): `1` → ADELANTE; `2` → ATRAS; `3` → GIRO_IZQ; `4` → GIRO_DER; `0` → STOP.

**Velocidad.** `app_speed` (0–100 %) se convierte a cm/s con un **tope parametrizable** en el Brain:

```
v_cm_s = round(app_speed / 100 × vel_max_cm_s)       # param de ADELANTE/ATRAS (entero)
```

- **`vel_max_cm_s` por defecto = 10** en las primeras pruebas (≈ 12,7 RPM, PWM estimado ≈ 48/255). **Tope duro en el código = 25.** Subirlo solo después de calibrar (etapa 4 del plan) y con acuerdo de la usuaria.
- El firmware nunca corrió en el robot: `PWM_ARRANQUE = 20` y `CM_S_POR_PWM = 0,36` son estimaciones de la hoja de datos (`main.c:135-136`). **Las velocidades en cm/s son estimadas, no medidas.** La velocidad real puede estar bien lejos.
- El firmware recorta a ~57 cm/s (`VEL_MAX_CM_S`, `main.c:137`), pero ese no debe ser el tope operativo.
- `param` es entero: con `vel_max_cm_s = 10` quedan solo 10 niveles. Si `app_speed > 0`, usar al menos 1 cm/s (SUPUESTO: es el mínimo con movimiento, `VEL_MIN_CM_S = 0,5`). Con `app_speed = 0` y `dir ≠ 0`: tratar como STOP.
- **El giro NO usa `app_speed`:** la velocidad de giro es fija (36 °/s, `GIRO_W_DPS`).

**Decisión abierta: giro continuo vs anti-hipo** (`e7_app_android.md` §4). Con el botón apretado la app manda `dir = 3/4` a 10 Hz. Si el Brain repitiera `GIRO 15°`, termina los 15°, para y arranca otro: giro a tirones. **PROPUESTA:** mientras el botón de giro siga apretado, el Brain manda **`GIRO` con `param = 720` (el máximo)**, repetido idéntico. El anti-hipo no lo reinicia y el latido lo mantiene vivo. Al soltar (`dir = 0`) manda STOP, que corta de inmediato. Ventajas: sin tirones y sin la desaceleración de los últimos 15°. A verificar en piso:
  - 720° a 36 °/s son unos 20 s de giro sostenido; luego `DONE`.
  - `rumbo_obj` se corre en cada giro; el STOP deja `rumbo_obj` = rumbo actual (el giro interrumpido lo recalcula, `arquitectura.md`).
  - Hay un tiempo máximo del giro (`GIRO_TIMEOUT_BASE_MS` + grados a la mitad del crucero): para 720° son ~43 s, no es un problema.
  - La alternativa del firmware (un modo "giro continuo") es del compañero.

### 4.7 Herramientas (cortadora y bordeadora)

Reglas propuestas (todas deben cumplirse para encender):
- El Brain tiene su **propio parámetro `tools_enabled`, apagado por defecto**, independiente de la compilación de la app (`TOOLS_ENABLED`). Es una segunda barrera.
- `app_state = MANUAL` (en AUTO se ignoran para la E7; `e7_app_android.md` §4), `app_connected = 1`, comando fresco, sin bumper presionado.
- **Enclavamiento por inclinación:** apagar si `|roll|` o `|pitch|` (índices 6–7 de `/sensores`, MPU-6500 del sensor) superan un límite, con histéresis. **No hay ningún límite definido en los docs: PREGUNTA (12).** SUPUESTO para empezar: un límite bajo, a decidir con datos reales.
- **Trabado por enclavamiento:** tras un disparo por cualquier causa, la herramienta queda apagada hasta que la app **pida 0 y después 1** de nuevo (no reencender sola al normalizarse).
- Datos inválidos de roll/pitch (NaN, sin IMU del sensor, `/sensores` viejo): tratar como enclavamiento activo.
- Herramientas **siempre apagadas** en STOP, AUTO_PAUSE, pérdida de app y en el arranque.
- El comando al motor siempre lleva ambas herramientas explícitas (nunca omitidas).

### 4.8 AUTO_RUN: lo que no está definido

El contrato dice: **sin un polígono válido cuyo id coincida con `app_polygon_id`, no se permite AUTO_RUN** (`e7_app_android.md` §5). **No dice qué hace el robot en AUTO_RUN.** Preguntas para la usuaria y el compañero:
1. ¿Qué es AUTO_RUN en la E7? El único comportamiento que existe hoy es el del nodo viejo (avanzar, bumper, STOP, retroceder, avanzar).
2. No hay localización más allá del GPS (precisión y `hdop` sin medir). ¿Cómo se comprueba que el robot está dentro del polígono con el margen de 1–2 m?
3. **PROPUESTA conservadora:** permitir AUTO_RUN solo con (a) polígono válido y con el id vigente, (b) GPS con fix y `hdop` bajo un umbral a definir, (c) herramientas apagadas, (d) STOP inmediato si sale del polígono con margen, si el GPS se vuelve viejo (> 3 s, NaN) o por cualquier prioridad 1–3 de 4.4.
4. Mientras eso no esté decidido, **recomendación: AUTO_RUN no mueve el robot** (queda como STOP con aviso en los logs).

**`working_area_node`** (nodo nuevo; `bumper_decision_node` no se toca según `e7_app_android.md` §5): recibe `/app/working_area`, reconstruye el polígono, **valida la geometría** (≥ 3 vértices, sin autointersecciones, área > 0, orientación) y la guarda en un JSON, convierte a metros locales y aplica el margen de 1–2 m hacia adentro. Publica si el área vigente es válida y su id; el Brain compara con el índice 23. Una vez cambiado el id o borrado el área, **AUTO_RUN se invalida de inmediato**. **El área se conserva aunque la app se desconecte** (decisión de la usuaria, 14/11/26): `/app/working_area` sigue llegando cada ~2 s y el nodo mantiene el polígono; AUTO_RUN no se permite si el área no es válida o su id no coincide con el índice 23. Los POK/PERR de la app son solo del ESP: la Raspberry no responde a la app.

### 4.9 Reacción a los bumpers

El nodo viejo reacciona con STOP → retroceso temporizado de 3 s → avanzar de nuevo. En MANUAL eso mueve el robot sin que el operador lo haya pedido. **PROPUESTA:**
- **MANUAL:** bumper presionado → STOP inmediato, herramientas 0, y se **bloquea la dirección de avance** mientras siga presionado; se permite retroceder. Sin retroceso automático.
- **AUTO:** la reacción (si existe) depende de 4.8.
- Cualquier bumper a nivel alto en el arranque es un fallo de cableado: el Brain no arranca el movimiento.
- Ultrasónicos: **PREGUNTA** si se usan como freno en E7 (índices 3–5, −1 = sin dato).

### 4.10 AUTO_RUN y pérdida de la app: RESUELTO (decisión de la usuaria, 14/11/26)

Antes quedaba abierto qué hacer con AUTO_RUN si la app se caía. **Está resuelto por requisito:** el ESP fuerza `app_state` a 0 (STOP) cuando la app se desconecta o el último comando tiene > 300 ms (300 vale, 301 corta), también desde AUTO_RUN y AUTO_PAUSE, y **no reanuda solo**. **Regla única (ST-9, `protocolo_ble_app_esp.md` §8.1–8.2):** tras cualquier corte de más de 300 ms o desconexión, el ESP queda en **STOP retenido** y solo acepta `state:2/3` después de recibir un comando válido con `state:0`; un `state:2/3` fresco antes de ese STOP no reanuda (también con el enlace vivo). La app arranca cada conexión con ese STOP. Si el corte ocurre en AUTO con el enlace vivo, además se manda `ESTOP`; el Brain simplemente sigue viendo `app_state=0`. El Brain ya recibe `app_state = 0`; no decide nada. Sigue valiendo su propio watchdog en MANUAL, y el requisito **no** borra el polígono (se conserva, decisión de la usuaria, 14/11/26).

### 4.11 Cómo probar la lógica sin ROS

- **PROPUESTA de estructura:** poner toda la decisión en un módulo Python **sin imports de ROS**, por ejemplo `app_policy.py`, con una función pura `decidir(entradas, ahora_ms, estado) → (comando, estado_nuevo)`. El nodo ROS solo adapta mensajes. El reloj entra como parámetro.
- Tests con `pytest`, tabla de casos: mapeo dir/velocidad con el tope; STOP con herramientas en cero; prioridades de 4.4 (cada fila, y que un bumper gane sobre MANUAL); watchdog de la app (300 vale / 301 corta); latido a 200 ms; secuencia de arranque (`imu_estado` 2, `FIJAR_RUMBO`); enclavamiento con latch; `tools_enabled = False` ⇒ nunca un 1 en ningún comando (propiedad con entradas aleatorias de semilla fija); `app_seq` retrocede sin efecto.
- Repetir en el ROS real con **`ros2 topic pub`** y grabaciones de `/sensores` (`ros2 bag`), sin motores, mirando `/motion_cmd`.
- El paquete no tiene carpeta `test/` hoy; hay que agregarla.

---

## 5. Watchdog de 500 ms del motor (recomendación para su firmware)

*Es del compañero; la usuaria no lo implementa.*

### 5.1 El problema (verificado en el código)

El firmware del motor v4.0 (`firmware/esp32_motor/active/active/main/main.c`) **no tiene watchdog de comandos**:
- El callback `motion_cmd_callback` (`:1242`) no guarda ningún instante. Un comando ADELANTE continúa **hasta recibir otro** (`arquitectura.md`: "los movimientos son continuos").
- Si el Brain, el agente micro-ROS o el cable se caen, **las ruedas siguen y las herramientas siguen encendidas**.
- **La bordeadora no se protege sola:** el Sabertooth está en modo serial simplificado ("Microcontroller mode") y, según su manual, en ese modo **no hay timeout y sigue la última orden** (`Datasheet/Sabertooth2x25v2.txt`, ~líneas 365-370). El timeout de 'Serial Timeout' existe solo en Packetized Serial, está apagado por defecto y no persiste (~líneas 620-624).
- **La cortadora central:** el GPIO 18 mantiene su nivel (`:1264`).
- **Riesgo adicional:** si la tarea de micro-ROS muere o se bloquea, **el lazo de control y la tarea de la rampa de la bordeadora también**, porque viven en esa misma tarea (`micro_ros_task`, `:1393-1444`). `RCCHECK` hace `vTaskDelete(NULL)` ante un error (`:81`, `:1334-1355`), y `CONFIG_ESP_TASK_WDT=n` (`sdkconfig.defaults`). Las salidas LEDC quedarían en el último ciclo de trabajo. **Un watchdog dentro de ese mismo lazo no sirve en ese caso.**
- La rama de anti-hipo (`:1288-1292`) hace `return` sin tocar nada más.

### 5.2 Propuesta

1. **Marca de tiempo:** `g_last_cmd_ms` se actualiza en `motion_cmd_callback` **justo después de validar el comando** (después de `param_valido`, `:1257`, y antes del anti-hipo `:1288`). Solo cuentan comandos **válidos**: uno rechazado no mantiene vivas las herramientas.
2. **Armado:** se arma con el primer comando válido tras el arranque (antes de eso no hay nada activo).
3. **Disparo:** si `ahora − g_last_cmd_ms > 500 ms` (PROPUESTA: 500 ms, no es una cifra medida):
   - tracción: PWM a 0 y `g_state` a IDLE;
   - bordeadora: orden de parada inmediata al Sabertooth (byte `TRIMMER_SPEED_STOP`, 64) sin esperar la rampa; `target_trimmer_state = 0`;
   - cortadora: GPIO 18 a 0;
   - un estado "watchdog disparado" retenido (latch), hasta el siguiente comando válido.
4. **Aviso al Brain:** publicar en `motion_status` un `estado = 5 (ERROR)` con un código nuevo. **PROPUESTA: `feedback = 8` ("watchdog de comandos")**, ya que 1–7 están en uso (`arquitectura.md`). Repetirlo en el heartbeat de 1 s mientras siga retenido, y limpiarlo con el siguiente comando válido. El código y el formato son del compañero.
5. **No debe dispararse** en reposo con todo apagado (sin spam de errores) ni antes del primer comando.
6. **Debe vivir fuera de `micro_ros_task`:** una tarea de FreeRTOS pequeña, de prioridad mayor, que cada ~50 ms mire dos cosas: `g_last_cmd_ms` y un contador de vida que `micro_ros_task` actualice en cada iteración del bucle. Si cualquiera de las dos se estanca más de 500 ms, dispara. Así cubre también el caso del lazo bloqueado o la tarea muerta.
7. **Un solo punto de salida:** revisar que todas las escrituras de PWM, del Sabertooth y del GPIO 18 pasen por funciones que respeten el latch (una función única `aplicar_salidas()`), para que el lazo de control no pise lo que apagó el watchdog. SUPUESTO: hoy hay varios puntos de escritura; no los revisé exhaustivamente.
8. Opcional: reevaluar `CONFIG_ESP_TASK_WDT=n` (puede haberse desactivado por los bloqueos de micro-ROS). **PREGUNTA al compañero.**

### 5.3 Interacciones

| Situación | Comportamiento recomendado |
|---|---|
| **"Siempre atento"** (un comando nuevo reemplaza al activo) | cualquier comando válido resetea el watchdog |
| **Anti-hipo** (mismo `modo` y `param` solo cambia accesorios) | el latido idéntico **no reinicia la marcha pero SÍ resetea el watchdog**: por eso la marca de tiempo va antes de esa rama |
| **Modos finitos** (GIRO, PIVOT, CALIBRAR) | el Brain debe seguir mandando latido; el watchdog no se suspende. Ver 4.5 sobre repetir un giro idéntico |
| **Tras un disparo** | el siguiente comando válido arranca normal (como desde IDLE) |
| **Accesorios** | el watchdog también los apaga; el siguiente comando los enciende solo si el Brain lo pide |

### 5.4 Cómo probarlo en banco, sin cargas

Con la placa S3 de banco (`pruebas.md` §4), **sin drivers ni motores conectados**, mirando `ros2 topic echo /motion_status` y, para lo que el status no muestra, un osciloscopio/analizador lógico o un adaptador USB-serie.

| # | Prueba | Aprobado |
|---|---|---|
| W-1 | `ADELANTE 15` y latido idéntico cada 200 ms durante 30 s | `pwm` estable; no se reinicia la rampa; sin ERROR |
| W-2 | Ídem y dejar de mandar | a los ~500 ms (hasta ~550 ms) `pwm` = 0 y `estado = 5`, `feedback = 8` |
| W-3 | Latido idéntico cada 400 ms durante 10 s | no dispara y no reinicia la marcha |
| W-4 | Latido cada 600 ms | dispara cada vez |
| W-5 | `ADELANTE` con bordeadora y cortadora en 1; luego dejar de mandar | GPIO 18 pasa a 0; el TX de la UART2 (GPIO 17) emite el byte 64 |
| W-6 | Matar el agente micro-ROS durante `ADELANTE` | PWM a 0 en ~500 ms (se ve solo con instrumento; el status ya no llega) |
| W-7 | Reposo sin comandos durante 5 min | sin ERROR ni tráfico anormal |
| W-8 | Tras un disparo, mandar un comando válido | arranca normal y limpia el latch |
| W-9 | Provocar un bloqueo del lazo (por ejemplo, una versión de prueba que se cuelgue) | el watchdog externo dispara igual |
| W-10 | Comando inválido (modo 9) repetido cada 200 ms con herramientas encendidas antes | no mantiene vivo nada: dispara a los 500 ms del último válido |

---

## 6. Seguridad de hardware

### 6.1 INHIBIT̄ del CBE-12A1C con el pin flotante

Contexto: GPIO 18 del ESP32 clásico → P1-9 INHIBIT̄ (`pines.md` §2); GND del ESP → P1-11. El firmware pone el pin en 0 en `motor_hw_init()` (`main.c:517`), **pero eso corre recién cuando arranca la tarea de micro-ROS.** Antes (reset, arranque del bootloader, flasheo) el pin está sin manejar.

`pines.md` §3.4 ya lo pide: ver qué pull interno tiene INHIBIT̄ y, si flotante habilita, agregar un pull-down dimensionado.

**Qué verificar en la hoja de datos** (que **no está en `Datasheet/`**):
- Polaridad: INHIBIT̄ activo en bajo ⇒ nivel bajo inhibe, alto o flotante podría habilitar. Confirmar.
- Si hay pull-up interno, su valor y la tensión a la que va.
- Umbrales de entrada: V_IL máximo y V_IH mínimo, y si **3,3 V del ESP alcanza para HIGH** (el firmware habilita con 3,3 V).
- Tipo de entrada (a transistor, optoacoplada, etc.), corriente que hay que dar o absorber.

**Qué pasa en un reset o flasheo:** el pin queda como entrada sin pull. Si el driver tiene pull-up interno, **la cortadora puede arrancar durante un reset o al flashear.** Es el riesgo central.

**Recomendación (PROPUESTA):** una resistencia de pull-down externa del pin al GND, dimensionada así:
- Debe mantener el nivel por debajo de V_IL aun con el pull-up interno del driver: `R_pd ≤ R_pu × V_IL / (V_pu − V_IL)`, con valores de la hoja de datos.
- Debe dejar que el ESP lleve el pin a HIGH sin exceder su corriente de salida: `3,3 V / R_pd` bien por debajo del máximo del GPIO (consultar la hoja del ESP32).
- **Los valores no se pueden fijar sin la hoja de datos.** Anotar el dimensionamiento y medirlo con multímetro en el pin durante un reset y un flasheo, **sin cuchilla montada y con el eje libre**.

Complemento: si el driver tiene alimentación separable, **no energizar el CBE-12A1C mientras se flashea.**

### 6.2 Corte físico de emergencia antes de la cuchilla

El software (Brain, watchdog, INHIBIT̄) **no es un sistema de seguridad certificado**. Antes de cualquier prueba con cuchilla hace falta un corte físico independiente del ESP, la Raspberry y la app.

**PROPUESTA de mínimo:**
- Un **interruptor o contactor DC** en la **alimentación del driver de la cortadora** (batería superior 4S → CBE-12A1C; el banco 8S llega a 33,6 V, `componentes.md` §3), de tipo **seta/enclavado**, accesible desde el exterior del robot.
- **A prueba de fallas:** si falta alimentación o se abre el circuito, la cortadora **queda sin energía** (contactor normalmente abierto con bobina alimentada por el circuito de emergencia; el corte no depende de ningún software).
- Capacidad **DC** (no AC) para al menos 60 V y con margen sobre la corriente pico del driver (8 A, `componentes.md` §2): **SUPUESTO de partida ≥ 15 A DC a ≥ 60 V**, a confirmar con la corriente real medida.
- **Probarlo antes de cualquier prueba con cuchilla**, con el eje libre y sin cuchilla (etapa 6 del plan).
- Recomendado además: un segundo polo que corte también la tracción y la bordeadora (batería inferior 4S), para el caso en que el robot deba frenar.

**Decisiones abiertas para la usuaria** (sección 9): ¿un corte para todo o solo para la cuchilla? ¿Montado en el robot o también remoto? (un corte inalámbrico agrega fallos propios; no lo recomiendo como único). ¿Quién lo prueba y cómo se registra?

**Honestidad sobre el corte:** cortar la alimentación **no detiene la cuchilla al instante.** El motor sigue por inercia. Hay que **medir el tiempo de parada** (etapa 6) y definir una distancia y un tiempo de espera antes de acercarse a la cuchilla. Un protector físico alrededor de la cuchilla está fuera de este documento pero es parte de la seguridad.

### 6.3 Accesorios apagados por defecto en el arranque

Verificar y, si hace falta, asegurar por hardware y firmware:
- **Cortadora:** GPIO 18 en 0 desde `motor_hw_init()` (`:517`) + pull-down (6.1).
- **Bordeadora:** el firmware envía el byte de parada (64) al Sabertooth. **Verificar** que lo haga también al arrancar (`sabertooth_hw_init`, no lo revisé en detalle) y qué hace el Sabertooth al encender sin ningún comando recibido (modo serial simplificado: SUPUESTO que queda detenido).
- **Tracción:** estado de las entradas del MC33926 durante un reset (pregunta 9).
- Un comando STOP, la pérdida de la app y el watchdog apagan todo (secciones 4 y 5).

### 6.4 Tope de PWM 180/255 (decisión de diseño, no se sube)

`PWM_MAX_TRACCION = 180` (`main.c:134`). Motivo (`componentes.md` §4): los Pololu 37D son de 12 V nominales y se alimentan desde la batería inferior 4S (hasta 16,8 V); 180/255 × 16,8 V ≈ 11,9 V. La corriente de bloqueo con el PWM al 100 % subiría a ~7,7 A contra los 5 A pico del MC33926. **Este tope no se sube** sin una decisión nueva y documentada. La bordeadora ya está limitada a `TRIMMER_SPEED_MAX = 85` (~33 %).

---

## 7. Plan de pruebas físicas por etapas

**Quién ejecuta:** el compañero (y quien él designe). **Nosotros no ejecutamos nada en el robot.** La usuaria opera la app cuando una etapa lo pide.

**Reglas generales:**
- Una etapa no empieza si la anterior no aprobó. Un criterio sin cumplir **detiene** el plan.
- El corte físico de emergencia (6.2) a mano en las etapas 3 en adelante.
- Registrar cada resultado distinguiendo **compilado / probado en banco / validado en piso** (como en `00_estado_actual.md`), con fecha, versión del firmware y quién lo hizo.
- Los criterios numéricos son **propuestas**: el compañero los confirma o ajusta.

### Etapa 0 — Banco sin potencia

- **Precondiciones:** baterías de potencia desconectadas; drivers sin alimentar; solo los ESP por USB.
- **Qué se prueba:** continuidad y cableado según `pines.md`; las verificaciones de `pines.md` §3 (módulo S3 dice N8R2, LED RGB, módulo clásico dice WROOM, divisores de los ECHO a 3,3 V, GND común); el circuito del corte de emergencia con multímetro o lámpara (abre y cierra); el pull-down del GPIO 18 durante un reset y un flasheo.
- **Aprobado:** cableado conforme al mapa; el corte abre el circuito de potencia; el GPIO 18 queda en nivel bajo en reset/flasheo.
- **Si falla:** corregir antes de seguir; no se energiza la potencia.
- **Registrar:** foto/medición de cada punto, hoja de datos del CBE-12A1C consultada.

### Etapa 1 — ESP solos, motores desconectados

- **Precondiciones:** etapa 0 aprobada; motores, cuchilla y bordeadora **físicamente desconectados**; drivers sin potencia.
- **Qué se prueba:**
  - BLE con nRF Connect: emparejamiento, bloqueo por intentos, los casos de `protocolo_ble_app_esp.md` §6–§7, `/sensores` 15–23 y el corte de 300 ms (300 vale, 301 corta).
  - Brain con la lógica nueva en seco: `ros2 topic echo /motion_cmd`, sin motores.
  - Watchdog del motor en banco (W-1 … W-10).
  - Heap mínimo, período de `/sensores` y ultrasónicos con BLE (3.9).
- **Aprobado:** todos los casos de los contratos cumplen; sin reinicios en 30 min; el watchdog dispara a ~500 ms; el Brain manda STOP con herramientas 0 ante cada condición de 4.4.
- **Si falla:** corregir el firmware o el Brain; no pasar a motores.
- **Registrar:** capturas de `/sensores` y `/motion_status`, medidas de latencia de punta a punta (completar la pregunta del presupuesto de 1.2).

### Etapa 2 — Ruedas en el aire, cuchilla y bordeadora físicamente desconectadas

- **Precondiciones:** robot sobre soportes, ruedas sin contacto; baterías 4S de tracción conectadas; **cableado de la cuchilla y de la bordeadora desconectado de los drivers** (no solo "apagadas por software").
- **Qué se prueba:** sentido de giro de cada rueda para ADELANTE/ATRAS/GIRO_IZQ/GIRO_DER; PWM máximo (≤ 180); STOP inmediato; corte BLE → ruedas paran en el tiempo esperado (≤ ~500 ms desde el último comando); matar el Brain (`kill -9`) → el watchdog para en ≤ ~550 ms; matar el agente; bumpers.
- **Aprobado:** sentidos correctos; ninguna rueda se mueve sin comando; todas las causas de parada detienen las ruedas dentro del tiempo.
- **Si falla:** parar; revisar cableado de fase/polaridad o la lógica; repetir la etapa completa.
- **Registrar:** tiempos medidos de cada parada.

### Etapa 3 — Piso a baja velocidad, cuchillas desconectadas

- **Precondiciones:** etapa 2 aprobada; zona despejada; **cable o cuerda de seguridad** para recuperar el robot; **corte físico a mano**; `vel_max_cm_s` del Brain en el valor mínimo de prueba (5–10 cm/s); herramientas deshabilitadas.
- **Qué se prueba:** recta corta; giro; STOP desde la app/nRF; pérdida de BLE (apagar el teléfono); bumper contra un obstáculo blando; sin app conectada el robot queda quieto.
- **Aprobado:** el robot hace lo pedido a baja velocidad; cada parada es inmediata; sin app = quieto; el recorrido tras perder la comunicación es el esperado (~4 cm a 10 cm/s, sección 1.2).
- **Si falla:** parar; volver a la etapa 2 si el problema es de control, a la 1 si es de comunicación.
- **Registrar:** velocidad real contra el valor pedido (alimenta la etapa 4).

### Etapa 4 — Calibración de `PWM_ARRANQUE` y `CM_S_POR_PWM`

- **Precondiciones:** etapa 3 aprobada; cinta métrica; terreno plano.
- **Qué se prueba:** `ADELANTE` durante 5 s a varios `param` y medir la distancia; despejar las dos constantes (`main.c:135-136`); rectas largas (ganancias de rumbo) y giros de 90°/180° (ganancias de giro). Es el pendiente de `00_estado_actual.md` §3 (lista general, punto 2).
- **Aprobado:** error de velocidad y de rumbo dentro de lo que decida el compañero (criterio a definir); constantes actualizadas y registradas.
- **Si falla:** repetir; no subir `vel_max_cm_s` hasta calibrar.
- **Registrar:** tabla PWM ↔ cm/s medidos. Solo después de esto el Brain puede subir su tope (máximo duro 25 cm/s hasta nuevo acuerdo).

### Etapa 5 — Bordeadora sola

- **Precondiciones:** etapa 4 aprobada; robot inmovilizado (ruedas en el aire o frenado); **cuchilla central desconectada**; el cabezal de la bordeadora **sin hilo de corte** y con protección; corte físico a mano; protección personal.
- **Qué se prueba:** arranque con rampa, parada, parada por STOP, por pérdida de app y por watchdog (la bordeadora no tiene timeout propio: Sabertooth); el tope `TRIMMER_SPEED_MAX`.
- **Aprobado:** arranca y para como se espera; cada causa de parada la detiene en ≤ ~500 ms; nunca arranca sola al encender.
- **Si falla:** parar; revisar el modo del Sabertooth y el watchdog.
- **Registrar:** tiempo de parada (inercia incluida).

### Etapa 6 — Cortadora central sola, SIN cuchilla montada

- **Precondiciones:** etapa 5 aprobada; eje libre, **sin cuchilla**; corte físico a mano.
- **Qué se prueba:** el comportamiento del GPIO 18 / INHIBIT̄ en reset, flasheo y encendido (6.1) mirando que el eje **no gire**; habilitar/inhibir; parada por STOP, por pérdida de app, por watchdog, por enclavamiento de inclinación y por el **corte físico**; **tiempo que tarda el eje en detenerse** tras cada corte.
- **Aprobado:** el eje no gira en reset/flasheo; las herramientas solo giran cuando se piden y se cumplen todas las condiciones de 4.7; el corte físico la deja sin energía; se midió el tiempo de parada por inercia.
- **Si falla:** **no se monta cuchilla.** Corregir y repetir.
- **Registrar:** tiempos de parada y valores del pull-down.

### Etapa 7 — Integración con la app real

- **Precondiciones:** etapas 1–6 aprobadas; el contrato BLE confirmado por ambos; en la app, los cambios de la sección 8.2 hechos; APK de prueba cargada con los UUID reales.
- **Qué se prueba:** emparejamiento real en el Galaxy M12, control manual con **tope de velocidad bajo**, STOP al apoyar, pérdida del teléfono/segundo plano → quieto, reconexión → arranca en STOP, la app **sin herramientas** (`TOOLS_ENABLED=false`).
- **Aprobado:** igual que la etapa 3 pero gobernado por la app real; ningún comando de herramientas llega nunca encendido.
- **Si falla:** volver a la etapa 1 (nRF Connect) para separar app de firmware.
- **Registrar:** versión de la APK y del firmware.

**No incluido en este plan:** montar la cuchilla y usarla. Eso es una decisión aparte, de la usuaria, con el corte físico probado y un protector. No es un paso automático después de la etapa 7.

---

## 8. Qué entrega la usuaria y qué espera de él

### 8.1 Lo que la usuaria entrega

| Entrega | Estado |
|---|---|
| **APK de prueba** (robot simulado) instalada en el Galaxy M12 | instalada el 14/11/26; arrancó sin errores; **todavía sin prueba manual en el teléfono** (`00_estado_actual.md` §1) |
| **Contrato BLE** `docs/protocolo_ble_app_esp.md` | v1.0, pendiente de revisión de la usuaria **y** del compañero; no está congelado |
| Auditoría | `app_android/AUDITORIA.md` (resultados y cantidad de tests: ver ese archivo) |
| Este documento | borrador |

### 8.2 Cambios de la app que dependen del firmware (para cuando el compañero confirme)

Hoy la conexión BLE real está **bloqueada a propósito**: los UUID son `null` (`app_android/lib/core/ble_robot_link.dart`, `BleConfig`).
1. Cargar los tres UUID reales en `BleConfig` (servicio, característica de comando, de notificaciones) y, si se decide, el nombre anunciado.
2. Llamar a **`createBond()` explícitamente** antes de descubrir servicios (hoy confía en que Android dispare el emparejamiento al fallar la autenticación; hay que verificarlo en el teléfono real).
3. Pedir **prioridad alta de conexión** (opcional, mejora la latencia).
4. Habilitar la opción BLE en la UI (hoy deshabilitada con aviso "pendiente del firmware BLE").
5. Ajustar al formato final los mensajes si el contrato cambia en la revisión.
5c. **Simulador de la app (`SimulatedRobotLink`):** hoy **no** fuerza `state` a STOP en el corte, no retiene el STOP y no emite `AREA` ni `ESTOP`; no es una referencia de estos requisitos. Pendiente de la segunda APK; no se implementa ahora.
5a. **Decodificar `ESTOP`** (`esp_protocol.dart`, hoy no lo hace): al recibirlo, pasar lo pedido a STOP (incluido el selector de AUTO), mostrar el aviso y exigir que la usuaria vuelva a pedir AUTO a propósito; la app debe mandar un `state:0` antes del nuevo `state:2`. Pendiente de la segunda APK.
5b. **Decodificar `AREA`** (`esp_protocol.dart`, hoy no lo hace), mostrar el `polygon_id` al reconectar y **guardar localmente cada polígono enviado, indexado por id**; si el id activo no lo conoce la app, mostrar solo el número. Pendiente de la segunda APK (mapa); no se implementa ahora.
6. Probar con radio real: **la ruta BLE no se probó nunca con hardware** (solo con un transporte falso en tests).
7. Más adelante (fase 6, fuera de esta entrega): mapa offline y editor de área.

### 8.3 Lo que se espera del compañero

- Revisar y responder la sección 2; confirmar o corregir el contrato BLE.
- Implementar y verificar el firmware contra los casos de `protocolo_ble_app_esp.md` §6 y §7.
- Avisar de cualquier cambio de formato antes de implementarlo (el contrato se cambia de a dos y queda en el registro de cambios).
- Ejecutar el plan de la sección 7 y registrar resultados por etapa.

---

## 9. Decisiones abiertas consolidadas

### 9.1 De la usuaria

| # | Decisión |
|---|---|
| U1 | Aprobar el esquema de clave de 6 dígitos sabiendo el riesgo residual. (La **ventana de emparejamiento con botón físico** es una **recomendación fuerte cuya decisión es del compañero**, C15; no es decisión de la usuaria.) |
| U2 | ¿Cifrar NVS/flash del ESP (la clave queda legible con acceso físico)? |
| U3 | Valores de bloqueo por intentos y máximo de teléfonos emparejados |
| ~~U4~~ | ~~¿AUTO_RUN debe sobrevivir a la desconexión de la app?~~ **Resuelta (la usuaria, 14/11/26): no; `app_state` pasa a 0 y no se reanuda solo** (4.10) |
| U5 | ¿Qué es AUTO_RUN en la E7 y con qué reglas de GPS? (4.8) |
| U6 | Corte físico de emergencia: alcance (cuchilla o todo), ubicación, dueño de la prueba (6.2) |
| U7 | Tope de velocidad de las primeras pruebas y quién autoriza subirlo (4.6) |
| U8 | Nombre anunciado; anuncio siempre abierto o con lista de aceptados |
| U9 | `PCLR` sin respuesta: ¿se acepta (con `AREA id:0` la app sí ve el área borrada), o se define una respuesta? |
| U12 | ¿La app debe poder recuperar los **vértices** del polígono activo desde el ESP? Hoy `AREA` solo da el id y la app guardaría los polígonos que envió (segunda APK, mapa; no se cierra) |
| U10 | Tamaño del cuadrado inicial del área (propuesto 10 × 10 m, `e7_app_android.md` §10) |
| U11 | Cuándo y bajo qué condiciones se monta la cuchilla (fuera del plan) |

### 9.2 Del compañero (o de ambos)

| # | Decisión |
|---|---|
| C1 | Preguntas 1–12 de la sección 2 |
| C2 | Transporte micro-ROS del sensor: USB nativo o COM, y unificar docs y código |
| C3 | Tabla de particiones del sensor y reparto de núcleos con NimBLE (3.1–3.2) |
| C4 | Parser JSON del ESP: cJSON con detección de duplicados o parser propio (3.5) |
| C5 | Latido hacia el motor: modo nuevo `8 = LATIDO` (propuesta A) o comando idéntico condicionado (opción B) (4.5) |
| C6 | Giro continuo: `GIRO 720` repetido (propuesta) o un modo nuevo del firmware (4.6) |
| C7 | Código y formato del aviso de watchdog (propuesto `ERROR` con `feedback = 8`) y reevaluar `CONFIG_ESP_TASK_WDT` (5.2) |
| C8 | Límites de roll/pitch para el enclavamiento de herramientas (4.7) |
| C9 | Qué publica `/app/working_area` tras un `PCLR` (3.4) |
| C10 | Valor máximo de `app_cmd_age_ms` (cota de saturación) |
| C13 | **¿El polígono sobrevive a un reinicio o corte de energía del ESP (RAM o NVS)?** Cambia lo que manda `AREA` tras reiniciar (`id:0` o el id guardado) |
| C14 | Objeciones a los requisitos del 14/11/26 (por memoria o seguridad): `app_state` → 0, polígono conservado, mensaje `AREA` (`protocolo_ble_app_esp.md` §11, pregunta 7) |
| C16 | **¿El STOP retenido también aplica a MANUAL?** La regla "cualquier corte" de §8.1 del contrato, su efecto en MANUAL y si se manda `ESTOP` se definen **junto con la pregunta 9** (la decide la usuaria con el compañero). (con la usuaria; recomendación: no, `protocolo_ble_app_esp.md` §11, pregunta 9) y objeciones al STOP retenido y al formato de `ESTOP` |
| C15 | **Ventana de emparejamiento con botón físico:** recomendación fuerte, decisión tuya (3.6); pin pendiente |
| C11 | Pull-down del GPIO 18 y estado de los pines del motor en reset (6.1, pregunta 9) |
| C12 | Si los ultrasónicos se usan como freno en la E7 |

### 9.3 Contradicciones entre documentos y código (sin elegir)

1. **Pi 4 / Ubuntu 26.04 / ROS 2 Lyrical** (`00_estado_actual.md` §1 y §3) **contra Pi 5 / ROS 2 Jazzy** (`componentes.md` §1 y §2; `e7_app_android.md` §1 y §10).
2. **Transporte del sensor v7.0:** el código usa USB-Serial-JTAG nativo (`esp32_serial_transport.c`, `sdkconfig.defaults`) y a la vez dice "UART0 exclusiva de micro-ROS" (`main.c`); `pines.md` §1 dice UART0/COM.
3. **Rechazo de comandos y accesorios:** `arquitectura.md` dice que un comando rechazado deja los accesorios sin cambios; en el código, un rechazo por `ERR_IMU` ocurre **después** de aplicarlos (`main.c:1263-1264`, `:1297`).
4. ~~`e7_app_android.md` §3 y el contrato: nada define qué pasa con AUTO_RUN si la app se desconecta~~ **Resuelta** por decisión de la usuaria (14/11/26); `e7_app_android.md` §3 ya lo refleja (4.10). Queda anotado que `AREA` **no está en la Directiva §3.2** y es una ampliación aprobada por la usuaria el 14/11/26.
5. **`componentes.md`** aún da la tracción en GPIO 4–7 y los pines viejos del sensor; son los del mapa anterior al intercambio (`pines.md`).
6. **`arquitectura.md`** da el puerto del sensor como `/dev/ttyUSB0`; `pines.md` §5 dice `/dev/ttyACM0` tras el intercambio.
7. **PIVOT:** enciende las dos herramientas aunque el comando diga 0 (`main.c:1062-1065`); no está reflejado como riesgo en ningún documento.
8. **Brain:** `00_estado_actual.md` y el código coinciden en que está en el protocolo viejo; confirmar que no haya otra versión en la PC Linux (pregunta 4).

---

## 10. Registro de cambios

| Versión | Fecha | Cambio |
|---|---|---|
| borrador 1 | 2026-11-15 | Primera versión. Pendiente de revisión de la usuaria y del compañero. |
