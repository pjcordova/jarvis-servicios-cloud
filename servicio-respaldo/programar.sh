#!/bin/sh
# Corre el respaldo todos los días a la hora RESPALDO_HORA (hora de Lima; por defecto 03:00), cuando casi nadie usa
# Jarvis. Duerme hasta esa hora: no consulta nada mientras espera. Si un respaldo falla, el siguiente es al otro día
# (y Grafana lo muestra: alerta RespaldoAtrasado).
hora="${RESPALDO_HORA:-03:00}"
echo "[respaldo] programado todos los días a las $hora ($(date +%Z))"
while true; do
  ahora=$(date +%s)
  objetivo=$(date -d "$(date +%Y-%m-%d) $hora" +%s)
  [ "$objetivo" -le "$ahora" ] && objetivo=$((objetivo + 86400))
  sleep $((objetivo - ahora))
  /app/respaldar.sh || true
done
