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

---

## Ronda APK — 14/11/26

APK: `d:\Moisés\Gramanova\entregas\gramanova_debug_arm64_2026-11-14.apk`, compilada por el coordinador desde el commit `a79daae`. Solo lectura: sin recompilar, sin instalar, sin tocar `lib/`. Herramientas de `D:\dev\android-sdk\build-tools\36.0.0`, sobre la ruta `R:` (la "é" rompe `aapt2`). `git status --short` vacío antes y después.

### 1. Integridad

```
entrega: B3F359E4F9C50345FE5998A76A766704B949BC48FF59104157B8BACB1CF96220   78272661 B  14/11/2026 03:11:18
build:   B3F359E4F9C50345FE5998A76A766704B949BC48FF59104157B8BACB1CF96220   78272661 B  14/11/2026 03:11:18
.sha256: B3F359E4F9C50345FE5998A76A766704B949BC48FF59104157B8BACB1CF96220  gramanova_debug_arm64_2026-11-14.apk
```
Los tres coinciden. En `build\app\outputs\flutter-apk\` solo está esa APK (y su `.sha1`).

### 2. Firma

```
apksigner verify --verbose --print-certs app-debug.apk
Verifies
Verified using v1 scheme (JAR signing): false
Verified using v2 scheme (APK Signature Scheme v2): true
Verified using v3 scheme (APK Signature Scheme v3): false
Number of signers: 1
Signer #1 certificate DN: C=US, O=Android, CN=Android Debug
Signer #1 certificate SHA-256 digest: 0ec5d71f924541c62b9247d09051a4e4948e8e76d002762c762150d122eec988
```
Esquema v2 (suficiente con minSdk 24; el M12 es API 33).

### 3. Nombre

`aapt2 dump badging` → `application: label='Gramanova' icon='res/mipmap-anydpi-v26/ic_launcher.xml'`, y `application-label-*:'Gramanova'` en todos los idiomas.

### 4. Icono

`aapt2 dump xmltree --file res/mipmap-anydpi-v26/ic_launcher.xml`:
```
E: adaptive-icon
    E: background   drawable=@0x7f060006
    E: foreground   E: inset drawable=@0x7f060007 inset=0.000000%
    E: monochrome   E: inset drawable=@0x7f060008 inset=0.000000%
```
`aapt2 dump resources` → `0x7f060006 drawable/ic_launcher_background`, `0x7f060007 drawable/ic_launcher_foreground`, `0x7f060008 drawable/ic_launcher_monochrome`. No hay `ic_launcher_round` y el manifest tampoco lo pide (solo `icon`).

PNG de la APK contra `git show a79daae:app_android/android/app/src/main/res/...` (SHA-256, prefijo de 16): **las 15 capas (fondo, figura y monocromo en mdpi, hdpi, xhdpi, xxhdpi y xxxhdpi) y el `mipmap-xxxhdpi/ic_launcher.png` de legado son idénticas byte a byte** (p. ej. foreground xxxhdpi `8B0EF35368E7C16C` = `8B0EF35368E7C16C`; monochrome xxxhdpi `9AB30182144346A9` = `9AB30182144346A9`).

Revisión visual (extraídos de la APK): foreground = robot cortacésped verde sobre transparente; background = césped a rayas verdes; legado = la composición de ambos; monochrome = silueta del robot rellena (6272 de 46 656 píxeles muestreados opacos, 6 tonos blanco/gris; Android usa solo su canal alfa), vista correctamente sobre fondo oscuro.

### 5. Permisos (manifest compilado)

```
aapt2 dump permissions app-debug.apk
uses-permission: name='android.permission.INTERNET'
uses-permission: name='android.permission.BLUETOOTH_SCAN' usesPermissionFlags='neverForLocation'
uses-permission: name='android.permission.BLUETOOTH_CONNECT'
uses-permission: name='android.permission.BLUETOOTH' maxSdkVersion='30'
uses-permission: name='android.permission.BLUETOOTH_ADMIN' maxSdkVersion='30'
uses-permission: name='android.permission.ACCESS_FINE_LOCATION' maxSdkVersion='30'
uses-permission: name='android.permission.ACCESS_COARSE_LOCATION' maxSdkVersion='28'
permission: com.robotcortadora.cortadora_e7.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION
uses-permission: name='com.robotcortadora.cortadora_e7.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'
```
Exactamente lo esperado y nada más. `INTERNET` viene solo de `src/debug` (verificado en la Ronda 1). `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` es el permiso interno de androidx (core).

### 6. AUD-10 → **CERRADO**

```
feature-group: label=''
  uses-feature-not-required: name='android.hardware.bluetooth'
  uses-feature-not-required: name='android.hardware.bluetooth_le'
  uses-feature-not-required: name='android.hardware.location'
  uses-feature: name='android.hardware.faketouch'
  uses-implied-feature: name='android.hardware.faketouch' reason='default feature for all apps'
