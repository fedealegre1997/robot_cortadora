# E7 — APP Android: Diseño y Hoja de Ruta — Robot Cortadora

**NOTA:** Documento **VIVO** del diseño de la entrega E7. Se edita a medida que se toman decisiones. Lo que ya está implementado y validado pasa a `docs/arquitectura.md`; el historial de cada sesión queda en `02_registro_acciones_raw.md`.

**Estado (28/10/26):** fase 1 compilada (sin probar en hardware). Fases 2–7 sin implementar. Diseño acordado el 27/10/26.

---

## 1. Objetivo

APP Android (Flutter) que se comunica por **Bluetooth** con el **ESP32 sensor**, que a su vez la pasa por **micro-ROS** a la **Raspberry Pi 5**.

```
[APP Android] --Bluetooth--> [ESP32 Sensor] --micro-ROS--> [Raspberry Pi 5] --micro-ROS--> [ESP32 Motor]
                              /sensores (índices 15-23)     Brain + working_area_node   /motion_cmd
                              /app/working_area
```

### Requisitos

1. **Control manual:** dirección, velocidad, cortadora, bordeadora y stop.
2. **Modo autónomo:** iniciar, pausar y detener.
3. **GPS en mapa offline.**
4. **Área de trabajo** definida como polígono.

### Principio de autoridad

La APP **pide**; la **Raspberry decide**. La Raspberry conserva la autoridad final sobre movimiento y herramientas. El ESP sensor solo transporta y aplica un recorte de seguridad básico.

---

## 2. Restricciones del hardware (ESP32 sensor)

> **Cambio decidido (02/11/26):** el sensor pasa al **ESP32-S3-WROOM-1 N8R2** (8 MB de flash, 2 MB de PSRAM, **solo BLE**), con el mapa de pines de `docs/pines.md`. La tabla describe la placa actual (clásico) hasta que se porte el firmware.

| Ítem | Valor |
|---|---|
| Placa | ESP32 clásico (target `esp32`), 2 MB de flash |
| Partición de app | 1 MB. Firmware v6.2: 285 KB (73 % libre) |
| Bluetooth | Soporta BT Classic y BLE |
| micro-ROS (`app-colcon.meta`) | `MAX_PUBLISHERS=4` (se usa 1), `MAX_SUBSCRIPTIONS=0`, `MAX_HISTORY=8` |
| Tareas | Core 0: ultrasonidos, GPS (UART2 9600, GPIO 16/17). Core 1: bumpers, IMU, micro-ROS. Un solo mutex compartido |

`MAX_SUBSCRIPTIONS=0`: el ESP sensor no recibe nada de la Raspberry → **no hay canal de retorno** hacia la APP (ver §6).

---

## 3. Datos de la APP en `/sensores` (fase 1 — ✅ compilada)

`/sensores` pasó de 13 a 24 valores (firmware v6.2). Tabla completa en `docs/arquitectura.md`.

| Índice | Campo | Valores |
|---|---|---|
| 13 | `gps_sats` | satélites en uso; `-1` sin dato |
| 14 | `gps_hdop` | precisión horizontal; `-1` sin dato |
| 15 | `app_connected` | `0` / `1` |
| 16 | `app_state` | `0` STOP, `1` MANUAL, `2` AUTO_RUN, `3` AUTO_PAUSE |
| 17 | `app_dir` | `0` nada, `1` adelante, `2` atrás, `3` izq, `4` der |
| 18 | `app_speed` | `0`–`100` % |
| 19 | `app_cutter` | `0` / `1` — pedido de cortadora |
| 20 | `app_trimmer` | `0` / `1` — pedido de bordeadora |
| 21 | `app_seq` | `0`–`65535`, secuencia del último comando |
| 22 | `app_cmd_age_ms` | antigüedad del último comando; `-1` = nunca llegó |
| 23 | `app_polygon_id` | id del área vigente en el ESP; `0` = ninguna |

