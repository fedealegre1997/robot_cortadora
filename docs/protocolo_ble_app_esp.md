# Protocolo BLE App ↔ ESP32 sensor — contrato para el firmware

**Estado: v1.0 — pendiente de revisión de la usuaria Y de su compañero de firmware. NO está congelado hasta que ambos lo confirmen.** Cualquier cambio posterior se hace por acuerdo entre ambos y queda registrado en la sección 13.

Este documento es un **contrato**: lo que el firmware del ESP32 debe cumplir para hablar con la app Android E7. La app ya lo implementa (`app_android/lib/core/esp_protocol.dart`, `control_command.dart`, `ble_robot_link.dart`), en modo simulado por defecto. Nada de lo marcado **PROPUESTA** o **PENDIENTE** está decidido.

Fuentes: Directiva "App de teléfono" §3, `docs/e7_app_android.md` (§3–§6) y el código real de `lib/core`. Las discrepancias con ellas están en la sección 12.

---

## 1. Topología y autoridad

```
[APP Android] --BLE--> [ESP32-S3 sensor] --micro-ROS--> [Raspberry Pi 5] --micro-ROS--> [ESP32 motor]
```

- La app **pide**; la Raspberry **decide**. El ESP solo transporta y aplica un recorte de seguridad básico (sección 8).
- **No hay canal de retorno** Raspberry → ESP → app (`MAX_SUBSCRIPTIONS=0`). La app solo ve: GPS, ACK de comandos, POK/PERR y los dos mensajes agregados el 14/11/26: `AREA` (requisito, 5.8) y `ESTOP` (propuesta de formato, 5.9). El ESP **no debe** inventar ni reenviar estado del Brain o de los motores.
- El ACK significa "el ESP recibió y validó el comando". **Nunca** significa que el robot lo ejecutó.
- Una sola conexión a la vez (sección 3.4).

## 2. GATT

| Elemento | Valor |
|---|---|
| Servicio | `d4d28957-613f-4007-8a1d-1deab4080779` |
| Característica de comando (app → ESP) | `5a38f5bc-797e-4e23-97e6-efc129c921d5` |
| Característica de notificaciones (ESP → app) | `9d803301-5ae6-4c4a-ab5a-8f783c540282` |

Estos UUID los generó el coordinador al azar. Se usan tal cual.

| Característica | Propiedades (exactas) | Permisos |
|---|---|---|
| Comando | **solo Write Without Response** (sin Write con respuesta, sin Read) | escritura **cifrada y autenticada** |
| Notificaciones | **solo Notify** (sin Indicate, sin Write, sin Read) | CCCD y notificación **cifrados y autenticados** |

- Por qué solo Write Without Response: la app elige el tipo de escritura según las propiedades (`withoutResponse = !properties.write`). Si el firmware agrega Write con respuesta, la app cambiaría de modo sin avisar.
- La app exige que existan el servicio y las dos características, que la de comando permita escritura y que la de notificaciones permita notify o indicate. Si no, la conexión falla.
- En NimBLE (PROPUESTA, verificar los nombres contra la versión de ESP-IDF usada): comando = `BLE_GATT_CHR_F_WRITE_NO_RSP | BLE_GATT_CHR_F_WRITE_ENC | BLE_GATT_CHR_F_WRITE_AUTHEN`; notificaciones = `BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_READ_ENC | BLE_GATT_CHR_F_READ_AUTHEN`. Verificar con el caso S-2 que escribir el CCCD sin emparejar también falla.

### 2.1 Anuncio

- El UUID de servicio de 128 bits va en el paquete de anuncio (la app escanea con filtro por ese UUID). El nombre va en la respuesta de escaneo.
- **PROPUESTA** de nombre: `Cortadora-E7`. La app hoy no filtra por nombre.
- Anuncio conectable. Con una conexión activa, el ESP **deja de anunciar** (sección 3.4).

### 2.2 Parámetros de conexión (PROPUESTA, a calibrar con el robot real)

| Parámetro | Valor sugerido | Justificación |
|---|---|---|
| Intervalo de conexión | 15–30 ms | la app manda a 10 Hz (cada 100 ms) y el corte es de 300 ms: un intervalo corto absorbe reintentos del enlace sin acercarse al corte |
| Latencia del periférico | 0 | evita que el ESP "se duerma" y vea el comando tarde |
| Supervision timeout | 2000 ms | detecta caída en un tiempo razonable; mucho menos produce desconexiones falsas por interferencia |

Android decide los parámetros finales y puede ignorar la solicitud del ESP. La app hoy no pide prioridad alta de conexión. Es una mejora posible (ver sección 11).

## 3. Seguridad del enlace

### 3.1 Esquema (decisión del usuario)

- Emparejamiento **LE Secure Connections, Passkey Entry**, con clave de **6 dígitos** (`000000`–`999999`).
- El ESP no tiene pantalla: capacidad de E/S **DisplayOnly**, con **clave estática** configurada en el ESP. El usuario la teclea en el diálogo de emparejamiento de Android.
- MITM obligatorio (`mitm=1`), `sc=1`, **bonding persistente**, claves ENC e ID distribuidas. Con MITM obligatorio y Display-only el ESP **debe rechazar Just Works**.
- Ninguna característica acepta escritura ni notificación sin cifrado y autenticación (sección 2).
- **Verificar:** que el stack permita exigir LE Secure Connections y no aceptar el emparejamiento "legacy". El Passkey Entry legacy es atacable offline por un atacante que solo escuche. Si NimBLE no lo permite directamente, comprobar en el callback de acceso que el enlace esté cifrado, autenticado y con clave de 16 bytes.

### 3.2 Dónde vive la clave (regla del usuario: NO va en el repositorio)

El repositorio es público en GitHub. La clave **no** puede estar en ningún archivo versionado, **tampoco en `sdkconfig.defaults`** (ese archivo SÍ se versiona; `.gitignore` solo excluye `**/sdkconfig`).

Opciones, de más a menos recomendada:

1. **NVS, cargada localmente (recomendada).** Namespace `ble_sec`, clave `passkey` (uint32). Se escribe una vez desde la PC del compañero con un CSV local generado con `nvs_partition_gen.py`, o por un comando de consola en el primer flasheo. Sobrevive a `fullclean` y a `set-target`. Agregar al `.gitignore`, **antes** de crear el archivo, `**/ble_secrets*`.
2. **`sdkconfig` local.** Funciona porque `**/sdkconfig` está ignorado, pero se regenera al cambiar de target o al hacer `fullclean`: es fácil perder o, peor, copiar la clave a un `sdkconfig.defaults`. No recomendada.

Reglas del firmware:
- **Falla cerrada:** si no hay clave en NVS, el ESP **no acepta emparejamientos**. **Nunca** una clave por defecto (123456, 000000, etc.).
- La clave **no se imprime** en logs ni en la consola serie.
- Generación sugerida: `python -c "import secrets; print(f'{secrets.randbelow(10**6):06d}')"`. Descartar claves triviales (`000000`, `123456`, repetidas, secuencias). El usuario la guarda en un gestor de contraseñas o en papel. **La app no la conoce ni la guarda.**
- Límite: el NVS no está cifrado por defecto. Quien tenga acceso físico a la flash puede leerla (cifrado de flash/NVS: decisión abierta, sección 11).

### 3.3 Intentos fallidos y bloqueo (PROPUESTA de valores)

- Se cuenta cada emparejamiento fallido (clave incorrecta o abandono tras pedir la clave). El contador **no se reinicia con el tiempo**: solo con un emparejamiento exitoso. Se guarda en NVS.
- 3 fallos seguidos → bloqueo de **5 min**. Cada fallo posterior **duplica** el bloqueo hasta un máximo de **1 h**.
- **Durante el bloqueo** el ESP hace fallar todo emparejamiento nuevo (por ejemplo, inyectando un passkey aleatorio distinto del configurado) y **no suma intentos**.
- A los **10 fallos acumulados** sin éxito: bloqueo hasta un desbloqueo físico (mecanismo y pin **PENDIENTE**, no inventado aquí) o reinicio del ESP.
- El bloqueo **solo afecta emparejamientos nuevos**. Un teléfono ya emparejado se reconecta con su clave guardada (LTK) y no pasa por la clave de 6 dígitos. Por eso un atacante no puede dejar fuera de servicio al dueño ya emparejado.

### 3.4 Emparejamiento nuevo con el robot ya conectado (decisión (d))

