# AUDITORÍA — App Android E7 (Robot Cortadora)

Auditor: Agente 4. Registro de hallazgos y verificaciones con evidencia ejecutada.
Todo flutter/dart se corrió desde `R:\app_android` (R: = `d:\Moisés\Gramanova\robot_cortadora`)
después de `. D:\dev\env_flutter.ps1` (Flutter 3.47.8). Sin `flutter build`, `gradlew` ni `flutter run`.

Formato: `ID | archivo:línea | qué está mal | evidencia | gravedad | responsable | estado`.

> **Estado vigente de cada hallazgo: ver la sección "Ronda 2"** (más abajo). La tabla de la
> Ronda 1 se conserva como historia, con los estados que tenían en ese momento.

---

## Ronda 1 — 13/11/26

### Hallazgos

| ID | Archivo:línea | Qué está mal | Evidencia (comando y salida) | Gravedad | Responsable | Estado |
|---|---|---|---|---|---|---|
| AUD-01 | `lib/core/simulated_robot_link.dart:184` (y doc en `:91-94`); test `test/core/simulated_robot_link_test.dart:269-278` | El ESP simulado corta dir/cutter/trimmer con el comando de **300 ms justos**. El contrato (Directiva §3 y docs §3 línea 66) dice "**más de** 300 ms": a 300 ms todavía NO corta, a 301 ms sí. El `Timer(AppConfig.espCommandTimeout)` dispara en 300 ms. Además el test del Agente 1 se llama "comando con **más de** 300 ms" pero exige el corte a 300 ms justos (nombre engañoso). | `flutter.bat test test/audit/audit_protocol_test.dart` → `comando con 300 ms EXACTOS de antigüedad: el ESP NO corta [E]` / `Expected: (Direction.forward, 1, 1)  Actual: (Direction.none, 0, 0)`. El caso 301 ms (corta) y 299 ms (no corta) pasan. | MEDIA (el desvío es hacia el lado seguro: nunca deja al robot menos protegido; pero el simulador es la referencia del firmware y no respeta el borde del contrato) | Agente 1 | ABIERTO |
| AUD-02 | `lib/ui/widgets/stop_button.dart:29` (`onPressed: controller.stop`) | El STOP usa `FilledButton.onPressed` (TapGestureRecognizer): se dispara recién al **levantar** el dedo y **se pierde** si el dedo se desliza más de kTouchSlop (18 dp), aunque siga dentro del botón. Un STOP apretado con pánico/arrastre no llega. Mientras el dedo está apoyado no se pidió nada. | `flutter.bat test test/audit/audit_ui_test.dart` → `STOP se dispara aunque el dedo se deslice al apretarlo (pánico) [E]` / `Expected: RobotState.stop  Actual: RobotState.manual` / `un STOP apretado con deslizamiento no debe perderse`; y `STOP se envía al APOYAR el dedo, no al levantarlo [E]` / `Expected: RobotState.stop Actual: RobotState.manual`. | ALTA (seguridad: STOP) | Agente 2 | ABIERTO |
| AUD-03 | `lib/ui/widgets/hold_button.dart:52-55` (`_up`) | Si el HoldButton se desmonta con el dedo apoyado (p. ej. cambiar de pestaña con otro dedo) y después se levanta ese dedo, `_up` llama `setState()` sobre un State ya desechado. En debug: FlutterError; en release: excepción (null check de `_element`) dentro del despacho de punteros. El dir sí queda en 0 (lo baja `dispose` + `_select`), por eso no es ALTA, pero es una excepción en el camino del mando. | `flutter.bat test test/audit/audit_ui_test.dart` → `cambiar de pestaña con otro dedo mientras se mantiene adelante → dir 0 [E]` / `setState() called after dispose(): _HoldButtonState#45abf(lifecycle state: defunct, not mounted)` / `#2 _HoldButtonState._up (package:cortadora_e7/ui/widgets/hold_button.dart:54:5)`. Las aserciones de `dir == none` previas al `up()` pasan. | MEDIA | Agente 2 | ABIERTO |
| AUD-04 | `lib/core/esp_protocol.dart:176-213` (`decodeEspLine` / `_decodeGps`) | El parser ESP→App acepta valores fuera de rango: `POK`/`PERR` con `id` fuera de 1–65535 (rango que propone el propio Agente 1, `polygonIdMin/Max`), GPS con lat > ±90° o lon > ±180° (en 1e-7°) y `fix` negativo. El ACK sí valida rango (asimetría). | `flutter.bat test test/audit/audit_protocol_test.dart` → `decodeEspLine: valores fuera de rango ... se descartan [E]` / aceptadas: `{"t":"POK","id":0}`, `{"t":"POK","id":-5}`, `{"t":"POK","id":70000}`, `{"t":"PERR","id":-1,"e":"FMT"}`, `{"t":"GPS","fix":1,"lat":900000001,"lon":0}`, `{"t":"GPS","fix":1,"lat":0,"lon":-1800000001}`, `{"t":"GPS","fix":1,"lat":99999999999,"lon":0}`, `{"t":"GPS","fix":-3,"lat":0,"lon":0}`. | BAJA | Agente 1 | ABIERTO |
| AUD-05 | `lib/core/ble_robot_link.dart:268-279` (`sendCommand`) y `:75-91` | El camino de envío BLE **conectado** no es ejercitable en tests (no hay costura para inyectar escritor/estado sin radio): la política de herramientas, el descarte por `_commandInFlight` y la fragmentación real solo se pueden verificar leyendo el código. | `audit_static_test.dart` → `BleRobotLink.sendCommand aplica la política de herramientas ANTES de escribir` pasa (verificación estática); `audit_safety_test.dart` → `BleRobotLink: sin radio no se puede llevar a "connected"...` solo cubre el estado desconectado. | MEDIA | Agente 1 | ABIERTO |
| AUD-06 | `lib/core/ble_robot_link.dart:269` (`|| _commandInFlight) return;`) | Si hay una escritura en curso, el comando nuevo **se descarta**, incluido el **STOP inmediato** (botón STOP, soltar, segundo plano, desconectar). En uso normal lo repite el heartbeat 100 ms después; en `detached` (cierre) puede no haber "después" y el STOP no sale (queda el respaldo de 300 ms del ESP, que no fuerza `state`). Hoy NO afecta a la APK (BLE no está cableado: `link_factory.dart:12`), pero debe corregirse antes de habilitar BLE. | Lectura de código (no ejecutable sin radio, ver AUD-05). `SessionController.stop()` → `_sendCurrent()` → `_deliver()` → `BleRobotLink.sendCommand` retorna sin escribir si `_commandInFlight`. | ALTA (seguridad: STOP) — latente | Agente 1 | ABIERTO |
| AUD-07 | `lib/core/ble_robot_link.dart:285-292` vs `lib/core/simulated_robot_link.dart:145-148` | Las dos implementaciones de `RobotLink.sendPolygon` se comportan distinto ante un polígono inválido: BLE lanza `ArgumentError` (incluso desconectado) y no transmite; el simulador lo transmite y responde `PERR`. El contrato (`robot_link.dart:77-79`) no dice cuál vale; quien llame tiene que manejar las dos. Hoy no hay llamador (APK sin editor). | `flutter.bat test test/core` → `sendPolygon inválido lanza ArgumentError (no fabrica un PERR)` (BLE) y `inválido → PERR con código; el área vigente no cambia` (sim): ambos verdes con comportamientos opuestos. | BAJA | Agente 1 (+ coordinador para fijar el contrato) | ABIERTO |
| AUD-08 | `app_android/README.md:14, 41, 91` | El README manda hacer `cd "d:\Moisés\..."` y correr flutter ahí; en esa ruta `flutter analyze` se cae por la "é". Debe indicar trabajar desde `R:\app_android`. | `Set-Location 'd:\Moisés\Gramanova\robot_cortadora\app_android'; flutter.bat analyze` → traza `[stderr] #26 _RawReceivePort._handleMessage ...` y `exit=255`. Desde `R:\app_android`: `No issues found!`. | BAJA | Agente 3 | ABIERTO |
| AUD-09 | `lib/core/ble_robot_link.dart:42-47` vs `android/app/build.gradle.kts:54-58` | Registro inconsistente: el comentario del gradle dice "Decisión del usuario (13/11/26): proyecto de uso educativo/personal sin fines de lucro (licencia FlutterBluePlus 1.6...)"; `BleConfig.license` sigue `null` con "PENDIENTE: decisión del usuario". No es defecto (BLE no cableado), pero uno de los dos está desactualizado. | Lectura de ambos archivos (citas literales arriba). | BAJA | Coordinador / Agente 1 | ABIERTO |
| AUD-10 | Manifest COMPILADO (`app-debug.apk`) | `aapt2 dump badging` muestra features implícitas **obligatorias** `android.hardware.bluetooth` (por BLUETOOTH/BLUETOOTH_ADMIN) y `android.hardware.location` (por ACCESS_FINE_LOCATION). Solo filtran en Play Store; la instalación manual en el M12 no se afecta. Si algún día se publica, declararlas `required="false"`. | `aapt2.exe dump badging app-debug.apk` → `uses-feature: name='android.hardware.bluetooth'` / `uses-implied-feature: name='android.hardware.bluetooth' reason='requested android.permission.BLUETOOTH permission...'` / `uses-feature: name='android.hardware.location'`. | BAJA (informativo) | Agente 3 | ABIERTO |

#### Correcciones que se piden

