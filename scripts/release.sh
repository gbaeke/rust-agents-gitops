#!/usr/bin/env bash
# Releases the rust agent through git: builds both images from the committed
# source, pushes them to the local registry, sets their tag in
# bases/rust-agent/kustomization.yaml (so for every agent) and commits that.
# Argo CD rolls it out once the commit is pushed.
#
#   scripts/release.sh
#
# The tag is the short hash of the last commit that changed the source (D3),
# so it is never reused and the release commit (only bases/) doesn't change it.
# It refuses to run while the source has uncommitted changes: the image must
# be exactly that commit.
set -euo pipefail

cd "$(dirname "$(realpath "$0")")/.."
SOURCE=(agent mcp-server knowledge-base Cargo.toml Cargo.lock Dockerfile .dockerignore)
REGISTRY=localhost:5001/rust-agents
KUSTOMIZATION=bases/rust-agent/kustomization.yaml

if [ -n "$(git status --porcelain -- "${SOURCE[@]}")" ]; then
  echo "the source has uncommitted changes; commit them first:" >&2
  git status --short -- "${SOURCE[@]}" >&2
  exit 1
fi
tag="$(git log -1 --format=%h -- "${SOURCE[@]}")"

for target in agent mcp-server; do
  docker build --target "$target" -t "$REGISTRY/$target:$tag" .
  docker push "$REGISTRY/$target:$tag"
done

for target in agent mcp-server; do
  name="$REGISTRY/$target" tag="$tag" yq -i '(.images[] | select(.name == strenv(name)) | .newTag) = strenv(tag)' "$KUSTOMIZATION"
done
if git diff --quiet -- "$KUSTOMIZATION"; then
  echo "rust-agents $tag is already the released version"
  exit 0
fi
git commit -q -m "Release rust-agents $tag" -- "$KUSTOMIZATION"
git show --stat --format='%h %s' HEAD

# Pushing deploys, so ask first.
if [ -t 0 ]; then
  read -r -p "push to $(git rev-parse --abbrev-ref '@{u}')? [y/N] " answer
  [ "$answer" = y ] && git push
else
  echo "not pushed; run: git push"
fi
