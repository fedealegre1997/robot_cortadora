# Cortadora E7 (app Android)

App E7 del Robot Cortadora: control manual por BLE (con modo simulado).
Proyecto Flutter, solo plataforma Android. Paquete: `com.robotcortadora.cortadora_e7`.

## 1. Cargar el entorno (cada vez que se abre una terminal)

Todo el toolchain vive en `D:\dev` (el disco C: está casi lleno). El script solo
cambia variables **del proceso actual** de PowerShell; no toca variables de usuario
ni de sistema.

```powershell
. D:\dev\env_flutter.ps1
cd R:\app_android
```

**Trabajar SIEMPRE desde `R:\app_android`, nunca desde `d:\Moisés\...`.** Las
herramientas de Flutter fallan con la "é" de la ruta: por ejemplo `flutter.bat analyze`
termina con `exit 255` en la ruta original y anda bien desde `R:`.

- `R:` es una unidad virtual (`subst`) que apunta a `d:\Moisés\Gramanova\robot_cortadora`.
  Son los mismos archivos, no una copia.
- `D:\dev\env_flutter.ps1` la monta si no existe. A mano: `subst R: "d:\Moisés\Gramanova\robot_cortadora"`.
- Ver qué está montado: `subst`. Quitarla: `subst R: /d` (no borra nada, solo quita la letra).
  `subst` dura hasta cerrar sesión o reiniciar; al volver, cargar el script de nuevo.