- Con una conexión activa el ESP **no anuncia**: un segundo teléfono no puede ni conectarse ni emparejar.
- Si el mismo teléfono ya conectado y cifrado pide emparejar de nuevo, el ESP **lo rechaza** sin cortar la conexión ni tocar los comandos en curso. No borra bonds.
- Si un teléfono se reconecta tras borrar su bond en Android y el ESP aún conserva el suyo, el ESP puede aceptar el re-emparejamiento solo si la clave es correcta y **sumando al contador de intentos** (en NimBLE: evento de re-emparejamiento, verificar). No si ya hay otra conexión cifrada activa.
- Tabla de bonds: máximo **3** teléfonos (PROPUESTA). Con la tabla llena no se aceptan emparejamientos nuevos. Borrar bonds requiere el desbloqueo físico (pin PENDIENTE). La app no puede borrar bonds del ESP.

### 3.5 Riesgo residual (honesto)

1. La clave tiene 10^6 combinaciones. Esa cifra **no es una cota fiable** de seguridad. En el Passkey Entry, cada emparejamiento fallido le revela a un atacante **activo** información sobre la clave (la comprometen bit a bit en 20 rondas), y con una clave **estática** esa información se acumula entre intentos. La especificación asume claves aleatorias por emparejamiento. **Estimación prudente:** un atacante activo dentro del alcance de radio podría necesitar del orden de **decenas de intentos**, no un millón. Esto se debe **verificar contra la especificación Core (Vol. 3, Part H)** antes de confiar en el número.
2. Por eso el límite de intentos (3.3) es la defensa real, y se recomienda además una **ventana de emparejamiento física**: aceptar emparejamientos nuevos solo durante ~2 minutos tras pulsar un botón. **RECOMENDACIÓN fuerte; la decisión es del compañero de firmware** (sección 11). Pin PENDIENTE.
3. Con el esquema bien hecho, un atacante pasivo (solo escucha) no obtiene la clave ni el cifrado posterior, y un teléfono ya emparejado no se ve afectado por los intentos ajenos.
4. Con la clave conocida, un teléfono ajeno puede emparejar durante una ventana de emparejamiento abierta. El robot corta con cuchilla: el riesgo es real aunque el alcance de radio sea corto (decenas de metros). Esto refuerza la necesidad del corte físico de emergencia, que es tema de otro documento.
5. Un atacante dentro del alcance puede interferir la radio (denegación de servicio). El corte de 300 ms deja el robot detenido. No es una amenaza de movimiento.

## 4. MTU, fragmentación y buffer

- La app pide **MTU 517** al conectar (solo Android; hoy `BleConfig.requestedMtu`).
- El ESP **debe aceptar al menos 293** (peor POLY de 290 B + 3 de cabecera ATT). Recomendado: configurar el MTU preferido del ESP en 517. Verificar en el firmware que ese valor se negocie.
- Si el MTU negociado es menor, la app **parte la línea en fragmentos de (MTU − 3) bytes** (mínimo 20 B) y los escribe en orden. El ESP **acumula hasta `\n`** y recién entonces interpreta la línea.
- Mínimos para no fragmentar: comando y GPS ≥ **80**; ACK y POK ≥ **27**; POLY de 10 vértices ≥ **293**.
- El ESP también debe fragmentar sus notificaciones si el MTU es menor (el GPS peor caso mide 77 B). La app reensambla hasta `\n`.
- **Buffer de recepción del ESP:** 512 B por línea (sin contar el `\n`). Si se supera: se descarta todo hasta el próximo `\n` y, solo si lo acumulado empieza con `{"t":"POLY"`, se responde `PERR` con `e:"LEN"`. En otro caso se descarta sin respuesta.
- Una línea incompleta se descarta al desconectarse y tras **2 s sin recibir bytes** (PROPUESTA).
- Terminador: `\n`. El ESP tolera un `\r` previo. La app solo envía `\n`.

## 5. Mensajes

Todos son **una línea JSON terminada en `\n`**, sin espacios ni saltos internos, enteros sin decimales salvo `hdop`. Los tamaños incluyen el `\n`.

### 5.1 CMD — app → ESP — Directiva §3.1 (nombres de campo del contrato)

`{"t":"CMD","state":S,"dir":D,"speed":V,"cutter":C,"trimmer":T,"seq":Q}`

| Campo | Rango | Significado |
|---|---|---|
| `state` | 0–3 | 0 STOP, 1 MANUAL, 2 AUTO_RUN, 3 AUTO_PAUSE |
| `dir` | 0–4 | 0 nada, 1 adelante, 2 atrás, 3 izquierda, 4 derecha |
| `speed` | 0–100 | % |
| `cutter` | 0 / 1 | pedido de cortadora |
| `trimmer` | 0 / 1 | pedido de bordeadora |
| `seq` | 0–65535 | contador que da la vuelta |

Tamaño: 71 B (mínimo) · 73 B (ejemplo) · **77 B** (peor caso).

- La app lo envía a **10 Hz mientras haya conexión**, aunque no se apriete nada (`dir:0`).
- **Primer comando de cada conexión = STOP** (`state:0, dir:0, speed:0, cutter:0, trimmer:0`). Es una **obligación de la app** (ya implementada en `lib/app/session_controller.dart`, `_onStatus`, ídem al reconectar). El ESP **no debe depender de ello**: ver la regla del ESP en 8.2.
- La app con `TOOLS_ENABLED=false` (el valor por defecto) manda siempre `cutter:0, trimmer:0`. El ESP **no** debe asumir eso: transporta lo que llega. Los enclavamientos son de la Raspberry.
- `seq` es solo eco. El ESP **no filtra** por `seq` (puede retroceder al reconectar).

**Reglas de validación del ESP para CMD:**
- Todos los campos presentes, enteros y en rango. Un valor fuera de rango **descarta la línea completa** (nunca se recorta).
- `t` debe ser exactamente `"CMD"`.
- Una clave **duplicada** descarta la línea (si no, `"cutter":0,…,"cutter":1` podría colar un valor). Claves desconocidas: se ignoran. El parser de referencia de la app (`ControlCommand.fromJsonLine`) rechaza las claves duplicadas **de primer nivel comparando las claves ya decodificadas** (`"cutter"` y `"cut\u0074er"` son la misma clave); los duplicados anidados dentro de un valor no se rechazan. **El firmware debe rechazar cualquier duplicado tras decodificar las claves** (escapes `\uXXXX`, `\/`, `\"`, pares sustitutos); un parser que se quede con la última o con la primera clave es ambiguo y no es válido. Ejemplo de entrada y resultado: `{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"cut\u0074er":1}` → **ninguna respuesta** (ni ACK ni cambio de estado), igual que CMD-15. Un CMD con la clave `cut\u0074er` escrita **una sola vez** (sin duplicado) es válido y se interpreta como `cutter`.
- Una línea inválida **no genera ACK, no refresca el reloj de antigüedad y no cambia el comando vigente**. Es decir, basura no puede actuar de "latido".

### 5.2 ACK — ESP → app

`{"t":"ACK","seq":Q}` — uno por cada CMD **válido** recibido. `seq` = el del comando. Tamaño: 21 B (ejemplo) · **24 B** (peor caso). **Solo recepción, nunca ejecución.**

La app descarta ACK con `seq` fuera de 0–65535.

### 5.3 GPS — ESP → app (~1 Hz)

`{"t":"GPS","fix":F,"lat":LAT,"lon":LON,"sats":N,"hdop":H}`

| Campo | Rango | Notas |
|---|---|---|
| `fix` | 0, 1, 2 | 0 sin fix, 1 GPS, 2 DGPS. La app descarta valores negativos |
| `lat` | int32, ±900000000 | 1e-7°. **Se omite** si `fix` = 0 |
| `lon` | int32, ±1800000000 | 1e-7°. **Se omite** si `fix` = 0 |
| `sats` | entero ≥ 0, o `-1` | `-1` = sin dato |
| `hdop` | número ≥ 0, o `-1` | `-1` = sin dato. Único campo que puede llevar decimales |

Tamaño: 40 B (sin fix) · 73 B (ejemplo) · **77 B** (peor caso). La app descarta el mensaje completo si `lat`/`lon` salen de ±90°/±180° o si `sats`/`hdop` son negativos distintos de `-1`.

### 5.4 POLY — app → ESP — Directiva §3.2

`{"t":"POLY","id":N,"p":[[lat,lon],...]}`

