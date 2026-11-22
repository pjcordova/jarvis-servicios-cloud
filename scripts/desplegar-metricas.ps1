# Pone en marcha el monitoreo de Jarvis como servicio en la VM de Google Cloud, de una vez y paso a paso.
# Se corre en la laptop del administrador (PowerShell), después del commit:
#   powershell -ExecutionPolicy Bypass -File C:\Users\Personal\Desktop\jarvis-app\scripts\desplegar-metricas.ps1
# 1) Abre la migración 019 para pegarla en Neon. 2) Genera la contraseña de jarvis_metricas (si falta) y abre su SQL.
# 3) Prende la VM, sube el código y la conexión, y levanta el colector, Prometheus y Grafana.
# Nunca muestra la contraseña en pantalla. Ver el README: "Jarvis como servicio en el monitoreo".
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$secretos = Join-Path $env:USERPROFILE '.jarvis'
$zona = 'us-east1-b'
Set-Location $app

function Falla($mensaje) { Write-Host "`nNo se pudo: $mensaje" -ForegroundColor Red; exit 1 }

# Lo que se sube es lo que tiene commit: si falta, se avisa antes de empezar.
$sinGuardar = git status --porcelain -- servicio-metricas monitoreo neon docker-compose.yml
if ($sinGuardar) { Falla 'hay cambios sin commit en el monitoreo. Pídele a Claude el commit y vuelve a correr esto.' }

Write-Host "`nPASO 1 de 3: la migración 019 en Neon" -ForegroundColor Cyan
Write-Host 'Se abre en el Bloc de notas. Copia todo (Ctrl+A, Ctrl+C), pégalo en el SQL Editor de Neon y dale Run.'
Start-Process notepad (Join-Path $secretos 'aplicar-019.sql')
Read-Host 'Cuando Neon diga que terminó (o si ya la habías aplicado), presiona Enter'

Write-Host "`nPASO 2 de 3: la contraseña del rol de métricas" -ForegroundColor Cyan
if (-not (Test-Path (Join-Path $secretos 'servicio-metricas.env'))) {
  node servicio-metricas/preparar.mjs
  if ($LASTEXITCODE -ne 0) { Falla 'generar la contraseña' }
}
Write-Host 'Se abre una línea en el Bloc de notas. Cópiala, pégala en el SQL Editor de Neon y dale Run.'
Start-Process notepad (Join-Path $secretos 'metricas-rol.sql')
Read-Host 'Cuando Neon diga que terminó, presiona Enter'

Write-Host "`nPASO 3 de 3: subir a la VM (tarda unos minutos, no cierres esta ventana)" -ForegroundColor Cyan
gcloud compute instances start jarvis-demo --zone=$zona --quiet
if ($LASTEXITCODE -ne 0) { Falla 'prender la VM' }
$paquete = Join-Path $env:TEMP 'jarvis-app.tar.gz'
git archive --format=tar.gz --prefix=jarvis-app/ -o $paquete HEAD
gcloud compute scp $paquete (Join-Path $secretos 'servicio-metricas.env') jarvis-demo:/tmp/ --zone=$zona --tunnel-through-iap
if ($LASTEXITCODE -ne 0) { Falla 'subir los archivos a la VM' }
$enLaVm = 'sudo tar -xzf /tmp/jarvis-app.tar.gz -C /opt && sudo mv /tmp/servicio-metricas.env /opt/jarvis-app/.env.servicio && sudo chmod 600 /opt/jarvis-app/.env.servicio && cd /opt/jarvis-app && sudo docker compose up -d --build metricas-servicio prometheus grafana && sudo docker compose restart prometheus && sleep 25 && sudo docker compose logs --tail 5 metricas-servicio'
gcloud compute ssh jarvis-demo --zone=$zona --tunnel-through-iap --command $enLaVm
if ($LASTEXITCODE -ne 0) { Falla 'levantar el colector en la VM' }
Remove-Item $paquete -ErrorAction SilentlyContinue

Write-Host "`nListo." -ForegroundColor Green
Write-Host "Si arriba dice 'lectura ok', abre https://<TU_MAQUINA>.<TU_TAILNET>.ts.net:3030 y busca el tablero 'Jarvis como servicio'."
Write-Host "Si dice que falló, mándale a Claude una captura de esta ventana."