Si se llama a Gradle directamente, usar `.\gradlew.bat` (con `.\`), no `gradlew.bat`:
en algunas terminales (por ejemplo la de Claude Code) está definida
`NoDefaultCurrentDirectoryInExePath=1`, y entonces Windows no ejecuta programas de la
carpeta actual sin ruta explícita ("no se reconoce como un comando interno o externo").
Desde `cmd /c`, además, hay que entrar con `cd /d R:\app_android\android`.

Qué fija el script:

| Variable | Valor | Para qué |
|---|---|---|
| `JAVA_HOME` | `D:\dev\jdk-17` | JDK Temurin 17 que usa Gradle |
| `ANDROID_HOME` / `ANDROID_SDK_ROOT` | `D:\dev\android-sdk` | SDK Android (platform 36, build-tools 36, NDK 28.2) |
| `ANDROID_USER_HOME` | `D:\dev\android-user-home` | Acá se crea `debug.keystore` (no en `C:\Users\...\.android`) |
| `GRADLE_USER_HOME` | `D:\dev\gradle-home` | Caché de Gradle |
| `PUB_CACHE` | `D:\dev\pub-cache` | Paquetes Dart |

Además Flutter tiene `flutter config --jdk-dir D:\dev\jdk-17 --android-sdk D:\dev\android-sdk`.

Usar siempre `flutter.bat`, `adb.exe` (no los alias sin extensión).

Chequeo rápido: `flutter.bat doctor -v` (el error de **Visual Studio** se puede
ignorar: solo hace falta para apps de escritorio Windows).

## 2. Compilar la APK debug

La APK debug va firmada con la keystore de debug (`D:\dev\android-user-home\debug.keystore`,
que Gradle crea sola la primera vez). Sirve para instalar a mano; no es para Play Store.

Hay dos variantes. **Elegir una** (el usuario todavía no eligió):

| Variante | Comando | Tamaño aprox. | Sirve en |
|---|---|---|---|
| A. Todas las ABI | `flutter.bat build apk --debug` | ~151 MB | cualquier Android (arm 32/64 bits, x86_64) |
| B. Solo arm64 | `flutter.bat build apk --debug --target-platform android-arm64` | ~78 MB | solo teléfonos de 64 bits ARM (la mayoría; el Galaxy M12 SM-M127F lo es) |

En una APK debug, las librerías nativas van sin comprimir y no se extraen al instalar:
el espacio que ocupa instalada es parecido al tamaño del archivo. La variante B ocupa
la mitad. Las dos se compilan con `TOOLS_ENABLED=false`.

**Antes de elegir la B**, con el teléfono conectado por USB (ver sección 3):

```powershell
. D:\dev\env_flutter.ps1
adb.exe shell getprop ro.product.cpu.abilist
```

Si la respuesta incluye `arm64-v8a` (por ejemplo `arm64-v8a,armeabi-v7a,armeabi`),
la B sirve. Si no aparece `arm64-v8a`, usar la A. Si no hay cable, usar la A.

```powershell
. D:\dev\env_flutter.ps1
cd R:\app_android
flutter.bat pub get
# Variante A (todas las ABI):
flutter.bat build apk --debug
# o Variante B (solo arm64):
flutter.bat build apk --debug --target-platform android-arm64
```

Salida (las dos variantes): `build\app\outputs\flutter-apk\app-debug.apk`.
La primera compilación descarga Gradle 9.3.1 y dependencias a `D:\dev\gradle-home` (tarda varios minutos).
Con log completo: agregar `-v` y redirigir, por ejemplo
`cmd /c "cd /d R:\app_android && flutter.bat build apk --debug -v > D:\dev\_logs\build_debug.log 2>&1"`.

Copiar a entregas con fecha y calcular el SHA-256:

```powershell
$fecha   = Get-Date -Format 'yyyy-MM-dd'
$destDir = 'd:\Moisés\Gramanova\entregas'
$dest    = Join-Path $destDir "cortadora_e7_debug_$fecha.apk"
New-Item -ItemType Directory -Force $destDir | Out-Null
Copy-Item 'build\app\outputs\flutter-apk\app-debug.apk' $dest
$h = (Get-FileHash -Algorithm SHA256 $dest).Hash.ToLower()
"$h  $(Split-Path $dest -Leaf)" | Out-File -Encoding ascii "$dest.sha256"
$h
```

Verificar la firma (opcional):

```powershell
& D:\dev\android-sdk\build-tools\36.0.0\apksigner.bat verify --print-certs $dest
```

Debe mostrar `CN=Android Debug`.

### Herramientas internas (`TOOLS_ENABLED`)

Por defecto la app se compila con `TOOLS_ENABLED=false`. Solo si se pide
expresamente una compilación con herramientas, hacerla **aparte** y con otro nombre:

```powershell
flutter.bat build apk --debug --dart-define=TOOLS_ENABLED=true
# copiar como: cortadora_e7_debug_tools_AAAA-MM-DD.apk
```

## 3. Instalar en el celular

### Opción A: por cable USB (adb)

1. En el teléfono: Ajustes > Acerca del teléfono > tocar 7 veces "Número de compilación"
   (activa Opciones de desarrollador). Luego Ajustes > Sistema > Opciones de desarrollador >
   activar **Depuración por USB**.
2. Conectar el cable y aceptar en el teléfono el cartel "¿Permitir depuración USB?".
3. En la PC:

```powershell
. D:\dev\env_flutter.ps1
adb.exe devices          # debe aparecer el equipo como "device" (no "unauthorized")
adb.exe install -r "d:\Moisés\Gramanova\entregas\cortadora_e7_debug_AAAA-MM-DD.apk"
```

`-r` reemplaza una versión anterior conservando los datos. Si falla con
`INSTALL_FAILED_UPDATE_INCOMPATIBLE` (firmada con otra keystore), desinstalar primero:
`adb.exe uninstall com.robotcortadora.cortadora_e7`.

### Opción B: sin cable (copiar el archivo)

1. Pasar el `.apk` al teléfono (cable en modo "Transferencia de archivos" a la carpeta
   `Download`, Google Drive, o mensaje a uno mismo). Comparar el SHA-256 si se quiere
   verificar la copia.
2. En el teléfono, abrir el archivo con la app **Archivos** (o desde Descargas).
3. Android va a avisar que no permite instalar apps de ese origen: tocar **Configuración** y
   activar **Permitir de esta fuente** para la app desde la que se abrió (Archivos / Chrome / Drive).
   (Android 8+ lo pide por app; en Android 7 o anterior es Ajustes > Seguridad > **Orígenes desconocidos**.)
4. Volver y tocar **Instalar**. Si Play Protect avisa "app no verificada", elegir
   **Instalar de todas formas** (es esperable en una APK debug propia).
5. Opcional: después desactivar de nuevo "Permitir de esta fuente".

## 4. Permisos de Bluetooth

Declarados en `android/app/src/main/AndroidManifest.xml`, según el README de
`flutter_blue_plus` 2.3.15 (sección "Add permissions for Android (No Location)"):

- Android 12 o superior: `BLUETOOTH_SCAN` (con `neverForLocation`) y `BLUETOOTH_CONNECT`.
  Al primer escaneo el sistema pide "Dispositivos cercanos". No pide ubicación.
- Android 11 o anterior: `BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION`
  (hasta API 30) y `ACCESS_COARSE_LOCATION` (hasta API 28). En estas versiones el
  sistema pide **ubicación** y además la **ubicación del teléfono debe estar encendida**
  para que el escaneo BLE encuentre equipos.
- Las features `bluetooth_le`, `bluetooth` y `location` están declaradas como no obligatorias
  (`required="false"`). Sin eso, los permisos de Bluetooth y ubicación las vuelven obligatorias
  de forma implícita. Solo afecta el filtro de Play Store; la app abre igual sin BLE, en modo simulado.

No usar `androidUsesFineLocation: true` en `startScan`: con `neverForLocation` y
`ACCESS_FINE_LOCATION` limitado a API 30, en Android 12+ ese permiso no se puede conceder
y el escaneo fallaría.

La APK **debug** incluye además `INTERNET` (viene del manifest `src/debug`, lo usa Flutter
para depurar / hot reload). El manifest principal no la declara.
