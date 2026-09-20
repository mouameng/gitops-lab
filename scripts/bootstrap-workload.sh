#!/usr/bin/env bash

set -euo pipefail

MGMT_CONTEXT="kind-gitops-management"
WORKLOAD_CONTEXT="kind-gitops-lab"

ARGOCD_NAMESPACE="argocd"

SA_NAMESPACE="kube-system"
SA_NAME="argocd-manager"

OUTPUT="clusters/management/cluster-registration/workload-dev-sealedsecret.yaml"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "=================================================="
echo "Bootstrap Workload"
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

SERVER="https://gitops-lab-control-plane:6443"

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
  create secret generic workload-dev \
  --from-literal=name=workload-dev \
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
      > "$TMPDIR/workload-dev-secret.yaml"

echo
echo "[4/5] Vérification label cluster"

grep \
  "argocd.argoproj.io/secret-type: cluster" \
  "$TMPDIR/workload-dev-secret.yaml"

echo
echo "[5/5] Génération SealedSecret"

kubeseal \
  --context "$MGMT_CONTEXT" \
  --controller-name sealed-secrets-controller \
  --controller-namespace sealed-secrets \
  --format yaml \
  < "$TMPDIR/workload-dev-secret.yaml" \
  > "$OUTPUT"

echo
echo "[OK] Généré : $OUTPUT"
echo
echo "Ne pas oublier :"
echo
echo "git add $OUTPUT"
echo "git commit"
echo "git push"
