# Rasteriza las capas SVG de esta carpeta a PNG de 1024x1024 con Chrome headless
# (no descarga nada). Uso, desde PowerShell:
#   powershell -ExecutionPolicy Bypass -File R:\app_android\assets\icono\rasterizar.ps1
# Genera: fondo_1024.png, figura_1024.png, monocromo_1024.png (capas, 108 dp -> 1024 px)
# y legado_1024.png (fondo + figura, recortado a la zona visible de 72 dp).
$ErrorActionPreference = 'Stop'
$aqui   = $PSScriptRoot
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$tmp    = 'D:\dev\_iconos\render'          # HTML temporales y perfil de Chrome: fuera de C:
New-Item -ItemType Directory -Force $tmp, "$tmp\..\chrome-perfil" | Out-Null
$base = 'file:///' + ($aqui -replace '\\','/')
$full = 'style="left:0;top:0;width:1024px;height:1024px"'
$crop = 'style="left:-256px;top:-256px;width:1536px;height:1536px"'   # 108 dp -> ver 18..90
$paginas = [ordered]@{
  fondo     = "<img $full src=`"$base/fondo.svg`">"
  figura    = "<img $full src=`"$base/figura.svg`">"
  monocromo = "<img $full src=`"$base/monocromo.svg`">"
  legado    = "<img $crop src=`"$base/fondo.svg`"><img $crop src=`"$base/figura.svg`">"
}
$cab = '<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;background:transparent;overflow:hidden}.c{position:relative;width:1024px;height:1024px;overflow:hidden}.c img{position:absolute;display:block}</style></head><body><div class="c">'
foreach ($k in $paginas.Keys) {
  $html = Join-Path $tmp "$k.html"; $png = Join-Path $aqui "${k}_1024.png"
  [IO.File]::WriteAllText($html, $cab + $paginas[$k] + '</div></body></html>')
  if (Test-Path $png) { Remove-Item $png -Confirm:$false }
  $a = @('--headless=new','--disable-gpu','--hide-scrollbars','--no-first-run','--no-default-browser-check',
         "--user-data-dir=$tmp\..\chrome-perfil",'--force-device-scale-factor=1','--default-background-color=00000000',
         '--window-size=1024,1024', "--screenshot=$png", ('file:///' + ($html -replace '\\','/')))
  Start-Process -FilePath $chrome -ArgumentList $a -Wait -WindowStyle Hidden
  if (-not (Test-Path $png)) { throw "Chrome no genero $png" }
  "ok  $png"
}