```
Las tres features son opcionales en la APK compilada (en la APK de las 21:41 del 13/11, `bluetooth` y `location` eran obligatorias implícitas). `faketouch` es la feature por defecto de toda app.

### 7. ABI y SDK

`native-code: 'arm64-v8a'` (solamente), `minSdkVersion:'24'`, `targetSdkVersion:'36'`, `compileSdkVersion='36'`, `versionName='1.0.0' versionCode='1'`.

### 8. Envío de datos de flutter_blue_plus

`D:\dev\_logs\build_arm64_2026-11-14_031113.log`:
```
executing: ... gradlew.bat ... -Ptarget-platform=android-arm64 -Ptarget=lib\main.dart ...
> Task :app:flutterBluePlusLicensePingDebug SKIPPED
Skipping task ':app:flutterBluePlusLicensePingDebug' as task onlyIf 'Task is enabled' is false.
BUILD SUCCESSFUL in 3s
√ Built build\app\outputs\flutter-apk\app-debug.apk
exiting with code 0
```
**TOOLS_ENABLED:** decodifiqué los `-Pdart-defines` (base64) del log y solo hay `FLUTTER_BUILD_NAME`, `FLUTTER_BUILD_NUMBER`, `FLUTTER_VERSION=3.47.8`, `FLUTTER_CHANNEL`, `FLUTTER_GIT_URL`, `FLUTTER_FRAMEWORK_REVISION`, `FLUTTER_ENGINE_REVISION` y `FLUTTER_DART_VERSION`. **No hay `TOOLS_ENABLED`**: las herramientas quedan bloqueadas (default `false`).

### 9. Contenido = commit `a79daae`

- Horas: commit `a79daae` 14/11 03:08:25 (−03:00); log creado 03:11:13; APK 03:11:18. `git status` vacío.
- Verificación directa sobre el código, no solo por horas. La APK debug lleva `assets/flutter_assets/kernel_blob.bin` (46 MB) con el texto fuente embebido. Para cada archivo de `lib/` en `a79daae` busqué en el kernel todas sus líneas de más de 25 caracteres:

  | archivo | líneas | en el kernel |
  |---|---|---|
  | `app/lifecycle_observer.dart` | 10 | 10 |
  | `app/link_factory.dart` | 9 | 9 |
  | `app/session_controller.dart` | 159 | 159 |
  | `core/app_config.dart` | 14 | 14 |
  | `core/control_command.dart` | 87 | 87 |
  | `core/esp_protocol.dart` | 147 | 147 |
  | `core/robot_link.dart` | 48 | 48 |
  | `core/simulated_robot_link.dart` | 137 | 137 |
  | `main.dart` | 14 | 14 |
  | `ui/app.dart` | 8 | 8 |
  | `ui/home_shell.dart` | 46 | 46 |
  | `ui/labels.dart` | 39 | 39 |
  | `ui/screens/connection_screen.dart` | 54 | 54 |
  | `ui/screens/control_screen.dart` | 150 | 150 |
  | `ui/theme.dart` | 24 | 24 |
  | `ui/widgets/hold_button.dart` | 47 | 47 |
  | `ui/widgets/requested_panel.dart` | 74 | 74 |
  | `ui/widgets/simulated_banner.dart` | 15 | 15 |
  | `ui/widgets/stop_button.dart` | 29 | 29 |
  | `core/ble_robot_link.dart` | 323 | 25 (solo líneas genéricas que también están en otros archivos) |

  **Los 19 archivos alcanzables coinciden al 100 %** con `a79daae`: el kernel contiene `Gramanova`, `monotonicClock`, `_espStaleTimerFired` y no contiene "Robot Cortadora E7". `ble_robot_link.dart` **no está en la APK**: nada alcanzable desde `main` lo importa (`link_factory.dart` solo construye `SimulatedRobotLink`), así que el enlace BLE no está cableado en esta APK, como corresponde. El texto "BleRobotLink" aparece solo en comentarios de otros archivos, y el paquete `flutter_blue_plus` entra por el registro de plugins. Control de método: un privado alcanzable (`_sendCurrent`) sí aparece, o sea que la ausencia de los privados de BLE no es un artefacto de la búsqueda.

### Observaciones (sin hallazgo)

- Es una APK **debug** (JIT, con `libVkLayer_khronos_validation.so` de 15 MB, propio del modo debug). Corre más lenta que una release en un teléfono de gama baja: las mediciones del heartbeat en el M12 con esta APK son pesimistas (cota superior del retraso).
- Como el código BLE no está en la APK, las correcciones de AUD-06/12/13/15 y D1/D2 no afectan a esta instalación. Quedan probadas por tests para cuando se cablee BLE.

### Hallazgos nuevos

Ninguno.

### Veredicto

**APTA para instalar** en el Samsung Galaxy M12 (arm64-v8a, API 33): integridad, firma, nombre, icono v3, permisos, features (AUD-10 cerrado), ABI, ping de licencia desactivado, herramientas bloqueadas y código = `a79daae`. No quedan hallazgos abiertos.

---

## Paso 1 — STOP al conectar — 15/11/26

Base `22427ee` + cambios sin commitear del Agente 2 en `lib/app/session_controller.dart` (SHA-256 `D64CF49105B3B883FF0D5FE497342CB7D5A51474BB152ED1FE1D0D7F09633CDE`) y `test/app/session_controller_test.dart`. Regla nueva aprobada por el usuario: al pasar a `connected` el primer envío de cada conexión es un STOP completo, sincrónico, y el heartbeat arranca después. Cambio de código: 2 líneas (`_sendCurrent()` en `_onStatus` tras `_resetToSafeStop()` y en el constructor si nace conectado, ambas antes de `_startHeartbeat()`).

### Corridas literales (desde `R:\app_android`)

```
flutter.bat analyze                                                  → No issues found! (ran in 3.3s)
flutter.bat test test/app test/ui test/widget_test.dart --concurrency=1 → 00:11 +52: All tests passed!   (Agente 2 dijo 52: coincide)
flutter.bat test test/audit --concurrency=1                          → 00:39 +118: All tests passed!
flutter.bat test --concurrency=1                                     → 00:55 +290: All tests passed!
```
290 = 120 (core) + 52 (app/ui) + 118 (auditor). El "267 verdes + 6 rojos" del Agente 2 era antes de reescribir mis 6 (267 + 6 + 17 de mis tests nuevos = 290).

### 1. Los 6 tests míos reescritos — diff explícito (ninguno quedó más flojo)

Hashes (SHA-256): `audit_heartbeat_test.dart` `B6833ED1C21A73907C2F28D99F6C4092467FD34907A96E62A6EE0D4EA22037DF` → `8349B421E2C39832BD671075E742547E057B501917E145FCBC6AD6DAF41B3BCA`; `audit_r4_first_command_test.dart` `C7061BC905F571480FC8A9222FA23104E5555AA4214D63C6F73D7D5B15616BBB` → `53674949543B1C39771FBA6903ED0520CCC187C3D5168A677A32335982F3D4CB`. Los demás archivos de `test/audit/` no cambiaron (hashes de `audit_hashes_paso1_antes.txt` iguales). Archivo nuevo: `audit_paso1_stop_on_connect_test.dart` `8B7E8F02801F33DBBB35C503B9730E7976771482EB35736B930325BA961F83E7`.

| # | Archivo / test | Aserción antes | Aserción ahora | Por qué / ¿más flojo? |
|---|---|---|---|---|
| 1 | `audit_heartbeat_test.dart` A1 "10 minutos…" | `sent.length == 6000`; para todo `i`: `sentAt[i] − t0 == 100 ms·(i+1)`; todos `dir none`, todos `state stop` | `sent.length == 6001`; `sentAt.first − t0 == 0` (STOP en t = 0); para `i ≥ 1`: `sentAt[i] − t0 == 100 ms·i` **y** hueco entre envíos consecutivos `== 100 ms`; se conservan `dir none` y `state stop` en todos | Regla nueva: +1 STOP inmediato. **Más estricto**: se agregó el hueco de 100 ms medido entre envíos y que el STOP salga exactamente en t = 0. |
| 2 | A1 "reconexión repetida (50 veces)" | `periodicTimerCount == 1` al conectar y `0` al caer (se conservan); `sent.length == 100` | `sent.length == 150` (50 × (1 STOP + 2 ticks)); para cada conexión `k`: primer tick a `+100 ms` y segundo a `+200 ms` **medidos desde el STOP de esa conexión**, y el 1.º envío de cada conexión es `state stop` | Regla nueva. **Más estricto**: antes solo contaba envíos; ahora verifica cadencia por conexión y que el primero sea STOP. Un tick de más o adelantado haría fallar. |
| 3 | A3 "seq… vuelta 65535 → 0" (simulador real) | recibidos `[65533, 65534, 65535, 0, 1, 2]`; ACKs == seqs; `lastTransmittedLine` contiene `"seq":2}` | `[65533, 65534, 65535, 0, 1, 2, 3]`; ACKs == seqs; `"seq":3}`; y `receivedCommands.first.state == stop` | Regla nueva: el STOP consume 65533. Misma vuelta sin saltos; **agrega** que el primero sea STOP. |
| 4 | A3 "2 vueltas" | `sent.length == 131072`; `seq[i] == i % 65536` para todo `i` | `sent.length == 131073`; el mismo bucle `seq[i] == i % 65536` sobre los 131 073 envíos | Regla nueva (+1). Se mantiene sin cambios el chequeo de saltos y repetidos a través de las 2 vueltas. Igual de estricto. |
| 5 | A3 "envíos inmediatos… sin repetir" | `[65534, 65535, 0]` | `[65534, 65535, 0, 1]` y `sent.first.state == stop` | Regla nueva: 65534 pasa a ser el STOP de conexión y el 3.º envío (tick) se agrega. Sin saltos; **agrega** que el primero sea STOP. |
| 6 | `audit_r4_first_command_test.dart` "(caracterización) pedidos EXPLÍCITOS…" | `first.state == manual` (el primero era lo pedido) | `expectSafeStop(cmds.first)` (STOP completo) **y** el primer no-STOP posterior tiene seq mayor y es exactamente `manual/forward/cutter 1` (lo pedido no se pierde) | Obsoleta: la regla la **invierte**. Más estricto: no solo el primero es STOP, también verifica que lo pedido sale después y en orden. |
| 6b | mismo archivo, "(caracterización) MANUAL pedido enseguida" | `first.dir/cutter/trimmer == 0` | `expectSafeStop(first)` (state stop, dir none, speed 0, cutter 0, trimmer 0) | **Más estricto** (compara los 5 campos, antes 3 y sin `state`/`speed`). |

Ninguna aserción sobre STOP desapareció ni se relajó; las de cadencia, duplicados y vuelta de seq se mantienen o se endurecen. El único cambio de conteo es el envío extra del STOP al conectar.

### 2. Tests propios independientes de la regla (`audit_paso1_stop_on_connect_test.dart`, 17 tests; `fake_async`, doble de enlace propio con streams sincrónicos o asíncronos, simulador real y `main.dart` real)

Con `toolsEnabled` false **y** true: primer envío = STOP completo con seq válido, sincrónico con `setStatus(connected)` (log `['status:connected','send']`, sin `flushMicrotasks`), primer tick a +100 ms exactos (a +99 ms todavía no); lo mismo con streams asíncronos; 7 reconexiones seguidas con TODO pedido antes de cada caída (el primero de cada conexión es STOP, seq `(n+1) % 65536` sin saltos en toda la sesión); pedidos durante `connecting` y **en el instante exacto de `connected`, con un listener registrado antes que el del controlador**, no salen y el primero es STOP; pedidos en la ventana entre el cambio del enlace y la entrega del aviso asíncrono se ignoran; el controlador nace ya conectado. Además: `connected` duplicado; `connected → connecting → connected` inmediato; segundo plano y pérdida de conexión (regresión); `SimulatedRobotLink` real (7 ciclos con todo pedido y caída, el primer comando recibido por el "ESP" es STOP); `main.dart` real (al conectar, exactamente 1 envío, STOP, `lastSentSeq == 0`, y a +100 ms el segundo). Todos verdes.

### 3. Prueba de mutación (copia `D:\dev\_mutacion\session_controller.dart.p1.orig`; el árbol ya tenía cambios sin commitear, así que el criterio es: mismo hash y `git diff -- app_android/lib` idéntico al de antes)

Antes: `session_controller.dart` = `D64CF491…3CDE` (igual a la base del coordinador); `git diff -- app_android/lib` sha `BE864C14C05AFC9A568E7D4C0B05C2E4E3A8C33BCB28C7281816D5E395252780`. Cada mutante se aplicó solo, se corrieron los tests del Agente 2 (`test/app test/ui test/widget_test.dart`) y los del auditor (heartbeat, r4, paso1, safety, ui, protocol) y se restauró (hash verificado cada vez: `igual_base=True`).

| Mutante | Qué hace | Tests del Agente 2 | Tests del auditor | Resultado |
|---|---|---|---|---|
| **A** (pedido por el usuario) | sin STOP inicial (ni al conectar ni al nacer conectado) | `+43 -9`: "heartbeat envía ~10 comandos…", "seq incrementa…", "no envía sin conexión; arranca al conectar…", "dispose cancela…", "mantener adelante…", "lo pedido pasa a STOP y al reconectar…", "STOP inmediato al conectar", "STOP inmediato en CADA reconexión", "nace ya conectado" | `+55 -22`: **los 6 reescritos fallan** (A1 10 min, A1 50 reconexiones, A3 vuelta, A3 2 vueltas, A3 inmediatos, R4 "pedidos EXPLÍCITOS") **más** R4 "MANUAL pedido enseguida" y los 15 de `paso1` | **DETECTADO**. Ningún reescrito queda trivialmente verde sin el STOP. |
| **B1** | `_startHeartbeat()` antes de `_sendCurrent()` | `+52` todos verdes | `+77` todos verdes | **SOBREVIVE — mutante equivalente, no hallazgo.** El envío es sincrónico y el primer tick de un `Timer.periodic` solo ocurre 100 ms después: el orden de esas dos líneas no cambia ningún comportamiento observable (mismos envíos, mismos instantes, mismos seq). |
| **B2** | el STOP se difiere con `scheduleMicrotask` (sale después de la ventana sincrónica) | `+49 -3` (STOP inmediato al conectar, en cada reconexión, "arranca al conectar…") | `+72 -5`: `paso1` sincrónico ×2 (tools false/true), pedidos durante connecting ×2, connected→connecting→connected | **DETECTADO** |
| **C** | al conectar NO se llama `_resetToSafeStop()` (solo en esa rama) | `+52` verdes | `+77` verdes | **SOBREVIVE — mutante equivalente, no hallazgo.** Se demuestra: el controlador siempre pasa por la rama `!nowConnected` (que sí hace `_stopHeartbeat()` + `_resetToSafeStop()`) antes de volver a `connected`; `requestState`, `pressDirection`, `pulseTurn`, `setCutter` y `setTrimmer` exigen `isConnected`, y `_status` solo cambia en `_onStatus`; un `connected` repetido no entra a la rama (`wasConnected`). No hay camino que llegue a `connected` con algo distinto de STOP pedido: el reset al conectar es defensa en profundidad redundante. (Mientras exista, no hace daño.) |
| **C2** | además se quita el reset de la rama de pérdida (arrastre real de lo pedido) | `+49 -3` ("lo pedido pasa a STOP y al reconectar arranca en STOP", "STOP inmediato en CADA reconexión", "connecting cuenta como pérdida") | `+70 -7`: R4 "reconexión … 5 ciclos", `paso1` 7 reconexiones ×2, connected→connecting→connected, segundo plano/pérdida, simulador real, `audit_safety` A5 simulador | **DETECTADO** (el arrastre sí se atrapa) |
| **D** | el STOP inicial lleva `cutter = 1` cuando `toolsEnabled = true` | `+49 -3` | `+64 -13`: R4 ×5, `paso1` con tools true ×6, simulador real, A5 | **DETECTADO** |

Cierre: `session_controller.dart` = `D64CF49105B3B883FF0D5FE497342CB7D5A51474BB152ED1FE1D0D7F09633CDE`; `stop_button.dart` = `34B20869C7BB89F0829639DBD74D0F00672F8F9A2AB7188B3E9AB5BB62D0E3B2`; `git diff -- app_android/lib` sha `BE864C14…2780` = el de antes (`igual=True`).

### 4. Riesgos nuevos buscados con lupa

- **¿Puede salir un no-STOP entre `connected` y el STOP inicial?** No. `_sendCurrent` exige `_status == connected` y `_status` solo se actualiza en `_onStatus`, justo antes del STOP; entre el cambio del enlace y la entrega del aviso (microtarea) el controlador todavía se ve desconectado y descarta los pedidos (test: pedidos en esa ventana y en el instante exacto de `connected`). Con el STOP sincrónico, el primero es STOP incluso con listeners previos.
- **¿Doble `_startHeartbeat`?** No: `??=` + la rama solo corre al pasar de no-conectado a conectado. `connected` repetido: sin segundo STOP, sin segundo timer (`periodicTimerCount == 1`) y a 10 Hz exactos después. (Informativo: un `connected` duplicado **no** manda un segundo STOP; la pregunta del coordinador asumía que sí, pero el código lo evita. Es lo correcto: no baja lo que el usuario ya pidió.)
- **`connected → connecting → connected` inmediato:** dos STOP (uno por conexión), un solo timer, nada no-STOP en el medio ni después.
- **STOP al segundo plano y por pérdida de conexión:** sin cambios (regresión verde: `paused` manda STOP inmediato y el heartbeat sigue en STOP; al caer el enlace no sale nada).
- **seq:** el STOP consume un seq; continuidad `(n+1) % 65536` verificada a lo largo de 7 reconexiones y 2 vueltas completas.
- **Observación con BLE real (no hallazgo; BLE no está en la APK):** el STOP sincrónico se pide en el mismo instante en que `BleRobotLink` pasa a `connected`; su cola lo escribe de inmediato (ya no hay "primer tick" de espera: antes ~108 ms, ahora ~6 ms desde el `open()` en `audit_r4_first_command_test`).

### Hallazgos nuevos

Ninguno (AUD-17 no se abre). Sobrevivieron dos mutantes, ambos equivalentes (B1, C), con la demostración arriba.

### Veredicto del Paso 1: **EN VERDE**

La regla se cumple en todas las vías probadas (enlace propio sincrónico y asíncrono, simulador real, `main.dart` real, tools false/true, reconexiones, controlador que nace conectado). Los 6 tests míos reescritos son igual o más estrictos y no quedan triviales sin el STOP. Siguen en cola, sin tocar los documentos: `docs/protocolo_ble_app_esp.md` y `docs/entrega_companero_firmware.md`.

---

## Documentos de entrega BLE — 15/11/26

Solo lectura de `docs/protocolo_ble_app_esp.md` (v1.0), `docs/entrega_companero_firmware.md` (borrador) y las dos frases nuevas de `docs/e7_app_android.md` §3 y §5 (`git diff -- docs/e7_app_android.md`). Contrastados contra la Directiva §3, `e7_app_android.md`, `arquitectura.md`, `pines.md`, `00_estado_actual.md`, `lib/core` (`esp_protocol.dart`, `control_command.dart`, `ble_robot_link.dart`, `simulated_robot_link.dart`) y, solo lectura, `firmware/*/active/active/main/main.c`, `esp32_serial_transport.c`, `bumper_decision_node.py`, `Datasheet/Sabertooth2x25v2.txt` y `.gitignore`. `git status` de `firmware/` y `ros2_ws/`: sin cambios; no edité ningún documento.

**Test propio:** `test/audit/audit_docs_protocol_test.dart` (hash `B10FA99C815D64D03FF8C9111E2CD84D353752276A3BE2438FD6FC891996B477`, 22 tests: 20 verdes y 2 rojos). Genera con `ControlCommand.toJsonLine()` y decodifica con `decodeEspLine`/`parsePolygonLine`/`fromJsonLine` cada fila de las tablas 6.1–6.3, verifica los tamaños en bytes de todos los mensajes, las constantes, los tres UUID y el 300 ms. **Dos rojos a propósito (AUD-19, AUD-20)**; el resto verde.

```
flutter.bat analyze                       → No issues found! (ran in 3.1s)
flutter.bat test test/audit --concurrency=1 → 00:40 +138 -2: Some tests failed.   (los 2 rojos: AREA tamaños y CMD-15)
flutter.bat test --concurrency=1          → 00:55 +310 -2: Some tests failed.   (312 tests = 120 core + 52 app/ui + 140 auditor; 310 verdes y los mismos 2 rojos)
```

### Verificado sin hallazgo (con evidencia)

- **UUID:** los tres son exactamente `d4d28957-613f-4007-8a1d-1deab4080779` (servicio), `5a38f5bc-797e-4e23-97e6-efc129c921d5` (comando) y `9d803301-5ae6-4c4a-ab5a-8f783c540282` (notificaciones), en la fila correcta de la tabla de §2, y **no hay ningún otro UUID** en los tres documentos (test verde). `BleConfig` sigue con los tres en `null`, y el doc lo dice (§9: "siguen en `null` (PENDIENTE)").
- **Constantes doc = código:** heartbeat 100 ms, corte 300 ms, buffer 512 B, MTU 517, vértices 3–10, `id` 1–65535, códigos `FMT/NVERT/RANGE/ID/LEN` (verde).
- **300 ms escrito igual:** ninguna línea de los tres documentos dice "≥ / desde / a partir de / o más 300 ms"; los dos documentos nuevos afirman "300 vale" y "301 corta"; `e7_app_android.md` dice "más de 300 ms" (verde, con búsqueda por expresión regular sobre todas las líneas).
- **Tamaños correctos:** CMD 71 / 73 / 77 (también el máximo real sobre 64 combinaciones de bordes); ACK 21 / 24; POK 19 / 23; PCLR 13; GPS 40 / 73 / 77; POLY 62 / 290 / 280; PERR 23 / 32 / 42 (máximo real sobre todas las combinaciones de id y código). MTU: ACK/POK ≥ 27 y POLY ≥ 293 son correctos.
- **Ejemplos aceptados/rechazados por el código real:** CMD-1/2/3/4/18 válidos y CMD-1 regenera la línea exacta; CMD-6…14, 16, 17, 19 rechazados por `fromJsonLine`; ACK-1/2, GPS-1…4, POK y PERR (incluido `id:-1` con `e:"ID"`) como dice §6.2; POLY-1 genera la línea exacta del documento y POLY-2/3/4/5/6 son válidos; POLY-8…20 devuelven el `id` y el código de la tabla (y la app acepta el PERR resultante); POLY-21 (> 512 B) → `LEN` sin id; **POLY-16** (id fuera de int32) → el ESP simulado emite PERR sin id y la app lo recibe (el hallazgo AUD-04 está bien reflejado).
- **`AREA`:** hoy `decodeEspLine` la ignora (devuelve `null`), tal como dice el documento ("pendiente de la app, segunda APK").
- **Primer comando = STOP / conexión arranca en STOP** (§5.1, §8.2): es verdad en el código (`session_controller.dart`, `_onStatus`; verificado en el Paso 1).
- **Citas del paquete del compañero, todas exactas contra el código:** `main.c` del sensor (`APP_CMD_TIMEOUT_US 300000`, tabla de tareas con núcleo/prioridad/stack, v7.0, `ROS_PUBLISH_MS 50`, `UART_NUM_0`, líneas 228–234); `main.c` del motor (`:134-137`, `:517`, `:1062-1065` PIVOT fuerza accesorios, `:1242`, `:1257`, `:1263-1264`, `:1288`, `:1297`, `:1395`, `:1424`, `:81`, `CONFIG_ESP_TASK_WDT=n`, `TRIMMER_SPEED_STOP 64`, `TRIMMER_SPEED_MAX 85`); `bumper_decision_node.py:114` (timer 0,20 s), `:137` (7 campos), `:141-152`, `:232`; `esp32_serial_transport.c:18` (115200); el sensor realmente usa `usb_serial_jtag` y su `main.c` dice "La UART0 es exclusiva de micro-ROS" (la contradicción que el documento señala existe); Sabertooth ~365-370 y ~620-624 (sin timeout en modo microcontrolador; "Serial Timeout" solo en Packetized, apagado y no persistente); `pines.md` (reservas libres `4, 5, 11, 12, 13, 14, 21, 40, 41, 42`; UART0 en 43/44; strapping; sensor en `/dev/ttyACM0`); `00_estado_actual.md` (pendientes (a)–(c), v6.2, Pi 4/Lyrical) y las discrepancias Pi 4/Pi 5, `/dev/ttyUSB0`, "accesorios sin cambios" vs `ERR_IMU` (§9.3 del paquete) son reales. Cálculos: 430 ms de presupuesto y 4/11/25 cm de recorrido; 36 °/s × 20 s = 720°; 180/255 × 16,8 V = 11,9 V. `.gitignore` solo excluye `**/sdkconfig` y `**/sdkconfig.old`; `sdkconfig.defaults` **sí** está versionado (9 archivos): la advertencia de que la clave no puede ir ahí es correcta.
- **Estado de verificación honesto:** ningún documento afirma algo compilado o probado en banco/piso que no lo esté. El paquete lo declara de entrada ("nada implementado, compilado ni probado en el robot"), distingue compilado / banco / piso en el plan, y dice que la ruta BLE "no se probó nunca con hardware". El contrato se declara **no congelado** (cabecera, §11.1 y registro de cambios) y todo lo no decidido está marcado PROPUESTA/PENDIENTE (nombre `Cortadora-E7`, parámetros de conexión 15–30 ms / latencia 0 / supervisión 2 s, tiempos de bloqueo 5 min / 1 h, 10 fallos, 3 bonds, 2 s de línea parcial, namespace NVS, pin del botón y del desbloqueo, cota de `app_cmd_age_ms`, código de watchdog `feedback = 8`). No hay pines ni valores presentados como decididos.
- **Paquete del compañero:** cada recomendación lleva etiqueta PREGUNTA / SUPUESTO / PROPUESTA; no asigna a la usuaria tareas del compañero (firmware, Brain, watchdog, banco y piso son del compañero; la usuaria opera la app y decide); no pide nada prohibido: sin tocar firmware, `ros2_ws` ni la PC Linux desde la entrega, sin compilar; las pruebas con cuchilla quedan fuera del plan ("decisión aparte").
- **Los tres requisitos del 14/11/26** figuran con fecha, entrada y resultado esperado: (1) en `protocolo` §8.1, ST-1…ST-9 (300 vale, 301 corta; AUTO_RUN y AUTO_PAUSE; no reanuda), A-13…A-16; (2) §5.4, AR-3/AR-4/AR-10, A-18; (3) §5.8, AR-1…AR-11, A-17/A-19; el compañero puede objetarlos (§11 pregunta 7, `entrega` C14); la supervivencia a un reinicio es pregunta suya (§11 pregunta 8, C13); la ventana con botón es "RECOMENDACIÓN FUERTE" (`entrega` §3.6, C15).
- **Seguridad del emparejamiento, afirmaciones técnicas a verificar contra la especificación (no las doy por falsas):** (a) "cada emparejamiento fallido en Passkey Entry revela información de la clave, bit a bit en 20 rondas" y la estimación "decenas de intentos": el documento ya la marca "verificar contra Core Vol. 3, Part H"; puede ser optimista (podría ser menos). (b) "el Passkey Entry legacy es atacable offline por quien solo escucha": coincide con lo publicado sobre emparejamiento legacy; verificar. (c) "Display-only + MITM obligatorio → rechazar Just Works": consistente con el modelo de asociación (DisplayOnly contra un teléfono con teclado da Passkey Entry); verificar que el stack lo imponga. (d) §2 línea 39: la característica de notificaciones se declara "solo Notify (sin Read)" pero las banderas de NimBLE propuestas incluyen `READ_ENC | READ_AUTHEN` (que en NimBLE gobiernan el permiso del CCCD); no es una contradicción demostrada, pero hay que aclararlo con la versión real de ESP-IDF (el documento ya dice "verificar"). (e) "inyectar un passkey aleatorio durante el bloqueo" y "evento de re-emparejamiento": marcadas "verificar". (f) Códigos ATT 0x05 (autenticación) y 0x0F (cifrado): correctos.

### Hallazgos nuevos

| ID | Documento:línea | Qué está mal | Evidencia | Gravedad | Responsable | Estado |
|---|---|---|---|---|---|---|
| AUD-17 | `protocolo` §6.5 T-7, §8.1, §8.2, ST-7 (y `entrega` §4.10) | **"No reanuda solo" queda ambiguo cuando el enlace sigue vivo.** Si pasan > 300 ms sin comando pero la conexión BLE no se cae (un tropiezo de radio) y la app, que no se entera, sigue mandando su heartbeat con `state:2`, el siguiente comando es "nuevo y válido" y T-7 dice que el ESP "vuelve a publicar el comando completo (incluido su `state`)": **AUTO_RUN se reanuda solo**, sin que el usuario haga nada. ST-7 solo cubre la reconexión (donde la app manda STOP primero). Además §8.2 dice a la vez "hasta recibir un comando válido" y "el siguiente comando válido, aunque sea `state:2`, recién entonces cambia `app_state`", que no se sabe si exige un STOP antes. El `SessionController` tampoco baja su estado pedido en ese caso. | Lectura: `protocolo` líneas 313 (T-7), 324–325 (ST-6/ST-7), 407 y 415; `session_controller.dart` (solo baja a STOP al perder el estado de enlace o ir a segundo plano). | MEDIA (seguridad: AUTO_RUN) | Agente 1 (documento) + decisión del usuario | ABIERTO |
| AUD-18 | `protocolo` §5.7, PCLR-1, PCLR-2, A-9 contra §5.8 (2), AR-6, A-19 | **Contradicción interna sobre `PCLR`.** §5.7 y PCLR-1 dicen que el ESP "no responde nada" y A-9 exige "sin notificación"; §5.8 regla 2, AR-6 y A-19 exigen que tras un `PCLR` el ESP mande `{"t":"AREA","id":0}`. Un firmware correcto (con `AREA`) **fallaría** la prueba A-9 del propio documento. | `protocolo` líneas 202, 298, 384 contra 212, 340, 394. | MEDIA (la prueba de aceptación del compañero se contradice) | Agente 1 | ABIERTO |
| AUD-19 | `protocolo` §5.8 (tamaños), AR-1, AR-2 | **Tamaños de `AREA` mal calculados.** El documento dice 17 B (`id` 0), 19 B (`id` 7) y 23 B (`id` 65535). Los reales son **20 B, 20 B y 24 B** (`"AREA"` tiene una letra más que `"POK"`; parece copiado del cálculo de POK). Con 24 B el mínimo de MTU sin fragmentar sigue en 27 (no cambia el MTU de §4, pero el número del contrato está mal). | `audit_docs_protocol_test.dart` → `AREA (5.8): 17 B (id 0) / 19 B (id 7) / 23 B (id 65535) [E]`: `Expected: <17>  Actual: <20>`. Test rojo a propósito. | BAJA | Agente 1 | ABIERTO |
| AUD-20 | `protocolo` §5.1, CMD-15 contra `control_command.dart:157-191` | **El parser de referencia acepta la clave duplicada** que el documento exige descartar (`...,"seq":12,"cutter":1}` → `cutter = 1`; `jsonDecode` se queda con la última). El documento llama a CMD-1…POLY-22 "la especificación ejecutable", y el ESP simulado (que usa `fromJsonLine`) no la cumple en esa fila. La app nunca genera duplicados, así que no hay riesgo operativo; sí una divergencia entre contrato y referencia (ya anotada como observación en la Ronda 2). | `audit_docs_protocol_test.dart` → `CMD-15 ... [E]`: `Expected: throws <Instance of 'FormatException'>  Actual: <Closure: () => ControlCommand>`. Rojo a propósito. | BAJA | Agente 1 (código, o documento que aclare que la referencia no detecta duplicados) | ABIERTO |
| AUD-21 | `e7_app_android.md` §3 (párrafo "Seguridad en el ESP (ya implementada)") | **El encabezado "(ya implementada)" ahora cubre algo que NO está implementado.** La frase nueva (forzar `app_state` a 0 y no reanudar) quedó dentro del mismo párrafo. El firmware real solo pone `app_dir`, `app_cutter` y `app_trimmer` en 0: `main.c` del sensor, líneas 773–777; `app_state` no se toca. El requisito es nuevo y está sin implementar, sin compilar y sin probar. | `firmware/esp32_sensor/active/active/main/main.c:773-777`: `if (app_connected < 0.5f ...) { app_dir = 0.0f; app_cutter = 0.0f; app_trimmer = 0.0f; }`. | MEDIA (afirma implementado algo que no lo está) | Agente 1 | ABIERTO |
| AUD-22 | `protocolo` §3.5 (2) y §11 ("Para la usuaria" 1), `entrega` §9.1 U1 contra `entrega` §3.6 y C15 | **Dueño de la decisión de la ventana de emparejamiento inconsistente.** El pedido es "recomendación fuerte, decisión del compañero". El paquete lo dice en §3.6 y C15, pero el protocolo la deja como "decisión abierta del usuario" y la lista en las preguntas de la usuaria, y el propio paquete la repite como U1 de la usuaria. | Líneas: `protocolo` 100 y 494; `entrega` 543 (U1) contra 154 y 572 (C15). | BAJA | Agente 1 | ABIERTO |
| AUD-23 | `entrega` §3.9 y §8.1; `protocolo` §1 línea 18 | Tres desactualizaciones menores: (a) §3.9 manda verificar "A-1 … A-12 y S-1 … S-11" y omite A-13…A-19 (las pruebas de los requisitos nuevos); (b) §8.1 dice "270 tests de la app" y, tras el Paso 1, son 290 en total (idem `00_estado_actual.md` línea 40); (c) §1 del protocolo todavía dice que la app "solo ve GPS, ACK y POK/PERR", sin `AREA`. | Líneas citadas. | BAJA | Agente 1 | ABIERTO |
| AUD-24 | `lib/core/simulated_robot_link.dart` (`espPublishedCommand`) contra `protocolo` §8.1, ST-2…ST-9, AR-1…AR-10 | **El ESP simulado de referencia no implementa los requisitos del 14/11/26:** en el corte conserva `state` (con AUTO_RUN publica AUTO_RUN; el documento pide 0) y no emite `AREA`. Sí conserva el polígono al desconectar y `PCLR` lo borra (AR-3, AR-6 en lo que le toca). Hoy no afecta a la app (la UI no muestra nada de eso), pero ST-x y AR-x no son ejecutables contra la referencia. | `audit_docs_protocol_test.dart`, caracterización (verde): tras 301 ms con `autoRun`, `pub.state == autoRun`; `link.espPolygonId` conserva 7 al desconectar. | BAJA | Agente 1 (opcional, junto con la segunda APK) | ABIERTO |

#### Correcciones que se piden (los documentos los edita su dueño)

- **AUD-17:** decidir y escribir una regla explícita para el corte con enlace vivo: o el ESP queda "trabado" en STOP hasta recibir un comando con `state:0` (y solo después acepta `state:2`), o se acepta que el siguiente heartbeat lo reanuda y entonces la app debe volver a STOP cuando note el hueco. Agregar el caso a ST-x. Reescribir §8.2 sin ambigüedad. Decide el usuario (seguridad).
- **AUD-18:** unificar: tras `PCLR` el ESP manda `AREA id:0` (si se mantiene `AREA`); corregir §5.7, PCLR-1/PCLR-2 y A-9, y la nota de la pregunta 6 de la usuaria.
- **AUD-19:** corregir a 20 / 20 / 24 B (AR-1, AR-2 y §5.8).
- **AUD-20:** o hacer que el parser de referencia rechace claves duplicadas (comprobación propia sobre el texto), o aclarar en CMD-15 que la referencia de la app no la detecta.
- **AUD-21:** marcar la frase de `app_state` como "requisito nuevo (14/11/26), **pendiente en el firmware v7.0**" y dejar "(ya implementada)" solo para dir/cutter/trimmer.
- **AUD-22:** que el protocolo y U1 digan "recomendación fuerte; decide el compañero".
- **AUD-23:** completar la lista de pruebas, corregir el conteo (290) y el §1.
- **AUD-24:** opcional.

### Observaciones (sin ID)

- Atribución de los requisitos: el pedido del coordinador atribuye las tres decisiones a "la usuaria"; el protocolo atribuye (1) `app_state → STOP` al **usuario** (§8.1, §11.1) y (2)/(3) a la **usuaria**. Confirmar cuál es la correcta para el requisito (1); no cambia el contenido.
- Mínimos de MTU (§4, §9): la lista "comando y GPS ≥ 80; ACK y POK ≥ 27" no menciona `PERR` (hasta 42 B, necesita ≥ 45) ni `AREA` (24 B, ≥ 27). No es un error, es una omisión.

### Veredicto por documento

| Documento | Veredicto | Motivo |
|---|---|---|
| `docs/protocolo_ble_app_esp.md` | **NO** | AUD-17 (MEDIA, ambigüedad de seguridad en AUTO_RUN), AUD-18 (MEDIA, la prueba A-9 se contradice con `AREA`), AUD-19, AUD-20, AUD-22, AUD-23. Lo demás está sólido: UUID exactos, tamaños y ejemplos verificados contra el código, 300 ms consistente, estado "no congelado" bien declarado. |
| `docs/entrega_companero_firmware.md` | **EN VERDE** con reservas menores | Citas exactas contra el código, recomendaciones etiquetadas, sin tareas mal asignadas ni acciones prohibidas, sin afirmar nada compilado o probado. Solo hereda AUD-17 (§4.10), AUD-22 (U1 vs C15) y AUD-23 (§3.9, §8.1); no se corrige nada propio fuera de eso. |
| `docs/e7_app_android.md` (dos frases en §3 y §5) | **NO** | AUD-21 (MEDIA): "(ya implementada)" ahora cubre un requisito que el firmware no tiene. La frase de §5 (conservar el polígono y `AREA`) es correcta y marca claramente que la app aún no la decodifica. |
---

## Verificación de las correcciones AUD-17…AUD-24, `fromJsonLine` y STOP retenido — 15/11/26

Todo con corrida propia (`R:\app_android`, `--concurrency=1`). No edité documentos ni `lib/`; la mutación se hizo con el protocolo de siempre.

```
flutter.bat analyze                         → No issues found! (ran in 3.1s)
flutter.bat test test/core --concurrency=1  → 00:02 +123: All tests passed!      (Agente 1: coincide; incluye sus 3 tests de AUD-20)
flutter.bat test test/audit --concurrency=1 → 00:41 +147 -3: Some tests failed.   (los 3 rojos = AUD-25)
flutter.bat test --concurrency=1            → 00:55 +322 -3: Some tests failed.   (325 tests = 123 core + 52 app/ui + 150 auditor)
```

### Mis dos tests actualizados (por qué)

- `audit_docs_protocol_test.dart`, AUD-19: ya no pega 17/19/23. Calcula `AREA` con `jsonEncode`, lo deriva de forma independiente (POK de un dígito + la diferencia de letras `"AREA"` − `"POK"`; +4 dígitos para 65535) y exige que el documento diga exactamente esos valores calculados (20 B, 20 B, 24 B, en §5.8, AR-1 y AR-2). Se agregó `ESTOP`: la línea `{"t":"ESTOP","why":"T"}\n` mide **24 B** (verdad contra el código; el documento y el paquete dicen 24 B), cabe en MTU 27, y la app hoy la ignora (`decodeEspLine` → `null`), como dicen ambos documentos. Verde.
- `audit_protocol_test.dart`, "claves extra / duplicada": antes caracterizaba "gana la última". Ahora exige: claves extra se aceptan (también con valores array), y la duplicada se rechaza en el final, al principio y con el mismo valor. No quedó más floja en nada (antes aceptaba el duplicado; ahora lo rechaza y conserva la aceptación de extras). Verde.

### Cambio de código AUD-20 (`_hasDuplicateTopLevelKey`): **NO — hay un bypass (AUD-25)**

Revisé el escáner línea por línea y lo ataqué con casos dirigidos y 9000 objetos aleatorios (semillas fijas) en `audit_dupkeys_test.dart` (nuevo, hash `09B50C172833FC0E…`, 11 tests).

- **Funciona** (verde): duplicadas de primer nivel de las 7 claves del contrato, desconocidas, en cualquier posición, con distinto valor y con el mismo valor, con valores escalar/string/array/objeto; claves anidadas repetidas NO se rechazan (ni dentro de arrays de objetos); lo que parece clave pero está dentro de un string (`"\"cutter\":1"`), strings con `{ [ : ,`, string que termina en `\\`, claves que difieren por mayúsculas o por un espacio final, espacios, tabuladores, `\r\n` y saltos alrededor de los separadores; JSON inválido, `{}`, `[]`, vacío, truncado: `FormatException` sin colgarse; 3000 objetos aleatorios SIN duplicados (por el significado de JSON) con extras y duplicados anidados: siempre aceptados con los campos intactos; 3000 con duplicados escritos igual: siempre rechazados; `toJsonLine` byte a byte y ida y vuelta en 4·5·5·4 = 400 combinaciones.
- **No funciona — AUD-25:** el escáner compara el **texto crudo** de la clave, pero `jsonDecode` compara claves **decodificadas**. `"cutter"` y `"cut\u0074er"` son la MISMA clave para JSON y gana la última, así que la línea `{"t":"CMD",…,"cutter":0,…,"cut\u0074er":1}` **se acepta con `cutter = 1`**. Fue exactamente la clase de ataque que describe el requisito. Evidencia: `audit_dupkeys_test.dart` → `clave duplicada escrita con escape \u … [E]` (`BYPASS: la línea se acepta con cutter = 1`; precondición verificada: `jsonDecode(...)['cutter'] == 1`); `escape de la primera aparición y de ambas [E]` (cinco variantes: en `t`, `cutter` en la primera o en las dos apariciones, `trimmer`, `seq`); y la propiedad con 3000 líneas aleatorias con duplicado por escape: **3000 de 3000 aceptadas** (ejemplo: `{"dir":1,"cu\u0074\u0074\u0065\u0072":0,"trimmer":0,…,"cutter":0,"seq":12}`).

**Prueba de mutación** (copia `D:\dev\_mutacion\control_command.dart.dup.orig`): se quitó el `if (_hasDuplicateTopLevelKey(line)) throw …`.

```
antes:     control_command.dart = 7681FA8631F39B0055C807DA0E9B56E0DA7C49E31C5CFA34AA0999DB7B232368
           git diff -- app_android/lib → sha BC313ABC664900CDBFCC589C96A54E7C788C01C165343F71F781ED4826B30B00
mutante:   test/core                  → +70 -1: ... clave duplicada (AUD-20) una clave de primer nivel repetida se rechaza [E]
           audit (dupkeys/docs/protocol) → +41 -7: dupkeys (casos dirigidos, 2 propiedades), docs "CMD-15", protocol "claves extra... duplicada" [E]
después:   control_command.dart = 7681FA86…2368  igual=True
           git diff -- app_android/lib → sha BC313ABC…0B00  igual=True
```
**Mutante DETECTADO** por 1 test del Agente 1 (los otros dos de AUD-20 solo comprueban aceptación y no pueden detectarlo) y por 7 míos. Regresión: `esp_protocol.dart` no cambió (`git diff` solo toca `control_command.dart`), `decodeEspLine` y `toJsonLine` sin cambios de comportamiento (tests de `test/core`, `audit_docs_protocol_test` y el bloque "regresión" de dupkeys, todos verdes).

### Verificación de los documentos (lectura de `protocolo_ble_app_esp.md`, `entrega_companero_firmware.md` y `e7_app_android.md`)

| Hallazgo anterior | Estado | Evidencia |
|---|---|---|
| AUD-17 (reanudación con enlace vivo) | **CERRADO** (la regla quedó escrita; ver AUD-26 por una ambigüedad nueva) | §6.5 requisito 2, ST-1…ST-12, §5.9, §8.1: tras un corte > 300 ms (300 vale, 301 corta) en AUTO_RUN/AUTO_PAUSE queda STOP retenido, no reanuda con `state:2/3` frescos hasta un `state:0` y un AUTO posterior, también con el enlace vivo; T-7 ya distingue MANUAL. |
| AUD-18 (PCLR vs AREA) | **CERRADO** | §5.7, PCLR-1/PCLR-2 y A-9 ahora exigen `AREA id:0` (coherente con §5.8 regla 2, AR-6, A-19). Residual → AUD-27. |
| AUD-19 (tamaños AREA) | **CERRADO** | 20/20/24 B en §5.8, AR-1, AR-2 y el paquete (`20–24 B`); verificado por mi test con valores calculados. |
| AUD-20 (CMD-15) | **ABIERTO** → AUD-25 | el rechazo funciona para duplicados escritos igual y falla con escapes `\u`. |
| AUD-21 (`e7` §3 "ya implementada") | **CERRADO** | el encabezado ahora dice "ya implementada solo para `app_dir`, `app_cutter` y `app_trimmer`" y marca el forzado de `app_state` y el STOP retenido como PENDIENTES (el v7.0 no lo hace; coincide con `main.c:773-777`). |
| AUD-22 (dueño de la ventana) | **CERRADO** con una observación | §3.5, §11 (pregunta 1 de la usuaria), §11.1 y el paquete (U1, C15) dicen "recomendación fuerte; decide el compañero". Observación: §11.1, última fila, aún agrupa la ventana en "Abiertos (usuaria/compañero)". |
| AUD-23 (desactualizaciones) | **PARCIAL** | (a) §3.9 ahora dice A-1…A-22; (b) el conteo de tests se reemplazó por una referencia a AUDITORIA.md; **(c) NO corregido:** `protocolo` §1 (línea 18) todavía dice que la app "solo ve GPS, ACK de comandos y POK/PERR" (sin `AREA` ni `ESTOP`). |
| AUD-24 (simulador) | **CERRADO** (documentado) | §8.1 "Pendiente de la app (simulador)", §11.1 y paquete 5c: el simulador no fuerza `state`, no retiene y no emite `AREA`/`ESTOP`, y no es referencia de estos requisitos. |

**Comprobaciones pedidas sobre el STOP retenido:**
- **ESTOP:** 24 B verificado. `why` es un carácter; `T` = timeout; `D` reservado y no se envía (coherente en §5.9, 5.9 punto 1 y 2, y ST-6/ST-7, que cubren la desconexión sin aviso). El formato figura como **PROPUESTA pendiente de la usuaria** en §5.9, §11.1, §9 y paquete (líneas 46 y 135); ningún documento lo da por decidido.
- **MANUAL:** pregunta abierta en §8.1, §11 pregunta 9, §11.1, T-7, ST-11, A-22 y paquete C16; la recomendación (no retener) está marcada "no es decisión" y se dan sus riesgos.
- **300 ms:** igual en todos lados (mi test sobre los tres documentos sigue verde: ninguna línea dice ≥ / desde / a partir de 300 ms; se afirma "300 vale, 301 corta").
- **Atribución:** las decisiones del 14/11/26 figuran "de la usuaria" en §5.9, §6.5, §8.1, §11, §11.1, `e7` §3 y el paquete; el único "usuario" con 14/11 que quedó en el paquete es la decisión previa "opción A" (robot quieto), que es otra decisión.
- **Lo pendiente de la app está listado:** decodificar `AREA` y `ESTOP`, guardar polígonos, reaccionar (STOP + volver a pedir AUTO + mandar `state:0` antes de AUTO), y que el simulador no emula el corte ni `AREA` (§5.8, §5.9, §9, §11.1, paquete 5a/5b/5c).
- **Documentos no afirman lo no probado:** §8.1 marca "Estado en el firmware: PENDIENTE DE IMPLEMENTAR"; el paquete sigue declarando que nada está implementado, compilado ni probado.

### Hallazgos nuevos

| ID | Archivo:línea | Qué está mal | Evidencia | Gravedad | Responsable | Estado |
|---|---|---|---|---|---|---|
| AUD-25 | `lib/core/control_command.dart` `_hasDuplicateTopLevelKey` (~l.216-245) y `protocolo` §5.1 línea 143 | **Bypass de la clave duplicada con escapes `\uXXXX`.** El escáner compara texto crudo; JSON compara claves decodificadas. `"cut\u0074er":1` después de `"cutter":0` se acepta con `cutter = 1`. Además el protocolo afirma que la referencia "ya rechaza las claves duplicadas de primer nivel" y que el firmware "debe hacer lo mismo": como está escrito, un firmware que imite ese escáner heredaría el agujero. Es un parser de referencia (la app nunca genera duplicados), pero es justo el vector que el requisito quería cerrar (herramientas). | `audit_dupkeys_test.dart`: 3 rojos (`BYPASS: la línea se acepta con cutter = 1`; 5 variantes; 3000/3000 aceptadas). Control: sin mutante, los demás 8 tests de ese archivo pasan. | **ALTA** (seguridad: herramientas) | Agente 1 | ABIERTO |
| AUD-26 | `protocolo` §8.1 (párrafo "El robot NO reanuda solo…") y §8.2 contra ST-9 y §6.5 requisito 2 | **Regla del primer comando ambigua.** §8.1 dice que `app_state` queda en 0 "hasta recibir un comando nuevo y válido"; §8.2 dice que "el siguiente comando válido, aunque sea `state:2`, recién entonces cambia `app_state`"; ST-9 dice que AUTO solo se acepta después de un `state:0` válido **en la conexión**. Con una conexión que arranca con `state:1` y sigue con `state:2` (sin `state:0`), §8.2 y ST-9 dan resultados distintos. Falta una frase única: "AUTO exige un `state:0` previo en cada conexión (y tras cada STOP retenido)" o la regla contraria. | `protocolo` líneas 436, 450 y 350. | MEDIA (seguridad: AUTO) | Agente 1 (decide la usuaria) | ABIERTO |
| AUD-27 | `protocolo` §5.7 contra PCLR-3 | §5.7 dice "un PCLR mal formado o **con otra clave**: sin respuesta"; PCLR-3 dice que `{"t":"PCLR","x":1}` "claves desconocidas se ignoran: se procesa como PCLR-1" (con respuesta `AREA`). Se contradicen sobre qué es "otra clave". | líneas 202 y 316. | BAJA | Agente 1 | ABIERTO |

Observaciones sin ID: `protocolo` §1 línea 18 (AUD-23c, sigue abierto, BAJA, Agente 1); §11.1 última fila aún lista la ventana de emparejamiento entre los "Abiertos (usuaria/compañero)"; la lista de pruebas de §7 está desordenada (A-13…A-16, A-20…A-22, A-17…A-19) y A-4 no menciona `16 = 0`.

### Veredictos

| Entregable | Veredicto | Motivo |
|---|---|---|
| Cambio de código AUD-20 (`fromJsonLine`) | **NO** | AUD-25 (ALTA): el chequeo se evade con escapes `\u`. Lo demás es sólido y la mutación lo detecta. |
| `docs/protocolo_ble_app_esp.md` | **NO** | AUD-25 (la afirmación de §5.1), AUD-26 (MEDIA), AUD-23c y AUD-27 (BAJAs). AUD-17/18/19/22/24 quedaron bien resueltos; STOP retenido, `ESTOP`, MANUAL y la atribución están correctos. |
| `docs/entrega_companero_firmware.md` | **EN VERDE** | Coherente con el protocolo (retención, `ESTOP` como propuesta, MANUAL abierto, pendientes de la app, A-1…A-22, ventana "decide el compañero"). Hereda la ambigüedad AUD-26. |
| `docs/e7_app_android.md` | **EN VERDE** | AUD-21 corregido: "ya implementada" acotado a dir/cutter/trimmer y lo nuevo marcado pendiente. |
---

## Verificación de AUD-25…AUD-27 y observaciones AUD-22/23 — 15/11/26

Todo con corrida propia (`R:\app_android`, `--concurrency=1`). No edité documentos ni `lib/`.

```
flutter.bat analyze                         → No issues found! (ran in 3.2s)
flutter.bat test test/core --concurrency=1  → 00:02 +125: All tests passed!
flutter.bat test test/audit --concurrency=1 → 00:42 +164: All tests passed!   (incluye "AUD-25 propiedad: aceptados=3000 rechazados=3000 discrepancias=0")
flutter.bat test --concurrency=1            → 01:03 +341: All tests passed!   (341 = 125 core + 52 app/ui + 164 auditor)
```

### Conteo de `audit_dupkeys_test.dart` (discrepancia 10 vs 11)

Contado por mí con `Select-String '^\s+test\('`: **10 tests** (6 en "casos dirigidos", 3 en "propiedad", 1 en "regresión"). Mi cifra de 11 fue un **error de conteo mío**; no se perdió ningún test. Pruebas: el hash del archivo no cambió (`09B50C172833FC0E…`, el mismo de la verificación anterior) y el total de la suite cuadra (140 del auditor antes de ese archivo + 10 = 150, y 150 + 7 de `audit_docs2` + 7 de `audit_dupkeys2` = 164).

### AUD-25 — `_hasDuplicateTopLevelKey`: **CERRADO** (código EN VERDE)

El escáner ahora decodifica cada clave de primer nivel con `jsonDecode` del literal. Mis tres rojos anteriores (`BYPASS …`, 5 variantes, 3000/3000) pasan, y agregué un oráculo independiente.

- **`audit_dupkeys2_test.dart` (nuevo, 7 tests, hash `DBE7C85DE60DAA05…`).** Tokenizador JSON escrito a mano (sin `jsonDecode` ni el escáner del código; decodifica `\uXXXX` en minúscula y mayúscula, `\/`, `\"`, `\\`, `\b\f\n\r\t` y pares sustitutos). Propiedad: **6000 objetos aleatorios** (mitad con duplicado forzado; claves difíciles: vacía `""`, `" "`, `"a b"`, `ñ`, `é`, emoji, `a"b`, `a\b`, `a/b`, `T`, `Cutter`, `"cutter "`, salto de línea, `U+2028`; cada clave escrita con codificaciones mezcladas; valores con `{ : "` dentro de strings, arrays y objetos anidados con las **mismas** claves repetidas; espacios y saltos): la decisión de `fromJsonLine` coincide con la del oráculo en **6000/6000** (aceptados 3000, rechazados 3000, **0 discrepancias**). Otra propiedad: 3000 con duplicado por escape se rechazan todos; 3000 sin duplicado se aceptan todos. Casos dirigidos: `cut\u0074er` (el ejemplo del documento), dos escapadas entre sí, `tri\u006dmer`/`tri\u006Dmer` y entre sí (minúscula vs mayúscula), clave escapada por completo, `seq` escapada, `t` escapada, `\/`, `\"`, `\\`, par sustituto escapado contra el literal 😀 y contra el escapado en minúscula, clave vacía duplicada, espacios iguales con escape, y **`cut\u0054er` NO duplica** (es "cutTer") junto con espacios distintos y `""` vs `" "` (aceptadas); duplicados anidados y strings con llaves/comillas/`\\` final: aceptados; JSON truncado/`{}`/`[…]`/inválido: `FormatException` sin colgarse.
- **Prueba de mutación** (copia `D:\dev\_mutacion\control_command.dart.dup2.orig`; el árbol tiene cambios sin commitear, así que el criterio es hash y `git diff -- app_android/lib` iguales a los de antes de mutar).

```
antes:  control_command.dart = EBDFACD5C8DB2E05FF8F0DCBDCB3A71FC0B6167CEF686D23B920A27594FE01A4
        git diff -- app_android/lib → sha F3CAB73A7D2814CF10EBF644D07D53507492CFF4DE7520B00D5E3CEBC59E2B90
M1 (quitar el chequeo):          test/core  → +70 -3  (clave duplicada AUD-20, "disfrazados con escapes", "\/ \" y pares sustitutos")
                                 audit      → +44 -11 (dupkeys ×5, dupkeys2 ×4, docs CMD-15, protocol claves duplicadas)
M2 (comparar el texto CRUDO):    test/core  → +71 -2  ("disfrazados con escapes", "\/ \" y pares sustitutos")
                                 audit      → +48 -7  (dupkeys ×3, dupkeys2 ×4)
después: control_command.dart = EBDFACD5…01A4  igual=True
         git diff -- app_android/lib → sha F3CAB73A…2B90  igual=True
```
Ambos mutantes **detectados** por tests del agente y por los míos (M2 solo por los casos con escape, que es lo esperable: el texto crudo funciona para duplicados escritos igual). Regresión: `git diff` solo toca `control_command.dart` (`esp_protocol.dart` sin cambios), `toJsonLine` byte a byte y ida y vuelta de 400 combinaciones verdes (bloque "regresión" de `audit_dupkeys_test`), `decodeEspLine` sin cambios (`audit_docs_protocol_test`, `test/core` verdes).

### Documentos

| Hallazgo | Estado | Evidencia |
|---|---|---|
| AUD-26 (una sola regla) | **CERRADO** | §8.1 "**Regla única (la de ST-9):** tras cualquier corte de más de 300 ms o desconexión, el ESP queda en STOP retenido y solo vuelve a aceptar AUTO después de un `state:0` válido"; §8.2 la aplica ("`state:2` como primer comando se mantiene en 0"); ST-9 coincide; las frases viejas ("comando nuevo y válido" suelto, "aunque sea `state:2`, recién entonces cambia") desaparecieron; MANUAL sigue como pregunta abierta 9 (§8.1, §8.2, T-7, ST-11, A-22, §11.1). Test `audit_docs2_test.dart` verde. |
| AUD-27 (§5.7 y PCLR-3) | **CERRADO** | §5.7: "Un PCLR con claves desconocidas se procesa igual (PCLR-3); un PCLR mal formado o sin `\n`: sin respuesta"; PCLR-3 dice lo mismo. |
| AUD-23 (c) | **CERRADO** | §1 línea 18: "…GPS, ACK, POK/PERR y los dos mensajes agregados el 14/11/26: `AREA` y `ESTOP`". (AUD-23 queda cerrado entero: a y b ya estaban.) |
| AUD-22 (observación) | **CERRADO** | §11.1 tiene fila propia ("RECOMENDACIÓN fuerte; la decisión es del compañero de firmware (no está abierta para la usuaria)") y la fila agregada de "Abiertos" ya no menciona la ventana; paquete U1 y C15 coherentes. |
| §5.1 frase nueva + CMD-15b | **VERIFICADO** | Extraje el ejemplo del texto del documento: `{"t":"CMD","state":1,"dir":1,"speed":50,"cutter":0,"trimmer":0,"seq":12,"cut\u0074er":1}`; `jsonDecode` lo lee con `cutter = 1` y `fromJsonLine` lo **rechaza** (= "ninguna respuesta", igual que CMD-15); con `cut\u0074er` escrita **una sola vez** es válido y da `cutter = 1` (como dice el documento); duplicados anidados no se rechazan; CMD-15b está en la tabla. Test verde. |

**Relectura completa del protocolo** (584 líneas) buscando contradicciones nuevas introducidas por la edición: ST-1…ST-12, §6.5, T-7, §8.1–§8.3, AREA, ESTOP, PCLR, §11/§11.1 y A-13…A-22 son coherentes entre sí; el 300 ms se escribe igual en todos lados (mi test sobre los tres documentos, verde); las decisiones del 14/11/26 se atribuyen a la usuaria; el formato de `ESTOP` y MANUAL siguen como propuesta/pregunta abierta; lo pendiente de la app (decodificar `AREA`/`ESTOP`, guardar polígonos, simulador) sigue listado. El paquete del compañero es coherente con el protocolo (retención, `ESTOP` propuesta, MANUAL abierto, A-1…A-22, ventana "decisión tuya", pendientes 5a/5b/5c). Solo encontré dos asuntos menores y uno de redacción:

| ID | Documento:línea | Qué está mal | Gravedad | Responsable | Estado |
|---|---|---|---|---|---|
| AUD-28 | `protocolo` §8.1 (regla única) contra el párrafo "STOP retenido en AUTO", T-7, ST-11 y 5.9 | La regla única dice "tras **cualquier** corte … solo vuelve a aceptar AUTO tras un `state:0`", pero el resto del documento habla del corte **en AUTO**. No dice qué pasa tras un corte **en MANUAL**: ¿un `state:2` posterior (la usuaria pasa de MANUAL a AUTO_RUN sin pasar por STOP) queda ignorado? ¿se manda `ESTOP`? Es lo más conservador, pero la app no sabría por qué el ESP lo ignora si no hay aviso. | BAJA | Agente 1 (decide la usuaria junto con la pregunta 9) | ABIERTO |
| AUD-29 | `entrega` §3.5 (línea 144) y §4.10 (línea 305) | (a) §3.5 recomienda detectar duplicados "recorriendo la lista de hijos" de cJSON o un parser propio, pero no dice que hay que comparar las claves **decodificadas** (exactamente el defecto que tuvo la referencia, AUD-25); con cJSON ya vienen decodificadas, con un parser propio no. (b) §4.10 todavía dice que `app_state` "queda en 0 hasta un comando nuevo y válido", la formulación que AUD-26 corrigió en el protocolo. | BAJA | Agente 1 | ABIERTO |

### Veredictos

| Entregable | Veredicto | Motivo |
|---|---|---|
| `lib/core/control_command.dart` (AUD-25) | **EN VERDE** | 6000/6000 concordancias con un oráculo independiente; casos dirigidos pedidos todos correctos; mutantes M1 y M2 detectados; restaurado con hash y `git diff` idénticos; regresión sin cambios. |
| `docs/protocolo_ble_app_esp.md` | **EN VERDE** | AUD-26/27/23c/22 corregidos y ejemplo de §5.1 verdadero contra el código real. Solo la observación AUD-28 (BAJA). |
| `docs/entrega_companero_firmware.md` | **EN VERDE** | Coherente con el protocolo; solo la observación AUD-29 (BAJA). |