- `id`: entero **1–65535** (PROPUESTA: el contrato no fija rango; 0 está reservado para "ninguna" en el índice 23).
- `p`: **3 a 10** vértices, cada uno `[lat, lon]` con **int32** en 1e-7°.
- Tamaño: 62 B (ejemplo de 4 vértices) · **290 B** (peor caso: 10 vértices, `id` 65535, todas las coordenadas `-2147483648`) · 280 B con coordenadas geográficas extremas.
- El ESP valida **solo integridad**: formato, `id`, cantidad de vértices y rango int32. **No valida geometría** (cruces, área, orientación): lo hace la Raspberry.
- **Doble buffer:** uno de recepción y uno vigente. Solo un polígono completo y válido pasa a vigente. Uno inválido **no cambia** el vigente.
- Al aceptarlo: índice 23 = `id`, publica `/app/working_area` (`Int32MultiArray`: `[id, n, lat0, lon0, …]`) y lo republica cada ~2 s.
- El ESP valida **primero el `id`**: así un `PERR` distinto de `ID` siempre lleva un `id` válido.
- **REQUISITO (decisión de la usuaria, 14/11/26): el polígono vigente se CONSERVA al desconectarse la app.** Solo se reemplaza con un `POLY`/`POK` nuevo o se borra con un `PCLR` explícito. Desconectar, el corte de 300 ms y pasar a STOP **no lo borran**: el índice 23 sigue con el mismo `id` y `/app/working_area` se sigue republicando cada ~2 s, de modo que la Raspberry conserva el área aunque no haya app. Un `POLY` inválido tampoco lo cambia. **Espacio para el compañero:** puede objetarlo por razones de memoria o de seguridad (ver sección 11, pregunta 7 y respuesta pendiente). Lo que **no** define el requisito: si el polígono sobrevive a un reinicio o corte de energía del ESP (solo RAM o guardado en NVS). **No inventé la respuesta**: es una pregunta abierta.
- Que el polígono se conserve **no cambia** que sin un polígono válido cuyo id coincida con `app_polygon_id` la Raspberry no permite AUTO_RUN (`e7_app_android.md` §5).

### 5.5 POK — ESP → app

`{"t":"POK","id":N}` — polígono recibido, íntegro y vigente. Tamaño: 19 B (ejemplo) · **23 B** (peor caso). La app descarta `id` fuera de 1–65535.

### 5.6 PERR — ESP → app (formato PROPUESTO, no en el contrato)

`{"t":"PERR","id":N,"e":"<código>"}` — `id` se **omite** si el ESP no pudo leerlo. Tamaño: 23 B (sin id) · 32 B (ejemplo) · **42 B** (peor caso).

| `e` | Causa | `id` |
|---|---|---|
| `FMT` | JSON inválido, `t` incorrecto, campo faltante o de tipo incorrecto, vértice que no es `[int,int]` | el leído si ya lo tenía **y** es válido; si no, omitido |
| `ID` | `id` fuera de 1–65535 | **eco** del id recibido, solo si cabe en int32; si no, omitido |
| `NVERT` | menos de 3 o más de 10 vértices | el id (válido) |
| `RANGE` | alguna coordenada fuera de int32 | el id (válido) |
| `LEN` | línea más larga que 512 B (solo si empieza como POLY) | omitido |

Orden de validación: longitud → formato → `id` → cantidad de vértices → rango. La app descarta un `PERR` con `id` fuera de 1–65535, salvo con `e:"ID"` (donde acepta cualquier int32).

### 5.7 PCLR — app → ESP

`{"t":"PCLR"}` — borrar el área. Tamaño: 13 B.

**El contrato original no define un ACK propio de PCLR.** El ESP no manda `POK` ni `PERR` para un PCLR. Pero, por la decisión de la usuaria (14/11/26, 5.8), **tras un PCLR el ESP envía `{"t":"AREA","id":0}`**, que es lo que la app puede ver. Efecto esperado: índice 23 = 0, el ESP deja de republicar un área en `/app/working_area` (propuesta de 3.4 de la entrega: publicar `[0, 0]`), y la notificación `AREA id:0`. Un PCLR sin polígono vigente también manda `AREA id:0` (la app lo ve igual, sin cambio de estado). Un PCLR con claves desconocidas se procesa igual (PCLR-3); un PCLR mal formado o sin `\n`: sin respuesta. Ver sección 11.

### 5.8 AREA — ESP → app — **REQUISITO** (decisión de la usuaria, 14/11/26)

**Por qué existe.** La usuaria decidió (14/11/26) que, al reconectar, la app muestre el **área activa** (`polygon_id`). La app **no recibe `/sensores`** (no hay canal de retorno; solo ve GPS, ACK y POK/PERR) y la Directiva §3.2 no tenía ningún mensaje ESP → app para informar el área vigente. La usuaria **aprobó ampliar el contrato** con este mensaje. **El compañero puede objetarlo** por razones de memoria o de seguridad; espacio para su respuesta: _(pendiente)_.

`{"t":"AREA","id":N}` — `id` en 0–65535; **`0` = no hay área vigente**. Tamaño: 20 B (`{"t":"AREA","id":0}` + `\n`), 20 B (`id` de un dígito, ej. 7), **24 B** (peor caso, `id` 65535).

**Cuándo lo manda el ESP (regla firme):**
1. **Al conectarse:** una vez por conexión, **en cuanto la app activa las notificaciones** (escritura del CCCD) sobre una conexión ya cifrada y autenticada. **Justificación de la elección:** es el primer momento en que el ESP *puede* notificar y no depende de que la app mande nada. Esperar al primer comando STOP ataría el aviso a un mensaje de la app que podría perderse o demorarse y dejaría la pantalla sin dato. (La app ya empieza la conexión con su STOP, pero eso no condiciona al `AREA`.) Si la app activa las notificaciones más de una vez en la misma conexión, el ESP lo manda de nuevo.
2. **Cada vez que cambia el área activa:** tras un `POLY` aceptado (el `AREA` va **después** del `POK`) y tras un `PCLR` (`id:0`).
3. **No** se manda tras un `POLY` inválido (el área vigente no cambió; solo hay `PERR`), ni tras el corte de 300 ms ni al desconectarse.
4. No se repite periódicamente (la app lo guarda).

**Qué debería informar `AREA` según el destino del polígono tras un reinicio o corte de energía del ESP** (la pregunta sigue abierta para el compañero, sección 11, pregunta 8; no se inventa la respuesta):
- si el polígono vive **solo en RAM**: tras un reinicio el ESP no tiene área → manda `AREA id:0`;
- si se guarda en **NVS**: tras un reinicio recupera el área → manda `AREA id:N` con el id guardado.

**Límite importante.** El ESP informa **solo el `id`**, no los vértices. Para dibujar el área, la app debe **guardar localmente cada polígono que envió, indexado por `id`**. Si el id activo no lo conoce la app (lo cargó otro teléfono, o se reinstaló la app), **muestra solo el número**. Si la app debe poder recuperar los vértices desde el ESP es una **decisión abierta de la usuaria** (segunda APK, con el mapa).

**Lo que NO cambia:** `AREA` no confirma nada de la Raspberry. Es lo que el ESP **tiene cargado**, no que la Raspberry lo haya validado ni que AUTO_RUN esté permitido.

**Pendiente de la app (segunda APK, mapa; NO se implementa ahora):** `esp_protocol.dart` (`EspProtocol.decodeEspLine`) todavía **no decodifica `AREA`** y `robot_link.dart` no tiene un mensaje para él (sería un `RobotMessage` nuevo, con `id` 0–65535, y la app descartaría valores fuera de rango). La UI deberá mostrar el `polygon_id` al conectar y guardar localmente los polígonos enviados. Mientras tanto la app **ignora** el mensaje (descarta los tipos desconocidos).

### 5.9 ESTOP — ESP → app — **PROPUESTA de formato** (la usuaria eligió "retener STOP + aviso", 14/11/26; el esquema exacto todavía no lo aprobó)

**Requisito (decidido por la usuaria, 14/11/26):** el ESP **avisa a la app** de que quedó en STOP retenido, para que la pantalla lo muestre. **Lo que es PROPUESTA** es el mensaje concreto de abajo (la usuaria debe confirmarlo); amplía el contrato, como `AREA`.

`{"t":"ESTOP","why":"T"}` — `why` es **un solo carácter**: `T` = corte por **timeout** de comandos (> 300 ms) con el enlace vivo. Tamaño: **24 B** (con `\n`).
- `D` (desconexión) **se reserva y no se envía**: sin enlace no hay a quién avisar, y al reconectar no hace falta, porque la app arranca la conexión en STOP y el ESP exige un `state:0` antes de volver a aceptar AUTO.

