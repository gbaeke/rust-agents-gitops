#!/usr/bin/env bash
# Backup and restore of the Sealed Secrets key, outside git. With the same key
# after a rebuild of the cluster, every SealedSecret in git still decrypts.
#
#   scripts/sealing-key.sh backup    save the key(s) to ~/.config/rust-agents-gitops/sealing-key.yaml
#   scripts/sealing-key.sh restore   apply that file (bootstrap.sh does this before Argo CD starts)
#   scripts/sealing-key.sh cert      print the public certificate, to compare before and after
#
# Run backup once, right after the controller first starts. The file holds the
# private key: it is mode 600 and must never go in git.
#
# KIND_CLUSTER picks the cluster (default: gitops), as in cluster/cluster.sh.
set -euo pipefail

CONTEXT="kind-${KIND_CLUSTER:-gitops}"
FILE="$HOME/.config/rust-agents-gitops/sealing-key.yaml"
LABEL=sealedsecrets.bitnami.com/sealed-secrets-key

k() { kubectl --context "$CONTEXT" "$@"; }

backup() {
  mkdir -p "$(dirname "$FILE")"
  local tmp
  tmp="$(mktemp "$FILE.XXXXXX")" # mktemp makes it mode 600
  # Only what's needed to recreate the Secret: no uid, resourceVersion etc.
  # from this cluster.
  k -n kube-system get secret -l "$LABEL" -o json |
    jq '{apiVersion, kind: "List", items: [.items[] | {apiVersion: "v1", kind, type, data,
         metadata: {name: .metadata.name, namespace: .metadata.namespace, labels: .metadata.labels}}]}' >"$tmp"
  if [ "$(jq '.items | length' "$tmp")" -eq 0 ]; then
    rm -f "$tmp"
    echo "no sealing key in kube-system yet; is the sealed-secrets Application Healthy?" >&2
    exit 1
  fi
  mv "$tmp" "$FILE"
  echo "saved $(jq '.items | length' "$FILE") key(s) to $FILE"
}

restore() {
  [ -f "$FILE" ] || { echo "no backup at $FILE" >&2; exit 1; }
  k apply -f "$FILE"
  # A controller that is already running only reads keys at startup.
  if k -n kube-system get deploy sealed-secrets-controller >/dev/null 2>&1; then
    k -n kube-system rollout restart deploy/sealed-secrets-controller
  fi
}

cert() {
  kubeseal --context "$CONTEXT" --fetch-cert
}

case "${1:-}" in
  backup|restore|cert) "$1" ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
