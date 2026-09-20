#!/usr/bin/env bash

set -euo pipefail

echo "=================================================="
echo "GitOps Platform Bootstrap"
echo "=================================================="

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if kind get clusters | grep -q "^gitops-management$"; then
    echo "[ERROR] Cluster gitops-management déjà présent"
    exit 1
fi

if kind get clusters | grep -q "^gitops-lab$"; then
    echo "[ERROR] Cluster gitops-lab déjà présent"
    exit 1
fi

echo
echo "[1/5] Bootstrap Workstation"

"${ROOT_DIR}/scripts/bootstrap-workstation.sh"

echo
echo "[2/5] Création cluster management"

kind create cluster \
  --name gitops-management \
  --config "${ROOT_DIR}/clusters/management/kind-config.yaml"

echo
echo "[3/5] Bootstrap management"

"${ROOT_DIR}/scripts/bootstrap-management.sh"

echo
echo "[4/5] Création cluster workload-dev"

kind create cluster \
  --name gitops-lab \
  --config "${ROOT_DIR}/clusters/workload-dev/kind-config.yaml"

echo
echo "[5/5] Bootstrap workload-dev"

"${ROOT_DIR}/scripts/bootstrap-workload.sh"

echo
echo "[6/6] Publication GitOps"
./scripts/bootstrap-gitops-sync.sh

echo "Attente de l'enregistrement du cluster workload-dev dans ArgoCD"
echo "avant de poursuivre le bootstrap GitOps"
kubectl --context kind-gitops-management \
  wait \
  --for=jsonpath='{.status.health.status}'=Healthy \
  application/cluster-registration \
  -n argocd \
  --timeout=300s

echo
echo "=================================================="
echo "Bootstrap terminé"
echo "=================================================="

echo
echo "Vérifications recommandées :"

echo "kubectl get applications -n argocd"
echo "kubectl get secret workload-dev -n argocd"
echo "kubectl get pods -A"