**Cuándo lo manda el ESP:**
1. **Una vez al entrar al STOP retenido** por timeout, si hay conexión cifrada.
2. Como máximo **una vez por segundo** mientras sigue ignorando comandos `state:2/3` con la retención activa (así una notificación perdida no deja la pantalla desactualizada sin generar tráfico a 10 Hz). PROPUESTA.
3. No se manda al liberarse la retención ni al conectar.

**Comportamiento esperado de la app (PENDIENTE de la segunda APK; NO se implementa ahora):** `esp_protocol.dart` todavía **no decodifica `ESTOP`** (se ignora como tipo desconocido). Al recibirlo, el controlador debe pasar lo pedido a **STOP** (incluido el selector de AUTO) y mostrar el aviso; **el usuario debe volver a pedir AUTO a propósito**, y la app debe mandar un `state:0` antes del nuevo `state:2` (el ESP lo exige).

**Lo que NO es:** `ESTOP` no es el paro de emergencia físico (6.2 de la entrega) ni confirma que el robot esté detenido; solo informa que el ESP dejó de pasar la orden.

## 6. Ejemplos con resultado esperado

El firmware debe poder verificar cada fila sin la app. "Ninguna" = ni ACK ni PERR ni otro cambio. Las entradas van **terminadas en `\n`** (se omite en la tabla).

### 6.1 CMD

| # | Entrada | Resultado esperado |
|---|---|---|
| CMD-1 | `{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12}` | ACK `{"t":"ACK","seq":12}`; `/sensores` 16–21 = `1,1,50,0,0,12` |
| CMD-2 | `{"t":"CMD","state":0,"dir":0,"speed":0,"cutter":0,"trimmer":0,"seq":0}` | ACK `seq:0`. Borde mínimo |
| CMD-3 | `{"t":"CMD","state":3,"dir":4,"speed":100,"cutter":1,"trimmer":1,"seq":65535}` | ACK `seq:65535`; 16–21 = `3,4,100,1,1,65535` (77 B, borde máximo) |
| CMD-4 | CMD-3 y luego `…"seq":0}` | ACK `seq:0`. El ESP no rechaza el retroceso |
| CMD-5 | CMD-1 en tres escrituras de ≤ 20 B (MTU 23), la última con el `\n` | un solo ACK al llegar el `\n`, nada antes |
| CMD-6 | `{"t":"CMD","state":4,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":1}` | Ninguna; comando vigente sin cambios |
| CMD-7 | igual con `"dir":5` | Ninguna |
| CMD-8 | igual con `"speed":101` | Ninguna |
| CMD-9 | igual con `"speed":-1` | Ninguna |
| CMD-10 | igual con `"cutter":2` | Ninguna |
| CMD-11 | igual con `"trimmer":-1` | Ninguna |
| CMD-12 | igual con `"seq":65536` | Ninguna |
| CMD-13 | igual con `"speed":50.5` o `"speed":"50"` | Ninguna |
| CMD-14 | falta el campo `trimmer` | Ninguna |
| CMD-15 | `{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"cutter":1}` | Ninguna (clave duplicada) |
| CMD-15b | el mismo CMD-15 con la clave duplicada escapada: `…,"seq":12,"cut\u0074er":1}` | Ninguna (las claves se comparan **decodificadas**) |
| CMD-16 | `{"t":"cmd",…}` (minúscula) | Ninguna |
| CMD-17 | `esto no es json` | Ninguna; sin PERR (no empieza como POLY) |
| CMD-18 | CMD-1 con un `\r` antes del `\n` | ACK normal |
| CMD-19 | `{"t":"ZZZ"}` | Ninguna (tipo desconocido se ignora) |

### 6.2 ACK y GPS (lo que **emite** el ESP; la app debe aceptarlos)

| # | Mensaje del ESP | Resultado esperado en la app |
|---|---|---|
| ACK-1 | `{"t":"ACK","seq":0}` y `{"t":"ACK","seq":65535}` | aceptados |
| ACK-2 | `{"t":"ACK","seq":65536}` o `-1` o `1.0` | descartados |
| GPS-1 | `{"t":"GPS","fix":1,"lat":-123456789,"lon":456789012,"sats":9,"hdop":0.8}` | posición −12.3456789°, 45.6789012° |
| GPS-2 | `{"t":"GPS","fix":0,"sats":-1,"hdop":-1}` | sin posición |
| GPS-3 | `{"t":"GPS","fix":2,"lat":-900000000,"lon":1800000000,"sats":12,"hdop":99.9}` | aceptado (bordes ±90°/±180°) |
| GPS-4 | `lat` 900000001, `fix` -1, `sats` -2, `hdop` -0.5 | descartado el mensaje entero |

### 6.3 POLY → POK / PERR

Entradas (`square` = `[[0,0],[0,1000],[1000,1000],[1000,0]]`, ≈ 11 m, **ficticio**):

| # | Entrada | Resultado esperado |
|---|---|---|
| POLY-1 | `{"t":"POLY","id":7,"p":[[0,0],[0,1000],[1000,1000],[1000,0]]}` | POK `{"t":"POK","id":7}`; índice 23 = 7 |
| POLY-2 | `{"t":"POLY","id":1,"p":[[0,0],[0,1000],[1000,0]]}` | POK `id:1` (3 vértices, borde mínimo) |
| POLY-3 | 10 vértices, `id` 65535 | POK `id:65535` (borde máximo) |
| POLY-4 | 10 vértices con todas las coordenadas `-2147483648` y `id` 65535 (290 B) | POK; con MTU 23 son 15 escrituras |
| POLY-5 | coordenadas `2147483647` y `-2147483648` mezcladas, 3 vértices | POK (extremos int32 válidos) |
| POLY-6 | autointersección (`[[0,0],[1000,1000],[0,1000],[1000,0]]`) | POK (el ESP no valida geometría) |
| POLY-7 | POLY-1 fragmentado en escrituras de 20 B | un solo POK al llegar el `\n` |
| POLY-8 | 2 vértices, `id` 5 | PERR `{"t":"PERR","id":5,"e":"NVERT"}`; el vigente no cambia |
| POLY-9 | 11 vértices, `id` 5 | PERR `{"t":"PERR","id":5,"e":"NVERT"}` |
| POLY-10 | `"p":[]`, `id` 5 | PERR `NVERT` con `id:5` |
| POLY-11 | una coordenada `2147483648`, `id` 5 | PERR `{"t":"PERR","id":5,"e":"RANGE"}` |
| POLY-12 | una coordenada `-2147483649`, `id` 5 | PERR `RANGE` con `id:5` |
| POLY-13 | `"id":0` | PERR `{"t":"PERR","id":0,"e":"ID"}` |
| POLY-14 | `"id":65536` | PERR `{"t":"PERR","id":65536,"e":"ID"}` |
| POLY-15 | `"id":-1` | PERR `{"t":"PERR","id":-1,"e":"ID"}` |
| POLY-16 | `"id":99999999999` | PERR `{"t":"PERR","e":"ID"}` (no cabe en int32: sin id) |
| POLY-17 | falta `id` | PERR `{"t":"PERR","e":"FMT"}` |
| POLY-18 | `"id":"7"` (texto) | PERR `{"t":"PERR","e":"FMT"}` |
| POLY-19 | `"p":7`, `id` 4 | PERR `{"t":"PERR","id":4,"e":"FMT"}` |
| POLY-20 | un vértice `[0]` o `[0,0.5]`, `id` 4 | PERR `{"t":"PERR","id":4,"e":"FMT"}` |
| POLY-21 | línea de más de 512 B que empieza con `{"t":"POLY"` | PERR `{"t":"PERR","e":"LEN"}`; descarta hasta el `\n` |
| POLY-22 | POLY-1 y luego POLY-8 | tras POLY-8 el índice 23 sigue en 7 (doble buffer) |

### 6.4 PCLR

| # | Entrada | Resultado esperado |
|---|---|---|
| PCLR-1 | `{"t":"PCLR"}` con polígono vigente | índice 23 = 0 y notificación **`{"t":"AREA","id":0}\n`**; sin `POK` ni `PERR` (el contrato original no define un ACK propio de PCLR) |
| PCLR-2 | PCLR sin polígono vigente | índice 23 sigue en 0; también `{"t":"AREA","id":0}\n`; sin `POK` ni `PERR` |
| PCLR-3 | `{"t":"PCLR","x":1}` o PCLR sin `\n` | claves desconocidas se ignoran: se procesa como PCLR-1 (sin `\n`, no se interpreta) |

### 6.5 Temporización (corte de 300 ms)

Se mide desde la **llegada del `\n`** del último CMD válido (`app_cmd_age_ms`, índice 22).

