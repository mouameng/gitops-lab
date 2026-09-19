#!/usr/bin/env bash
set -euo pipefail

MGMT_CONTEXT="kind-gitops-management"
WORKLOAD_CONTEXT="kind-gitops-lab"
ARGOCD_NAMESPACE="argocd"
SA_NAMESPACE="kube-system"
SA_NAME="argocd-manager"
OUTPUT="argocd/cluster-registration/workload-dev-sealedsecret.yaml"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

command -v kubectl >/dev/null
command -v kubeseal >/dev/null

# Compte technique du cluster workload avec droits admin pour ce lab.
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

for i in $(seq 1 30); do
  TOKEN="$(kubectl --context "$WORKLOAD_CONTEXT" -n "$SA_NAMESPACE" get secret "${SA_NAME}-token" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [ -n "$TOKEN" ] && break
  sleep 1
done
[ -n "${TOKEN:-}" ] || { echo "Token non genere" >&2; exit 1; }

CA_DATA="$(kubectl --context "$WORKLOAD_CONTEXT" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
# Les deux conteneurs Kind doivent partager le reseau Docker 'kind'.
SERVER="https://gitops-lab-control-plane:6443"
CONFIG="$(printf '{"bearerToken":"%s","tlsClientConfig":{"insecure":false,"caData":"%s"}}' "$TOKEN" "$CA_DATA")"

kubectl --context "$MGMT_CONTEXT" -n "$ARGOCD_NAMESPACE" create secret generic workload-dev \
  --from-literal=name=workload-dev \
  --from-literal=server="$SERVER" \
  --from-literal=config="$CONFIG" \
  --dry-run=client -o yaml \
  | kubectl annotate --local -f - \
      argocd.argoproj.io/sync-wave="-20" \
      argocd.argoproj.io/sync-options=SkipDryRunOnMissingResource=true \
      -o yaml \
  | kubectl label --local -f - \
      argocd.argoproj.io/secret-type=cluster \
      -o yaml \
      > "$TMPDIR/workload-dev-secret.yaml"

kubeseal --context "$MGMT_CONTEXT" \
  --controller-name sealed-secrets-controller \
  --controller-namespace sealed-secrets \
  --format yaml \
  < "$TMPDIR/workload-dev-secret.yaml" > "$OUTPUT"

echo "Genere: $OUTPUT"
echo "Le Secret en clair temporaire a ete supprime. Verifier puis commiter uniquement le SealedSecret."
