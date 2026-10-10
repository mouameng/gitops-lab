#!/usr/bin/env bash

set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../lib/lab-paths.sh" || { echo "[ERREUR] lab-paths.sh illisible" >&2; exit 1; }

MGMT_CONTEXT="${MGMT_CONTEXT:?Definir MGMT_CONTEXT explicitement}"
KIND_CLUSTER="${KIND_CLUSTER:?Définir KIND_CLUSTER explicitement}"
ARGOCD_CLUSTER="${ARGOCD_CLUSTER:?Définir ARGOCD_CLUSTER explicitement}"
WORKLOAD_CONTEXT="kind-${KIND_CLUSTER}"

ARGOCD_NAMESPACE="argocd"

SA_NAMESPACE="kube-system"
SA_NAME="argocd-manager"

OUTPUT="${OUTPUT:?Definir OUTPUT explicitement}"

# Vérifier le couple dans l'inventaire avant toute action Kubernetes.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPTS_DIR/.." && pwd -P)"
INVENTORY="${ROOT_DIR}/clusters/workloads.tsv"
if [[ ! -f "$INVENTORY" ]] ||
   ! awk -F '\t' -v kind="$KIND_CLUSTER" -v argo="$ARGOCD_CLUSTER" '
     NR > 1 && $2 == kind && $3 == argo { found = 1 }
     END { exit !found }
   ' "$INVENTORY"; then
  echo "[ERROR] Correspondance absente de $INVENTORY" >&2
  exit 1
fi

CANDIDATE_DIR="${LAB_REGISTRATION_CANDIDATES_DIR}"
EXPECTED_OUTPUT="${CANDIDATE_DIR}/${ARGOCD_CLUSTER}-sealedsecret.yaml"
[[ -d "$CANDIDATE_DIR" && "$OUTPUT" == "$EXPECTED_OUTPUT" ]] || {
  echo "[STOP] OUTPUT doit designer le candidat hors Git attendu" >&2
  exit 1
}
[[ ! -L "$OUTPUT" ]] || {
  echo "[STOP] OUTPUT ne doit pas etre un lien symbolique" >&2
  exit 1
}

umask 077
TMPDIR="$(mktemp -d)"
STAGED_OUTPUT="$(mktemp "${CANDIDATE_DIR}/.${ARGOCD_CLUSTER}.XXXXXX")"
trap 'rm -rf -- "$TMPDIR"; rm -f -- "$STAGED_OUTPUT"' EXIT

echo "=================================================="
echo "Bootstrap Workload ${KIND_CLUSTER}"
echo "=================================================="

command -v kubectl >/dev/null
command -v kubeseal >/dev/null

echo
echo "[1/5] Création ServiceAccount ArgoCD"

kubectl --context "$WORKLOAD_CONTEXT" apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${SA_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${SA_NAME}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${SA_NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SA_NAME}-token
  namespace: ${SA_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
YAML

echo
echo "[2/5] Récupération token"

for i in $(seq 1 30); do

  TOKEN="$(
    kubectl \
      --context "$WORKLOAD_CONTEXT" \
      -n "$SA_NAMESPACE" \
      get secret "${SA_NAME}-token" \
      -o jsonpath='{.data.token}' \
      2>/dev/null | base64 -d || true
  )"

  [ -n "$TOKEN" ] && break

  sleep 1

done

[ -n "${TOKEN:-}" ] || {
  echo "[ERROR] Token non généré"
  exit 1
}

CA_DATA="$(
kubectl \
  --context "$WORKLOAD_CONTEXT" \
  config view \
  --raw \
  --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'
)"

SERVER="https://${KIND_CLUSTER}-control-plane:6443"

CONFIG="$(
printf \
'{"bearerToken":"%s","tlsClientConfig":{"insecure":false,"caData":"%s"}}' \
"$TOKEN" \
"$CA_DATA"
)"

echo
echo "[3/5] Génération Secret Cluster ArgoCD"

kubectl \
  --context "$MGMT_CONTEXT" \
  -n "$ARGOCD_NAMESPACE" \
  create secret generic "$ARGOCD_CLUSTER" \
  --from-literal=name="$ARGOCD_CLUSTER" \
  --from-literal=server="$SERVER" \
  --from-literal=config="$CONFIG" \
  --dry-run=client -o yaml \
  | kubectl annotate \
      --local \
      -f - \
      argocd.argoproj.io/sync-wave="-20" \
      argocd.argoproj.io/sync-options=SkipDryRunOnMissingResource=true \
      -o yaml \
  | kubectl label \
      --local \
      -f - \
      argocd.argoproj.io/secret-type=cluster \
      -o yaml \
      > "$TMPDIR/${ARGOCD_CLUSTER}-secret.yaml"

echo
echo "[4/5] Vérification label cluster"

grep \
  "argocd.argoproj.io/secret-type: cluster" \
  "$TMPDIR/${ARGOCD_CLUSTER}-secret.yaml"

echo
echo "[5/5] Génération SealedSecret"

kubeseal \
  --context "$MGMT_CONTEXT" \
  --controller-name sealed-secrets-controller \
  --controller-namespace sealed-secrets \
  --format yaml \
  < "$TMPDIR/${ARGOCD_CLUSTER}-secret.yaml" \
  > "$STAGED_OUTPUT"

kubeseal --validate \
  --context "$MGMT_CONTEXT" \
  --controller-name sealed-secrets-controller \
  --controller-namespace sealed-secrets \
  < "$STAGED_OUTPUT" >/dev/null

[[ ! -L "$OUTPUT" && ( ! -e "$OUTPUT" || -f "$OUTPUT" ) ]] || {
  echo "[STOP] Chemin candidat invalide : $OUTPUT" >&2
  exit 1
}
mv -fT -- "$STAGED_OUTPUT" "$OUTPUT"

echo
echo "[OK] Généré : $OUTPUT"
echo
echo "Fichier candidat généré ; validation et activation à traiter par le PRA."