**Seguridad en el ESP (ya implementada):** si `app_connected = 0`, si nunca llegó comando o si el último tiene más de 300 ms (`APP_CMD_TIMEOUT_US`), el ESP publica `app_dir`, `app_cutter` y `app_trimmer` en `0`.

**Valor esperado sin APP:** índices 15–23 = `0, 0, 0, 0, 0, 0, 0, -1, 0`.

---

## 4. Control manual y modos

### Envío de comandos

- La APP manda el comando a **10 Hz siempre que esté conectada**, aunque no se apriete nada (`dir = 0`). Así la Raspberry distingue "suelto" de "conexión caída".
- Formato JSON exacto del mensaje de comando por Bluetooth: **a definir en la fase 2**. Debe transportar los campos de los índices 16–21.

### Watchdog (Raspberry)

- Si `app_state = MANUAL` y (`app_cmd_age_ms > 300` o `app_connected = 0`) → **STOP**.

### Mapeo a `motion_cmd`

- Botones discretos. `app_dir` mapea directo a los modos del motor: `0` → STOP, `1` → ADELANTE, `2` → ATRAS, `3` → GIRO_IZQ, `4` → GIRO_DER.
- `app_speed` (%) lo escala la Raspberry a su rango de RPM.
- **Giro continuo:** la Raspberry reenvía GIRO con ~15° mientras el botón está apretado (el motor reemplaza el comando activo) y manda STOP al soltar.

> ⚠️ **Punto a resolver (observado en el código el 28/10/26):** el firmware del motor tiene el *anti-hipo* (`main.c:1055`): si llega el **mismo `modo` y el mismo `param`** mientras está en `EXECUTING`, **no reinicia** el comando, solo actualiza accesorios. Reenviar GIRO 15° idéntico no extiende el giro: termina sus 15° (con `GIRO_DECEL_DEG = 12`, desacelera en casi todo el recorrido), para y recién el siguiente reenvío arranca otro giro desde cero → giro a tirones. Hay que definir cómo resolverlo antes de la fase 4.

### Herramientas (cortadora / bordeadora)

- En **MANUAL**: son **pedidos** sujetos a enclavamientos en la Raspberry (por ejemplo, por roll/pitch del IMU).
- En **AUTO**: se ignoran para la E7.

---

## 5. Área de trabajo

### Formato

- Máximo **10 vértices**. Coordenadas **int32 en 1e-7°** (lat, lon).

### Protocolo Bluetooth (APP → ESP)

JSON, un mensaje por línea:

| Mensaje | Dirección | Significado |
|---|---|---|
| `{"t":"POLY","id":N,"p":[[lat,lon],...]}` | APP → ESP | Polígono completo en un solo mensaje |
| `{"t":"POK","id":N}` | ESP → APP | Recibido y aceptado |
| `PERR` | ESP → APP | Rechazado (formato exacto a definir en la fase 3) |
| `{"t":"PCLR"}` | APP → ESP | Borrar el área |

### ESP sensor

- **Doble buffer:** uno de recepción y uno vigente. Solo pasa a vigente un polígono completo y válido.
- Valida **solo integridad** (formato, cantidad de vértices). **No valida geometría.**
- Actualiza el índice 23 (`app_polygon_id`) con el id vigente.
- Publica `/app/working_area` (`Int32MultiArray`: `[id, n, lat0, lon0, lat1, lon1, ...]`) y lo **republica cada ~2 s**.

### Raspberry — nodo nuevo `working_area_node`

- Nodo **nuevo**; no se toca `bumper_decision_node`.
- Reconstruye el polígono, **valida la geometría**, lo guarda en un archivo JSON, lo convierte a metros locales y aplica un **margen de 1–2 m hacia adentro**.
- **Sin un polígono válido cuyo id coincida con `app_polygon_id` no se permite AUTO_RUN.**

### UI del editor (APP)