- **AUD-01**: cortar con antigüedad **> 300 ms** (p. ej. guardar el instante de recepción con un reloj inyectable y comparar `edad > espCommandTimeout` al consultar, o `Timer(espCommandTimeout + 1 ms)`); actualizar el comentario de `espPublishedCommand` y el test del Agente 1 (que hoy exige el corte a 300 ms). Criterio de cierre: `audit_protocol_test.dart` grupo "borde de 300 ms" en verde (300 → no corta, 301 → corta).
- **AUD-02**: pedir STOP en **pointer down** (p. ej. `Listener(onPointerDown: (_) => controller.stop())` alrededor del botón, conservando `onPressed`/semántica para accesibilidad; `stop()` es idempotente). Cierre: los dos tests A5 de STOP en verde.
- **AUD-03**: en `_HoldButtonState._up` (y `_down`) salir si `!mounted` antes de `setState`. Cierre: test "cambiar de pestaña con otro dedo..." en verde.
- **AUD-04**: en `decodeEspLine` devolver `null` si `id ∉ [polygonIdMin, polygonIdMax]` (POK/PERR con id), si `|lat| > 900000000`, `|lon| > 1800000000` o `fix < 0`. Cierre: test A8 `decodeEspLine: valores fuera de rango...` en verde.
- **AUD-05**: agregar una costura `@visibleForTesting` (escritor de bytes + estado inyectables) para poder testear `sendCommand` conectado; con ella, tests de política de herramientas y de STOP.
- **AUD-06**: no descartar comandos: dejar un "último comando pendiente" (gana el más nuevo) que se escriba al terminar la escritura en curso, o al menos nunca descartar uno con `state = STOP`. Cierre: test con la costura de AUD-05.
- **AUD-07**: el coordinador fija en `robot_link.dart` el comportamiento de `sendPolygon` ante inválidos; ambas implementaciones lo siguen.
- **AUD-08**: README: trabajar desde `R:\app_android` (y explicar por qué).
- **AUD-09**: alinear: o se pone `License.nonprofit` en `BleConfig` (si esa es la decisión del usuario), o se corrige el comentario del gradle.
- **AUD-10**: opcional; solo si se publica en tienda.

### Observaciones (sin hallazgo, quedan registradas)

- **Parser de CMD** (`control_command.dart:157-191`): acepta claves extra y, con clave duplicada, gana la última (`"cutter":0,...,"cutter":1` → cutter 1). Es comportamiento de `jsonDecode`; a tener en cuenta al congelar el formato con el firmware (el ESP debería rechazar duplicadas). Test de caracterización: `audit_protocol_test.dart` "(caracterización) parser de CMD..." (verde).
- **Pulso de giro**: en t = 300 ms el tick del heartbeat y el fin del pulso empatan; sale un último `dir = izquierda` y en el MISMO instante el `dir = 0`. Mantener apretado no extiende el giro. Test `audit_safety_test.dart` "pulso: mantener apretado NO extiende..." (verde).
- **Heartbeat y trabajo síncrono largo**: un bloqueo síncrono de 400 ms en el hilo de la UI abre un hueco de ~450 ms (> 300 ms). Es inherente a Dart de un solo hilo; el respaldo es el corte del ESP. Ver test A2 abajo.
- Los fakes del Agente 2 (`test/app/fakes.dart`) usan streams **síncronos**, a diferencia de los enlaces reales (asíncronos). Lo cubrí con un doble propio asíncrono (`test/audit/audit_helpers.dart`) y con el `SimulatedRobotLink` real: no apareció ningún defecto por esa diferencia.
- Un test del Agente 1 (`ble_robot_link_test.dart:30-37`, "sin conexión, sendCommand/clearPolygon no hacen nada ni lanzan") solo comprueba que no lanza y que sigue desconectado; no puede comprobar "no hacen nada" (ver AUD-05). No es trivialmente verdadero, pero es débil.

### Verificado sin hallazgos (con evidencia)

**analyze (todo el proyecto, incluidos mis tests)**

```
R:\app_android> flutter.bat analyze
Analyzing app_android...
No issues found! (ran in 5.2s)
```

**Conteo real de tests del Agente 1 (`test/core`)** — declarado 63:

```
R:\app_android> flutter.bat test test/core --reporter expanded
...
00:01 +62: .../simulated_robot_link_test.dart: dispose cierra los streams y deja de enviar
00:01 +63: All tests passed!
```
+63 / −0 / ~0 skip. Revisé los 4 archivos línea por línea: ningún test vacío ni salteado (`grep skip:|.skip(|@Skip` sin resultados en `test/` fuera de `audit/`); todos ejercitan lo que dice su nombre (salvo la debilidad anotada arriba y el nombre engañoso de AUD-01).

**Conteo real de tests del Agente 2 (`test/app`, `test/ui`, `test/widget_test.dart`)** — declarado 41:

```
R:\app_android> flutter.bat test test/app test/ui test/widget_test.dart
...
00:04 +40: .../small_screen_test.dart: 360×800 dp, texto 1.3: STOP visible y sin overflow (toolsEnabled=true)
00:04 +41: All tests passed!
```
+41 / −0 / ~0 skip. Sin tests vacíos ni salteados.

**Suite completa (agentes + auditor)**

```
R:\app_android> flutter.bat test
...
00:10 +164 -5: Some tests failed.
```
169 tests = 104 de los agentes (todos verdes) + 65 del auditor (60 verdes, 5 rojos = AUD-01, AUD-02 ×2, AUD-03, AUD-04).

**docs/e7_app_android.md** — el Agente 1 solo AGREGÓ:

```
git -C d:\Moisés\Gramanova\robot_cortadora diff --stat
 docs/e7_app_android.md | 24 ++++
```
Dos bloques, ambos encabezados "**PROPUESTA (no decidida...)**": uno en §4 (después de "Formato JSON exacto ... a definir en la fase 2", CMD/ACK/GPS/MTU, "UUID: PENDIENTES") y uno en §5 (formato de PERR y códigos). Cero líneas borradas o modificadas (solo `+`).

**Datos inventados como decididos**: ninguno. UUID de servicio/características y licencia en `null` (PENDIENTE); ningún UUID literal en `lib/` (test estático); el JSON de CMD, ACK, GPS y PERR está marcado PROPUESTA en el código (`esp_protocol.dart:9-15`, `control_command.dart:58-60, 146`) y en docs. POLY/POK/PCLR respetan el formato fijo (test A7: claves `t,id,p` exactas).

**Tests del auditor que pasan** (`test/audit/`):

| Pedido | Test(s) | Resultado |
|---|---|---|
| 1. Heartbeat ~10 Hz y no se detiene | `audit_heartbeat_test.dart` grupo A1: 10 min → 6000 envíos exactamente cada 100 ms con dir 0; con `SimulatedRobotLink` real 60 s sin que el ESP simulado corte nunca; ráfaga de 5000 acciones de UI con **un solo** timer periódico y nunca > 100 ms entre envíos; 50 reconexiones sin timers duplicados. | 4/4 verdes |
| 2. Heartbeat bajo carga | `audit_heartbeat_load_test.dart` (reloj REAL, ver abajo) | 3/3 verdes |
| 3. seq 65535 → 0 | A3: comando, JSON y ACK del simulador `[65533, 65534, 65535, 0, 1, 2]`; 131072 envíos (2 vueltas) sin saltos; envíos inmediatos (soltar/STOP) también consumen seq sin repetir. | 3/3 verdes |
| 4. Soltar → dir 0 | `audit_safety_test.dart` A4 (4 direcciones: envío inmediato con dir 0 en el mismo instante, y todos los siguientes en 0; STOP cancela el pulso); `audit_ui_test.dart` A4 (pointer cancel, dedo que se desliza/scrollea, dos dedos). | 6/6 verdes + 3 UI verdes (el de cambio de pestaña falla por AUD-03, no por dir) |
| 5. Pérdida de conexión / segundo plano → STOP | A5: `simulateLinkLoss` del simulador real → STOP, sin heartbeat, ESP con dir/herramientas 0, y al reconectar el **primer** comando es STOP; ventana caída/aviso asíncrono sin envíos; los 4 estados ≠ resumed (inactive, hidden, paused, detached) → STOP inmediato y heartbeat sigue en STOP; ciclo de vida REAL por el binding con `SessionLifecycleObserver`; `main.dart` real (observer registrado, robot simulado, banner, STOP). | todos verdes |
| 6. TOOLS_ENABLED=false imposible | `AppConfig.fromEnvironment.toolsEnabled == false`; controlador con 20 000 acciones aleatorias (semilla fija 20261113, incluye ciclo de vida y reconexiones) → ningún 1 en >1000 comandos ni en sus líneas JSON; `SimulatedRobotLink(off)` con 1/1 en las 20 combinaciones state/dir → llega 0/0; controlador ON + enlace OFF → el enlace igual filtra; UI: botones deshabilitados, aviso, tocar no envía 1; estático: nadie en `lib/` construye `AppConfig(` ni pone `toolsEnabled: true`, `main.dart` usa `AppConfig.fromEnvironment`, BLE y sim aplican `applyToolsPolicy` antes de escribir. El **constructor** `ControlCommand` sí admite cutter=1 (por diseño: la barrera está en controlador + enlaces; caracterizado). BLE conectado: solo estático (AUD-05). | todos verdes |
| 7. POK/PERR del simulador | A7: válidos (3 y 10 vértices, int32 extremos, id 1 y 65535) → exactamente un POK con su id; 9 inválidos → PERR con id y código correctos, nunca POK, área vigente intacta (doble buffer); sin conexión no responde nada; en sesión real solo llegan ACK/GPS/POK/PERR, un POK no cambia lo pedido, GPS simulado sin sats/hdop inventados, ACK = comandos realmente recibidos; PCLR sin respuesta. | 5/5 verdes |
| 8. Rangos | A8: bordes y fuera de rango por campo; las 640 combinaciones de bordes pasan un **oráculo independiente** (regex + rangos, `audit_helpers.dart`) y miden ≤ 77 B; JSON del controlador en sesión larga pasa el oráculo; parser rechaza bool, null, `5e1`, `50.0`, enteros enormes, negativos, sin `t`, `t` en minúscula, basura final, vacío, `null`; ACK con bordes 0/65535 y fuera de rango; `setSpeed` fuera de rango lanza. | verdes (salvo AUD-04) |
| Estáticos | `audit_static_test.dart`: manifest fuente, gradle, BLE no cableado, sin mapa (el `MapScreen` de `home_shell.dart:43-44` está solo en comentario). | 11/11 verdes |

**Test 2 — heartbeat bajo carga (reloj real).** Salida literal de la última corrida completa:

