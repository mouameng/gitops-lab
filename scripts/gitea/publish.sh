#!/usr/bin/env bash
# Publie main vers Gitea par kubectl port-forward (avant que Traefik et
# gitea.local existent). Jamais de --force. Jeton lu dans un fichier 600,
# transmis a Git par GIT_ASKPASS (jamais en argument de commande).
# Usage : scripts/gitea/publish.sh --check          (avance rapide possible)
#         scripts/gitea/publish.sh --check-aligned  (HEAD strictement aligne)
#         scripts/gitea/publish.sh --push <sha>     (fast-forward de main)
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../lib/lab-paths.sh" || { echo "[ERREUR] lab-paths.sh illisible" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPTS_DIR/.." && pwd -P)"
CONTEXT="${MGMT_CONTEXT:-kind-gitops-management}"
TOKEN_FILE="${GITEA_GIT_TOKEN_FILE:-${LAB_CONFIG_DIR}/gitea-git-token}"
REPO_PATH="platform/infrastructure-devops"
LOCAL_PORT="${GITEA_PF_PORT:-13000}"
MODE="${1:-}"
TARGET="${2:-}"

stop() { echo "[STOP] $*" >&2; exit 1; }

case "$MODE" in
    --check|--check-aligned)
        TARGET="$(git -C "$ROOT_DIR" rev-parse HEAD)"
        ;;
    --push)
        [[ "$TARGET" =~ ^[0-9a-f]{40}$ ]] || stop "--push exige un SHA complet (40 caracteres)"
        ;;
    *)
        echo "Usage : $0 --check | --check-aligned | --push <sha>" >&2
        exit 2
        ;;
esac

git -C "$ROOT_DIR" cat-file -e "${TARGET}^{commit}" 2>/dev/null ||
    stop "Commit inconnu du depot local : $TARGET"

if [[ ! -f "$TOKEN_FILE" || -L "$TOKEN_FILE" || ! -s "$TOKEN_FILE" ]]; then
    stop "Fichier de jeton absent, vide ou lien symbolique : $TOKEN_FILE"
fi
[[ "$(stat -c %a "$TOKEN_FILE")" == "600" ]] ||
    stop "Le fichier de jeton doit etre en mode 600 : $TOKEN_FILE"
echo "[OK] Fichier de jeton present (600)"

if ss -ltn "( sport = :${LOCAL_PORT} )" | grep -q LISTEN; then
    stop "Port local ${LOCAL_PORT} deja utilise (GITEA_PF_PORT pour en changer)"
fi

pf_pid=""
askpass=""
cleanup() {
    if [[ -n "$pf_pid" ]]; then
        kill "$pf_pid" 2>/dev/null || true
        wait "$pf_pid" 2>/dev/null || true
    fi
    if [[ -n "$askpass" ]]; then
        rm -f "$askpass"
    fi
}
trap cleanup EXIT

kubectl --context "$CONTEXT" -n gitea port-forward --address 127.0.0.1 \
    deploy/gitea "${LOCAL_PORT}:3000" >/dev/null 2>&1 &
pf_pid=$!

ready=0
for _ in $(seq 1 30); do
    if ! kill -0 "$pf_pid" 2>/dev/null; then
        stop "port-forward vers deploy/gitea interrompu"
    fi
    if curl -fsS -o /dev/null "http://127.0.0.1:${LOCAL_PORT}/api/healthz" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 1
done
(( ready )) || stop "Gitea ne repond pas sur 127.0.0.1:${LOCAL_PORT}"
echo "[OK] Gitea joignable par port-forward (127.0.0.1:${LOCAL_PORT})"

umask 077
askpass="$(mktemp)"
printf '#!/bin/sh\ncase "$1" in\n  Username*) echo gitea_admin ;;\n  *) cat "%s" ;;\nesac\n' \
    "$TOKEN_FILE" > "$askpass"
chmod 700 "$askpass"

url="http://127.0.0.1:${LOCAL_PORT}/${REPO_PATH}.git"
g() {
    GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
        git -C "$ROOT_DIR" -c credential.helper= "$@"
}

remote_main="$(g ls-remote "$url" refs/heads/main | cut -f1)"
[[ "$remote_main" =~ ^[0-9a-f]{40}$ ]] || stop "main absent ou depot illisible"
git -C "$ROOT_DIR" cat-file -e "${remote_main}^{commit}" 2>/dev/null ||
    stop "main distant (${remote_main:0:8}) inconnu du depot local : divergence"
git -C "$ROOT_DIR" merge-base --is-ancestor "$remote_main" "$TARGET" ||
    stop "Publication refusee : ${TARGET:0:8} n'avance pas main distant (${remote_main:0:8})"
echo "[OK] Avance rapide possible : main distant ${remote_main:0:8} -> ${TARGET:0:8}"

if [[ "$MODE" == "--check-aligned" ]]; then
    [[ "$remote_main" == "$TARGET" ]] ||
        stop "HEAD local (${TARGET:0:8}) et main distant (${remote_main:0:8}) differents"
    echo "[OK] HEAD local strictement aligne avec main distant"
fi

if [[ "$MODE" == "--check" || "$MODE" == "--check-aligned" ]]; then
    g push --dry-run "$url" "${TARGET}:refs/heads/main"
    echo "[OK] Dry-run accepte (jeton valide, droits d'ecriture) ; rien n'a ete publie"
    exit 0
fi

g push "$url" "${TARGET}:refs/heads/main"
actual="$(g ls-remote "$url" refs/heads/main | cut -f1)"
[[ "$actual" == "$TARGET" ]] || stop "main distant (${actual:0:8}) different du commit publie"
echo "[OK] main publie sur Gitea : ${TARGET}"
