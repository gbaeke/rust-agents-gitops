#!/usr/bin/env bash
# Gives one app its own key for the central AI gateway (D11), as two files:
#
#   apps/<app>/sealed-gateway-key.yaml              the key, sealed: Secret gateway-key (key: key) in namespace <app>
#   platform/ai-gateway/apps/<app>/key.yaml         only its sha256 hash, with metadata {"app": "<app>"}
#
# The gateway accepts a call when the hash of its x-api-key header matches one
# of these ConfigMaps, and policies can then use apiKey.app. The key itself
# never touches the disk unencrypted. Running this again replaces the key.
#
#   scripts/agent-key.sh <app>
#
# KIND_CLUSTER picks the cluster (default: gitops), as in cluster/cluster.sh.
set -euo pipefail

CONTEXT="kind-${KIND_CLUSTER:-gitops}"
ROOT="$(dirname "$(realpath "$0")")/.."
APP="${1:?usage: $0 <app>}"
[[ "$APP" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "app must be a namespace name" >&2; exit 1; }

key="$(openssl rand -hex 32)"
# sha256sum on Linux; macOS before 15 only has shasum. Same output either way.
if command -v sha256sum >/dev/null; then sha256() { sha256sum; }; else sha256() { shasum -a 256; }; fi
hash="$(printf '%s' "$key" | sha256 | cut -d' ' -f1)"

mkdir -p "$ROOT/apps/$APP" "$ROOT/platform/ai-gateway/apps/$APP"
printf 'key=%s\n' "$key" |
  kubectl create secret generic gateway-key -n "$APP" --from-env-file=/dev/stdin --dry-run=client -o yaml |
  kubeseal --context "$CONTEXT" -o yaml >"$ROOT/apps/$APP/sealed-gateway-key.yaml"

cat >"$ROOT/platform/ai-gateway/apps/$APP/key.yaml" <<EOF
# $APP's gateway key, as a hash only (written by scripts/agent-key.sh; the key
# itself is sealed in apps/$APP/). Picked up by the policy in api-keys.yaml.
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-key-$APP
  labels:
    ai-gateway.platform/api-key: "true"
  annotations:
    argocd.argoproj.io/sync-wave: "2"
data:
  $APP: '{"keyHash": "sha256:$hash", "metadata": {"app": "$APP"}}'
EOF
echo "wrote apps/$APP/sealed-gateway-key.yaml and platform/ai-gateway/apps/$APP/key.yaml"