```
A2 línea base: envíos=10 medio=99.1ms máx=100ms
A2 con carga:  envíos=244 medio=15.9ms máx=26ms  (tareas=409, microtareas=81800, notificaciones UI=819)
A2 solo heartbeat con carga: envíos=39 medio=99.4ms máx=106ms (tareas=487)
A2 bloqueo 400 ms: envíos=10 medio=132.1ms máx=462ms gaps=[92, 107, 95, 92, 462, 51, 85, 100, 105]
```

- **Diseño**: `test()` sin `testWidgets` (timers reales). Durante 4 s se encadenan tareas del event loop (`Timer.run`) que ocupan la CPU 8 ms cada una (≈ 100 % del isolate: 409–487 tareas × 8 ms ≥ 3,2 s, el test lo exige), cada una con 200 microtareas y acciones de UI sobre el controlador (`setSpeed`, `pressDirection`/`releaseDirection` → `notifyListeners`). Se sellan los envíos con un `Stopwatch`.
- **Tolerancias explícitas**: hueco máximo < 200 ms (corte del ESP: 300 ms); período medio del heartbeat solo 95–110 ms; 36–41 envíos en 4 s.
- **Qué demuestra**: con el isolate saturado en trozos cortos, el `Timer.periodic` sigue saliendo a ~100 ms (medio 99,4 ms, máx. 106 ms): la carga no lo empuja más que un trozo; las notificaciones de UI no lo frenan ni lo duplican.
- **Qué NO demuestra**: el comportamiento en el Galaxy M12 real (CPU lenta, GC, hilo de raster, BLE con write-with-response, ahorro de energía de Android en segundo plano). Y un trabajo **síncrono largo** sí lo retrasa: el tercer test lo caracteriza (hueco de 462 ms con un bloqueo de 400 ms; después el timer se realinea, hueco de 51 ms). La medición en el teléfono queda para la ronda con la APK instalada.

**Manifest fuente** (`android/app/src/main/AndroidManifest.xml`, test estático + lectura): `BLUETOOTH_SCAN` con `usesPermissionFlags="neverForLocation"` y sin maxSdk; `BLUETOOTH_CONNECT` sin maxSdk; `BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION` con `maxSdkVersion="30"`; `ACCESS_COARSE_LOCATION` con `maxSdkVersion="28"`; `bluetooth_le required="false"`; sin `ACCESS_BACKGROUND_LOCATION` ni `BLUETOOTH_ADVERTISE`; label "Cortadora E7". El manifest del plugin (`flutter_blue_plus_android-9.0.5/android/src/main/AndroidManifest.xml`) está vacío a propósito: no mergea permisos.

**Manifest COMPILADO** (APK debug del Agente 3, `build\app\outputs\flutter-apk\app-debug.apk`, 151 450 690 B, 13/11/2026 21:41:14; solo lectura):

```
aapt2.exe dump permissions app-debug.apk
package: com.robotcortadora.cortadora_e7
uses-permission: name='android.permission.INTERNET'
uses-permission: name='android.permission.BLUETOOTH_SCAN' usesPermissionFlags='neverForLocation'
uses-permission: name='android.permission.BLUETOOTH_CONNECT'
uses-permission: name='android.permission.BLUETOOTH' maxSdkVersion='30'
uses-permission: name='android.permission.BLUETOOTH_ADMIN' maxSdkVersion='30'
uses-permission: name='android.permission.ACCESS_FINE_LOCATION' maxSdkVersion='30'
uses-permission: name='android.permission.ACCESS_COARSE_LOCATION' maxSdkVersion='28'
uses-permission: name='com.robotcortadora.cortadora_e7.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'
aapt2.exe dump badging → minSdkVersion:'24'  targetSdkVersion:'36'  application-label:'Cortadora E7'
aapt2.exe dump xmltree → BLUETOOTH_SCAN usesPermissionFlags=0x00010000 (neverForLocation)
```
`INTERNET` viene solo de `src/debug/AndroidManifest.xml` y `src/profile/AndroidManifest.xml` (el `main` no la declara): normal en debug (hot reload). Verificar en la APK release que no esté. API 33 del M12 dentro de 24–36.

**License ping de flutter_blue_plus.** Razonamiento sobre `D:\dev\pub-cache\hosted\pub.dev\flutter_blue_plus_android-9.0.5\android\license_ping.gradle`: el plugin registra, en `gradle.projectsEvaluated`, para cada `applicationVariants.all`, la tarea `flutterBluePlusLicensePing<Variante>` con `appProject.tasks.create(...)` en el proyecto `:app`; el envío (`sendLicensePing`, POST a `script.google.com`) ocurre **solo en `doLast`**, es decir al ejecutar la tarea, no al configurarla. El bloque del coordinador (`android/app/build.gradle.kts:59-61`) está en el mismo proyecto `:app`: `tasks.matching { ... }` devuelve una colección **viva** y `configureEach` se aplica también a las tareas agregadas después (incluidas las creadas con `create` en `projectsEvaluated`, que se evalúa después del script de `:app`). Con `enabled = false`, Gradle saltea la tarea y `doLast` no corre. Alcanza para todas las variantes (el filtro es por prefijo del nombre). Evidencia de ejecución (log del Agente 3, `D:\dev\_logs\build_debug_2026-11-13_213903.log`):
```
> Task :app:flutterBluePlusLicensePingDebug SKIPPED
Skipping task ':app:flutterBluePlusLicensePingDebug' as task onlyIf 'Task is enabled' is false.
BUILD SUCCESSFUL in 2m 7s
```
La licencia (FlutterBluePlus License 1.6, Sección 1.4) dice que el ping "may attempt" y que su fallo "does not prevent use or building": desactivarlo no contradice la licencia. Pendiente: confirmar `SKIPPED` también en la variante release.

**UI contra la directiva**: banner MODO SIMULADO en todas las pantallas (tests del Agente 2 + `main.dart` real en mi test); STOP fuera del scroll, ≥ 76 dp de alto y visible en 360×800 con texto 1.3 (test del Agente 2 + mío); panel "Lo que la app está pidiendo" con la leyenda "Esto es lo pedido, no lo confirmado"; ACK rotulado "recibido por el ESP (no significa ejecutado)"; GPS del simulador rotulado "GPS (simulado)"; no se muestra estado de motores/herramientas; sin mapa (solo comentado); BLE visible pero deshabilitado ("pendiente del firmware BLE del ESP").

### Qué quedó sin poder auditar en esta ronda

- **Envío BLE conectado** (política de herramientas, descarte, fragmentación real, MTU): sin radio ni costura de test (AUD-05). Solo estático.
- **Heartbeat en el Galaxy M12 real** (CPU, GC, segundo plano de Android, latencia BLE): requiere la APK instalada.
- **APK release**: manifest sin `INTERNET` y `flutterBluePlusLicensePingRelease SKIPPED` — no hay build release (la compilación está a cargo del Agente 3/coordinador).
- **Permisos en tiempo de ejecución** ("Dispositivos cercanos") que menciona el README §4: BLE no está cableado en esta APK, no hay flujo que los pida.

### Archivos del auditor

- `test/audit/audit_helpers.dart` — doble `RecordingLink` (streams asíncronos, sin filtrar) y oráculo `auditCommandLine`.
- `test/audit/audit_heartbeat_test.dart` — tests 1 y 3.
- `test/audit/audit_heartbeat_load_test.dart` — test 2 (reloj real).
- `test/audit/audit_safety_test.dart` — tests 4, 5, 6 (controlador y enlaces).
- `test/audit/audit_ui_test.dart` — tests 4, 5, 6 en widgets + `main.dart`.
- `test/audit/audit_protocol_test.dart` — borde 300/301 ms, tests 7 y 8.
- `test/audit/audit_static_test.dart` — fuentes, manifest, gradle.

---

## Ronda 2 — 13/11/26

Base: commit `5f9b6ce` del coordinador ("feat(app): app E7 en modo simulado con correcciones de la ronda 1"). Cada cierre se verificó con corrida propia, no con el reporte del agente.

### Corridas literales (desde `R:\app_android`)

```
R:\app_android> flutter.bat analyze
Analyzing app_android...
No issues found! (ran in 4.0s)

R:\app_android> flutter.bat test test/core
00:00 +91: All tests passed!                       ← Agente 1 dijo 91: coincide (+91 / −0 / ~0)

R:\app_android> flutter.bat test test/app test/ui test/widget_test.dart
00:06 +49: All tests passed!                       ← Agente 2 dijo 49: coincide (+49 / −0 / ~0)

R:\app_android> flutter.bat test test/audit --concurrency=1
00:01 +8 -1: .../audit_ble_test.dart: reconexión (hallazgos nuevos si fallan) nada que se pidió ANTES de la caída sale por la conexión NUEVA [E]
00:01 +8 -2: .../audit_ble_test.dart: reconexión (hallazgos nuevos si fallan) una escritura colgada de la conexión vieja no bloquea el STOP de la nueva (< 300 ms) [E]
A2 con carga + press/release: heartbeat envíos=259 medio=14.9ms máx=20ms | testigo envíos=39 medio=99.4ms máx=108ms | carga 88 % (tareas=440)
A2 solo heartbeat con carga: heartbeat envíos=39 medio=99.5ms máx=107ms | testigo envíos=39 medio=99.5ms máx=107ms | carga 86 % (tareas=433)
A2 bloqueo 400 ms: envíos=10 medio=132.9ms máx=447ms gaps=[93, 109, 92, 109, 447, 46, 91, 101, 108]
00:20 +79 -2: Some tests failed.

R:\app_android> flutter.bat test --concurrency=1
00:02 +37 -1: .../audit_ble_test.dart: ... nada que se pidió ANTES de la caída sale por la conexión NUEVA [E]
00:02 +37 -2: .../audit_ble_test.dart: ... una escritura colgada de la conexión vieja no bloquea el STOP de la nueva (< 300 ms) [E]
00:35 +219 -2: Some tests failed.
```

221 tests = 91 (Agente 1) + 49 (Agente 2) + 81 (auditor). Los dos rojos son hallazgos NUEVOS (AUD-12 y AUD-13), no regresiones. Ningún test salteado (`grep skip:|.skip(|@Skip|markTestSkipped` en `test/`: solo aparecen usos de `Iterable.skip`).

