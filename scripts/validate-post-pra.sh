#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"

. "$ROOT_DIR/scripts/lib/lab-paths.sh" || {
    echo "[ERREUR] lab-paths.sh illisible" >&2
    exit 1
}

usage() {
    echo "Usage : $0 --backup AAAAMMJJ-HHMMSS" >&2
    exit 1
}

[[ "${1:-}" == "--backup" && "$#" -eq 2 ]] || usage

GITEA_GAME="$2"

[[ "$GITEA_GAME" =~ ^[0-9]{8}-[0-9]{6}$ ]] || {
    echo "[STOP] Identifiant de sauvegarde invalide" >&2
    exit 1
}

CTX="${MGMT_CONTEXT:-kind-gitops-management}"
TOKEN="${GITEA_DISCOVERY_TOKEN_FILE:-$LAB_CONFIG_DIR/gitea-repository-discovery.token}"
TMP="$(mktemp -d)"

trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

[[ -f "$TOKEN" && "$(stat -c '%a' "$TOKEN")" == 600 ]] || {
    echo "[STOP] Jeton de découverte absent ou hors mode 600" >&2
    exit 1
}

(
    umask 077
    printf 'Authorization: token %s\n' \
        "$(tr -d '[:space:]' < "$TOKEN")" > "$TMP/auth.hdr"
)

check_repo() {
    local org="$1"
    local repo="$2"
    local out="$TMP/${org}.json"

    curl -fsS \
        -H @"$TMP/auth.hdr" \
        "https://gitea.local/api/v1/orgs/${org}/repos" \
        -o "$out"

    jq -e --arg full "${org}/${repo}" '
        any(
            .[];
            .full_name == $full
            and .default_branch == "main"
            and .has_actions == true
        )
    ' "$out" > /dev/null || {
        echo "[STOP] Dépôt absent ou non conforme : ${org}/${repo}" >&2
        exit 1
    }

    echo "[OK] Dépôt restauré : ${org}/${repo}, branche main, Actions actives"
}

echo "=== 1. Dépôts Gitea restaurés ==="

check_repo platform infrastructure-devops
check_repo games 2048

echo "=== 2. Référence principale de la plateforme ==="

platform_sha="$(
    GIT_TERMINAL_PROMPT=0 timeout 30 \
        git ls-remote \
        https://gitea.local/platform/infrastructure-devops.git \
        refs/heads/main \
    | awk '{print $1}'
)"

local_sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"

[[ -n "$platform_sha" && "$platform_sha" == "$local_sha" ]] || {
    echo "[STOP] platform/main non aligné avec HEAD" >&2
    echo "local=$local_sha" >&2
    echo "gitea=$platform_sha" >&2
    exit 1
}

echo "[OK] platform/main aligné : ${platform_sha:0:12}"

echo "=== 3. Dépôts applicatifs de secours ==="

while IFS=$'\t' read -r \
    id status g_owner g_repo gh_owner gh_repo refs
do
    [[ -z "$id" || "$id" == \#* ]] && continue
    [[ "$status" == "REQUIRED" ]] || continue

    g_sha="$(
        GIT_TERMINAL_PROMPT=0 timeout 30 \
            git ls-remote \
            "https://gitea.local/${g_owner}/${g_repo}.git" \
            refs/heads/main \
        | awk '{print $1}'
    )"

    gh_sha="$(
        GIT_TERMINAL_PROMPT=0 timeout 30 \
            git ls-remote \
            "git@github.com:${gh_owner}/${gh_repo}.git" \
            refs/heads/main \
        | awk '{print $1}'
    )"

    [[ -n "$g_sha" && "$g_sha" == "$gh_sha" ]] || {
        echo "[STOP] ${g_owner}/${g_repo} non aligné avec GitHub" >&2
        exit 1
    }

    echo "[OK] Dépôt de secours aligné : ${g_owner}/${g_repo} (${g_sha:0:12})"
done < "$ROOT_DIR/scripts/git-backup-repositories.tsv"

echo "=== 4. Applications Argo CD ==="

apps_json="$TMP/applications.json"

kubectl --context "$CTX" -n argocd \
    get applications -o json > "$apps_json"

app_count="$(jq '.items | length' "$apps_json")"

[[ "$app_count" -gt 0 ]] || {
    echo "[STOP] Aucune Application Argo CD trouvée" >&2
    exit 1
}

bad_apps="$(
    jq -r '
        .items[]
        | select(
            .status.sync.status != "Synced"
            or .status.health.status != "Healthy"
        )
        | [
            .metadata.name,
            .status.sync.status,
            .status.health.status
        ]
        | @tsv
    ' "$apps_json"
)"

[[ -z "$bad_apps" ]] || {
    echo "[STOP] Applications Argo CD non conformes :" >&2
    echo "$bad_apps" >&2
    exit 1
}

echo "[OK] Applications Argo CD conformes : $app_count Synced/Healthy"

echo "=== 5. Runner Gitea Actions ==="

NS=gitea-runner
STS=gitea-runner
POD=gitea-runner-0

ready="$(
    kubectl --context "$CTX" -n "$NS" \
        get statefulset "$STS" \
        -o jsonpath='{.status.readyReplicas}'
)"

current="$(
    kubectl --context "$CTX" -n "$NS" \
        get statefulset "$STS" \
        -o jsonpath='{.status.currentReplicas}'
)"

[[ "$ready" == "1" && "$current" == "1" ]] || {
    echo "[STOP] StatefulSet runner non prêt" >&2
    exit 1
}

kubectl --context "$CTX" -n "$NS" \
    get pod "$POD" -o json > "$TMP/runner.json"

jq -e '
    .status.phase == "Running"
    and ([.status.containerStatuses[]?.ready] | all)
    and ([.status.containerStatuses[]?.restartCount] | add == 0)
' "$TMP/runner.json" > /dev/null || {
    echo "[STOP] Pod runner non conforme" >&2
    exit 1
}

pvc_status="$(
    kubectl --context "$CTX" -n "$NS" \
        get pvc data-gitea-runner-0 \
        -o jsonpath='{.status.phase}'
)"

[[ "$pvc_status" == "Bound" ]] || {
    echo "[STOP] PVC runner non lié" >&2
    exit 1
}

runner_logs="$(
    kubectl --context "$CTX" -n "$NS" \
        logs "$POD" -c runner --tail=200
)"

for marker in \
    "Runner registered successfully" \
    "Docker is ready" \
    "declare successfully"
do
    grep -Fq "$marker" <<< "$runner_logs" || {
        echo "[STOP] Marqueur runner absent : $marker" >&2
        exit 1
    }
done

echo "[OK] Runner lab-games enregistré, Docker prêt, StatefulSet 1/1, PVC Bound"

echo "[RESULT] PRA=OK backup=$GITEA_GAME commit=${local_sha:0:12} apps=$app_count"
