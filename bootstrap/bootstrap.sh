#!/usr/bin/env bash
# Puts Argo CD on the kind cluster and hands the rest over to git: after this,
# everything else comes from the root Application (root.yaml).
#
#   bootstrap/bootstrap.sh            restore the sealing key, install Argo CD, apply root.yaml
#   bootstrap/bootstrap.sh password   print the initial admin password
#   bootstrap/bootstrap.sh status     Argo CD pods and the Applications
#   bootstrap/bootstrap.sh uninstall  remove Argo CD; what it deployed keeps running
#
# KIND_CLUSTER picks the cluster (default: gitops), as in cluster/cluster.sh.
set -euo pipefail

CLUSTER="${KIND_CLUSTER:-gitops}"
CONTEXT="kind-$CLUSTER"
DIR="$(dirname "$(realpath "$0")")"
NAMESPACE=argocd
CHART_VERSION=10.14.0 # Argo CD v3.6.1
SEALING_KEY="$HOME/.config/rust-agents-gitops/sealing-key.yaml"

k() { kubectl --context "$CONTEXT" "$@"; }
h() { helm --kube-context "$CONTEXT" "$@"; }

check_context() {
  kubectl config get-contexts -o name | grep -qx "$CONTEXT" ||
    { echo "no context $CONTEXT; run: cluster/cluster.sh up" >&2; exit 1; }
}

install() {
  check_context
  # Before Sealed Secrets starts, so it finds the old key and doesn't make a
  # new one (which would make every SealedSecret in git unreadable).
  if [ -f "$SEALING_KEY" ]; then
    "$DIR/../scripts/sealing-key.sh" restore
  fi
  h upgrade -i argocd argo-cd --repo https://argoproj.github.io/argo-helm --version "$CHART_VERSION" \
    -n "$NAMESPACE" --create-namespace -f "$DIR/argocd-values.yaml" --wait --timeout 5m
  k -n "$NAMESPACE" rollout status deploy/argocd-server --timeout=120s
  k apply -f "$DIR/root.yaml"
  echo
  echo "Argo CD: http://$(hostname):31009 (user admin)"
  password
}

password() {
  check_context
  echo "admin password: $(k -n "$NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
}

status() {
  check_context
  k -n "$NAMESPACE" get pods
  echo
  k -n "$NAMESPACE" get applications
}

uninstall() {
  check_context
  # Drop the finalizers first so deleting an Application doesn't delete what
  # it deployed: this removes Argo CD, not the apps.
  for app in $(k -n "$NAMESPACE" get applications -o name 2>/dev/null); do
    k -n "$NAMESPACE" patch "$app" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null
  done
  k -n "$NAMESPACE" delete applications --all --wait=false
  h uninstall argocd -n "$NAMESPACE" --ignore-not-found
  k delete namespace "$NAMESPACE" --ignore-not-found
}

case "${1:-install}" in
  install|password|status|uninstall) "${1:-install}" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
