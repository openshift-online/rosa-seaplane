#!/usr/bin/env bash
set -euo pipefail

# Helm's post-renderer input becomes a Kustomize resource; apply the same
# declarative patch used by Argo CD's steady-state Kustomize operand.
patch_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/argocd-helm-post-renderer.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

cat >"$work_dir/rendered.yaml"
cp "$patch_dir/redis-haproxy-command.yaml" "$work_dir/redis-haproxy-command.yaml"
cat >"$work_dir/kustomization.yaml" <<'KUSTOMIZATION'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - rendered.yaml
patches:
  - path: redis-haproxy-command.yaml
KUSTOMIZATION

kubectl kustomize "$work_dir"