### Estado de los hallazgos de la Ronda 1

| ID | Estado | Evidencia de la Ronda 2 |
|---|---|---|
| AUD-01 | **CERRADO** (con salvedad → AUD-11) | `simulated_robot_link.dart:32-33` `espStaleAfter = espCommandTimeout + 1 µs`. Mi test del borde, sin cambios: `comando con 300 ms EXACTOS de antigüedad: el ESP NO corta` ✔, `301 ms: el ESP SÍ corta` ✔, `299 ms: no corta` ✔ (todos verdes en `test/audit --concurrency=1`). Verificado con fake_async (resolución µs). En la VM real el µs se pierde: ver AUD-11. |
| AUD-02 | **CERRADO** | `stop_button.dart:33-35` `Listener(onPointerDown: (_) => controller.stop())` + `onPressed` + `Semantics.onTap`. Mis tests (nuevos a pedido del usuario, con mi doble de streams asíncronos) verdes: dedo que se desliza 25 dp (> kTouchSlop) y después SALE del botón (150 dp arriba) → STOP al apoyar (+1 envío inmediato) y solo STOP después; gesto CANCELADO → STOP ya salió y no se revierte; toque normal → EXACTAMENTE 2 envíos inmediatos, ambos STOP completos (state, dir, speed, cutter, trimmer = STOP,0,0,0,0) y nada distinto en el medio ni en el segundo siguiente; STOP mantenido 2 s → todo lo que sale es STOP. Prueba de mutación A y B: ver abajo. |
| AUD-03 | **CERRADO** | `hold_button.dart:47,56` `if (!mounted ...) return;`. Mi test `cambiar de pestaña con otro dedo mientras se mantiene adelante → dir 0` (rojo en la Ronda 1 por `setState() called after dispose()`) ahora verde. |
| AUD-04 | **CERRADO** | `esp_protocol.dart:181-238`. Mi test `decodeEspLine: valores fuera de rango ... se descartan` verde (incluye `{"t":"PERR","id":-1,"e":"FMT"}`). **Excepción PERR `e:"ID"`** (id fuera de 1–65535 aceptado si es int32): la evalué y es **correcta, no es un agujero**. (a) Es necesaria: el ESP responde a un id inválido con PERR que hace eco de ese id; sin la excepción la app descartaría el rechazo en silencio. Lo demuestra mi test A7 `inválidos → PERR con el id y el código` (ids 0, 65536, −1 con `ID`): verde y espera exactamente esos PERR. (b) Un PERR es un rechazo: aceptarlo nunca confirma nada ni cambia lo pedido; POK sigue estricto (id 0, −5, 70000 descartados). Residual menor: un PERR `ID` con id fuera de int32 se descarta (no representable en el firmware: irrelevante). |
| AUD-05 | **CERRADO** | Costura `BleTransport` + `BleRobotLink.withTransport` (`ble_robot_link.dart:85-119`). La usé con un transporte falso PROPIO (`test/audit/audit_ble_test.dart`, `AuditTransport`): camino conectado ejercitado (política de herramientas en los BYTES escritos, fragmentos ≤ 20 B con MTU 23, cola, reconexión). |
| AUD-06 | **CERRADO** para las 4 condiciones del usuario (pero ver AUD-12 y AUD-13, nuevos) | `enqueueCommand` (`:166-177`) y `sendCommand` (`:244-266`). Mis tests verdes: escritura retenida + MANUAL 2, 3, STOP 4, MANUAL 5, 6 → salen `[1, 4, 6]` (condiciones 2, 3, 4); STOP + 100 MANUAL posteriores → `[1, 2, 102]` (4); error de escritura en la actual → el STOP pendiente sale igual (1); **propiedad** con 2000 secuencias aleatorias (semilla 1311, retenciones y errores al azar): orden siempre creciente, el último comando siempre sale, y para cada STOP enviado lo primero que sale con seq ≥ al suyo es un STOP (ningún comando posterior lo adelanta). Caracterización: un STOP pendiente es reemplazado por un STOP más nuevo (sale solo el nuevo); es aceptable, ambos son STOP seguros y la orden de detener no se pierde. |
| AUD-07 | **CERRADO** | `robot_link.dart:80-86` documenta: BLE lanza `ArgumentError` sin enviar; el simulador emula al ESP y responde PERR. Coincide con el código: `ble_robot_link.dart:273-279` valida ANTES de mirar la conexión (lanza conectado o no) y no escribe; test del Agente 1 `sendPolygon inválido lanza ArgumentError y no escribe (ni conectado)` verde; simulador: mi A7 (PERR por cada inválido) verde. |
| AUD-08 | **CERRADO** | `README.md:14,17,21-25,27,31,78,89` → todo desde `R:\app_android`, explica `subst` y `.\gradlew.bat`. Las rutas con "é" que quedan (`:95, :135`) son de `Copy-Item`/`adb`, no de flutter. `D:\dev\env_flutter.ps1` monta R: (`subst R: 'd:\Moisés\Gramanova\robot_cortadora'`). |
| AUD-09 | **CERRADO** | `ble_robot_link.dart:56` `static const License license = License.nonprofit;` (decisión del usuario). Mi test `BleConfig.license == License.nonprofit; UUID null; connect() real lanza sin tocar la radio` verde. |
| AUD-10 | **CORREGIDO EN FUENTE — ABIERTO** hasta reverificar en la APK | Fuente: `uses-feature bluetooth`, `bluetooth_le` y `location` con `required="false"` (mi test estático `AUD-10: features ... required="false"` verde). La APK existente es VIEJA (`app-debug.apk` 21:41:14; manifest fuente modificado 22:00:23) y todavía dice `uses-feature: name='android.hardware.bluetooth'` / `uses-feature: name='android.hardware.location'` (aapt2 dump badging). Se cierra con `aapt2 dump badging` de la APK nueva. |

### Hallazgos nuevos (Ronda 2)

| ID | Archivo:línea | Qué está mal | Evidencia | Gravedad | Responsable | Estado |
|---|---|---|---|---|---|---|
| AUD-11 | `lib/core/simulated_robot_link.dart:32-33,192` | El "+1 µs" de `espStaleAfter` solo existe en fake_async. En la VM real `Timer` trunca a milisegundos, así que `Timer(300 ms + 1 µs)` = `Timer(300 ms)`: en el teléfono el simulador vuelve a cortar con 300 ms justos. Es imperceptible (jitter de timers ≫ 1 µs), pero el comentario "Con 300 ms justos todavía no corta" no es cierto fuera de los tests. | Fuente del SDK: `D:\dev\flutter\bin\cache\dart-sdk\lib\_internal\vm\lib\timer_patch.dart:15` `int milliseconds = duration.inMilliseconds;` (dentro de `_createTimer`). | BAJA | Agente 1 | ABIERTO |
| AUD-12 | `lib/core/ble_robot_link.dart:208-213, 227-234, 290-301` | Tras perder el enlace y reconectar, un comando pedido ANTES de la caída que esperaba en `_writeChain` (p. ej. detrás de un POLY retenido en la radio) se escribe por la conexión NUEVA: `_teardown` borra `_pendingCommands` pero no corta `_writeChain` ni la línea en curso, y `_writeLine` solo mira `_isUp`, que vuelve a ser true. El ESP recibe un MANUAL adelante viejo después de reconectar, cuando la app ya pidió STOP. | `flutter.bat test test/audit/audit_ble_test.dart` → `nada que se pidió ANTES de la caída sale por la conexión NUEVA [E]` / `el MANUAL adelante seq 7 es de ANTES de la caída y salió por la conexión nueva: [manual/forward/seq7, stop/none/seq8]`. | ALTA (STOP/seguridad) — latente: BLE no está cableado en esta APK | Agente 1 | ABIERTO |
| AUD-13 | `lib/core/ble_robot_link.dart:133, 248-265, 290-294` | Una escritura que quedó colgada en la conexión vieja bloquea TODOS los comandos de la conexión nueva (incluido el STOP) hasta que esa escritura termine: `_commandWriting` y `_writeChain` no se reinician en `_teardown`. En el test, el STOP de la conexión nueva sale recién a los 15 s (cuando la escritura vieja falla por timeout). La UI muestra "conectado · enviando" mientras tanto. | `flutter.bat test test/audit/audit_ble_test.dart` → `una escritura colgada de la conexión vieja no bloquea el STOP de la nueva (< 300 ms) [E]` / `Expected: a value less than 0:00:00.300000  Actual: 0:00:15.000000` / `el STOP de la conexión nueva salió recién a los 0:00:15.000000`. | ALTA (STOP) — latente | Agente 1 | ABIERTO |
| AUD-14 | `test/ui/app_widget_test.dart:176-180` | El test modificado del Agente 2 ("el botón STOP pide STOP de inmediato") exige el MÍNIMO correcto (`inInclusiveRange(1, 2)`: con 0 envíos falla, demostrado con el mutante B), pero de los envíos aceptados solo verifica `state == STOP`, no `dir`, `speed`, `cutter` ni `trimmer` como pidió el usuario. Mitigado: `test/ui/stop_and_hold_test.dart` (`expectAllStopFrom`) y mis tests R2 sí verifican los 5 campos. | Lectura: `expect(link.sent.skip(n).map((e) => e.state), everyElement(RobotState.stop));` es la única aserción sobre el contenido. | BAJA | Agente 2 | ABIERTO |

#### Correcciones que se piden

- **AUD-11**: guardar el instante de recepción (reloj inyectable, p. ej. `package:clock`) y decidir "fresco" con `edad <= espCommandTimeout` al consultar, en lugar de un `Timer` de µs; o corregir el comentario.
- **AUD-12 y AUD-13** (una sola corrección): un contador de generación de conexión. `_teardown` lo incrementa y reinicia `_commandWriting = false` y `_writeChain = Future.value()`. Cada escritura captura la generación al encolarse, y `_writeLine` y el bucle de `sendCommand` abortan si cambió. Así nada de la conexión vieja sale por la nueva, y una escritura colgada no bloquea la nueva. Si se quiere, también un timeout por escritura. Cierre: los dos tests de `audit_ble_test.dart` grupo "reconexión" en verde.
- **AUD-14**: en ese test, verificar los 5 campos de cada envío (p. ej. reusar `expectSafeStop`).

