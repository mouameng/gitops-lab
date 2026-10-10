#!/usr/bin/env bash
# Secret de lecture du registre games sur les clusters workload.
# Le jeton games-puller (read:package) reste hors Git, dans ${LAB_CONFIG_DIR} (voir lab-paths.sh).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/lab-paths.sh" || { echo "[ERREUR] lab-paths.sh illisible" >&2; exit 1; }
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="${ROOT_DIR}/clusters/workloads.tsv"
TOKEN_FILE="${LAB_CONFIG_DIR}/gitea-games-registry-pull.token"
REGISTRY_HOST="gitea.local"
REGISTRY_URL="${REGISTRY_BASE_URL:-https://${REGISTRY_HOST}}"
REGISTRY_USER="games-puller"
SECRET_NAME="games-registry-pull"
# Un seul jeu aujourd'hui : namespace fixe, surchargeable pour les tests uniquement.
NAMESPACE="${PULL_SECRET_NAMESPACE:-game-2048}"

stop() { echo "[STOP] $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage : ensure-games-pull-secret.sh --help | --check | --apply | --verify
  --check   jeton local conforme et lecture du registre (EXTERNAL_DEPS_OFFLINE=1 : sans réseau)
  --apply   crée namespace et Secret sur les workloads ; refuse d'écraser un Secret différent
  --verify  contrôle en lecture seule que le Secret est conforme sur chaque workload
EOF
}

require_tools() {
  local t
  for t in kubectl jq base64 curl; do command -v "$t" >/dev/null || stop "Outil absent : $t"; done
  [[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || stop "Namespace invalide : $NAMESPACE"
}

read_token() {
  [[ -f "$TOKEN_FILE" && ! -L "$TOKEN_FILE" && -r "$TOKEN_FILE" ]] || stop "Jeton absent, illisible ou lien : $TOKEN_FILE"
  [[ "$(stat -c '%a' "$TOKEN_FILE")" == "600" ]] || stop "Mode 600 attendu : $TOKEN_FILE"
  TOKEN="$(<"$TOKEN_FILE")"
  [[ "$TOKEN" =~ ^[0-9a-f]{40}$ ]] || stop "Format du jeton inattendu"
  EXPECTED_AUTH="$(printf '%s:%s' "$REGISTRY_USER" "$TOKEN" | base64 -w0)"
}

check_registry() {
  local code
  code="$(printf 'user = "%s:%s"\n' "$REGISTRY_USER" "$TOKEN" | curl -sS -K - --max-time 20 \
    -o /dev/null -w '%{http_code}' "${REGISTRY_URL}/v2/games/2048/tags/list" 2>/dev/null || true)"
  [[ "$code" == "200" ]] || stop "Lecture du registre refusée ou injoignable (HTTP ${code:-000})"
  echo "[OK] Lecture du registre games par ${REGISTRY_USER} (HTTP 200)"
}

load_contexts() {
  [[ -f "$INVENTORY" && ! -L "$INVENTORY" ]] || stop "Inventaire absent : $INVENTORY"
  mapfile -t CONTEXTS < <(awk -F '\t' 'NR > 1 && $2 != "" { print "kind-" $2 }' "$INVENTORY")
  [[ "${#CONTEXTS[@]}" -gt 0 ]] || stop "Aucun workload dans l'inventaire"
}

cluster_state() {
  local ctx="$1" json current
  json="$(kubectl --context "$ctx" --request-timeout=15s -n "$NAMESPACE" \
    get secret "$SECRET_NAME" -o json --ignore-not-found 2>/dev/null)" || { echo error; return 0; }
  [[ -n "$json" ]] || { echo absent; return 0; }
  [[ "$(jq -r '.type' <<<"$json")" == "kubernetes.io/dockerconfigjson" ]] || { echo invalid; return 0; }
  current="$(jq -r '.data[".dockerconfigjson"] // empty' <<<"$json" | base64 -d 2>/dev/null \
    | jq -r --arg h "$REGISTRY_HOST" '.auths[$h].auth // empty' 2>/dev/null || true)"
  if [[ "$current" == "$EXPECTED_AUTH" ]]; then echo ok; else echo different; fi
}

survey() {
  local ctx s
  STATES=()
  for ctx in "${CONTEXTS[@]}"; do
    s="$(cluster_state "$ctx")"
    STATES+=("$s")
    echo "[INFO] ${ctx} : ${NAMESPACE}/${SECRET_NAME} = ${s}"
  done
}

verify_all() {
  local s
  survey
  for s in "${STATES[@]}"; do [[ "$s" == "ok" ]] || stop "Secret non conforme sur au moins un workload"; done
}

apply_all() {
  local i ctx s
  survey
  for s in "${STATES[@]}"; do
    case "$s" in absent|ok) ;; *) stop "État incompatible (${s}) : aucune création effectuée" ;; esac
  done
  TMP="$(mktemp -d)"; trap '[[ -z "${TMP:-}" ]] || rm -rf -- "$TMP"' EXIT
  AUTH="$EXPECTED_AUTH" jq -n --arg h "$REGISTRY_HOST" '{auths: {($h): {auth: env.AUTH}}}' > "$TMP/dockerconfig.json"
  for i in "${!CONTEXTS[@]}"; do
    ctx="${CONTEXTS[$i]}"
    if [[ "${STATES[$i]}" == "ok" ]]; then echo "[OK] Déjà conforme : ${ctx}"; continue; fi
    if [[ -z "$(kubectl --context "$ctx" get namespace "$NAMESPACE" -o name --ignore-not-found)" ]]; then
      jq -n --arg ns "$NAMESPACE" '{apiVersion:"v1",kind:"Namespace",metadata:{name:$ns,labels:{"app.kubernetes.io/part-of":"games"}}}' \
        | kubectl --context "$ctx" create -f - >/dev/null
      echo "[OK] Namespace créé : ${ctx}/${NAMESPACE}"
    fi
    kubectl --context "$ctx" -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
      --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson="$TMP/dockerconfig.json" >/dev/null
    echo "[OK] Secret créé : ${ctx}/${NAMESPACE}/${SECRET_NAME}"
  done
  verify_all
}

case "${1:-}" in
  --help|-h) usage ;;
  --check)
    require_tools; read_token; load_contexts
    echo "[OK] Jeton local conforme (mode 600, format valide)"
    if [[ "${EXTERNAL_DEPS_OFFLINE:-0}" == "1" ]]; then echo "[INFO] Contrôle réseau ignoré (EXTERNAL_DEPS_OFFLINE=1)"; else check_registry; fi
    echo "[RESULT] check=OK" ;;
  --apply)  require_tools; read_token; load_contexts; apply_all;  echo "[RESULT] apply=OK" ;;
  --verify) require_tools; read_token; load_contexts; verify_all; echo "[RESULT] verify=OK" ;;
  *) usage >&2; exit 2 ;;
esac
