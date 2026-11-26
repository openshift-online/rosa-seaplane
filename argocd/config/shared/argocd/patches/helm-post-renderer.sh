#!/usr/bin/env bash
set -euo pipefail

# Helm's post-renderer input becomes a Kustomize resource; apply the same
# declarative patch set used by Argo CD's steady-state Kustomize operand.
patch_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/argocd-helm-post-renderer.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

cat >"$work_dir/rendered.yaml"
cp "$patch_dir/valkey-cli-compat.yaml" "$work_dir/valkey-cli-compat.yaml"
cp "$patch_dir/haproxy-init-image.yaml" "$work_dir/haproxy-init-image.yaml"
cat >"$work_dir/kustomization.yaml" <<'KUSTOMIZATION'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - rendered.yaml
patches:
  - path: valkey-cli-compat.yaml
  - path: haproxy-init-image.yaml
KUSTOMIZATION

kubectl kustomize "$work_dir"
