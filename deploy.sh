#!/usr/bin/env bash
#
# End-to-end deployment of the Poll application:
#   1. build the three application images
#   2. push them to the private registry
#   3. apply the kubernetes manifests (in order)
#   4. wait until everything is ready
#
# Environment (see README.md):
#   REGISTRY_URL       registry to push to      (default: localhost:5000)
#   REGISTRY_USER      registry login           (default: polluser)
#   REGISTRY_PASSWORD  registry password        (required)
#   POSTGRES_PASSWORD  database password        (required)
#   REDIS_PASSWORD     redis password           (required)
#   POSTGRES_USER      (default: poll)
#   POSTGRES_DB        (default: poll)
#   TAG                image tag                (default: latest)
#
set -euo pipefail
cd "$(dirname "$0")"

REGISTRY_URL="${REGISTRY_URL:-localhost:5000}"
REGISTRY_USER="${REGISTRY_USER:-polluser}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is not set (see README.md)}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set (see README.md)}"
REDIS_PASSWORD="${REDIS_PASSWORD:?REDIS_PASSWORD is not set (see README.md)}"
POSTGRES_USER="${POSTGRES_USER:-poll}"
POSTGRES_DB="${POSTGRES_DB:-poll}"
TAG="${TAG:-latest}"

echo "==> building images (tag: $TAG)"
docker build -t "$REGISTRY_URL/poll:$TAG" ./poll
docker build -t "$REGISTRY_URL/worker:$TAG" ./worker
docker build -t "$REGISTRY_URL/result:$TAG" ./result

echo "==> pushing to $REGISTRY_URL"
docker login "$REGISTRY_URL" -u "$REGISTRY_USER" --password-stdin <<<"$REGISTRY_PASSWORD"
docker push "$REGISTRY_URL/poll:$TAG"
docker push "$REGISTRY_URL/worker:$TAG"
docker push "$REGISTRY_URL/result:$TAG"
docker logout "$REGISTRY_URL" >/dev/null

echo "==> applying manifests"
kubectl apply -f k8s/00-namespace.yaml

# Secrets first: every manifest references them. Re-created on each run,
# so a password change takes effect on the next deploy.
kubectl create secret generic postgres-credentials -n poll \
  --from-literal=postgres-user="$POSTGRES_USER" \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --from-literal=postgres-db="$POSTGRES_DB" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic redis-credentials -n poll \
  --from-literal=redis-password="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
# The private registry needs a pull secret so the nodes can authenticate.
kubectl create secret docker-registry registry-credentials -n poll \
  --docker-server="$REGISTRY_URL" \
  --docker-username="$REGISTRY_USER" \
  --docker-password="$REGISTRY_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f k8s/10-redis.yaml
kubectl apply -f k8s/20-postgres.yaml
kubectl apply -f k8s/30-poll.yaml
kubectl apply -f k8s/31-worker.yaml
kubectl apply -f k8s/32-result.yaml

echo "==> applying the database schema"
# The ConfigMap is generated from schema.sql so the file stays the source
# of truth. The Job is (almost) immutable, so delete the previous run and
# start a fresh one: the SQL is idempotent, this is safe on redeploys.
kubectl create configmap postgres-schema -n poll \
  --from-file=schema.sql \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl delete job postgres-schema -n poll --ignore-not-found --wait=false >/dev/null
kubectl apply -f k8s/21-postgres-schema.yaml
kubectl wait --for=condition=complete job/postgres-schema -n poll --timeout=180s

echo "==> applying the ingress"
kubectl apply -f k8s/40-ingress.yaml

echo "==> waiting for the rollouts"
kubectl rollout status deploy/poll -n poll --timeout=180s
kubectl rollout status deploy/worker -n poll --timeout=180s
kubectl rollout status deploy/result -n poll --timeout=180s

NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')"
echo
echo "Deployed. The app is behind the ingress on NodePort 30080:"
echo "  poll:   curl -s --resolve poll.bernstein.local:30080:$NODE_IP http://poll.bernstein.local:30080/ | head -5"
echo "  result: curl -s --resolve result.bernstein.local:30080:$NODE_IP http://result.bernstein.local:30080/ | head -5"
