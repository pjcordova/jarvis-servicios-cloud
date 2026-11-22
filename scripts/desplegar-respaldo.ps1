# Pone en marcha el respaldo diario de Jarvis como servicio, de una vez y paso a paso.
# Se corre en la laptop del administrador (PowerShell), con Docker abierto y después del commit:
#   powershell -ExecutionPolicy Bypass -File C:\Users\Personal\Desktop\jarvis-app\scripts\desplegar-respaldo.ps1
# 1) La migración 020 en Neon. 2) La contraseña de jarvis_respaldo y las llaves de cifrado (la privada no sale de esta
# laptop). 3) El bucket privado en Google Cloud (borra solo lo de más de 14 días) y una cuenta de servicio que solo
# puede SUBIR archivos ahí. 4) Sube todo a la VM, levanta el respaldo y hace el primero en el momento.
# Nunca muestra un secreto en pantalla. Ver el README: "Respaldo diario de Jarvis como servicio".
# "Continue": en PowerShell 5.1 lo que gcloud escribe por stderr cortaría el script; cada paso revisa su código de salida.
$ErrorActionPreference = 'Continue'
$app = Split-Path -Parent $PSScriptRoot
$secretos = Join-Path $env:USERPROFILE '.jarvis'
$zona = 'us-east1-b'
$proyecto = '<TU_PROYECTO_GCP>'
$bucket = "jarvis-respaldos-$proyecto"
$cuenta = "jarvis-respaldo@$proyecto.iam.gserviceaccount.com"
$envBase = Join-Path $secretos 'servicio-respaldo.env'
$llaveGcs = Join-Path $secretos 'respaldo-gcs.json'
Set-Location $app

function Falla($mensaje) { Write-Host "`nNo se pudo: $mensaje" -ForegroundColor Red; exit 1 }
function Paso($texto) { Write-Host "`n$texto" -ForegroundColor Cyan }

$sinGuardar = git status --porcelain -- servicio-respaldo servicio-metricas monitoreo neon docker-compose.yml
if ($sinGuardar) { Falla 'hay cambios sin commit. Pídele a Claude el commit y vuelve a correr esto.' }

Paso 'PASO 1 de 4: la migración 020 en Neon'
Write-Host 'Se abre en el Bloc de notas. Copia todo (Ctrl+A, Ctrl+C), pégalo en el SQL Editor de Neon y dale Run.'
Start-Process notepad (Join-Path $secretos 'aplicar-020.sql')
Read-Host 'Cuando Neon diga que terminó (o si ya la habías aplicado), presiona Enter'

Paso 'PASO 2 de 4: la contraseña del rol de respaldo y las llaves de cifrado'
if (-not (Test-Path $envBase)) {
  node servicio-respaldo/preparar.mjs
  if ($LASTEXITCODE -ne 0) { Falla 'preparar la contraseña y las llaves (¿Docker está abierto?)' }
}
Write-Host 'Se abre una línea en el Bloc de notas. Cópiala, pégala en el SQL Editor de Neon y dale Run.'
Write-Host "La llave privada quedó en $secretos\respaldo-llave.txt: sin ella no se abren los respaldos. No la borres ni la compartas." -ForegroundColor Yellow
Start-Process notepad (Join-Path $secretos 'respaldo-rol.sql')
Read-Host 'Cuando Neon diga que terminó, presiona Enter'

Paso 'PASO 3 de 4: el bucket privado y la cuenta de servicio en Google Cloud'
gcloud storage buckets describe "gs://$bucket" --project=$proyecto --format='value(name)' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  gcloud storage buckets create "gs://$bucket" --project=$proyecto --location=us-east1 --uniform-bucket-level-access --public-access-prevention
  if ($LASTEXITCODE -ne 0) { Falla 'crear el bucket' }
}
$reglas = Join-Path $env:TEMP 'respaldo-14-dias.json'
'{"rule":[{"action":{"type":"Delete"},"condition":{"age":14}}]}' | Out-File -Encoding ascii $reglas
gcloud storage buckets update "gs://$bucket" --project=$proyecto --lifecycle-file=$reglas
if ($LASTEXITCODE -ne 0) { Falla 'poner la regla de 14 días' }
Remove-Item $reglas
gcloud iam service-accounts describe $cuenta --project=$proyecto --format='value(email)' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  gcloud iam service-accounts create jarvis-respaldo --project=$proyecto --display-name='Jarvis: subir respaldos'
  if ($LASTEXITCODE -ne 0) { Falla 'crear la cuenta de servicio' }
}
# Solo crear archivos en este bucket: no puede leerlos, borrarlos ni tocar nada más del proyecto.
gcloud storage buckets add-iam-policy-binding "gs://$bucket" --project=$proyecto --member="serviceAccount:$cuenta" --role=roles/storage.objectCreator --quiet | Out-Null
if ($LASTEXITCODE -ne 0) { Falla 'dar el permiso de subir al bucket' }
if (-not (Test-Path $llaveGcs)) {
  gcloud iam service-accounts keys create $llaveGcs --iam-account=$cuenta --project=$proyecto
  if ($LASTEXITCODE -ne 0) { Falla 'crear la llave de la cuenta de servicio' }
}
# El archivo para la VM: la base de preparar.mjs más el bucket y la cuenta de servicio (en una sola línea).
$credenciales = node -e "process.stdout.write(JSON.stringify(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))))" $llaveGcs
$envVm = Join-Path $env:TEMP 'servicio-respaldo.env'
((Get-Content $envBase -Raw) + "RESPALDO_BUCKET=$bucket`nRCLONE_CONFIG_GCS_SERVICE_ACCOUNT_CREDENTIALS='$credenciales'`n") | Out-File -Encoding ascii -NoNewline $envVm

Paso 'PASO 4 de 4: subir a la VM y hacer el primer respaldo (tarda unos minutos, no cierres esta ventana)'
gcloud compute instances start jarvis-demo --zone=$zona --quiet
if ($LASTEXITCODE -ne 0) { Remove-Item $envVm; Falla 'prender la VM' }
$paquete = Join-Path $env:TEMP 'jarvis-app.tar.gz'
git archive --format=tar.gz --prefix=jarvis-app/ -o $paquete HEAD
gcloud compute scp $paquete $envVm jarvis-demo:/tmp/ --zone=$zona --tunnel-through-iap
$subio = $LASTEXITCODE
Remove-Item $envVm, $paquete -ErrorAction SilentlyContinue
if ($subio -ne 0) { Falla 'subir los archivos a la VM' }
$enLaVm = 'sudo tar -xzf /tmp/jarvis-app.tar.gz -C /opt && sudo mv /tmp/servicio-respaldo.env /opt/jarvis-app/.env.respaldo && sudo chmod 600 /opt/jarvis-app/.env.respaldo && cd /opt/jarvis-app && sudo docker compose up -d --build respaldo metricas-servicio prometheus grafana && sudo docker compose restart prometheus && sudo docker compose exec -T respaldo /app/respaldar.sh'
gcloud compute ssh jarvis-demo --zone=$zona --tunnel-through-iap --command $enLaVm
if ($LASTEXITCODE -ne 0) { Falla 'el primer respaldo en la VM (mira el mensaje de arriba)' }

Write-Host "`nListo." -ForegroundColor Green
Write-Host "Arriba debe decir '[respaldo] listo'. Desde hoy se repite cada noche a las 3:00 y Grafana avisa si falla."
Write-Host 'Para comprobar que se puede recuperar: scripts\restaurar-respaldo.ps1 (lo prueba en tu Docker, sin tocar Neon).'
