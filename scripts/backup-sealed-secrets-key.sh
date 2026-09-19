#!/usr/bin/env bash
set -euo pipefail
CONTEXT="kind-gitops-management"
OUTPUT="${1:-$HOME/.config/gitops-lab/sealed-secrets-key.yaml}"
mkdir -p "$(dirname "$OUTPUT")"
umask 077
kubectl --context "$CONTEXT" -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml > "$OUTPUT"
echo "Cle sauvegardee hors Git: $OUTPUT"