| # | Escenario | Resultado esperado |
|---|---|---|
| T-1 | CMD-3 y se consulta `/sensores` a los **299 ms** | 16, 17, 19, 20 = `3, 4, 1, 1` (vigente) |
| T-2 | ídem a los **300 ms** | **sigue vigente**: 16 = 3 (corta solo con "más de 300") |
| T-3 | ídem a los **301 ms** | **16 = 0 (STOP)**, 17, 19, 20 = `0, 0, 0`; 18, 21 = `100, 65535` (speed y seq no los define el requisito: se conservan, PROPUESTA) |
| T-4 | CMD cada 100 ms durante 60 s | nunca corta |
| T-5 | 2 comandos perdidos seguidos (hueco de 300 ms) | en el borde: depende del jitter. El margen real es de **1 comando perdido** |
| T-6 | un CMD **inválido** a los 250 ms de uno válido | no refresca el reloj: corta a los 301 ms del válido |
| T-7 | tras cortar un CMD con `state:1` (MANUAL), llega un CMD válido | vuelve a publicar el comando completo. **Con `state:2/3` el corte deja un STOP retenido** (ST-3, ST-4): el comando fresco NO reanuda. MANUAL: pregunta abierta, sección 11 (pregunta 9) |

**REQUISITOS de seguridad ante el corte (decisiones del 14/11/26).**

1. **El corte fuerza `app_state` a STOP (0)** además de dir, cutter y trimmer (decisión de **la usuaria**, 14/11/26; ver 8.1).
2. **STOP retenido en AUTO (decisión de la usuaria, 14/11/26, AUD-17):** tras un corte de más de 300 ms (300 vale, 301 corta) estando en AUTO_RUN o AUTO_PAUSE, el ESP queda en **STOP retenido**: `app_state=0` y dir/cutter/trimmer=0, y **NO reanuda aunque lleguen comandos frescos con `state:2/3`**, hasta recibir un comando válido con `state:0` (STOP) y, **después**, uno nuevo que pida AUTO. Vale igual si el enlace sigue vivo (el latido siguiente de la app con `state:2` no reanuda) y si hay desconexión.
3. **Aviso a la app:** el ESP avisa que quedó en STOP retenido con el mensaje `ESTOP` (5.9, **PROPUESTA de formato**, pendiente de la usuaria).

Casos de aceptación:

| # | Entrada | Resultado esperado |
|---|---|---|
| ST-1 | CMD `{"t":"CMD","state":2,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":5}` y silencio de **300 ms exactos** | `/sensores` 16 = **2** (sigue AUTO_RUN); sin `ESTOP` |
| ST-2 | ídem, silencio de **301 ms** con el enlace vivo | 16 = **0**; 17, 19, 20 = `0, 0, 0`; 15 sigue en 1; notificación `{"t":"ESTOP","why":"T"}\n` (propuesta); STOP **retenido** |
| ST-3 | tras ST-2, la app manda CMD con `state:2` a 10 Hz (comandos frescos) | ACK de cada uno (es ACK de recepción); 16 **sigue en 0**, 17, 19, 20 = 0; **no reanuda** |
| ST-4 | tras ST-3, CMD `state:0` y después CMD `state:2` | tras el `state:0`: 16 = 0 (retención liberada); recién con el CMD `state:2` siguiente, 16 = **2** |
| ST-5 | CMD con `"state":3` (AUTO_PAUSE) y silencio de 301 ms | 16 = 0, retenido; `ESTOP`; un CMD `state:3` posterior no reanuda |
| ST-6 | AUTO_RUN activo (16 = 2) y se corta la conexión BLE | 15 = **0**, 16 = **0**, 17, 19, 20 = 0 (retenido) |
| ST-7 | tras ST-6, reconexión (emparejado) **sin enviar nada** | 15 = 1 (cifrada), 16 = **0**, 17–21 = 0, 22 = -1; no se reanuda |
| ST-8 | tras ST-7, primer CMD `state:0` y luego CMD `state:2` | tras el STOP, 16 = 0; recién con el CMD `state:2`, 16 = **2** |
| ST-9 | tras ST-7, el **primer** CMD de la conexión es `state:2` (sin STOP antes) | 16 = **0**: AUTO solo se acepta después de un `state:0` válido en la conexión (**regla única**, 8.1) |
| ST-10 | ST-2 con un CMD **inválido** entre medio (a los 250 ms) | no refresca el reloj: 16 = 0 a los 301 ms del último válido |
| ST-11 | CMD con `"state":1` (MANUAL) y silencio de 301 ms | 16 = 0 (el corte base). **Qué pasa con los comandos frescos siguientes es la pregunta abierta 9** (sección 11): sin retención (recomendación) vuelve a publicar `state:1` |
| ST-12 | el ESP **no** guarda ni reenvía el estado anterior | tras ST-6/ST-7 no hay ningún CMD "viejo" reaplicado |

### 6.6 Polígono vigente y AREA (decisiones de la usuaria, 14/11/26)

Con el polígono vigente sin tocar tras desconectar o cortar a los 301 ms. Se supone un ESP recién arrancado, sin área, emparejado y con notificaciones activadas por la app.

| # | Entrada / escenario | Resultado esperado |
|---|---|---|
| AR-1 | la app se conecta y activa las notificaciones, **sin área** | notificación `{"t":"AREA","id":0}\n` (20 B) |
| AR-2 | `POLY id=7` válido | `POK` `{"t":"POK","id":7}` y **después** `{"t":"AREA","id":7}\n` (20 B); `/sensores[23]` = 7 |
| AR-3 | la app se desconecta, o pasan 301 ms sin comandos | `[23]` **sigue en 7**; `/app/working_area` se **sigue republicando cada ~2 s** (la Raspberry conserva el área sin app) |
| AR-4 | reconexión **sin enviar nada** (activa notificaciones) | llega `{"t":"AREA","id":7}\n`; el área activa sigue siendo 7 |
| AR-5 | `POLY id=8` válido | `POK id:8`, luego `AREA id:8`; `[23]` = 8 (reemplaza al 7) |
| AR-6 | `PCLR` | `[23]` = 0; luego `{"t":"AREA","id":0}\n`; sin `POK` ni `PERR` |
| AR-7 | `POLY id=9` con 11 vértices (con área 8 vigente) | `PERR` `{"t":"PERR","id":9,"e":"NVERT"}` y **NO** se envía `AREA`; `[23]` sigue en 8 |
| AR-8 | tras AR-4, un CMD `state:2` (AUTO_RUN) | `[16]` = 2; **la Raspberry** valida el área; sin polígono válido con el id vigente, no hay AUTO_RUN (el requisito no cambia eso) |
| AR-9 | notificaciones activadas por segunda vez en la misma conexión | se vuelve a mandar `AREA` con el id actual |
| AR-10 | `AREA` no se manda tras el corte de 301 ms ni al desconectarse | confirmado: ningún `AREA` espontáneo |
| AR-11 | reinicio/corte de energía del ESP con área 7 cargada, y reconexión | **pregunta abierta** (sección 11, pregunta 8): solo RAM → `AREA id:0`; NVS → `AREA id:7` |

### 6.7 Seguridad (deben cumplirse todas)

| # | Escenario | Resultado esperado |
|---|---|---|
| S-1 | Sin emparejar, escribir CMD en la característica de comando | **falla** con error ATT de autenticación/cifrado (0x05 o 0x0F); ningún efecto en `/sensores` |
| S-2 | Sin emparejar, activar notificaciones (escribir el CCCD) | **falla** o dispara el emparejamiento; no se reciben notificaciones hasta emparejar |
| S-3 | Emparejar con la clave correcta | se establece el bond y el cifrado; S-1 y S-2 ahora funcionan |
| S-4 | Emparejar con clave incorrecta | falla; el contador de intentos sube |
| S-5 | 3 fallos seguidos, luego clave correcta durante el bloqueo | **falla**: sigue bloqueado 5 min |
| S-6 | Teléfono ya emparejado se reconecta durante un bloqueo | **conecta** sin pedir clave (el bloqueo solo afecta emparejamientos nuevos) |
| S-7 | Emparejamiento Just Works (sin clave) | rechazado |
| S-8 | Reiniciar el ESP y reconectar el teléfono emparejado | reconecta cifrado sin pedir la clave (bond persistente) |
| S-9 | Con una conexión activa, buscar el robot desde otro teléfono | **no aparece** (el ESP no anuncia) |
| S-10 | Sin clave en NVS | no acepta ningún emparejamiento |
| S-11 | Buscar la clave en logs seriales, en el repositorio y en `sdkconfig.defaults` | **no aparece** |

