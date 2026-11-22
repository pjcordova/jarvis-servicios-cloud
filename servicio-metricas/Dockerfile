# Colector de métricas de Jarvis como servicio (ver colector.js). Imagen chica: Node y el cliente de Postgres.
FROM node:24.11.1-bookworm-slim

WORKDIR /app
ENV NODE_ENV=production TZ=America/Lima
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY colector.js ./

USER node
EXPOSE 9465
HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:9465/salud').then((r) => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"
CMD ["node", "colector.js"]
