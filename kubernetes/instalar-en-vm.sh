#!/bin/sh
# Corre EN LA VM (como root), lo llama scripts/desplegar-k8s.ps1 desde la laptop. Instala k3s si falta, importa la
# imagen del panel que subió la laptop (/tmp/jarvis-panel-k8s.tar.gz), aplica los manifiestos (/tmp/k8s) y publica
# el panel solo en Tailscale (:8445). Docker y lo que ya corre (cliente-a, cliente-b, monitoreo, respaldo) no se tocan.
# Quitar todo k3s, sin dejar rastro: /usr/local/bin/k3s-uninstall.sh  (y: tailscale serve --https=8445 off)
set -eu

if ! command -v k3s >/dev/null 2>&1; then
  echo "[k8s] instalando k3s (instalador oficial get.k3s.io, canal estable)..."
  # Sin Traefik ni el balanceador (no hacen falta), y con memoria reservada para el sistema y Docker: k3s desaloja
  # sus pods antes de que la VM se quede sin memoria (no hay swap).
  curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -s - \
    --disable=traefik --disable=servicelb --write-kubeconfig-mode=600 \
    --kubelet-arg=system-reserved=memory=300Mi \
    '--kubelet-arg=eviction-hard=memory.available<200Mi'
fi
for i in $(seq 1 60); do
  k3s kubectl get nodes 2>/dev/null | grep -q ' Ready' && break
  sleep 2
done
echo "[k8s] $(k3s --version | head -1)"

echo "[k8s] importando la imagen del panel..."
gunzip -c /tmp/jarvis-panel-k8s.tar.gz | k3s ctr images import - >/dev/null
rm -f /tmp/jarvis-panel-k8s.tar.gz

echo "[k8s] aplicando los manifiestos..."
k3s kubectl apply -f /tmp/k8s/panel.yaml -f /tmp/k8s/carga.yaml
# Misma etiqueta de imagen con contenido nuevo: reiniciar hace que las copias tomen la nueva.
k3s kubectl -n jarvis rollout restart deployment/panel
k3s kubectl -n jarvis rollout status deployment/panel --timeout=180s

echo "[k8s] publicando solo en Tailscale (:8445)..."
tailscale serve --bg --https=8445 http://127.0.0.1:30800 >/dev/null

echo
k3s kubectl -n jarvis get pods,svc,hpa
echo
free -m | head -2
echo "[k8s] listo"