## 7. Pruebas de aceptación con nRF Connect

Con la app **nRF Connect for Mobile** (sin la app E7). Las características se identifican por los UUID de la sección 2.

**Preparación**
1. Escanear y conectar a `Cortadora-E7` (o por el UUID de servicio).
2. Menú → **Request MTU** → 517 (o 23 para probar fragmentación).
3. En la característica de notificaciones, tocar el ícono de triple flecha (**Enable notifications**).
4. Para escribir: tocar la flecha de subida de la característica de comando, tipo **UTF-8/Text**. Para el `\n`, hacer **una segunda escritura** con tipo **Byte array** = `0A`. Eso prueba además el reensamblado hasta `\n`.
5. En la PC del robot: `ros2 topic echo /sensores` para ver los índices 15–23.

| Prueba | Pasos | Resultado esperado |
|---|---|---|
| A-1 (S-1, S-2) | Conectar **sin** emparejar. Intentar escribir y activar notificaciones | error de autenticación; nada en `/sensores` |
| A-2 (S-3) | Emparejar (Android pide los 6 dígitos). Repetir A-1 | funciona |
| A-3 (CMD-1) | Escribir `{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12}` + `0A` | llega la notificación `{"t":"ACK","seq":12}`; 15–21 = `1,1,1,50,0,0,12` |
| A-4 (T-2/T-3) | Tras A-3, esperar sin enviar | a los 301 ms: 17 = 0; 15 sigue en 1; 22 crece |
| A-5 (CMD-6…16) | Probar cada inválido de 6.1 | sin ACK; sin cambios |
| A-6 (POLY-1) | Escribir POLY-1 + `0A` | POK `id:7`; 23 = 7 |
| A-7 (POLY-8, 13) | Probar inválidos de 6.3 | el PERR exacto de la tabla; 23 sigue en 7 |
| A-8 (POLY-7) | MTU 23; escribir POLY-1 en trozos de 20 B, y `0A` al final | un solo POK |
| A-9 (PCLR-1) | Escribir PCLR + `0A` | llega la notificación `{"t":"AREA","id":0}` (sin `POK` ni `PERR`); 23 = 0 |
| A-10 (8.2) | Desconectar y reconectar (ya emparejado) | 15 = 0 al desconectar; al reconectar 15 = 1 y 16–21 = `0,0,0,0,0,0`, 22 = -1, hasta el primer CMD |
| A-11 (S-9) | Conectar con un teléfono, buscar con otro | el ESP no aparece |
| A-12 (S-4, S-5) | Emparejar con clave incorrecta 3 veces; luego la correcta | sigue bloqueado |
| A-13 (ST-1, ST-2) | Escribir CMD con `"state":2` + `0A`; esperar sin enviar | a 300 ms: 16 = 2; a 301 ms: 16 = 0, 17, 19, 20 = 0 y llega `{"t":"ESTOP","why":"T"}` (propuesta) |
| A-14 (ST-3) | Tras A-13, con el enlace vivo, escribir CMD `state:2` (varias veces, cada ~100 ms) | ACK de cada uno; 16 **sigue en 0** (retenido) |
| A-15 (ST-4) | Tras A-14, escribir CMD `state:0` y luego CMD `state:2` | 16 = 0 y recién con el segundo, 16 = 2 |
| A-16 (ST-5) | CMD con `"state":3`; esperar 301 ms | 16 = 0 retenido; un CMD `state:3` posterior no reanuda |
| A-20 (ST-6, ST-7) | Con `state:2` activo, desconectar en nRF Connect; reconectar **sin escribir nada** | al desconectar 15 = 0 y 16 = 0; al reconectar 15 = 1, 16 = 0, no se reanuda |
| A-21 (ST-8, ST-9) | Tras A-20: (a) escribir CMD `state:2` sin STOP antes; (b) CMD `state:0` y luego CMD `state:2` | (a) 16 = 0; (b) 16 = 0 y después 16 = 2 |
| A-22 (ST-11) | CMD `state:1` y esperar 301 ms; luego CMD `state:1` | 16 = 0 a los 301 ms; el siguiente depende de la pregunta 9 (sin retención: vuelve a 1) |
| A-17 (AR-1, AR-2) | Con área cargada (POLY id=7), activar las notificaciones | llega `{"t":"AREA","id":7}`; sin área, `id:0` |
| A-18 (AR-3, AR-4) | Con `id` 7 cargado, desconectar y reconectar sin escribir | `[23]` = 7 en todo momento; `/app/working_area` sigue publicándose cada ~2 s; al reconectar llega `AREA id:7` |
| A-19 (AR-5…AR-7) | `POLY id=8` válido; `PCLR`; POLY de 11 vértices | `POK`+`AREA 8`; `AREA 0`; `PERR` sin `AREA` |

## 8. Comportamiento del ESP y `/sensores`

### 8.1 Corte de seguridad

**REQUISITO (decisión de la usuaria, 14/11/26).** **Estado en el firmware: PENDIENTE DE IMPLEMENTAR.** El firmware del sensor v7.0 hoy fuerza solo dir, cutter y trimmer (`main.c`, ~líneas 773-777); el forzado de `app_state`, el STOP retenido y los mensajes `AREA`/`ESTOP` son requisitos para el firmware BLE, aún sin escribir. El ESP fuerza `app_state` a **STOP (0)** y además `app_dir`, `app_cutter`, `app_trimmer` a **0** (índices 16, 17, 19, 20) si ocurre cualquiera de:
- `app_connected` = 0 (la app se desconecta);
- nunca llegó un comando válido en esta conexión;
- el último comando válido tiene **más de 300 ms** (300 vale, 301 corta).

Y lo publica así en `/sensores`. Esto cubre también **AUTO_RUN y AUTO_PAUSE**: ninguna orden previa sobrevive a una desconexión.

**El robot NO reanuda solo al reconectar:** el ESP no restaura el último estado. **Regla única (la de ST-9):** tras cualquier corte de más de 300 ms o desconexión, el ESP queda en STOP retenido y **solo vuelve a aceptar AUTO (`state:2/3`) después de recibir un comando válido con `state:0`**; recién un comando posterior que pida AUTO cambia `app_state`. La app ya arranca cada conexión con ese STOP (no cuesta nada) y la usuaria tiene que volver a pedir AUTO_RUN a propósito. El requisito no define qué pasa con `app_speed` y `app_seq` en el corte: **PROPUESTA** de este documento, se conservan como llegaron.

**STOP retenido en AUTO (decisión de la usuaria, 14/11/26, AUD-17).** Si el corte de más de 300 ms ocurre en **AUTO_RUN o AUTO_PAUSE**, el ESP queda en **STOP retenido**: mantiene `app_state=0` y dir/cutter/trimmer=0 y **no reanuda aunque lleguen comandos frescos con `state:2/3`** (el enlace puede seguir vivo: el siguiente latido de la app con `state:2` no reanuda). La retención se libera solo con un comando válido `state:0` y se vuelve a aceptar AUTO con un comando **posterior** que lo pida. Lo mismo vale tras una desconexión en AUTO: la conexión nueva exige un `state:0` antes de aceptar AUTO. El ESP avisa a la app con `ESTOP` (5.9, propuesta de formato). El ESP sigue mandando el ACK de recepción de cada comando válido aunque lo ignore, así que **un ACK no significa que se aplicó**.

**MANUAL: pregunta abierta** (sección 11, pregunta 9). El requisito de la usuaria se refiere a AUTO; no se inventa la respuesta.

**Pendiente de la app (simulador):** el ESP simulado de la app (`SimulatedRobotLink`) **no** fuerza `state` a STOP en el corte, **no** retiene el STOP y **no** emite `AREA` ni `ESTOP`. Es código de la app y queda para la segunda APK; hasta entonces el simulador **no** es una referencia de estos requisitos.

**Efecto en la Raspberry:** ya no tiene que decidir qué hacer con AUTO_RUN tras una caída de la app, porque le llega `app_state = 0`. Sigue valiendo su propio watchdog en MANUAL (`app_cmd_age_ms > 300` o `app_connected = 0` → STOP, `e7_app_android.md` §4).

**El polígono vigente NO se borra** con nada de lo anterior (decisión de la usuaria, 14/11/26; ver 5.4 y 5.8).

### 8.2 Estado inicial de cada conexión (regla del ESP)

