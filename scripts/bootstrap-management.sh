#!/usr/bin/env bash
set -euo pipefail

CONTEXT="kind-gitops-management"
ARGOCD_VERSION="v3.1.7"
ROOT_APP="clusters/management/root-app/root-app.yaml"
SEALED_KEYS="${SEALED_KEYS:-$HOME/.config/gitops-lab/sealed-secrets-key.yaml}"

kubectl --context "$CONTEXT" create namespace argocd --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
kubectl --context "$CONTEXT" apply --server-side -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl --context "$CONTEXT" -n argocd wait --for=condition=Established crd/applications.argoproj.io --timeout=180s

# Necessaire au PRA Sealed Secrets: la cle privee ne doit jamais etre stockee dans Git.
if [ -f "$SEALED_KEYS" ]; then
  kubectl --context "$CONTEXT" apply -f "$SEALED_KEYS"
fi

kubectl --context "$CONTEXT" apply -f "$ROOT_APP"
echo "Bootstrap lance. Controle: kubectl --context $CONTEXT get applications -n argocd"
