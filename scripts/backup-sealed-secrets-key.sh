#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/lab-paths.sh" || { echo "[ERREUR] lab-paths.sh illisible" >&2; exit 1; }
CONTEXT="kind-gitops-management"
OUTPUT="${1:-${LAB_CONFIG_DIR}/sealed-secrets-key.yaml}"
mkdir -p "$(dirname "$OUTPUT")"
umask 077
kubectl --context "$CONTEXT" -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml > "$OUTPUT"
echo "Cle sauvegardee hors Git: $OUTPUT"