### Prueba de mutación (pedido explícito del usuario)

Protocolo: OK del coordinador ("OK MUTACIÓN", base `5f9b6ce`, `git diff` vacío, agentes quietos); copia de respaldo en `D:\dev\_mutacion\` (fuera del repo); un mutante por vez; restauración desde la copia.

**Antes**

```
Get-FileHash -Algorithm SHA256
34B20869C7BB89F0829639DBD74D0F00672F8F9A2AB7188B3E9AB5BB62D0E3B2  ...\app_android\lib\ui\widgets\stop_button.dart
ED58542889953AAF19F140FC4EDD4FCD0E01D20255F42707A2E07C0501A67D24  ...\app_android\lib\app\session_controller.dart
(copias D:\dev\_mutacion\stop_button.dart.orig y session_controller.dart.orig: mismos hashes)
git log --oneline -1 → 5f9b6ce feat(app): app E7 en modo simulado con correcciones de la ronda 1
git diff --stat → (vacío)
```

**Mutante A** — `stop_button.dart`: `onTap: () {}`, `onPointerDown: (_) {}`, `onPressed: () {}` (el botón no llama a `stop()` por ningún camino). `git diff --stat` → `app_android/lib/ui/widgets/stop_button.dart | 6 +++---`.

```
flutter.bat test test/ui/app_widget_test.dart --plain-name "el botón STOP pide STOP de inmediato"
Expected: RobotState:<RobotState.stop>
  Actual: RobotState:<RobotState.manual>
00:01 +0 -1: el botón STOP pide STOP de inmediato [E]
00:01 +0 -1: Some tests failed.

flutter.bat test test/audit/audit_ui_test.dart --name "STOP"
00:01 +1 -1: A5 UI: STOP STOP se dispara aunque el dedo se deslice al apretarlo (pánico) [E]          (Expected: stop  Actual: manual)
00:01 +1 -2: A5 UI: STOP STOP se envía al APOYAR el dedo, no al levantarlo [E]                        (Expected: stop  Actual: manual)
00:01 +1 -3: A5 UI: STOP R2 STOP: dedo que se desliza > 18 dp y SALE del botón → STOP al apoyar, y solo STOP después [E]   (Expected: stop  Actual: manual)
00:02 +1 -4: A5 UI: STOP R2 STOP: gesto CANCELADO por el sistema → el STOP ya salió y no se revierte [E]  (Expected: stop  Actual: manual)
00:02 +1 -5: A5 UI: STOP R2 STOP: toque normal → EXACTAMENTE 2 envíos inmediatos (apoyar + levantar), ... [E]   (Expected: <2>  Actual: <0>)
00:02 +1 -6: A5 UI: STOP R2 STOP: mantener el STOP apretado 2 s → todo lo que sale es STOP [E]
             (Expected: (stop, none, 0, 0, 0)  Actual: (manual, forward, 30, 0, 0))
00:03 +3 -6: Some tests failed.
```
Resultado: **mutante A detectado** por el test del Agente 2 y por los 6 tests de STOP del botón del auditor. (Los 3 verdes del filtro no usan el botón: alto ≥ 76 dp, ciclo de vida y `main.dart`.) Restaurado: `stop_button.dart = 34B20869...E3B2  coincide con base: True`, `git diff --stat` vacío.

**Mutante B** — `session_controller.dart` `stop()`: se eliminó solo `_sendCurrent();` (el estado sigue pasando a STOP, sin envío inmediato). `git diff --stat` → `app_android/lib/app/session_controller.dart | 2 +-`.

```
flutter.bat test test/ui/app_widget_test.dart --plain-name "el botón STOP pide STOP de inmediato"
Expected: be in range from 1 (inclusive) to 2 (inclusive)
  Actual: <0>
00:01 +0 -1: el botón STOP pide STOP de inmediato [E]
00:01 +0 -1: Some tests failed.
```
Esto prueba que el MÍNIMO aceptado por el test del Agente 2 es 1 y que con 0 envíos falla.

Primera corrida de mis tests contra B: detectaron el mutante 3 de ellos (`R2 ... dedo que se desliza ... SALE del botón` Expected <10> Actual <9>; `R2 ... EXACTAMENTE 2 envíos` Expected <2> Actual <0>; `ciclo de vida REAL ... paused → STOP` Expected > <10> Actual <10>). **Debilidad propia detectada:** dos tests míos cuyo nombre promete el envío ("STOP se **envía** al APOYAR..." de la Ronda 1 y "gesto CANCELADO ... el STOP **ya salió**") solo miraban el estado o los envíos del heartbeat, y no detectaron B. Los reforcé (exigen `+1` envío inmediato al apoyar) y los corrí otra vez CON el mutante B aplicado:

```
flutter.bat test test/audit/audit_ui_test.dart --name "STOP"     (mutante B, tests reforzados)
Expected: <9>   Actual: <8>
00:01 +2 -1: A5 UI: STOP STOP se envía al APOYAR el dedo, no al levantarlo [E]
Expected: <10>  Actual: <9>
00:01 +2 -2: A5 UI: STOP R2 STOP: dedo que se desliza > 18 dp y SALE del botón → STOP al apoyar, y solo STOP después [E]
Expected: <10>  Actual: <9>
00:02 +2 -3: A5 UI: STOP R2 STOP: gesto CANCELADO por el sistema → el STOP ya salió y no se revierte [E]
Expected: <2>   Actual: <0>
00:02 +2 -4: A5 UI: STOP R2 STOP: toque normal → EXACTAMENTE 2 envíos inmediatos ... [E]
Expected: a value greater than <10>  Actual: <10>
00:02 +3 -5: A5 UI: STOP ciclo de vida REAL (binding → SessionLifecycleObserver): paused → STOP [E]
00:03 +4 -5: Some tests failed.
```
Resultado: **mutante B detectado** por el test del Agente 2 y por 5 tests del auditor. Los que siguen verdes con B ("pánico" con deslizamiento de 40 dp, "mantener 2 s") verifican otras propiedades (estado / contenido de los envíos), no el envío inmediato, que cubren los demás. Ningún mutante sobrevivió a los tests de STOP: **no hay hallazgo por la regla (e)**.

**Después (criterio de cierre del coordinador)**

```
stop_button.dart        = 34B20869C7BB89F0829639DBD74D0F00672F8F9A2AB7188B3E9AB5BB62D0E3B2  igual_base=True
session_controller.dart = ED58542889953AAF19F140FC4EDD4FCD0E01D20255F42707A2E07C0501A67D24  igual_base=True
--- git diff -- app_android/lib app_android/test (inicio) ---
warning: in the working copy of 'app_android/lib/app/session_controller.dart', LF will be replaced by CRLF the next time Git touches it
--- (fin: vacío) ---
git status --short →  ?? app_android/AUDITORIA.md
                      ?? app_android/test/audit/
```
(El `warning` de fin de línea es de git, no una diferencia: el diff está vacío.) Con el código restaurado:

```
flutter.bat test test/ui/app_widget_test.dart --plain-name "el botón STOP pide STOP de inmediato"  → 00:01 +1: All tests passed!
flutter.bat test test/audit/audit_ui_test.dart --name "STOP"                                       → 00:02 +9: All tests passed!
```

### Cambios en mis tests en esta ronda (y por qué)

- `audit_static_test.dart`: el test de BLE exigía `License? license = null`. El usuario DECIDIÓ `License.nonprofit` (AUD-09): no es un dato inventado. Ahora exige exactamente `static const License license = License.nonprofit;`, que no aparezca `License.commercial`, que los 3 UUID sigan `null` (PENDIENTE) y que `isConfigured` dependa de los 3 UUID. Además, `audit_ble_test.dart` comprueba en ejecución que `BleRobotLink(off).connect()` real sigue lanzando `BleLinkException` sin tocar la radio. Agregué la verificación de AUD-10 (features `required="false"`).
- `audit_heartbeat_load_test.dart`: falló en corridas en paralelo por contención de CPU (no se cumplía la precondición de carga). No se debilitó: ahora hay **tres veredictos distintos**. (1) "MEDICIÓN INVÁLIDA — no se generó la carga" (< 80 % de ocupación). (2) "MEDICIÓN INVÁLIDA — el entorno retrasó también al timer testigo" (un `Timer.periodic` de 100 ms independiente del controlador tuvo un hueco ≥ 200 ms). (3) Solo si la medición es válida se juzga el heartbeat: hueco < 200 ms, medio 95–110 ms y no peor que el testigo + 20 ms. **Cómo se corre:** `flutter.bat test test/audit/audit_heartbeat_load_test.dart --concurrency=1` (o la suite con `--concurrency=1`). Resultado: carga 86–88 %, heartbeat medio 99,5 ms y máx. 107 ms, igual que el testigo (máx. 107 ms). Qué demuestra y qué no: igual que en la Ronda 1 (ver arriba). Además ahora prueba que el heartbeat no es peor que un timer cualquiera del mismo isolate.
- `audit_ui_test.dart`: 4 tests nuevos de STOP pedidos por el usuario (deslizar fuera del botón, gesto cancelado, exactamente 2 envíos STOP completos, mantener 2 s) y el refuerzo de 2 tests por la prueba de mutación (ver arriba).
- `audit_ble_test.dart` (nuevo): transporte falso propio; condiciones del usuario de la cola (AUD-06), propiedad con 2000 secuencias aleatorias, camino conectado (AUD-05), reconexión (AUD-12, AUD-13), licencia (AUD-09).

### Pendiente para la ronda de la APK final (pedido del usuario)

- Verificar en la APK COMPILADA: label = "Gramanova"; icono adaptativo con fondo, figura y monocromático en `mipmap-anydpi-v26`; permisos y features correctos (cierre de AUD-10); `flutterBluePlusLicensePing*` SKIPPED (también en release, si la hay). Cambio de nombre/icono: responsable Agente 3. **No se verificó todavía:** al cierre de esta ronda `git status` no muestra cambios en `android/`, y la APK es la de las 21:41.
- Heartbeat medido en el Galaxy M12 real.

---

## Ronda 3 — 13/11/26

Cada cierre se verificó con corridas propias. Los cambios en `android/` y `assets/` son del Agente 3 (nombre/icono) y quedan para la ronda de la APK.

### Corridas literales (desde `R:\app_android`)

```
R:\app_android> flutter.bat analyze
Analyzing app_android...
No issues found! (ran in 3.4s)

