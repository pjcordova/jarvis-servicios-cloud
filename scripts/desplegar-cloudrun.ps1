# Despliega la RÉPLICA de Jarvis como servicio en Google Cloud Run, paso a paso.
# Es el mismo panel y la misma base (Neon, proyecto jarvis-servicio) que Vercel, en un contenedor en otra nube.
# Vercel sigue siendo la dirección principal. Hoy sirve para mostrar en el curso que el servicio corre en Google
# Cloud; con un dominio propio, será el plan B (si Vercel cae, se cambia el DNS a esta réplica).
# En la réplica no aparece Administración (en clase no se ven nombres de clientes) y no hay avisos, cobros por correo
# ni reclamos (no lleva secretos).
# Se corre en la laptop del administrador (PowerShell), con Docker abierto y después del commit:
#   powershell -ExecutionPolicy Bypass -File C:\Users\Personal\Desktop\jarvis-app\scripts\desplegar-cloudrun.ps1
# "Continue": en PowerShell 5.1 lo que docker o gcloud escriben por stderr cortaría el script; cada paso revisa su
# código de salida.
$ErrorActionPreference = 'Continue'
$app = Split-Path -Parent $PSScriptRoot
$secretos = Join-Path $env:USERPROFILE '.jarvis'
$proyecto = '<TU_PROYECTO_GCP>'
$region = 'us-east1'
$servicio = 'jarvis-panel'
$imagen = "$region-docker.pkg.dev/$proyecto/jarvis/panel"
Set-Location $app

function Falla($mensaje) { Write-Host "`nNo se pudo: $mensaje" -ForegroundColor Red; exit 1 }
function Paso($texto) { Write-Host "`n$texto" -ForegroundColor Cyan }

$sinGuardar = git status --porcelain -- panel
if ($sinGuardar) { Falla 'hay cambios sin commit en el panel. Pídele a Claude el commit y vuelve a correr esto.' }
docker version --format '{{.Server.Version}}' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Falla 'Docker no está abierto' }

Paso 'PASO 1 de 4: las direcciones de Neon (las mismas de Vercel; son públicas, no claves)'
$local = Join-Path $app 'panel\.env.local'
if (-not (Test-Path $local)) { Falla 'no encontré panel\.env.local' }
$leer = { param($nombre) (Select-String -Path $local -Pattern "^$nombre=(.+)$").Matches.Groups[1].Value.Trim() }
$auth = & $leer 'NEXT_PUBLIC_NEON_AUTH_URL'
$dataApi = & $leer 'NEXT_PUBLIC_NEON_DATA_API_URL'
if (-not $auth -or -not $dataApi) { Falla 'faltan NEXT_PUBLIC_NEON_AUTH_URL o NEXT_PUBLIC_NEON_DATA_API_URL en panel\.env.local' }
Write-Host 'Listas.'

Paso 'PASO 2 de 4: armar la imagen del panel (tarda unos minutos)'
docker build -t "${imagen}:latest" --build-arg "NEXT_PUBLIC_NEON_AUTH_URL=$auth" --build-arg "NEXT_PUBLIC_NEON_DATA_API_URL=$dataApi" panel
if ($LASTEXITCODE -ne 0) { Falla 'armar la imagen' }

Paso 'PASO 3 de 4: subirla a Google Cloud y desplegar en Cloud Run'
gcloud services enable run.googleapis.com artifactregistry.googleapis.com --project=$proyecto
if ($LASTEXITCODE -ne 0) { Falla 'activar Cloud Run y Artifact Registry' }
gcloud artifacts repositories describe jarvis --location=$region --project=$proyecto --format='value(name)' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  gcloud artifacts repositories create jarvis --repository-format=docker --location=$region --project=$proyecto --description='Imágenes de Jarvis'
  if ($LASTEXITCODE -ne 0) { Falla 'crear el repositorio de imágenes' }
}
gcloud auth configure-docker "$region-docker.pkg.dev" --quiet 2>$null | Out-Null
docker push "${imagen}:latest"
if ($LASTEXITCODE -ne 0) { Falla 'subir la imagen' }
# Escala a cero (no cobra si nadie entra) y como mucho 3 instancias (límite de gasto).
gcloud run deploy $servicio --image="${imagen}:latest" --region=$region --project=$proyecto --allow-unauthenticated `
  --port=8080 --cpu=1 --memory=512Mi --min-instances=0 --max-instances=3 --concurrency=80 --quiet
if ($LASTEXITCODE -ne 0) { Falla 'desplegar en Cloud Run' }
$url = gcloud run services describe $servicio --region=$region --project=$proyecto --format='value(status.url)'

Paso 'PASO 4 de 4: permitir el login en la réplica'
$marca = Join-Path $secretos 'cloudrun-dominio-listo.txt'
if (-not (Test-Path $marca) -or (Get-Content $marca) -ne $url) {
  Write-Host "En Neon, proyecto jarvis-servicio: Auth → Domains → agrega esta dirección (si no, el login da 403):"
  Write-Host "  $url" -ForegroundColor Yellow
  Read-Host 'Cuando la hayas agregado, presiona Enter'
  Set-Content -Path $marca -Value $url -Encoding ascii
}
Write-Host "`nListo. Réplica en Cloud Run: $url" -ForegroundColor Green
Write-Host 'La dirección principal sigue siendo https://<TU_PANEL>.vercel.app'
Write-Host 'En clase: entra con tu cuenta, muestra tu propio contenido y, de los demás, solo los totales de Grafana.'
