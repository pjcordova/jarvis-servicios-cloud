# Jarvis de cada cliente en el monitoreo

Cada cliente con su propio Jarvis (ver "Varios clientes" en el README) se agrega a Prometheus con un archivo
`<cliente>.json` en esta carpeta. Prometheus lo lee solo (sin reiniciar), y el Jarvis de ese cliente aparece
en Grafana y en las alertas con la etiqueta `cliente`.

```json
[{ "targets": ["jarvis-cliente-b:9464"], "labels": { "cliente": "cliente-b" } }]
```

Los `.json` de esta carpeta no entran en Git: dependen de cada servidor.
