# Lleva el panel de Jarvis como servicio a Kubernetes (k3s) en la VM de Google Cloud, paso a paso.
# Es la misma imagen que Cloud Run (panel/Dockerfile), con la banda "Réplica de Jarvis en Kubernetes (k3s)": la
# misma base de producción, sin secretos y sin la sección Administración. Vercel sigue siendo la dirección principal.
# k3s corre AL LADO de Docker: cliente-a, cliente-b, el monitoreo y el respaldo no se tocan.
# Se corre en la laptop del administrador (PowerShell), con Docker abierto y después del commit:
#   powershell -ExecutionPolicy Bypass -File C:\Users\Personal\Desktop\jarvis-app\scripts\desplegar-k8s.ps1
# La primera vez instala k3s en la VM con su instalador oficial (get.k3s.io). Para quitarlo: k8s/instalar-en-vm.sh.
# "Continue": en PowerShell 5.1 lo que docker o gcloud escriben por stderr cortaría el script; cada paso revisa su
# código de salida.
$ErrorActionPreference = 'Continue'
$app = Split-Path -Parent $PSScriptRoot
$secretos = Join-Path $env:USERPROFILE '.jarvis'
$zona = 'us-east1-b'
$url = 'https://<TU_MAQUINA>.<TU_TAILNET>.ts.net:8445'
Set-Location $app

function Falla($mensaje) { Write-Host "`nNo se pudo: $mensaje" -ForegroundColor Red; exit 1 }
function Paso($texto) { Write-Host "`n$texto" -ForegroundColor Cyan }

$sinGuardar = git status --porcelain -- panel k8s
if ($sinGuardar) { Falla 'hay cambios sin commit en el panel o en k8s. Pídele a Claude el commit y vuelve a correr esto.' }
docker version --format '{{.Server.Version}}' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Falla 'Docker no está abierto' }

Paso 'PASO 1 de 4: armar la imagen del panel para Kubernetes (tarda unos minutos)'
$local = Join-Path $app 'panel\.env.local'
if (-not (Test-Path $local)) { Falla 'no encontré panel\.env.local' }
$leer = { param($nombre) (Select-String -Path $local -Pattern "^$nombre=(.+)$").Matches.Groups[1].Value.Trim() }
$auth = & $leer 'NEXT_PUBLIC_NEON_AUTH_URL'
$dataApi = & $leer 'NEXT_PUBLIC_NEON_DATA_API_URL'
if (-not $auth -or -not $dataApi) { Falla 'faltan las direcciones de Neon en panel\.env.local' }
docker build -t jarvis-panel:k8s --build-arg "NEXT_PUBLIC_NEON_AUTH_URL=$auth" --build-arg "NEXT_PUBLIC_NEON_DATA_API_URL=$dataApi" `
  --build-arg "NEXT_PUBLIC_JARVIS_DONDE=Kubernetes (k3s)" panel
if ($LASTEXITCODE -ne 0) { Falla 'armar la imagen' }
$paquete = Join-Path $env:TEMP 'jarvis-panel-k8s.tar.gz'
Write-Host 'Empaquetando la imagen...'
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${env:TEMP}:/salida" docker:28-cli sh -c 'docker save jarvis-panel:k8s | gzip -1 > /salida/jarvis-panel-k8s.tar.gz'
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $paquete)) { Falla 'empaquetar la imagen' }

Paso 'PASO 2 de 4: subir la imagen y los manifiestos a la VM'
gcloud compute instances start jarvis-demo --zone=$zona --quiet
if ($LASTEXITCODE -ne 0) { Falla 'prender la VM' }
gcloud compute ssh jarvis-demo --zone=$zona --tunnel-through-iap --command 'rm -rf /tmp/k8s && mkdir -p /tmp/k8s'
gcloud compute scp $paquete jarvis-demo:/tmp/ --zone=$zona --tunnel-through-iap
$subio = $LASTEXITCODE
gcloud compute scp k8s/panel.yaml k8s/carga.yaml k8s/instalar-en-vm.sh jarvis-demo:/tmp/k8s/ --zone=$zona --tunnel-through-iap
Remove-Item $paquete -ErrorAction SilentlyContinue
if ($subio -ne 0 -or $LASTEXITCODE -ne 0) { Falla 'subir los archivos a la VM' }

Paso 'PASO 3 de 4: instalar k3s (la primera vez) y desplegar el panel (no cierres esta ventana)'
gcloud compute ssh jarvis-demo --zone=$zona --tunnel-through-iap --command 'sudo sh /tmp/k8s/instalar-en-vm.sh'
if ($LASTEXITCODE -ne 0) { Falla 'instalar o desplegar en la VM (mira el mensaje de arriba)' }

Paso 'PASO 4 de 4: permitir el login en la réplica de Kubernetes'
$marca = Join-Path $secretos 'k8s-dominio-listo.txt'
if (-not (Test-Path $marca)) {
  Write-Host 'En Neon, proyecto jarvis-servicio: Better Auth → Configure Auth → Domains → agrega:'
  Write-Host "  $url" -ForegroundColor Yellow
  Read-Host 'Cuando la hayas agregado, presiona Enter'
  Set-Content -Path $marca -Value $url -Encoding ascii
}
Write-Host "`nListo. Réplica en Kubernetes (solo por Tailscale): $url" -ForegroundColor Green
Write-Host 'Para la clase (dentro de la VM, con: gcloud compute ssh jarvis-demo --zone=us-east1-b --tunnel-through-iap):'
Write-Host '  sudo k3s kubectl -n jarvis get pods,hpa -w                          (ver copias y CPU en vivo)'
Write-Host '  sudo k3s kubectl -n jarvis scale deployment/carga --replicas=1      (prender la carga)'
Write-Host '  sudo k3s kubectl -n jarvis scale deployment/carga --replicas=0      (apagarla)'
Write-Host '  sudo k3s kubectl -n jarvis delete pod -l app=panel                  (autocuración)'
