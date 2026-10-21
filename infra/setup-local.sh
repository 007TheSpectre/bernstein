#!/usr/bin/env bash
#
# Provisions the local platform used to run the Poll application:
#   1. a multi-node kubernetes cluster (kind: 1 control-plane + 2 workers)
#   2. a private docker registry with authentication (port 5000)
#   3. a TCP forwarder exposing the cluster API to the CI runner (port 16443)
#   4. the ingress-nginx controller (NodePort 30080)
#   5. the metrics server (for autoscaling and `kubectl top`)
#
# Idempotent: safe to re-run.
#
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=bernstein
REGISTRY_PORT=5000
INGRESS_HTTP_PORT=30080

# --- 1. cluster -----------------------------------------------------------
if kind get clusters | grep -qx "$CLUSTER"; then
  echo "==> cluster '$CLUSTER' already exists"
else
  echo "==> creating cluster '$CLUSTER' (this takes a few minutes)"
  kind create cluster --name "$CLUSTER" --config kind-config.yaml
fi
kubectl config use-context "kind-$CLUSTER"

# --- 2. private registry ---------------------------------------------------
REGISTRY_USER="${REGISTRY_USER:-polluser}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-pollpass2026}"
mkdir -p registry/data
docker run --rm httpd:2-alpine htpasswd -Bbn "$REGISTRY_USER" "$REGISTRY_PASSWORD" > registry/htpasswd
docker rm -f local-registry >/dev/null 2>&1 || true
echo "==> starting the private registry on :$REGISTRY_PORT (user: $REGISTRY_USER)"
docker run -d --name local-registry --restart unless-stopped \
  -p "$REGISTRY_PORT:$REGISTRY_PORT" \
  -v "$PWD/registry/data:/var/lib/registry" \
  -v "$PWD/registry/htpasswd:/auth/htpasswd:ro" \
  -e REGISTRY_AUTH=htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_REALM="Poll Private Registry" \
  registry:2

# --- 3. expose the cluster API to the CI runner ---------------------------
# CI jobs run in their own docker network, where the kind node IPs are not
# routable (and the API port mapping is bound to loopback). A tiny socat
# forwarder on the kind network publishes the API on the host instead, so
# the CI kubeconfig (secret KUBECONFIG_B64) can point at <bridge-ip>:16443.
echo "==> exposing the cluster API on :16443 for the CI runner"
CP_IP="$(docker inspect "$CLUSTER-control-plane" -f '{{.NetworkSettings.Networks.kind.IPAddress}}')"
docker rm -f k8s-api-proxy >/dev/null 2>&1 || true
docker run -d --name k8s-api-proxy --restart unless-stopped \
  --network kind -p 16443:6443 \
  alpine/socat "TCP-LISTEN:6443,fork,reuseaddr TCP:$CP_IP:6443"

# --- 4. let the cluster talk to the registry -------------------------------
# kind nodes reach the host through the docker bridge gateway; the
# containerd mirror config points localhost:5000 at it (see the kind docs,
# "Using a Local Registry"). Two gotchas:
#   - the node's containerd config must declare config_path pointing at
#     /etc/containerd/certs.d, otherwise the mirror file is ignored and
#     localhost resolves to ::1 inside the node;
#   - containerd has to be restarted to pick up the change.
BRIDGE_IP="$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')"
for node in $(kind get nodes --name "$CLUSTER"); do
  echo "==> configuring node $node for the registry"
  docker exec "$node" sh -c "
    grep -q 'localhost:$REGISTRY_PORT' /etc/hosts || echo '$BRIDGE_IP localhost:$REGISTRY_PORT' >> /etc/hosts
    mkdir -p /etc/containerd/certs.d/localhost:$REGISTRY_PORT
    {
      printf 'server = \"http://$BRIDGE_IP:$REGISTRY_PORT\"\n'
      printf '[host.\"http://$BRIDGE_IP:$REGISTRY_PORT\"]\n'
      printf '  capabilities = [\"pull\", \"resolve\"]\n'
    } > /etc/containerd/certs.d/localhost:$REGISTRY_PORT/hosts.toml
    if ! grep -q '^\[plugins..io.containerd.grpc.v1.cri..registry\]$' /etc/containerd/config.toml; then
      printf '\n[plugins.\"io.containerd.grpc.v1.cri\".registry]\n  config_path = \"/etc/containerd/certs.d\"\n' >> /etc/containerd/config.toml
    else
      grep -q config_path /etc/containerd/config.toml || sed -i '/^\[plugins..io.containerd.grpc.v1.cri..registry\]$/a\  config_path = \"/etc/containerd/certs.d\"' /etc/containerd/config.toml
    fi
    systemctl restart containerd
  "
done

# --- 5. ingress controller -------------------------------------------------
echo "==> installing ingress-nginx (NodePort $INGRESS_HTTP_PORT)"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http="$INGRESS_HTTP_PORT" \
  --set controller.service.nodePorts.https=30443

# --- 5. metrics server -------------------------------------------------------
# Required for the HorizontalPodAutoscalers and for `kubectl top`.
# The kind kubelets serve their metrics with a localhost-only
# certificate, so the metrics server needs --kubelet-insecure-tls
# (see the kind documentation).
echo "==> installing the metrics server (needed for autoscaling)"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system --create-namespace \
  --set args[0]=--kubelet-insecure-tls

echo
echo "Platform ready: cluster '$CLUSTER', private registry on :$REGISTRY_PORT, ingress on NodePort $INGRESS_HTTP_PORT."
echo "Next: ../deploy.sh"