R:\app_android> flutter.bat test test/core
00:00 +100: All tests passed!                      (+100 / −0 / ~0)

R:\app_android> flutter.bat test test/app test/ui test/widget_test.dart
00:05 +49: All tests passed!                       (+49 / −0 / ~0)

R:\app_android> flutter.bat test test/audit --concurrency=1
R3 cierre tras caída (syncLost=false): eventos=[open#1, close]
R3 cierre tras caída (syncLost=true): eventos=[open#1, close]
R3 reconexión desde el aviso: estado=connected eventos=[open#1, open#2, close] escucha linkLost=true
00:01 +5 -1: .../audit_ble_r3_test.dart: CARRERA: reconexión desde el aviso de "desconectado" (streams asíncronos, async real) → la conexión nueva queda abierta y una caída posterior SE DETECTA [E]
R3 carrera forzada: estado=connected eventos=[open#1, open#2, close] escucha linkLost=true
00:01 +5 -2: .../audit_ble_r3_test.dart: CARRERA forzada: connect() mientras _teardown() de la caída sigue en sus await (intercalado garantizado, async real) → la conexión nueva queda sana [E]
A2 con carga + press/release: heartbeat envíos=260 medio=14.8ms máx=20ms | testigo envíos=39 medio=99.7ms máx=108ms | carga 88 % (tareas=442)
A2 solo heartbeat con carga: heartbeat envíos=39 medio=99.5ms máx=107ms | testigo envíos=39 medio=99.5ms máx=107ms | carga 89 % (tareas=447)
A2 bloqueo 400 ms: envíos=10 medio=132.8ms máx=449ms gaps=[99, 100, 99, 100, 449, 49, 99, 100, 100]
R3 borde reloj real: consultas vigentes=99 cortadas=111
R3 timer de respaldo: disparos medidos en µs (cota inferior de la edad real) mín=301165 máx=304015
00:33 +94 -2: Some tests failed.

R:\app_android> flutter.bat test --concurrency=1
00:02 +34 -1: .../audit_ble_r3_test.dart: CARRERA: reconexión desde el aviso de "desconectado" ... [E]
00:02 +34 -2: .../audit_ble_r3_test.dart: CARRERA forzada: connect() mientras _teardown() ... [E]
00:48 +243 -2: Some tests failed.
```

245 tests = 100 (Agente 1) + 49 (Agente 2) + 96 (auditor: 81 de antes + 15 nuevos de esta ronda). El "230/230" del Agente 1 corresponde a 100 + 49 + 81, sin mis tests nuevos de esta ronda: coincide. Los 2 rojos son el hallazgo NUEVO AUD-15.

### Estado de los hallazgos

| ID | Estado | Evidencia |
|---|---|---|
| AUD-12 | **CERRADO** | `ble_robot_link.dart`: generación de conexión (`_generation`; `_teardown` la sube antes de cualquier `await`; `_writeLine(line, gen)` aborta si cambió). Mi test de la Ronda 2 `nada que se pidió ANTES de la caída sale por la conexión NUEVA` pasa **sin haber sido tocado**: `audit_ble_test.dart` sigue con SHA-256 `ECA82B4D5254732E2719BC2313D2E44AE1AFB902D9D909A9E7F08CB393C220F5` y fecha 22:13:15 (cuando lo escribí), y su aserción (`c.seq == 7), isEmpty`, línea 316) está intacta. |
| AUD-13 | **CERRADO** | Mismo archivo sin tocar: `una escritura colgada de la conexión vieja no bloquea el STOP de la nueva (< 300 ms)` (aserción `lessThan(300 ms)`, línea 346) pasa. Además, en `audit_ble_r3_test.dart`: tres caídas seguidas con escrituras colgadas → en cada conexión nueva el STOP sale en < 300 ms y nada de las viejas; cuando las escrituras viejas terminan tarde (con error), no sale nada por la vigente. |
| AUD-06 (dentro de cada conexión) | **sigue valiendo** | `audit_ble_r3_test.dart`, propiedad multi-conexión (1500 secuencias, semilla 2611, con caídas, reconexiones, retenciones y errores): (1) por la conexión k sale SOLO lo pedido durante la conexión k; (2) orden creciente; (3) ningún STOP adelantado por un comando posterior; (4) en la conexión vigente sale lo último pedido. Verde. Caída en medio del `await` del bucle: el bucle viejo no toca la cola nueva ni libera el "escribiendo" de la nueva (el STOP pendiente de la nueva sale en orden `[2, 3]`). POLY cortado por la caída → `sendPolygon` falla con `BleLinkException` (no da por enviado algo que no salió). |
| AUD-11 | **CERRADO** (con observación → AUD-16) | `simulated_robot_link.dart`: la antigüedad se mide al consultar con `monotonicClock` (por defecto un `Stopwatch` real, en µs) y el comando vale si `edad ≤ 300 ms`. Probado con **reloj real** (sin fake_async; la VM real trunca los timers a ms): (a) con un reloj real inyectado que registra cada lectura, en 210 consultas entre 299,5 y 300,5 ms de antigüedad (10 rep. × 21), **cada** resultado cumple `corta ⇔ edad_leída > 300 ms` (99 vigentes, 111 cortadas); (b) con el reloj POR DEFECTO, 20 rep.: a 298 ms no corta, a 302 ms sí; (c) sin espera activa: a ~250 ms vigente, a ~320 ms cortado. **Timer de respaldo (301 ms):** solo puede marcar "cortado"; nunca extiende la vigencia (la regla por reloj corta igual a los > 300 ms). ¿Puede cortar antes de tiempo? 30 timers de `espStaleTimerDelay`, creados en fases sub-ms distintas y con el cronómetro arrancado DESPUÉS de crearlos (cota inferior de la edad real): disparos entre 301 165 y 304 015 µs, todos > 300 000 µs. Con fake_async y reloj inyectado (`async.elapsed`): 300 ms vale, 300 ms + 1 µs corta. **Borde en el teléfono:** 300 vale / > 300 corta, decidido por el Stopwatch (µs), sin depender de la resolución de los timers. |
| AUD-14 | **CERRADO** | `test/ui/app_widget_test.dart:163-200`: antes del STOP deja MANUAL/adelante/70 %/cortadora 1/bordeadora 1 con herramientas habilitadas (y lo verifica), y comprueba los 5 campos de cada envío. **Mutante C** (protocolo: copia + hash + restaurar): `outgoingSpeed => _speed` (STOP no pone speed en 0) → el test FALLA: `Expected: <0>  Actual: <70>` / `speed de ControlCommand(state: stop, dir: none, speed: 70, cutter: 0, trimmer: 0, seq: 9)`. Hash antes `ED58542889953AAF19F140FC4EDD4FCD0E01D20255F42707A2E07C0501A67D24` (= base); restaurado, el mismo hash (`igual_base=True`); `git diff -- app_android/lib/app` vacío; el test vuelve a pasar (`00:01 +1: All tests passed!`). |
| AUD-10 | ABIERTO (espera la APK nueva) | Sin cambios respecto de la Ronda 2. |
| Nombre "Gramanova" | **verificado** | `labels.dart:8` `appTitle = 'Gramanova'`; `home_shell.dart:71` (AppBar) y `app.dart:16` (`MaterialApp.title`) usan `Labels.appTitle`. Mi test: `MaterialApp.title == 'Gramanova'`, el AppBar muestra "Gramanova" y "Robot Cortadora E7" no aparece (verde). Ningún test depende del nombre viejo (`grep "Robot Cortadora E7"` en `lib/` y `test/`: sin resultados; `widget_test.dart:19` usa `Labels.appTitle`). Comentario de `main.dart:1` actualizado (Agente 2). |

### Hallazgos nuevos (Ronda 3)

| ID | Archivo:línea | Qué está mal | Evidencia | Gravedad | Responsable | Estado |
|---|---|---|---|---|---|---|
| AUD-15 | `lib/core/ble_robot_link.dart:214-219` (`_onLinkLost`), `:233-244` (`_teardown`), `:187-212` (`connect`) | **Carrera de reconexión.** `_onLinkLost` hace `unawaited(_teardown().then((_) => _transport.close()))`. Si se llama `connect()` mientras ese teardown sigue en sus `await` (p. ej. un "reconectar solo" que reaccione al aviso de "desconectado", la forma natural de implementarlo), el `close()` viejo corre DESPUÉS del `open()` nuevo y **cierra el transporte de la conexión nueva**, mientras `status` queda en `connected`. En el transporte real, `close()` cancela la escucha de `connectionState` antes de desconectar: no llegaría ningún aviso de caída, y la app quedaría mostrando "conectado · enviando" mientras todos los comandos, STOP incluido, fallan en silencio (los errores de escritura solo se registran). Además, `_teardown` pone `_rxSub = null` y cancela `_lostSub` DESPUÉS de sus `await`, así que puede pisar las suscripciones que el `connect()` nuevo acaba de crear. Hoy no afecta a la APK (BLE no está cableado; la reconexión es manual, a escala de frames). | `flutter.bat test test/audit --concurrency=1` → `CARRERA: reconexión desde el aviso de "desconectado" (streams asíncronos, async real) ... [E]` y `CARRERA forzada ... [E]`, ambos con `el transporte de la conexión 2 se cerró después de abrirse: [open#1, open#2, close]` y `estado=connected`. Control: `reconexión "humana"` (después de que termina el teardown, 5 ciclos) verde. | ALTA (STOP/heartbeat) — latente | Agente 1 | ABIERTO |
| AUD-16 | `lib/core/simulated_robot_link.dart:36` (`espStaleTimerDelay`) y su timer en `_espReceiveCommandLine` | El timer de respaldo existe en producción solo por una limitación de los tests (con fake_async el `Stopwatch` por defecto no avanza). Está probado que es **inocuo**: nunca corta con ≤ 300 ms (disparos ≥ 301,165 ms medidos) y no extiende la vigencia. Efecto documentado: con fake_async SIN reloj inyectado, a 300,5 ms el comando sigue "vigente" y corta recién el timer, a los 301 ms (mi test de caracterización). Es código de producción cuya razón de ser es un test. | `audit_r3_misc_test.dart`: `(caracterización) con fake_async y SIN reloj inyectado: a 300,5 ms ... sigue "vigente"` (verde: lo documenta) y `con fake_async y reloj INYECTADO: 300 ms vale, 300 ms + 1 µs corta` (verde: la alternativa funciona). | BAJA | Agente 1 | ABIERTO (sugerencia) |

#### Correcciones que se piden

- **AUD-15**: que el teardown de una conexión no pueda tocar la siguiente. Por ejemplo: (a) en `_teardown`, tomar `_rxSub`/`_lostSub` en variables locales y anularlas **antes** del primer `await`; y (b) guardar el Future del cierre (`_closing = _teardown().then(... close ...)`) y que `connect()` lo espere antes del `open()`, o cerrar solo si la generación no cambió (`if (gen == _generation) close()`). Cierre: los dos tests `CARRERA` de `audit_ble_r3_test.dart` en verde (async real).
- **AUD-16** (opcional): que los tests del simulador inyecten `monotonicClock: () => async.elapsed` y quitar el timer de respaldo; o dejarlo documentado como está (es inocuo). Lo decide el coordinador.

### Observación importante sobre los tests con fake_async (vale para todos)

`StreamSubscription.cancel()` devuelve un Future **ya completado de la zona raíz** (`Future._nullFuture`). Con fake_async, la continuación de `await sub.cancel()` va a la cola de microtareas REAL, que no corre durante el test, así que `_teardown()` queda **congelado después de su primer `await`**. Evidencia: el mismo test "tras una caída el transporte se cierra" da `eventos=[open#1]` con fake_async y `eventos=[open#1, close]` con async real. Consecuencias: (1) la parte síncrona del teardown (generación, cola, `_commandWriting`, `_writeChain`) SÍ queda probada con fake_async, así que AUD-12/13 se cierran con evidencia válida; (2) la segunda mitad (cancelar suscripciones, cerrar el transporte) **no** la ejercita ningún test con fake_async, ni del Agente 1 ni de la Ronda 2 del auditor. Por eso AUD-15 no apareció antes. Los tests de teardown y reconexión tienen que correr con async real (`pumpEventQueue`).

### Regla del usuario ("frenar si un hallazgo de seguridad reaparece después de dos rondas")

Ningún hallazgo de seguridad **reapareció**: AUD-02, 06, 12 y 13 están cerrados con evidencia y sus tests siguen verdes. Pero lo digo explícitamente: AUD-15 es el **tercer hallazgo ALTA seguido en la misma zona**, el manejo de conexión y escritura del enlace BLE (AUD-06 en la Ronda 1, AUD-12/13 en la Ronda 2, AUD-15 en la Ronda 3). No es el mismo defecto, pero el patrón se repite. Los tres son latentes: BLE no está cableado en esta APK, que usa el robot simulado. Lo dejo a decisión del coordinador y del usuario.

### Mis tests en esta ronda

- `audit_ble_test.dart` (Ronda 2): **sin tocar** (hash arriba). Queda como regresión de AUD-12/13.
- `audit_ble_r3_test.dart` (nuevo, 8 tests): propiedad multi-conexión; caídas seguidas con escrituras colgadas; caída en medio del `await` del bucle; POLY cortado; y, con async real, cierre del transporte tras la caída, las dos carreras y la reconexión "humana". Durante el desarrollo corregí dos errores míos: un `onError` de `Future.then` que devolvía un valor, y el pase de los tests de carrera de fake_async a async real (motivo arriba).
- `audit_r3_misc_test.dart` (nuevo, 7 tests): AUD-11 con reloj real (regla exacta, reloj por defecto, sin espera activa, timer de respaldo), dos caracterizaciones con fake_async y el nombre "Gramanova". Error mío corregido: la primera versión consultaba con mi cronómetro en 299,0 ms, sin calentamiento, y esa primera consulta pagaba la compilación JIT antes de que el simulador leyera su reloj (falso "cortó con ≤ 300 ms"). Ahora la aserción usa el valor que el código realmente leyó.
- Mutación (AUD-14): copia `D:\dev\_mutacion\session_controller.dart.r3.orig`; hash igual a la base antes y después; `git diff -- app_android/lib/app` vacío.

---

## CHECKPOINT — 14/11/26 (escrito por el coordinador)

> El usuario pidió el 13/11 a las ~22:45 un punto seguro por límite de uso. El árbol se verificó a las **22:46 del 13/11**, pero el CHECKPOINT y el commit no llegaron a hacerse antes del corte. Se escriben ahora, al retomar. Entre la verificación y este momento **no se modificó ningún archivo** de `lib/`, `test/`, `android/` ni `assets/` (comprobado por fecha de modificación).

### Estado verificado (coordinador, 13/11 22:46, desde `R:\app_android`)
- `flutter.bat analyze` → `No issues found! (ran in 3.3s)`
- `flutter.bat test --concurrency=1` → `00:48 +245: All tests passed!`
- Hashes de las bases de mutación (SHA-256), idénticos a la base del commit `5f9b6ce`:
  - `lib/ui/widgets/stop_button.dart` = `34B20869C7BB89F0829639DBD74D0F00672F8F9A2AB7188B3E9AB5BB62D0E3B2`
  - `lib/app/session_controller.dart` = `ED58542889953AAF19F140FC4EDD4FCD0E01D20255F42707A2E07C0501A67D24`
- Último commit antes del CHECKPOINT: `5f9b6ce` (rama `feature/app-android-e7`, sin push). El commit de este CHECKPOINT va a continuación.

### Cerrado y verificado con evidencia del auditor
AUD-01, 02, 03, 04, 05, 06, 07, 08, 09 (rondas 1–2); AUD-11, 12, 13, 14 (ronda 3). AUD-16 aceptado por el coordinador (timer de respaldo de 301 ms inocuo, verificado por el auditor). Mutantes A y B (STOP) y mutante de AUD-14: todos detectados; archivos restaurados con hash idéntico.

### Abierto
1. **AUD-15 (ALTA, latente):** el Agente 1 lo corrigió antes de la pausa (`ble_robot_link.dart`: una sola cola para `open()`/`close()`, generación al conectar, `_closeGeneration` que suelta suscripciones antes de cualquier `await`). Los dos tests `CARRERA` pasan y la suite completa da 245/245, **pero el auditor todavía no lo verificó**: se cierra en la ronda 4.
2. **Barrido del ciclo de vida de la conexión BLE (Agente 1):** tabla combinación → invariante → test con async real (connect/connect, disconnect durante connect, pérdida durante el cierre, dispose durante connect, doble pérdida, envíos en vuelo). **No empezado.**
3. **AUD-10 (BAJA):** features `bluetooth`/`location` opcionales; se verifica en la APK nueva.
4. **APK final:** compilar la debug de 64 bits (`--target-platform android-arm64`; el M12 reporta `arm64-v8a,armeabi-v7a,armeabi`). El auditor la verifica: label "Gramanova", icono adaptativo v3 (fondo, figura y monocromo), permisos y AUD-10. Recién después se instala en el M12.

### Estado de cada agente
- **Agente 1 (core):** quieto. Terminó AUD-15; no empezó el barrido.
- **Agente 2 (UI):** quieto. Terminó AUD-14 y el comentario de `main.dart`.
- **Agente 3 (entorno/APK):** quieto. Icono v3 aprobado por la usuaria y copiado a `res/` por el coordinador (21 archivos con hash idéntico al generador). No compiló.
- **Agente 4 (auditor):** quieto. Terminó la ronda 3.

### Orden de lo que sigue
1. Agente 1: barrido del ciclo de conexión (tabla + tests con async real).
2. Ronda 4 del auditor: AUD-15 + barrido, con corrida propia.
3. Si queda en verde: commit, APK debug arm64, verificación del auditor sobre la APK (nombre, icono, permisos, AUD-10).
4. Instalación en el M12 (`adb install -r`) y lista de pruebas manuales para la usuaria.

---

## Ronda 4 — 14/11/26

Base: commit `3874f7a` + cambios sin commitear del Agente 1 (`lib/core/ble_robot_link.dart`, `test/core/ble_robot_link_test.dart`, nuevo `test/core/ble_lifecycle_test.dart`). Todo verificado con corrida propia.

### 1. Mis tests no fueron tocados

```
git diff --stat 3874f7a -- app_android/test/audit app_android/AUDITORIA.md   → (vacío)
git status --short → solo  M lib/core/ble_robot_link.dart,  M test/core/ble_robot_link_test.dart,  ?? test/core/ble_lifecycle_test.dart
```
Los hashes coinciden con los registrados en las rondas 2 y 3 (prefijos SHA-256): `audit_ble_test.dart` ECA82B4D…, `audit_heartbeat_load_test.dart` 6A8422C9…, `audit_heartbeat_test.dart` B6833ED1…, `audit_helpers.dart` 1434E5EB…, `audit_protocol_test.dart` 8519FB13…, `audit_safety_test.dart` 9ED80665…, `audit_static_test.dart` 1D8C4A65…, `audit_ui_test.dart` 521C518C…. Las aserciones clave de `audit_ble_r3_test.dart` (líneas 314, 316, 335, 344, 346) y de `audit_r3_misc_test.dart` (82, 140) están intactas.

### Corridas literales (desde `R:\app_android`)

```
R:\app_android> flutter.bat analyze
Analyzing app_android...
No issues found! (ran in 3.2s)

R:\app_android> flutter.bat test test/core
00:01 +120: All tests passed!                       (+120 / −0 / ~0)

R:\app_android> flutter.bat test test/app test/ui test/widget_test.dart
00:04 +49: All tests passed!

R:\app_android> flutter.bat test test/audit --concurrency=1
R3 cierre tras caída (syncLost=false): eventos=[open#1, close]
R3 cierre tras caída (syncLost=true): eventos=[open#1, close]
R3 reconexión desde el aviso: estado=connected eventos=[open#1, close, open#2] escucha linkLost=true
R3 carrera forzada: estado=connected eventos=[open#1, close, open#2] escucha linkLost=true
A2 con carga + press/release: heartbeat envíos=262 medio=14.6ms máx=20ms | testigo envíos=39 medio=99.3ms máx=107ms | carga 89 % (tareas=446)
A2 solo heartbeat con carga: heartbeat envíos=39 medio=99.3ms máx=107ms | testigo envíos=39 medio=99.3ms máx=107ms | carga 90 % (tareas=450)
A2 bloqueo 400 ms: envíos=10 medio=133.1ms máx=450ms gaps=[100, 99, 100, 101, 450, 48, 100, 101, 99]
R3 borde reloj real: consultas vigentes=100 cortadas=110
R3 timer de respaldo: disparos medidos en µs (cota inferior de la edad real) mín=301237 máx=303147
R4 primer comando: stop a 108 ms del open()
R4 caracterización 2: primer comando con MANUAL+adelante+cortadora pedidos en < 100 ms = ControlCommand(state: manual, dir: forward, speed: 30, cutter: 1, trimmer: 0, seq: 0)
R4 caracterización: primer comando con MANUAL pedido enseguida = ControlCommand(state: manual, dir: none, speed: 30, cutter: 0, trimmer: 0, seq: 0)
00:37 +101: All tests passed!

R:\app_android> flutter.bat test --concurrency=1
00:54 +270: All tests passed!
```

270 = 120 (Agente 1) + 49 (Agente 2) + 101 (auditor: 96 de antes + 5 nuevos de esta ronda). El "265/265" del Agente 1 es 120 + 49 + 96, sin mis 5 nuevos: coincide.

### Estado de los hallazgos

| ID | Estado | Evidencia |
|---|---|---|
| AUD-15 | **CERRADO** | Mis dos tests `CARRERA` (async real, sin tocar desde la Ronda 3) en verde. El orden de eventos ahora es `[open#1, close, open#2]` (antes `[open#1, open#2, close]`): el `close()` viejo termina ANTES del `open()` nuevo, y la conexión nueva queda escuchando `linkLost` y detecta su propia caída. Mecanismo revisado en el código: `_serialTransportOp` (una sola cola para open/close), generación que sube al conectar y al cerrar, y `_closeGeneration` que suelta las suscripciones y pasa a `disconnected` de forma síncrona, antes de cualquier `await`. |
| AUD-06 (4 condiciones) | **sigue en verde** | `audit_ble_test.dart` (condiciones 1–4, propiedad con 2000 secuencias) y la propiedad multi-conexión de `audit_ble_r3_test.dart` (1500 secuencias): verdes. |
| AUD-12 / AUD-13 | **siguen en verde** | Mismos tests de la Ronda 2 sin tocar, más los de la Ronda 3: verdes. |
| AUD-10 | ABIERTO (espera la APK nueva) | Sin cambios. |
| AUD-16 | Aceptado por el coordinador (CHECKPOINT) | Mis tests de reloj real siguen verdes (timer de respaldo ≥ 301,237 ms). |

### Barrido del ciclo de vida (C1–C20, `test/core/ble_lifecycle_test.dart`)

Leí los 20 tests y el transporte falso. **Son reales:** async real (`pumpEventQueue`, sin fake_async); un transporte que cumple el contrato (`close()` cancela un `open()` en curso, compuertas para colgar `open`/`close`/escrituras, caída síncrona o asíncrona) y registra violaciones (open con un close en curso, write con el transporte cerrado); `expectConsistent` verifica I1 (connected ⇒ abierto, disconnected ⇒ cerrado), I6 (escuchas 1/1 o 0/0), "nunca queda en connecting en reposo" y la lista de violaciones; `expectStopFast` verifica I4 (STOP < 300 ms). Cada combinación arma de verdad su escenario (C3 cuelga el close y conecta encima; C6 desconecta durante el open y reconecta; C9 doble pérdida con close colgado; C11 30 reconexiones inmediatas, desde el aviso y directas; C14/C15 escrituras colgadas; C16 llamadas después de dispose; C19 open que falla; C20 50 ciclos).

**Prueba de mutación** (protocolo: copia en `D:\dev\_mutacion\ble_robot_link.dart.r4.orig`, hash, restaurar; como el archivo tiene cambios del Agente 1 sin commitear, el criterio fue "hash idéntico al de antes de mutar" y "`git diff -- app_android/lib` idéntico al de antes de mutar").

```
antes: ble_robot_link.dart = A9D09D04AE5C4118923507011A45EFEC7FFC6450E367F990C83389B628446A42
       git diff -- app_android/lib → 71 líneas, sha 37E24A3F74DA6A81CB5BECCDE2B7158AB375BBE04C01BEB484F7E21B09362720
```

- **Mutante D** (revierte D1: `if (inFlight != null) return inFlight;`):
  ```
  C6 disconnect durante open() y connect() inmediato: el nuevo SÍ conecta [E]
    Expected: LinkStatus:<LinkStatus.connected>
      Actual: LinkStatus:<LinkStatus.disconnected>
    el connect() nuevo no puede devolver el intento cancelado [open#1, close, open#1 cancelado, close]
  00:05 +38 -1: Some tests failed.
  ```
  **Detectado por C6.** Restaurado: hash `A9D09D04…6A42 igual=True`.
- **Mutante E** (revierte D2: `await _transport.write(chunk);` sin competir contra "conexión cerrada"):
  ```
  C14 dispose con escrituras COLGADAS: sendCommand completa y sendPolygon falla en seguida [E]
    Expected: 'ok'   Actual: 'colgado'   sendCommand quedó esperando a la radio
  C15 disconnect con escritura colgada: los Futures completan y la reconexión manda STOP en < 300 ms [E]
    Expected: <Instance of 'BleLinkException'>   Actual: 'colgado'
  00:06 +37 -2: Some tests failed.
  ```
  **Detectado por C14 y C15.**

```
después: ble_robot_link.dart = A9D09D04AE5C4118923507011A45EFEC7FFC6450E367F990C83389B628446A42  igual_antes=True
         git diff -- app_android/lib → sha 37E24A3F74DA6A81CB5BECCDE2B7158AB375BBE04C01BEB484F7E21B09362720  igual_antes=True
         fc lib_diff_r4_antes.txt lib_diff_r4_despues.txt → "FC: no se han encontrado diferencias"
```
Con el código restaurado, la suite completa da `+270: All tests passed!` (arriba).

### Test del Agente 1 modificado (POLY sin confirmar cuando cae el enlace → error)

`test/core/ble_robot_link_test.dart:474-490`: antes exigía que el POLY "completara"; ahora exige `BleLinkException`. **Es correcto y no esconde nada.** La escritura estaba en la radio SIN confirmar cuando se cayó el enlace: no se sabe si llegó al ESP, y decir "completó" afirmaba algo que no se sabe. La verdad del área la da solo el POK del ESP. Además, el mismo test sigue exigiendo lo importante: nada de antes de la caída sale por la conexión nueva (`expect(t.commands(2).map((c) => c.seq), [8])`). Con D2, un error tardío de la radio se ignora sin dejar errores sin manejar (C14 completa las escrituras colgadas con error y no hay excepciones).

### Limitación declarada: lo pedido durante `connecting` no se transmite

Evaluado contra el `SessionController` real del Agente 2 sobre `BleRobotLink`, con async y reloj reales (`test/audit/audit_r4_first_command_test.dart`, nuevo):
- Primera conexión sin tocar nada: lo primero que sale es **STOP completo**, a 108 ms del `open()` (primer tick del heartbeat).
- 5 caídas con MANUAL + adelante + 90 % + cortadora + bordeadora pedidos: en cada conexión nueva lo primero que sale es **STOP completo**. Nada se arrastra (el controlador vuelve a STOP al perder y al recuperar el enlace).
- Durante `connecting`, el controlador ignora los pedidos y el enlace no escribe nada (`writes` vacío); al conectar, el primer comando es STOP.
- **¿Puede salir algo distinto de STOP como primer comando?** Sí, pero SOLO si el usuario lo pide explícitamente antes del primer tick (100 ms después de conectar): pedir MANUAL + cortadora + mantener adelante en ese lapso hace salir `manual/forward/cutter 1` primero (caracterización). Hacerlo a mano requiere al menos 3 gestos (y un cambio de pestaña) en 100 ms; no es un arrastre, es el pedido del usuario. **No lo registro como hallazgo.** Sugerencia opcional para el Agente 2: enviar un STOP inmediato al pasar a `connected`, así el primer comando es STOP siempre.

### Hallazgos nuevos

Ninguno. **Ningún hallazgo de seguridad reapareció** (STOP, heartbeat y herramientas, con todos sus tests en verde: 270/270).

### Mis tests en esta ronda
- `audit_r4_first_command_test.dart` (nuevo, 5 tests, async y reloj reales). Error mío corregido: la primera versión pedía MANUAL + adelante a los 30 ms de conectar, antes del primer tick, y medía su propio pedido en lugar de un arrastre. Ahora pide a los 150 ms, y el caso "antes del primer tick" quedó como caracterización aparte.
- Ninguno de mis tests anteriores fue modificado.

### Resultado de la ronda
**EN VERDE.** El único hallazgo abierto es AUD-10 (BAJA), que espera la APK nueva. Sigue lo que pide el CHECKPOINT: commit, APK debug arm64 y verificación del auditor sobre la APK (label "Gramanova", icono adaptativo v3 con fondo, figura y monocromo en `mipmap-anydpi-v26`, permisos y AUD-10).