Una conexión nueva arranca con `app_state = 0` (STOP) y dir, speed, cutter y trimmer en 0, **sin heredar nada de la conexión anterior**. Aplica la **regla única de 8.1 (la de ST-9):** AUTO (`state:2/3`) solo se acepta después de un comando válido con `state:0` en esa conexión; un `state:2` como primer comando se mantiene en 0. (La app ya manda STOP primero; esta regla cubre otros clientes y fallos.) Qué pasa con `state:1` (MANUAL) en esa situación es la **pregunta abierta 9** (sección 11); no se cierra acá.

### 8.3 Índices 15–23 en cada caso

| Caso | 15 `app_connected` | 16 `app_state` | 17 `app_dir` | 18 `app_speed` | 19 / 20 | 21 `app_seq` | 22 `app_cmd_age_ms` | 23 `app_polygon_id` |
|---|---|---|---|---|---|---|---|---|
| Sin app, nunca conectada | 0 | 0 | 0 | 0 | 0 / 0 | 0 | -1 | el vigente (0 si no hay; tras un reinicio, ver pregunta 8) |
| Conectada y cifrada, sin comando todavía | 1 | 0 | 0 | 0 | 0 / 0 | 0 | -1 | vigente |
| Comando válido, antigüedad ≤ 300 ms | 1 | `state` | `dir` | `speed` | `cutter` / `trimmer` | `seq` | ms desde la llegada | vigente |
| STOP (CMD con `state:0`) | 1 | 0 | `dir` recibido | `speed` recibido | recibidos | `seq` | ms | vigente |
| Comando con más de 300 ms (de AUTO: **retenido** hasta un `state:0` válido y un AUTO posterior) | 1 | **0** | **0** | `speed` | **0 / 0** | `seq` | > 300 | vigente |
| Desconexión | 0 | **0** | 0 | 0 | 0 / 0 | 0 | -1 | **vigente (se conserva)** |

- `app_connected = 1` cuando hay una conexión **cifrada y autenticada** (PROPUESTA), no con la simple conexión GAP.
- Al desconectarse, el ESP vuelve a anunciar.
- Los valores se publican en un `Float32MultiArray`: todos los enteros de la tabla (hasta 65535) son exactos en Float32.
- Valor máximo de `app_cmd_age_ms`: **PENDIENTE** (cota de saturación no definida).

## 9. Correspondencia exacta con la app

| Campo JSON | Contrato (Directiva §3.1) | `/sensores` | Código de la app |
|---|---|---|---|
| `state` | state: 0 STOP, 1 MANUAL, 2 AUTO_RUN, 3 AUTO_PAUSE | 16 `app_state` | `ControlCommand.state` / `RobotState.code` (`control_command.dart`) |
| `dir` | dir: 0 nada, 1 adelante, 2 atrás, 3 izquierda, 4 derecha | 17 `app_dir` | `ControlCommand.dir` / `Direction.code` |
| `speed` | speed: 0–100 % | 18 `app_speed` | `ControlCommand.speed` |
| `cutter` | cutter: 0/1 | 19 `app_cutter` | `ControlCommand.cutter` |
| `trimmer` | trimmer: 0/1 | 20 `app_trimmer` | `ControlCommand.trimmer` |
| `seq` | seq: 0–65535 | 21 `app_seq` | `ControlCommand.seq` / `SeqCounter` |
| — | antigüedad del último comando | 22 `app_cmd_age_ms` | (no la ve la app) |
| — | conexión de la app | 15 `app_connected` | `LinkStatus.connected` |
| `id` (POLY/POK/PERR) | id del área | 23 `app_polygon_id` | `sendPolygon(id, …)`, `PolygonAccepted.id`, `PolygonRejected.id` |
| `p` | vértices int32 1e-7° (lat, lon) | `/app/working_area` | `List<(int, int)>` |
| `AREA` (`t:"AREA"`, `id` 0–65535; 0 = sin área) | área activa informada a la app (**REQUISITO**, usuaria 14/11/26) | 23 `app_polygon_id` (misma fuente) | **PENDIENTE DE LA APP (segunda APK, mapa):** `esp_protocol.dart` todavía **NO** decodifica `AREA` y no hay `RobotMessage` para él; la app deberá guardar localmente cada polígono enviado indexado por id y, si no conoce el id activo, mostrar solo el número. No se implementa ahora |
| `ESTOP` (`t:"ESTOP"`, `why:"T"`; 24 B; **PROPUESTA de formato**, la usuaria eligió el aviso el 14/11/26) | el ESP quedó en STOP retenido tras un corte > 300 ms en AUTO | 16 `app_state` = 0 | **PENDIENTE DE LA APP (segunda APK):** `esp_protocol.dart` todavía **NO** decodifica `ESTOP`; al recibirlo el controlador debe pasar lo pedido a STOP y la usuaria debe volver a pedir AUTO |
| `sats` | — | 13 `gps_sats` | `GpsFix.satellites` |
| `hdop` | — | 14 `gps_hdop` | `GpsFix.hdop` |
| `fix`, `lat`, `lon` | — | (GPS interno del ESP) | `GpsFix.fixQuality/lat/lon` |

| Constante | Valor | Archivo |
|---|---|---|
| Heartbeat | 100 ms | `app_config.dart` (`heartbeatPeriod`) |
| Corte del ESP | 300 ms | `app_config.dart` (`espCommandTimeout`) |
| Rango de `id` | 1–65535 | `esp_protocol.dart` (`polygonIdMin/Max`) |
| Vértices | 3–10 | `esp_protocol.dart` (`minVertices/maxVertices`) |
| Buffer de línea | 512 B | `esp_protocol.dart` (`maxLineLength`) |
| MTU pedido | 517 | `ble_robot_link.dart` (`BleConfig.requestedMtu`) |
| Códigos PERR | `FMT, NVERT, RANGE, ID, LEN` | `esp_protocol.dart` (`PerrCode`) |
| UUID | sección 2 | `ble_robot_link.dart` (`BleConfig`): **siguen en `null` (PENDIENTE)**, para que `connect()` quede bloqueado hasta que exista el firmware |

Comportamientos de la app que el firmware debe conocer:
- Escribe siempre en orden y serializa las escrituras: nunca intercala los fragmentos de dos líneas.
- Si se cae el enlace, descarta lo pendiente y **nunca** reenvía una línea de la conexión anterior. Una línea cortada a la mitad queda incompleta en el ESP, que la descarta (sección 4).
- Los comandos pendientes se juntan en el último, salvo STOP, que nunca se descarta ni se adelanta.
- Ignora mensajes ESP → app de tipo desconocido o fuera de rango.

## 10. Validaciones del ESP (resumen)

- **CMD:** formato, rangos, duplicados. Sin ACK si es inválido.
- **POLY:** formato, `id`, 3–10 vértices, int32. **No** geometría (la valida la Raspberry en `working_area_node`).
- Entradas inválidas **nunca** cambian el estado vigente.
- El ESP no interpreta ni valida lo que el Brain hace con los comandos.

## 11. Preguntas y decisiones abiertas

**Para el compañero de firmware** (necesarias para el diseño del firmware, aunque el protocolo BLE no depende de ellas):

1. **Sensor v7.0:** ¿el firmware v7.0 ya se compiló y se flasheó? (`00_estado_actual.md` línea 64 lo da como pendiente de confirmar).
2. ¿El micro-ROS del sensor sale por el **USB nativo** o por el **conector COM** (UART0)? El código del sensor v7.0 dice USB nativo y `docs/pines.md` §1 dice COM/UART0. Hay que unificar. Afecta qué pines y qué cable usa el firmware que va a convivir con NimBLE.
3. ¿Ya se hizo el intercambio físico de placas (sensor al ESP32-S3)? El doc `e7_app_android.md` §2 todavía describe el ESP32 clásico con partición de app de 1 MB; con NimBLE y micro-ROS hay que revisar partición y RAM.
4. ¿NimBLE permite exigir LE Secure Connections (rechazar legacy) y negociar MTU 517 con tu versión de ESP-IDF? (secciones 3.1 y 4).
5. ¿Qué evento de NimBLE usás para el re-emparejamiento y para inyectar la clave estática? (3.3, 3.4)
6. ¿El GPS (UART2 9600, GPIO 16/17 en el clásico) cambia de pines en el S3?
7. **Objeciones a los requisitos de la usuaria y del usuario** (podés objetarlas por memoria o por seguridad; respuesta pendiente de cada una):
   - **Conservar el polígono al desconectarse** (usuaria, 14/11/26, 5.4): _respuesta:_ ________
   - **Mensaje `AREA` al conectarse y al cambiar el área** (usuaria, 14/11/26, 5.8): _respuesta:_ ________
   - **Mensaje `ESTOP` (propuesta de formato) y la retención** (usuaria, 14/11/26, 5.9): _respuesta:_ ________
   - **`app_state` a 0 en desconexión y al pasar de 300 ms** (usuaria, 14/11/26, 8.1, incluido el STOP retenido): _respuesta:_ ________
