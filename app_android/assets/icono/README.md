# Icono de la app (Gramanova)

Dibujo propio y vectorial: un robot cortacésped de perfil (sin manija), con rueda
trasera grande y rueda loca delantera, sobre césped a franjas. No usa ninguna marca
ni imagen de terceros. Esta carpeta guarda **las fuentes**. Los PNG que usa Android
están en `android/app/src/main/res/` y se generan a partir de estas.

> Estado (13/11/2026): estas fuentes son la **versión 3, aprobada por la usuaria**.
> Los 21 recursos generados con flutter_launcher_icons 0.14.4 están copiados a `res/`
> (hashes verificados contra el proyecto generador). Licencia de flutter_launcher_icons: MIT.

| Archivo | Qué es |
|---|---|
| `fondo.svg` | Capa de fondo del icono adaptativo (108×108 dp) |
| `figura.svg` | Capa de figura, transparente. Entra en un círculo de radio ~32 dp; la zona segura es de 66 dp de diámetro |
| `monocromo.svg` | La misma silueta en un solo color, para los iconos temáticos de Android 13+ |
| `*_1024.png` | Los SVG rasterizados a 1024 px. `legado_1024.png` es fondo + figura recortado a la zona visible (72 dp), para Android 7 o anterior |
| `rasterizar.ps1` | SVG → PNG con Chrome headless (no descarga nada) |
| `flutter_launcher_icons.yaml` | Configuración usada para generar los tamaños |

## Regenerar (después de editar un SVG)

No se agrega nada al `pubspec.yaml` de la app. Se usa un proyecto Flutter descartable.

```powershell
. D:\dev\env_flutter.ps1
# 1. SVG -> PNG 1024 (se guardan en esta carpeta)
powershell -ExecutionPolicy Bypass -File R:\app_android\assets\icono\rasterizar.ps1

# 2. Proyecto descartable con flutter_launcher_icons 0.14.4 (licencia MIT)
#    (si D:\dev\_iconos\gen ya existe, saltear create y pub add)
cd D:\dev\_iconos
flutter.bat create --platforms android --no-pub --project-name gen gen
cd gen
flutter.bat pub add --dev flutter_launcher_icons:0.14.4
New-Item -ItemType Directory -Force icono | Out-Null
Copy-Item R:\app_android\assets\icono\*_1024.png icono\
Copy-Item R:\app_android\assets\icono\flutter_launcher_icons.yaml .
dart.bat run flutter_launcher_icons

# 3. Copiar a la app SOLO lo generado
$src = 'D:\dev\_iconos\gen\android\app\src\main\res'
$dst = 'R:\app_android\android\app\src\main\res'
Get-ChildItem -Recurse $src -File | Where-Object {
  ($_.Directory.Name -like 'mipmap-*'   -and $_.Name -like 'ic_launcher*') -or
  ($_.Directory.Name -like 'drawable-*' -and $_.Name -match '^ic_launcher_(foreground|background|monochrome)\.png$')
} | ForEach-Object {
  $d = Join-Path $dst $_.FullName.Substring($src.Length + 1)
  New-Item -ItemType Directory -Force (Split-Path $d) | Out-Null
  Copy-Item $_.FullName $d -Force
}
```

Comprobar que `res/mipmap-anydpi-v26/ic_launcher.xml` tenga `<background>`, `<foreground>`
y `<monochrome>` con `inset="0%"`, y que el manifest siga con
`android:icon="@mipmap/ic_launcher"`.

El inset es 0 porque el dibujo ya respeta la zona segura. El valor por defecto de la
herramienta (16%) achicaría la figura.
