#!/usr/bin/env bash

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?Définir CLUSTER_NAME explicitement}"
ARGOCD_NAMESPACE="argocd"
ARGOCD_MANIFEST="${ARGOCD_MANIFEST:?Définir ARGOCD_MANIFEST explicitement}"
EXPECTED_SHA256="7efe2d6bbc03f63623640f1e4198f16c84009d510fb810ef71e56df1b7614ba9"

[[ -f "$ARGOCD_MANIFEST" && -r "$ARGOCD_MANIFEST" ]] || {
  echo "[STOP] Manifeste Argo CD absent ou illisible" >&2
  exit 1
}
ACTUAL_SHA256="$(sha256sum "$ARGOCD_MANIFEST" | cut -d ' ' -f 1)"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || {
  echo "[STOP] Empreinte du manifeste Argo CD inattendue" >&2
  exit 1
}
echo "[OK] Manifeste Argo CD v3.5.3 vérifié"

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
MGMT_CONTEXT="kind-${CLUSTER_NAME}"

#
# Namespace ArgoCD
#
kubectl --context "$MGMT_CONTEXT" create namespace argocd \
  --dry-run=client -o yaml \
  | kubectl --context "$MGMT_CONTEXT" apply -f -

#
# Installation ArgoCD
#
if ! kubectl --context "$MGMT_CONTEXT" get deployment argocd-server \
  -n argocd >/dev/null 2>&1; then

  echo "[INFO] installation ArgoCD"

  kubectl --context "$MGMT_CONTEXT" apply \
    --server-side \
    -n argocd \
    -f "$ARGOCD_MANIFEST"

else

  echo "[INFO] ArgoCD déjà installé"

fi

#
# Attente pods ArgoCD
#
echo "[INFO] attente ArgoCD"

kubectl --context "$MGMT_CONTEXT" wait \
  --for=condition=available \
  deployment/argocd-server \
  -n argocd \
  --timeout=300s

kubectl --context "$MGMT_CONTEXT" wait \
  --for=condition=available \
  deployment/argocd-repo-server \
  -n argocd \
  --timeout=300s

echo "[OK] ArgoCD disponible"

echo "[OK] Argo CD disponible ; Root App non appliquée par ce script"
