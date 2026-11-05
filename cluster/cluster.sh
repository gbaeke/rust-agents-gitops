#!/usr/bin/env bash
# Lifecycle of the kind cluster for the GitOps version, and of the local
# image registry its nodes pull from. Knows nothing about the apps: Argo CD
# brings those (see bootstrap/bootstrap.sh).
#
#   cluster/cluster.sh install   install kind, kubectl, helm, argocd and kubeseal (with mise)
#   cluster/cluster.sh up        start the registry; create the cluster, or start it if it is stopped
#   cluster/cluster.sh stop      stop the node containers; state is kept
#   cluster/cluster.sh start     start them again
#   cluster/cluster.sh status    nodes, published ports and the registry
#   cluster/cluster.sh down      delete the cluster; the registry keeps running
#
# KIND_CLUSTER picks the cluster name (default: gitops); kubectl's context is kind-$KIND_CLUSTER.
set -euo pipefail

CLUSTER="${KIND_CLUSTER:-gitops}"
CONFIG="$(dirname "$(realpath "$0")")/cluster.yaml"
REGISTRY=kind-registry
REGISTRY_PORT=5001

nodes() { docker ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER" --format '{{.Names}}'; }
exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; }
need() { command -v "$1" >/dev/null || { echo "$1 is not installed; run: $0 install" >&2; exit 1; }; }

wait_ready() {
  kubectl config use-context "kind-$CLUSTER" >/dev/null
  echo "waiting for nodes to be Ready..."
  kubectl wait --for=condition=Ready nodes --all --timeout=180s
}

install() {
  command -v mise >/dev/null || { echo "install mise first: https://mise.jdx.dev" >&2; exit 1; }
  mise use -g kind@latest kubectl@latest helm@latest argocd@latest kubeseal@latest
  kind version && kubectl version --client && helm version --short
  argocd version --client --short && kubeseal --version
}

# The registry is shared: another kind cluster may use it too, so it is only
# ever started here, never removed. From kind's local registry guide.
registry() {
  if [ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY" 2>/dev/null || true)" != true ]; then
    if docker inspect "$REGISTRY" >/dev/null 2>&1; then
      docker start "$REGISTRY" >/dev/null
    else
      docker run -d --restart=always -p "127.0.0.1:$REGISTRY_PORT:5000" --network bridge \
        --name "$REGISTRY" registry:3 >/dev/null
    fi
  fi
}

# Tell each node's containerd that localhost:5001 is the registry container
# (localhost inside a node is the node itself), put the registry on the kind
# network, and document it in the cluster. Safe to run again.
connect_registry() {
  local dir="/etc/containerd/certs.d/localhost:$REGISTRY_PORT"
  for node in $(kind get nodes --name "$CLUSTER"); do
    docker exec "$node" mkdir -p "$dir"
    printf '[host."http://%s:5000"]\n' "$REGISTRY" | docker exec -i "$node" cp /dev/stdin "$dir/hosts.toml"
  done
  if [ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "$REGISTRY")" = null ]; then
    docker network connect kind "$REGISTRY"
  fi
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:$REGISTRY_PORT"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
}

up() {
  need kind; need kubectl
  registry
  if exists; then
    start
  else
    kind create cluster --name "$CLUSTER" --config "$CONFIG"
    wait_ready
    connect_registry
  fi
}

start() {
  need kind; need kubectl
  exists || { echo "no cluster $CLUSTER; run: $0 up" >&2; exit 1; }
  registry
  # The control plane first, so the workers find the API server when they come up.
  docker start "$CLUSTER-control-plane" >/dev/null
  nodes | grep -vx "$CLUSTER-control-plane" | xargs -r docker start >/dev/null
  wait_ready
  connect_registry
}

stop() {
  nodes | xargs -r docker stop >/dev/null
  echo "cluster $CLUSTER stopped"
}

status() {
  need kubectl
  echo "registry: $(docker inspect -f '{{.State.Status}}' "$REGISTRY" 2>/dev/null || echo absent) (localhost:$REGISTRY_PORT)"
  if ! exists; then echo "no cluster $CLUSTER"; return; fi
  echo
  docker ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER" --format 'table {{.Names}}\t{{.Status}}'
  if docker ps --format '{{.Names}}' | grep -qx "$CLUSTER-control-plane"; then
    echo
    kubectl --context "kind-$CLUSTER" get nodes
    echo
    # Host port = node port + 1000 (see cluster.yaml).
    kubectl --context "kind-$CLUSTER" get services --all-namespaces --field-selector spec.type=NodePort \
      -o custom-columns='NAMESPACE:.metadata.namespace,SERVICE:.metadata.name,NODE PORT:.spec.ports[*].nodePort'
  fi
}

down() {
  need kind
  kind delete cluster --name "$CLUSTER"
}

case "${1:-}" in
  install|up|start|stop|status|down) "$1" ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