8. **¿El polígono vigente sobrevive a un reinicio o a un corte de energía del ESP: solo RAM o se guarda en NVS?** El requisito de la usuaria no lo define y acá no se inventa la respuesta. Qué debe informar `AREA` en cada caso: solo RAM → tras un reinicio manda `AREA id:0`; NVS → manda `AREA id:N` con el id guardado (y `/app/working_area` y el índice 23 deben coincidir con eso). Si se guarda en NVS, cuidar el desgaste de la flash (se escribe solo al aceptar un `POLY` o un `PCLR`) y el valor que se guarda si se corta la energía a mitad de escritura (solo se debe guardar un polígono completo y válido).

9. **PREGUNTA abierta (usuaria y compañero): ¿el STOP retenido también aplica a MANUAL?** El requisito de la usuaria se refiere a AUTO. **Recomendación (no es decisión):** **no** retener en MANUAL. Razón: en MANUAL el robot solo se mueve mientras la usuaria mantiene apretado un botón (acción explícita y continua), el corte de 300 ms ya lo detiene, y una retención convertiría cada microcorte del enlace en un "volver a pedir STOP". Riesgo de esa opción: si el enlace vuelve con el botón todavía apretado, el robot reanuda sin una pulsación nueva. La alternativa (retener también en MANUAL) es más conservadora y exige un `state:0` tras cada corte. Si se retiene en MANUAL, un comando `state:1` fresco durante la retención se mantiene en 0 igual que `state:2/3`.

**Para la usuaria:**

1. ¿Aprobás el esquema de clave de 6 dígitos sabiendo el riesgo de 3.5? Sobre la **ventana de emparejamiento física** (botón): es una **recomendación fuerte** y la decide el compañero (ver 3.5 y la entrega); la usuaria solo la conoce.
2. ¿Cifrar el NVS / la flash del ESP? (la clave queda legible con acceso físico).
3. Valores de bloqueo (3.3) y máximo de teléfonos emparejados (3.4).
4. Nombre anunciado (`Cortadora-E7` es una propuesta).
5. ¿Anuncio siempre abierto o con lista de aceptados una vez que hay un bond? (más seguro, pero impide emparejar un segundo teléfono sin borrar bonds).
6. `PCLR` sin respuesta: ¿se acepta que la app no pueda confirmar el borrado, o se define una respuesta (cambio al contrato)? (Nota: con `AREA`, tras un `PCLR` el ESP manda `AREA id:0`, así que la app sí puede ver que el área quedó borrada; la respuesta del contrato al `PCLR` en sí sigue sin definirse.)
7. Cota de saturación de `app_cmd_age_ms` (hoy sin definir).
8. Si la app debe poder recuperar los **vértices** del polígono activo desde el ESP (hoy `AREA` solo informa el id; la app guarda localmente los que envió). Para la segunda APK (mapa); **no se cierra acá**.

### 11.1 Lista única de estado (qué está decidido, qué es pregunta, qué sigue abierto)

| Tema | Estado | Quién | Fecha |
|---|---|---|---|
| Seguridad del enlace: clave de 6 dígitos, LE Secure Connections, cifrado y autenticación obligatorios | **Decidido** (pendiente de objeción del compañero) | usuario | previo |
| UUID de servicio y de las dos características | **Decidido** (sección 2) | coordinador | previo |
| Primer comando de cada conexión = STOP; la conexión arranca en STOP | **Decidido** | usuario | previo |
| `app_state` a 0 si la app se desconecta o pasan > 300 ms; no se reanuda solo | **REQUISITO** (8.1); **pendiente de implementar en el firmware** | usuaria | 14/11/26 |
| **STOP retenido en AUTO** tras un corte > 300 ms: no reanuda con comandos frescos hasta un `state:0` y un AUTO posterior | **REQUISITO** (8.1, 6.5) | usuaria | 14/11/26 |
| Mensaje `ESTOP` (`{"t":"ESTOP","why":"T"}`, 24 B) para avisar a la app del STOP retenido | **Requisito de avisar; el formato es PROPUESTA pendiente de la usuaria** (5.9) | usuaria | 14/11/26 |
| ¿El STOP retenido aplica también a MANUAL? | **Pregunta abierta** (usuaria y compañero; recomendación: no) | usuaria/compañero | — |
| La app decodifica `ESTOP` y reacciona (STOP, volver a pedir AUTO) | **Pendiente de la app** (segunda APK) | usuaria | — |
| El simulador de la app fuerza STOP en el corte, retiene y emite `AREA`/`ESTOP` | **Pendiente de la app** (segunda APK) | usuaria | — |
| Ventana de emparejamiento con botón físico | **RECOMENDACIÓN fuerte; la decisión es del compañero de firmware** (no está abierta para la usuaria) | compañero | — |
| El polígono vigente se conserva al desconectar; solo POLY/PCLR lo cambian | **REQUISITO** (5.4) | usuaria | 14/11/26 |
| Mensaje `AREA` (`{"t":"AREA","id":N}`) al activar notificaciones y al cambiar el área | **REQUISITO** (5.8) | usuaria | 14/11/26 |
| El compañero puede objetar los tres requisitos de arriba | **Espacio abierto** (pregunta 7) | compañero | — |
| ¿El polígono sobrevive a un reinicio del ESP (RAM o NVS)? | **Pregunta para el compañero** (8) | compañero | — |
| Formatos CMD, ACK, GPS, PERR, rango de `id`, buffer de 512 B | Escritos en este documento; **el contrato no está congelado hasta que la usuaria y el compañero lo confirmen** | ambos | — |
| La app decodifica `AREA` y la muestra; guarda polígonos localmente | **Pendiente de la app** (segunda APK) | usuaria | — |
| Recuperar los vértices desde el ESP | **Abierto** (usuaria, segunda APK) | usuaria | — |
| Cifrado de NVS, valores de bloqueo, nombre, anuncio abierto, cota de `app_cmd_age_ms` | **Abiertos** (lista "Para la usuaria" y 3.5) | usuaria/compañero | — |

**De la app (para después):** la app **no llama a `createBond()`** explícitamente: Android dispara el emparejamiento solo al encontrar un error de autenticación al activar notificaciones. Comportamiento a verificar en el teléfono real. Puede convenir un `createBond()` explícito y pedir prioridad alta de conexión.

## 12. Contradicciones y puntos a confirmar con el contrato

No elegí en ninguno; los dejo señalados.

1. **El ESP valida más de lo que dice el contrato.** La Directiva dice que valida "solo integridad (formato, cantidad de vértices)". Este documento agrega `id` en 1–65535 y rango int32. Es una ampliación (las coordenadas deben ser int32 por definición), no una contradicción, pero hay que confirmarla.
2. ~~Estado al desconectarse y modo AUTO.~~ **RESUELTA por decisión de la usuaria (14/11/26):** el ESP fuerza `app_state` a STOP (0) además de dir/cutter/trimmer, también para AUTO_RUN y AUTO_PAUSE, y no reanuda solo (8.1). `e7_app_android.md` §3 lo registra con una referencia mínima.
3. ~~Polígono vigente sin app.~~ **RESUELTA por decisión de la usuaria (14/11/26):** el polígono vigente se conserva al desconectar (5.4). Queda **abierta** solo la pregunta del compañero sobre su supervivencia a un reinicio (pregunta 8). El valor "sin app" de `e7_app_android.md` §3 (`…,-1,0`, índice 23 = 0) describe un ESP **sin área cargada**; con un área vigente, el índice 23 conserva su id.
4. **`app_connected`.** El doc lo define como "0/1". Acá se propone 1 solo con enlace cifrado y autenticado.
5. **Regla "primer comando = STOP"** y **"conexión nueva arranca en STOP"** son decisiones nuevas del usuario, ausentes de la Directiva y de `e7_app_android.md` §3–§4.
6. ~~Referencia errónea en el código~~ (`robot_link.dart` citaba "Directiva §5.2" para PERR): ya corregida por el coordinador a §3.2.
7. **`AREA` no está en la Directiva §3.2** (que no tiene ningún mensaje ESP → app para el área vigente). Es una ampliación aprobada por la usuaria el 14/11/26, que hay que reflejar en la Directiva si se mantiene.

## 13. Registro de cambios

| Versión | Fecha | Cambio |
|---|---|---|
| 1.0 | 2026-11-15 | Primera versión. Pendiente de revisión de la usuaria y de su compañero de firmware. |
