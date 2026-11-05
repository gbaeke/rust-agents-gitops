#!/usr/bin/env bash
# Makes SealedSecrets: encrypted with the cluster's Sealed Secrets key, safe
# to commit, readable only by the controller in that cluster. The plain values
# only travel on stdin: never on disk, in git or in a process argument.
#
#   scripts/seal.sh anthropic <.env file>        the Anthropic key, for the central gateway
#   scripts/seal.sh postgres <namespace> <file>  a new random Postgres password, only if <file> doesn't exist
#
# KIND_CLUSTER picks the cluster (default: gitops), as in cluster/cluster.sh.
set -euo pipefail

CONTEXT="kind-${KIND_CLUSTER:-gitops}"
ROOT="$(dirname "$(realpath "$0")")/.."

# Reads a Secret in env-file form (name=value lines) on stdin and writes it,
# sealed, to $3. A SealedSecret only decrypts under its own name and namespace.
seal() {
  local namespace="$1" name="$2" out="$3"
  kubectl create secret generic "$name" -n "$namespace" --from-env-file=/dev/stdin --dry-run=client -o yaml |
    kubeseal --context "$CONTEXT" -o yaml >"$out.tmp"
  mv "$out.tmp" "$out"
  echo "wrote ${out#"$ROOT/"}"
}

anthropic() {
  local env_file="${1:?usage: $0 anthropic <.env file>}" line key
  line="$(grep -m1 '^ANTHROPIC_API_KEY=' "$env_file")" || { echo "no ANTHROPIC_API_KEY line in $env_file" >&2; exit 1; }
  key="${line#ANTHROPIC_API_KEY=}"
  key="${key%\"}"; key="${key#\"}"
  [ -n "$key" ] || { echo "ANTHROPIC_API_KEY is empty in $env_file" >&2; exit 1; }
  # printf is a shell builtin, so the key doesn't show up in ps.
  printf 'Authorization=%s\n' "$key" |
    seal ai-gateway anthropic "$ROOT/platform/ai-gateway/sealed-anthropic.yaml"
}

postgres() {
  local namespace="${1:?usage: $0 postgres <namespace> <file>}" out="${2:?usage: $0 postgres <namespace> <file>}"
  # Postgres keeps the password it was initialised with; a new one would lock
  # it out of its own data.
  if [ -f "$out" ]; then
    echo "$out exists; keeping it"
    return
  fi
  printf 'password=%s\n' "$(openssl rand -hex 24)" | seal "$namespace" postgres "$out"
}

case "${1:-}" in
  anthropic|postgres) cmd="$1"; shift; "$cmd" "$@" ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
