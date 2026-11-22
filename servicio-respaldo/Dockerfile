# Respaldo diario de Jarvis como servicio (ver respaldar.sh). pg_dump 18 copia Neon (Postgres 17 o 18), age cifra y
# rclone sube a Cloud Storage. Los secretos llegan por .env.respaldo (también la cuenta de servicio, en
# RCLONE_CONFIG_GCS_SERVICE_ACCOUNT_CREDENTIALS), nunca en la imagen.
FROM postgres:18-alpine
RUN apk add --no-cache age rclone tzdata ca-certificates
ENV TZ=America/Lima \
    RCLONE_CONFIG_GCS_TYPE="google cloud storage" \
    RCLONE_CONFIG_GCS_BUCKET_POLICY_ONLY=true
WORKDIR /app
COPY respaldar.sh programar.sh ./
RUN chmod 755 respaldar.sh programar.sh
ENTRYPOINT []
CMD ["/app/programar.sh"]
