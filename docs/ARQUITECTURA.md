# Arquitectura

Documento de apoyo del repositorio de infraestructura. El informe técnico del curso desarrolla cada punto;
aquí está lo necesario para leer los archivos de este repositorio y reproducir el despliegue.

## 1. El sistema base

Jarvis es un asistente con inteligencia artificial que se usa por voz y por texto. El proyecto tiene tres piezas:

| Pieza | Dónde corre | Qué aporta al curso |
| --- | --- | --- |
| Asistente personal | Una laptop | El sistema previo que se lleva a la nube |
| Demo multicliente | VM en Google Compute Engine | Contenedores, orquestación y monitoreo |
| Jarvis como servicio | Panel en Vercel + PostgreSQL gestionado | Aislamiento por cliente y respaldo |

Este repositorio cubre la segunda y la tercera: lo que vive en la nube.

## 2. Requerimientos y dimensionamiento

La VM es una **e2-medium**: 2 vCPU y 4 GB de memoria, en `us-east1-b`, **sin swap**. Que no haya swap es una decisión
de diseño: obliga a que los límites de memoria de cada contenedor sean reales y a presupuestarlos.

| Servicio | Memoria | CPU | Por qué |
| --- | --- | --- | --- |
| Jarvis (por cliente) | 512 MB | 1.0 | Node con la sesión de voz abierta |
| Prometheus | 256 MB | — | 15 días de series temporales |
| Alertmanager | 128 MB | — | Solo agrupa y envía |
| Colector de métricas | 128 MB | 0.25 | Una consulta por hora |
| Respaldo | 256 MB | 0.5 | `pg_dump` canalizado al cifrador |
| Grafana | 768 MB | — | Con 512 MB el kernel lo mataba (OOM); es Go, así que además lleva `GOMEMLIMIT` |
| k3s | ~650 MB | — | Nodo, servidor de API y el panel |

En el pico, con Docker y k3s a la vez, se midieron **1.7 GB usados de 4 GB**.

## 3. Modelo de despliegue

Es **híbrido**, y cada pieza se eligió por una razón:

| Capa | Modelo | Servicio | Por qué |
| --- | --- | --- | --- |
| Cómputo de la demo | IaaS | Compute Engine | Hace falta controlar Docker y el kernel |
| Panel | PaaS | Vercel y Cloud Run | Escala solo y no hay servidor que mantener |
| Base de datos | DBaaS | PostgreSQL gestionado (Neon) | Respaldos y réplicas sin administrarlos |
| Respaldos | Almacenamiento de objetos | Cloud Storage | Barato, con ciclo de vida a 14 días |

## 4. Red y seguridad

- La VM **no tiene IP pública**. La salida a internet va por **Cloud NAT**.
- La administración entra por **IAP**, no por SSH abierto.
- Todos los puertos de los contenedores se publican en `127.0.0.1`. Nada escucha en la red.
- El acceso de las personas va por **Tailscale**, con etiquetas: cada cliente solo alcanza su propio Jarvis. Está
  comprobado que con la clave de otro cliente la respuesta es **401**.
- Cada servicio usa su **propio rol de base de datos**, con el mínimo privilegio. El colector de métricas solo lee
  totales agregados; el respaldo solo lee.
- Los datos de cada organización se separan con **aislamiento por fila (RLS)** en PostgreSQL: la regla la aplica la
  base, no la aplicación.

## 5. Contenedores y orquestación

**Docker Compose** (`docker-compose.yml`) levanta los 6 servicios. Todos con `restart: unless-stopped`, con límites de
memoria y CPU, e `init: true` donde corre Node, para que las señales lleguen al proceso y el contenedor cierre limpio.

Las imágenes se fijan con versión exacta (`prom/prometheus:v3.13.5`, `grafana/grafana:13.2.4`): nada de `latest`, para
que el despliegue sea reproducible.

**Kubernetes (k3s)** corre *al lado* de Docker en la misma VM, no en vez de él. El panel va ahí:

- `Deployment` con sondas de vida y de disponibilidad, `requests` y `limits`, y sin privilegios de root.
- `Service` de tipo `NodePort`, publicado solo dentro de Tailscale.
- `HorizontalPodAutoscaler` de 1 a 3 copias, con `behavior` para que suba rápido y baje despacio.

Se eligió k3s sobre minikube o kind porque es un Kubernetes completo que cabe en 4 GB junto con Docker.

## 6. Monitoreo

- **Prometheus** recoge las métricas cada 15 segundos y las guarda 15 días. Descubre el Jarvis de cada cliente leyendo
  archivos de `monitoring/clientes/`, sin reiniciarse.
- **4 reglas de alerta**, con sus **pruebas** en `monitoring/alertas.test.yml`, que se verifican con
  `promtool test rules`. Las reglas se prueban como se prueba el código.
- **Alertmanager** agrupa y envía los avisos.
- **Dos tableros de Grafana** aprovisionados desde archivo, no hechos a mano: uno de la demo y otro del servicio.

## 7. Escalabilidad

| Tipo | Dónde | Cómo |
| --- | --- | --- |
| Horizontal automática | k3s | HPA de 1 a 3 copias según el uso de CPU |
| Horizontal gestionada | Cloud Run | De 0 a 3 instancias; escala a cero cuando nadie entra |
| Vertical | Compute Engine | Cambiar el tipo de máquina, con la VM detenida |
| Por cliente | Docker Compose | Un contenedor por cliente, con su propio límite |

Medido en la VM: con carga, **3 copias a los 60 segundos**; sin carga, vuelve a **1 copia a los 150 segundos**.

## 8. Resiliencia

| Mecanismo | Estado | Cómo se comprueba |
| --- | --- | --- |
| Reinicio automático de contenedores | Implementado | Detener un contenedor y verlo volver |
| Autocuración de pods | Implementado | Borrar un pod: copia nueva lista en 10 s |
| Actualización progresiva y reversión | Implementado | `kubectl rollout undo` |
| Respaldo diario cifrado | Implementado | Restauración verificada con los mismos conteos |
| Réplica en otra nube | Implementado | Cloud Run, pendiente de dominio propio para conmutar |
| Alta disponibilidad multizona | **Propuesto** | No implementado: hoy hay una sola VM |

Conviene decirlo con claridad: **la VM es un punto único de falla**. Si cae, caen el servicio de la demo y el monitoreo
a la vez. La arquitectura multizona con balanceador está diseñada y documentada, pero no desplegada; el costo no lo
justifica para una demo de curso.

### Respaldo

Cada noche a las 3:00, la VM copia la base, la cifra con una **llave pública** y la sube a un bucket privado. La copia
sin cifrar nunca toca el disco: va de `pg_dump` al cifrador por una tubería. El bucket borra solo lo que pasa de
**14 días**.

La **llave privada vive únicamente en la laptop del administrador**: ni en la VM, ni en el bucket, ni en este
repositorio. Si se pierde, los respaldos no se abren. Es el precio de que nadie más pueda leerlos.

## 9. Correspondencia con la rúbrica

| Criterio | Dónde mirar en este repositorio |
| --- | --- |
| 1. Análisis y arquitectura base | Secciones 1 a 3 de este documento |
| 2. Contenedorización y orquestación | `docker/`, `docker-compose.yml`, `kubernetes/` |
| 3. Infraestructura, monitoreo y escalabilidad | Secciones 4, 6 y 7; `monitoring/`, `scripts/` |
| 4. Resiliencia y patrones de diseño | Sección 8; `servicio-respaldo/`, `kubernetes/panel.yaml` |
| 5. Sustentación | Comandos del README y del informe técnico |
