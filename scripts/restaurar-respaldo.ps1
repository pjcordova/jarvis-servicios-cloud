# Comprueba que un respaldo de Jarvis como servicio se puede recuperar, sin tocar Neon: baja el último de Cloud Storage
# (o el archivo que le pases), lo descifra con la llave privada de esta laptop y lo restaura en un Postgres de Docker.
# Al final muestra cuántos negocios, personas y encargos trae, y borra la copia descifrada y el contenedor.
#   powershell -ExecutionPolicy Bypass -File C:\Users\Personal\Desktop\jarvis-app\scripts\restaurar-respaldo.ps1
#   ... -Archivo C:\ruta\jarvis-AAAA-MM-DD_HHMM.dump.age     (uno ya descargado)
#   ... -Dejar      (deja el Postgres corriendo en 127.0.0.1:5499 para revisarlo; se borra con: docker rm -f jarvis-restaurar)
# Es una copia con datos reales: no la muestres en demos ni la dejes en otras carpetas.
param([string]$Archivo, [switch]$Dejar, [string]$Llave = (Join-Path $env:USERPROFILE '.jarvis\respaldo-llave.txt'))
# "Continue": en PowerShell 5.1 lo que docker o gcloud escriben por stderr cortaría el script; cada paso revisa su
# código de salida.
$ErrorActionPreference = 'Continue'
$imagen = 'jarvis-servicio-respaldo:local' # la misma del respaldo: trae age y Postgres 18 (pg_restore)
$app = Split-Path -Parent $PSScriptRoot
$bucket = 'jarvis-respaldos-<TU_PROYECTO_GCP>'
$trabajo = Join-Path $env:TEMP 'jarvis-restaurar'
$contenedor = 'jarvis-restaurar'

function Falla($mensaje) { Write-Host "`nNo se pudo: $mensaje" -ForegroundColor Red; Limpiar; exit 1 }
function Limpiar {
  Remove-Item $trabajo -Recurse -Force -ErrorAction SilentlyContinue
  if (-not $Dejar) { docker rm -f $contenedor 2>$null | Out-Null }
}

if (-not (Test-Path $Llave)) { Falla "no está la llave privada ($Llave)" }
$carpetaLlave = Split-Path (Resolve-Path $Llave)
$nombreLlave = Split-Path $Llave -Leaf
docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Falla 'Docker no está abierto' }
New-Item -ItemType Directory -Force $trabajo | Out-Null
Write-Host 'Preparando la imagen del respaldo (la primera vez tarda un poco)...'
docker build -q -t $imagen "$app\servicio-respaldo" | Out-Null
if ($LASTEXITCODE -ne 0) { Falla 'armar la imagen de servicio-respaldo' }

if (-not $Archivo) {
  Write-Host 'Buscando el último respaldo en Cloud Storage...'
  $ultimo = gcloud storage ls "gs://$bucket/neon/" | Sort-Object | Select-Object -Last 1
  if (-not $ultimo) { Falla 'no hay respaldos en el bucket todavía' }
  Write-Host "Bajando $ultimo"
  gcloud storage cp $ultimo $trabajo
  if ($LASTEXITCODE -ne 0) { Falla 'bajar el respaldo' }
  $Archivo = Join-Path $trabajo (Split-Path $ultimo -Leaf)
} else {
  Copy-Item $Archivo $trabajo
  $Archivo = Join-Path $trabajo (Split-Path $Archivo -Leaf)
}
$nombre = Split-Path $Archivo -Leaf

Write-Host 'Descifrando con la llave de esta laptop...'
docker run --rm -v "${trabajo}:/d" -v "${carpetaLlave}:/k:ro" $imagen age -d -i "/k/$nombreLlave" -o /d/copia.dump "/d/$nombre"
if ($LASTEXITCODE -ne 0) { Falla 'descifrar (¿es la llave correcta?)' }

Write-Host 'Restaurando en un Postgres de Docker...'
docker rm -f $contenedor 2>$null | Out-Null
docker run -d --name $contenedor -e POSTGRES_PASSWORD=restaurar-local -p 127.0.0.1:5499:5432 --entrypoint docker-entrypoint.sh $imagen postgres | Out-Null
for ($i = 0; $i -lt 40; $i++) { Start-Sleep 1; docker exec $contenedor pg_isready -U postgres -q 2>$null; if ($LASTEXITCODE -eq 0) { break } }
Start-Sleep 2
docker cp "$app\neon\local\000_simulacion.sql" "${contenedor}:/tmp/simulacion.sql" | Out-Null
docker cp "$trabajo\copia.dump" "${contenedor}:/tmp/copia.dump" | Out-Null
Remove-Item "$trabajo\copia.dump" -Force # la copia descifrada no queda en la laptop
# Lo que Neon trae de por sí (auth.user_id y los roles), para que las reglas de la copia se puedan crear.
$roles = "do `$`$ begin " + (('jarvis_avisos', 'jarvis_reclamos', 'jarvis_metricas', 'jarvis_respaldo' | ForEach-Object {
  "if not exists (select 1 from pg_roles where rolname = '$_') then create role $_ nologin; end if;" }) -join ' ') + " end `$`$;"
docker exec $contenedor psql -U postgres -q -v ON_ERROR_STOP=1 -f /tmp/simulacion.sql | Out-Null
docker exec $contenedor psql -U postgres -q -c $roles | Out-Null
# La copia trae su propio esquema public: el de este Postgres recién creado (vacío) se quita antes.
docker exec $contenedor psql -U postgres -q -c 'drop schema public cascade;' | Out-Null
docker exec $contenedor pg_restore -U postgres -d postgres --no-owner --exit-on-error /tmp/copia.dump
if ($LASTEXITCODE -ne 0) { Falla 'restaurar la copia' }
docker exec $contenedor rm -f /tmp/copia.dump

$conteo = "select (select count(*) from organizaciones) as negocios, (select count(*) from perfiles) as personas, (select count(*) from encargos) as encargos, (select count(*) from proyectos) as proyectos, (select count(*) from publicaciones) as publicaciones;"
Write-Host "`nLa copia $nombre se restauró bien y trae:" -ForegroundColor Green
docker exec $contenedor psql -U postgres -c $conteo
Limpiar
if ($Dejar) { Write-Host 'El Postgres queda en 127.0.0.1:5499 (usuario postgres, clave restaurar-local). Bórralo con: docker rm -f jarvis-restaurar' }
