#!/usr/bin/env bash

set -euo pipefail

CLUSTER_NAME="gitops-management"
ARGOCD_NAMESPACE="argocd"

echo "==================================="
echo " Bootstrap cluster management"
echo "==================================="

#
# Vérifications préalables
#
for cmd in kubectl helm git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERREUR: commande absente: $cmd"
    exit 1
  fi
done

echo "[OK] outils présents"

#
# Vérification contexte
#
CURRENT_CONTEXT=$(kubectl config current-context)

if [[ "$CURRENT_CONTEXT" != "kind-${CLUSTER_NAME}" ]]; then
  echo "ERREUR:"
  echo "Contexte attendu : kind-${CLUSTER_NAME}"
  echo "Contexte actuel  : $CURRENT_CONTEXT"
  exit 1
fi

echo "[OK] contexte kubectl valide"

#
# Namespace ArgoCD
#
kubectl create namespace argocd \
  --dry-run=client -o yaml \
  | kubectl apply -f -

#
# Installation ArgoCD
#
if ! kubectl get deployment argocd-server \
  -n argocd >/dev/null 2>&1; then

  echo "[INFO] installation ArgoCD"

  kubectl apply \
    --server-side \
    -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

else

  echo "[INFO] ArgoCD déjà installé"

fi

#
# Attente pods ArgoCD
#
echo "[INFO] attente ArgoCD"

kubectl wait \
  --for=condition=available \
  deployment/argocd-server \
  -n argocd \
  --timeout=300s

kubectl wait \
  --for=condition=available \
  deployment/argocd-repo-server \
  -n argocd \
  --timeout=300s

echo "[OK] ArgoCD disponible"

#
# Root App
#
echo "[INFO] application Root App"

kubectl apply \
  -f clusters/management/root-app/root-app.yaml

#
# Attente synchronisation initiale
#
echo "[INFO] attente création applications"

sleep 15

#
# Contrôles
#
kubectl get applications -n argocd || true

echo
echo "[INFO] Résumé"
echo "-----------------------------------"
kubectl get appprojects -n argocd
echo
kubectl get applications -n argocd
echo

echo "[OK] bootstrap-management terminé"