- Cuadrado inicial centrado en la posición GPS del robot (requiere fix válido). Tamaño propuesto: 10 × 10 m (pendiente de confirmar).
- **Tocar** selecciona un vértice; **arrastrar** lo mueve.
- **[+]** inserta un vértice en el punto medio de un lado (máx. 10). **[−]** borra el seleccionado (mín. 3).
- Botón **Centrar**.
- Si los lados se cruzan: el polígono se pinta en **rojo** y **Enviar** queda desactivado.

---

## 6. Canal de retorno

No hay canal Raspberry → ESP sensor (`MAX_SUBSCRIPTIONS=0`). La APP **solo muestra lo que sabe el ESP**: GPS, ACK de comandos y el área recibida. No ve el estado del Brain ni del motor.

---

## 7. Mapa offline

- `flutter_map` con tiles en zoom z19–z20.
- Fuente y método de descarga de los tiles: no definido todavía.

---

## 8. Entorno de desarrollo (PC Linux — listo)

| Ítem | Valor |
|---|---|
| SO | Ubuntu 24.04.4 |
| Flutter | 3.47.8 (snap) |
| JDK | 17 |
| Android SDK | `~/Android/Sdk` — platforms android-35/36, build-tools 35/36/28.0.3, licencias aceptadas |
| `flutter doctor` | Android toolchain ✓ (el ✗ de Linux toolchain se ignora) |
| Android Studio | No instalado |
| Pruebas | Celular físico con depuración USB |

En la Raspberry **no se instala nada** de esto.

---

## 9. Hoja de ruta

| Fase | Contenido | Estado |
|---|---|---|
| 1 | Ampliar `/sensores` a 24 valores | ✅ Compilado — falta flashear y validar |
| 2 | Bluetooth básico en el ESP (GPS en JSON + ACK), probado con la app nRF Connect | ⬜ Desbloqueado (02/11/26): BLE. Requiere portar antes el sensor al ESP32-S3 |
| 3 | ESP: comandos hacia los índices 15–23, recepción del polígono, topic `/app/working_area` | ⬜ |
| 4 | Raspberry: Brain al protocolo de 5 campos + estados/watchdog + `working_area_node` | ⬜ |
| 5 | Flutter: conexión BT y control manual | ⬜ |
| 6 | Flutter: mapa offline y editor de área | ⬜ |
| 7 | Integración y APK final | ⬜ |

### Validación pendiente de la fase 1

```bash
~/robot_cortadora/scripts/pc/flash_sensor.sh /dev/ttyUSB0
~/robot_cortadora/scripts/pc/run_agent_serial.sh /dev/ttyUSB0 -v4
```

En otra terminal:

```bash
source ~/robot_cortadora/scripts/common/env.sh
ros2 topic echo /sensores --once
```

Esperado: 24 valores, índices 15–23 = `0, 0, 0, 0, 0, 0, 0, -1, 0`. Confirmar que el Brain sigue reaccionando a los bumpers.

---

## 10. Decisiones pendientes

| # | Decisión | Opciones | Recomendación |
|---|---|---|---|
| 1 | ~~Tipo de Bluetooth~~ | ✅ **Resuelto (02/11/26): BLE.** Se decidió que el sensor pase al ESP32-S3, que **solo** tiene BLE (`componentes.md` §5, `pines.md`) | **BLE con NimBLE**: menos flash y RAM; `flutter_blue_plus` está bien mantenido |
| 2 | Comportamiento sin APP conectada | A: robot quieto / B: comportamiento actual | **A** |
| 3 | Tamaño del cuadrado inicial del área | — | 10 × 10 m |
| 4 | SO de la Raspberry | Confirmar con `lsb_release -a` y anotarlo en `docs/arquitectura.md` | Probablemente Ubuntu 24.04 (ROS 2 Jazzy) |
| 5 | Giro continuo vs. anti-hipo del motor (§4) | A definir | — |
