#!/usr/bin/env bash
# Installation directe de Gitea (helm template + kubectl apply).
# A executer APRES scripts/gitea/restore.sh. Source unique : argocd/applications/gitea.yaml.
# --render-check : outils, source et rendu uniquement, SANS acces au cluster (prevol).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPTS_DIR/.." && pwd -P)"
CONTEXT="${MGMT_CONTEXT:-kind-gitops-management}"
NS="gitea"
APP_FILE="$ROOT_DIR/argocd/applications/gitea.yaml"
MODE="${1:---preflight}"

case "$MODE" in
    --preflight|--install|--render-check) ;;
    *) echo "Usage : $0 [--preflight|--install|--render-check]" >&2; exit 2 ;;
esac

for tool in helm yq jq kubectl; do
    command -v "$tool" >/dev/null || {
        echo "[STOP] Outil absent : $tool" >&2
        exit 1
    }
done

k() { kubectl --context "$CONTEXT" --request-timeout=30s "$@"; }

# Source unique : la premiere source (chart) de l'Application Argo CD.
chart_repo="$(yq -r '.spec.sources[0].repoURL' "$APP_FILE")"
chart_name="$(yq -r '.spec.sources[0].chart' "$APP_FILE")"
chart_version="$(yq -r '.spec.sources[0].targetRevision' "$APP_FILE")"
release="$(yq -r '.spec.sources[0].helm.releaseName' "$APP_FILE")"
values_ref="$(yq -r '.spec.sources[0].helm.valueFiles[0]' "$APP_FILE")"
values_file="$ROOT_DIR/${values_ref#\$values/}"

for v in "$chart_repo" "$chart_name" "$chart_version" "$release" "$values_ref"; do
    if [[ -z "$v" || "$v" == "null" ]]; then
        echo "[STOP] Champ manquant dans $APP_FILE" >&2
        exit 1
    fi
done
if [[ "$chart_name" != "gitea" || "$release" != "gitea" ]]; then
    echo "[STOP] Chart ou release inattendu : $chart_name / $release" >&2
    exit 1
fi
if [[ ! -f "$values_file" ]]; then
    echo "[STOP] Fichier de values absent : $values_file" >&2
    exit 1
fi
echo "[OK] Source : chart ${chart_name} ${chart_version} (${chart_repo}), values ${values_ref#\$values/}"

umask 077
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

helm template "$release" "$chart_name" --repo "$chart_repo" \
    --version "$chart_version" --namespace "$NS" --skip-tests \
    -f "$values_file" > "$rendered"

expected="$(printf '%s\n' \
    Deployment/gitea \
    PersistentVolumeClaim/gitea-shared-storage \
    Secret/gitea Secret/gitea-init Secret/gitea-inline-config \
    Service/gitea-http Service/gitea-ssh | LC_ALL=C sort)"
actual="$(yq -r '.kind + "/" + .metadata.name' "$rendered" |
    grep -v -- '^---$' | LC_ALL=C sort)"
if [[ "$actual" != "$expected" ]]; then
    echo "[STOP] Objets rendus inattendus :" >&2
    printf '%s\n' "$actual" >&2
    exit 1
fi
echo "[OK] Rendu conforme : 7 objets, ni Secret administrateur ni Namespace"

if [[ "$MODE" == "--render-check" ]]; then
    echo "[OK] Controle de rendu termine ; aucun acces au cluster"
    exit 0
fi

blocked=0

if ! k get namespace "$NS" -o name >/dev/null 2>&1; then
    echo "[STOP] Namespace $NS absent (scripts/gitea/restore.sh non execute ?)" >&2
    blocked=1
fi

if ! k -n "$NS" get secret gitea-admin-secret -o name >/dev/null 2>&1; then
    echo "[STOP] Secret gitea-admin-secret absent (restauration requise)" >&2
    blocked=1
fi

pvc_json="$(k -n "$NS" get pvc gitea-shared-storage -o json 2>/dev/null || true)"
if [[ -z "$pvc_json" ]]; then
    echo "[STOP] PVC gitea-shared-storage absent (restauration requise)" >&2
    blocked=1
else
    phase="$(jq -r '.status.phase' <<<"$pvc_json")"
    if [[ "$phase" != "Bound" ]]; then
        echo "[STOP] PVC non lie : $phase" >&2
        blocked=1
    fi
    if ! yq -o=json 'select(.kind=="PersistentVolumeClaim")' "$rendered" |
        jq -e --argjson live "$pvc_json" '
            .spec.storageClassName == $live.spec.storageClassName and
            .spec.resources.requests.storage == $live.spec.resources.requests.storage and
            .spec.accessModes == $live.spec.accessModes' >/dev/null; then
        echo "[STOP] La spec du PVC rendu differe du PVC restaure" >&2
        blocked=1
    fi
fi

if [[ -n "$(k -n "$NS" get deployment gitea --ignore-not-found -o name 2>/dev/null)" ]]; then
    echo "[STOP] Deployment gitea deja present : installation refusee" >&2
    blocked=1
fi
pods="$(k -n "$NS" get pods -o name 2>/dev/null || true)"
if [[ -n "$pods" ]]; then
    echo "[STOP] Pods presents dans le namespace $NS :" >&2
    printf '%s\n' "$pods" >&2
    blocked=1
fi

if (( blocked )); then
    echo "[STOP] Prevol refuse ; aucune ecriture Kubernetes" >&2
    exit 1
fi
echo "[OK] Prerequis : namespace, Secret admin, PVC lie et conforme, aucun Gitea en place"

k apply --dry-run=server -f "$rendered"
echo "[OK] Dry-run serveur accepte"

if [[ "$MODE" == "--preflight" ]]; then
    echo "[OK] Prevol termine ; aucune ecriture Kubernetes"
    exit 0
fi

k apply -f "$rendered"
kubectl --context "$CONTEXT" -n "$NS" rollout status deployment/gitea --timeout=300s
kubectl --context "$CONTEXT" -n "$NS" wait \
    --for=jsonpath='{.status.phase}'=Bound pvc/gitea-shared-storage --timeout=60s
echo "[OK] Gitea installe ; reprise par Argo CD a la synchronisation de l'Application gitea"
