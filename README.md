# Jarvis en la nube — infraestructura

Infraestructura cloud del asistente **Jarvis**, entregable del proyecto final del curso **Servicios Cloud** (UTP).

Aquí está lo que despliega y sostiene el sistema: contenedores, orquestación, monitoreo, alertas, respaldo y
despliegue. **El código del asistente no es parte de este repositorio**: vive en un repositorio privado, porque es un
producto en uso. Lo que se publica es la capa de infraestructura, que es lo que evalúa el curso.

## Qué hay

| Carpeta | Contenido |
| --- | --- |
| `docker/` | Dockerfiles de Jarvis y del panel (construcción en dos etapas, usuario sin privilegios) |
| `docker-compose.yml` | Los 6 servicios de la demo, con límites de CPU y memoria |
| `kubernetes/` | Manifiestos de k3s: Deployment, Service y escalado automático (HPA), más el generador de carga |
| `monitoring/` | Prometheus, reglas de alerta con sus pruebas, Alertmanager y dos tableros de Grafana |
| `servicio-metricas/` | Colector que lee totales de la base una vez por hora y los expone a Prometheus |
| `servicio-respaldo/` | Respaldo diario cifrado a Cloud Storage |
| `scripts/` | Despliegue en Cloud Run y en k3s, publicación del monitoreo, respaldo y restauración |
| `docs/` | Arquitectura y correspondencia con la rúbrica |

## Arquitectura, en corto

Una máquina virtual **e2-medium** (2 vCPU, 4 GB) en Google Compute Engine, **sin IP pública**:

- **Docker Compose** corre un Jarvis por cliente más Prometheus, Alertmanager, Grafana, el colector de métricas y el
  respaldo. Cada contenedor tiene límites de memoria y CPU; la VM no tiene swap, así que los límites son reales.
- **k3s** (Kubernetes liviano) corre al lado, con el panel y un **HorizontalPodAutoscaler** de 1 a 3 copias.
- **Cloud Run** tiene una réplica del panel que escala a cero: es el plan de contingencia en otra nube.
- La base de datos es **PostgreSQL gestionado (Neon)**, con aislamiento por fila (RLS) por organización.
- No hay puertos abiertos a internet: todo se publica en `127.0.0.1` y se llega por **Tailscale**. La salida a internet
  va por **Cloud NAT** y la administración por **IAP**.

El detalle está en [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md).

## Cómo se levanta

```bash
cp .env.demo.example .env.demo     # y poner la API key de Gemini
docker compose up -d
docker compose ps                  # los contenedores deben decir healthy
```

- Jarvis: `http://127.0.0.1:3747` · Grafana: `http://127.0.0.1:3030`
- Prometheus: `http://127.0.0.1:9090` · Alertmanager: `http://127.0.0.1:9093`

Kubernetes, sobre la VM:

```bash
bash kubernetes/instalar-en-vm.sh
kubectl apply -f kubernetes/panel.yaml
kubectl get pods,hpa -n jarvis -w
```

Las pruebas de escalado y de autocuración:

```bash
kubectl apply -f kubernetes/carga.yaml      # sube de 1 a 3 copias
kubectl delete pod -n jarvis <pod>          # se recrea solo
kubectl delete -f kubernetes/carga.yaml     # vuelve a 1
```

## Valores por completar

Los datos de la instalación real van como marcadores. Hay que reemplazarlos por los propios:

| Marcador | Qué es |
| --- | --- |
| `<TU_PROYECTO_GCP>` | El id del proyecto de Google Cloud |
| `<TU_MAQUINA>.<TU_TAILNET>.ts.net` | La dirección de la VM dentro de Tailscale |
| `<TU_PANEL>.vercel.app` | La dirección del panel |
| `jarvis-respaldos-<TU_PROYECTO_GCP>` | El bucket de Cloud Storage de los respaldos |

## Secretos

**Este repositorio no tiene ninguna credencial.** Las claves se generan con los scripts `preparar.mjs` y quedan en
archivos `.env` que nunca entran en Git (ver `.gitignore`). Cada servicio usa un rol de base de datos distinto, con el
mínimo privilegio: el colector solo lee totales y el respaldo solo lee.

La llave privada que descifra los respaldos vive únicamente en la laptop del administrador: ni en la VM, ni en la nube,
ni aquí.

## Resultados medidos

| Prueba | Resultado |
| --- | --- |
| Escalado con carga (HPA) | 3 copias a los 60 s |
| Autocuración de un pod borrado | nueva copia lista en 10 s |
| Vuelta al reposo sin carga | 1 copia a los 150 s |
| Memoria en el pico, con k3s y Docker a la vez | 1.7 GB usados de 4 GB |
| Respaldo | diario, cifrado, con restauración verificada |

---

Proyecto final del curso Servicios Cloud (100000S91T) — Universidad Tecnológica del Perú, 2026.
