#!/usr/bin/env bash

set -euo pipefail

CONTEXT="kind-gitops-management"
ARGOCD_VERSION="v3.1.7"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_APP="${ROOT_DIR}/clusters/management/root-app/root-app.yaml"
SEALED_KEYS="${SEALED_KEYS:-$HOME/.config/gitops-lab/sealed-secrets-key.yaml}"

kubectl --context "$CONTEXT" \
  create namespace argocd \
  --dry-run=client \
  -o yaml | kubectl --context "$CONTEXT" apply -f -

kubectl --context "$CONTEXT" apply \
  --server-side \
  -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

kubectl --context "$CONTEXT" \
  -n argocd \
  wait \
  --for=condition=Established \
  crd/applications.argoproj.io \
  --timeout=180s

kubectl --context "$CONTEXT" \
  -n argocd \
  rollout status deployment/argocd-server \
  --timeout=300s

if [ -f "$SEALED_KEYS" ]; then
    echo "[INFO] Restauration clé privée Sealed Secrets"
    kubectl --context "$CONTEXT" apply -f "$SEALED_KEYS"
fi

kubectl --context "$CONTEXT" apply -f "$ROOT_APP"

echo
echo "[OK] Bootstrap management lancé"
echo
echo "Contrôle :"
echo "kubectl --context $CONTEXT get applications -n argocd"
