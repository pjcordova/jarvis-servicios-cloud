#!/bin/sh
# Un respaldo de Jarvis como servicio: copia la base de Neon, la cifra y la sube a Cloud Storage.
# - pg_dump con el rol jarvis_respaldo (migración 020: solo lee), en formato custom (pg_restore).
# - age la cifra con la llave PÚBLICA: solo la llave privada, que vive en la laptop del administrador, puede abrirla.
#   La copia sin cifrar nunca se escribe en disco: va de pg_dump a age por una tubería.
# - rclone la sube al bucket con una cuenta de servicio que solo puede CREAR archivos (no leer ni borrar).
#   El bucket borra solo los de más de 14 días.
# - Deja el resultado en /estado/respaldo.json: el colector de métricas lo muestra en Grafana.
# A mano, en la VM: sudo docker compose exec respaldo /app/respaldar.sh
set -eu

: "${NEON_RESPALDO_URL:?falta NEON_RESPALDO_URL (.env.respaldo)}"
: "${RESPALDO_LLAVE_PUBLICA:?falta RESPALDO_LLAVE_PUBLICA (.env.respaldo)}"
: "${RESPALDO_BUCKET:?falta RESPALDO_BUCKET (.env.respaldo)}"

fecha=$(date +%Y-%m-%d_%H%M)
archivo="/tmp/jarvis-$fecha.dump.age"
inicio=$(date +%s)
mkdir -p /estado

estado() { # ok bytes mensaje
  if [ "$1" = 1 ]; then date +%s > /estado/ultimo_ok; fi
  ultimo=$(cat /estado/ultimo_ok 2>/dev/null || echo 0)
  printf '{"ok":%s,"intento":%s,"ultimo_ok":%s,"bytes":%s,"mensaje":"%s"}\n' \
    "$1" "$(date +%s)" "$ultimo" "$2" "$3" > /estado/respaldo.json
}
falla() { echo "[respaldo] FALLÓ: $1"; estado 0 0 "$1"; rm -f "$archivo"; exit 1; }

echo "[respaldo] empieza $fecha"
# set -o pipefail no existe en todos los sh: el resultado de pg_dump se revisa aparte.
( pg_dump "$NEON_RESPALDO_URL" --schema=public --enable-row-security --no-owner --no-privileges --format=custom \
    || echo fallo > /tmp/pg_dump.fallo ) | age -r "$RESPALDO_LLAVE_PUBLICA" > "$archivo" || falla "no se pudo cifrar"
if [ -f /tmp/pg_dump.fallo ]; then rm -f /tmp/pg_dump.fallo; falla "pg_dump no pudo copiar la base"; fi

bytes=$(wc -c < "$archivo" | tr -d ' ')
[ "$bytes" -gt 1024 ] || falla "la copia salió casi vacía ($bytes bytes)"

rclone copyto "$archivo" "gcs:$RESPALDO_BUCKET/neon/jarvis-$fecha.dump.age" \
  --gcs-bucket-policy-only --gcs-no-check-bucket --no-check-dest --retries 3 \
  || falla "no se pudo subir a Cloud Storage"

rm -f "$archivo"
estado 1 "$bytes" "ok"
echo "[respaldo] listo: jarvis-$fecha.dump.age, $bytes bytes, en $(( $(date +%s) - inicio )) s"
