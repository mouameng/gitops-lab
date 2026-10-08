#!/usr/bin/env bash
# check-github-mirror.sh — contrôle du push mirror Gitea -> GitHub (dépôt de secours).
#
# Modes :
#   --check   lecture seule : expiration du PAT GitHub, état du mirror (API Gitea),
#             égalité des branches et tags Gitea / GitHub. Aucune écriture, aucune question.
#   --update  remédiation (rotation du PAT) : NON IMPLÉMENTÉ dans cette version.
#
# Codes retour (--check) :
#   0 = OK   2 = AVERTISSEMENT   3 = CRITIQUE   1 = usage ou erreur interne
# La politique (profil lab / exploit) appartient au bootstrap, pas à ce script.
#
# Secrets : le jeton Gitea est lu dans un fichier 600 et transmis à curl par stdin
# (jamais en argument). Le PAT GitHub n'est jamais lu par --check.

set -euo pipefail

GITEA_URL="${GITEA_URL:-https://gitea.local}"
GITEA_OWNER="${GITEA_OWNER:-gitea_admin}"
GITEA_REPO="${GITEA_REPO:-gitops-lab}"
GITHUB_URL="${GITHUB_URL:-https://github.com/mouameng/gitops-lab.git}"
GITEA_TOKEN_FILE="${GITEA_GIT_TOKEN_FILE:-$HOME/.config/gitops-lab/gitea-git-token}"
EXPIRY_FILE="${GITHUB_MIRROR_EXPIRY_FILE:-$HOME/.config/gitops-lab/github-mirror-token.env}"
WARN_DAYS="${MIRROR_WARN_DAYS:-14}"
CRIT_HOURS="${MIRROR_CRIT_HOURS:-24}"

GITEA_GIT_URL="${GITEA_URL}/${GITEA_OWNER}/${GITEA_REPO}.git"

usage() { echo "Usage : $0 --check | --update" >&2; exit 1; }
(($# == 1)) || usage

# Niveaux : 0 OK, 2 WARN, 3 CRIT
token_level=0; mirror_level=0; refs_level=0

level_name() { case "$1" in 0) echo OK ;; 2) echo WARN ;; *) echo CRIT ;; esac; }

check_tools() {
    local tool
    for tool in curl jq git date timeout; do
        command -v "$tool" >/dev/null || { echo "[STOP] Outil absent : $tool" >&2; exit 1; }
    done
    [[ "$WARN_DAYS" =~ ^[0-9]+$ && "$CRIT_HOURS" =~ ^[0-9]+$ ]] ||
        { echo "[STOP] Seuils invalides" >&2; exit 1; }
}

# 1. Expiration du PAT GitHub (date déclarée localement, sans le secret)
check_token_expiry() {
    local expires exp_epoch now remaining
    if [[ ! -f "$EXPIRY_FILE" || -L "$EXPIRY_FILE" ]]; then
        echo "[CRIT] Fichier d'expiration absent ou lien symbolique : $EXPIRY_FILE"
        token_level=3; return
    fi
    expires="$(sed -n 's/^GITHUB_MIRROR_TOKEN_EXPIRES=\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)$/\1/p' "$EXPIRY_FILE")"
    if [[ -z "$expires" ]] || ! exp_epoch="$(date -d "$expires" +%s 2>/dev/null)"; then
        echo "[CRIT] Date d'expiration absente ou invalide"
        token_level=3; return
    fi
    # Convention prudente : le jeton est considéré expiré dès 00:00 (heure locale) du jour affiché.
    now="$(date +%s)"
    remaining=$((exp_epoch - now))
    if ((remaining <= CRIT_HOURS * 3600)); then
        echo "[CRIT] PAT GitHub expiré ou expirant sous ${CRIT_HOURS} h (échéance $expires)"
        token_level=3
    elif ((remaining <= WARN_DAYS * 86400)); then
        echo "[WARN] PAT GitHub expirant sous ${WARN_DAYS} jours (échéance $expires, reste $((remaining / 86400)) j)"
        token_level=2
    else
        echo "[OK] PAT GitHub valide jusqu'au $expires (reste $((remaining / 86400)) j)"
    fi
}

# 2. État du mirror via l'API Gitea (lecture seule)
check_mirror_api() {
    local json summary
    if [[ ! -f "$GITEA_TOKEN_FILE" || -L "$GITEA_TOKEN_FILE" || ! -s "$GITEA_TOKEN_FILE" ]] ||
       [[ "$(stat -c %a "$GITEA_TOKEN_FILE")" != "600" ]]; then
        echo "[CRIT] Jeton Gitea absent, vide, lien symbolique ou mode différent de 600"
        mirror_level=3; return
    fi
    if ! json="$(
        { printf 'Authorization: token '; tr -d '[:space:]' < "$GITEA_TOKEN_FILE"; printf '\n'; } |
        curl --silent --show-error --fail --connect-timeout 10 --max-time 30 \
            --header @- \
            "${GITEA_URL}/api/v1/repos/${GITEA_OWNER}/${GITEA_REPO}/push_mirrors?limit=50"
    )"; then
        echo "[CRIT] API Gitea inaccessible ou refusée"
        mirror_level=3; return
    fi
    # Filtre sur l'URL GitHub (hors identifiants éventuels) ; jamais d'affichage de last_error brut.
    if ! summary="$(jq -er --arg url "${GITHUB_URL#https://}" '
        if type != "array" then error("réponse inattendue") else . end
        | map(select((.remote_address // "") | contains($url)))
        | "\(length) \(map(select((.last_error // "") != "")) | length) \(map(select(.last_update == null)) | length) \(map(select(.sync_on_commit == true)) | length)"
    ' <<< "$json")"; then
        echo "[CRIT] Réponse API Gitea illisible"
        mirror_level=3; return
    fi
    local count errors never sync
    read -r count errors never sync <<< "$summary"
    if ((count == 0)); then
        echo "[CRIT] Aucun push mirror vers ${GITHUB_URL}"
        mirror_level=3
    elif ((errors > 0)); then
        echo "[CRIT] Push mirror en erreur ($errors/$count) ; consulter Gitea > Réglages Miroir"
        mirror_level=3
    elif ((never > 0)); then
        echo "[CRIT] Push mirror jamais synchronisé ($never/$count)"
        mirror_level=3
    else
        echo "[OK] Push mirror présent ($count), sans erreur, sync_on_commit actif sur $sync"
        ((sync == count)) || { echo "[WARN] sync_on_commit inactif sur au moins un mirror"; mirror_level=2; }
        ((count == 1)) || echo "[INFO] $count mirrors vers GitHub (rotation en cours ?)"
    fi
}

# 3. Égalité des branches et tags (lecture anonyme des deux côtés)
check_refs() {
    local gitea_refs github_refs
    if ! gitea_refs="$(GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote --heads --tags "$GITEA_GIT_URL" | sort)"; then
        echo "[CRIT] Lecture des références Gitea impossible"
        refs_level=3; return
    fi
    if ! github_refs="$(GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote --heads --tags "$GITHUB_URL" | sort)"; then
        echo "[CRIT] Lecture des références GitHub impossible"
        refs_level=3; return
    fi
    if [[ -z "$gitea_refs" ]]; then
        echo "[CRIT] Aucune référence côté Gitea"
        refs_level=3
    elif [[ "$gitea_refs" == "$github_refs" ]]; then
        echo "[OK] Branches et tags identiques ($(wc -l <<< "$gitea_refs") références)"
    else
        echo "[CRIT] Références Gitea / GitHub différentes :"
        diff <(printf '%s\n' "$gitea_refs") <(printf '%s\n' "$github_refs") |
            sed -n 's/^\([<>]\) /  \1 /p' | sed 's/^  </  Gitea  :/; s/^  >/  GitHub :/' || true
        refs_level=3
    fi
}

case "$1" in
    --check)
        check_tools
        echo "=== Contrôle du dépôt de secours GitHub (lecture seule) ==="
        check_token_expiry
        check_mirror_api
        check_refs
        overall=$token_level
        ((mirror_level > overall)) && overall=$mirror_level
        ((refs_level > overall)) && overall=$refs_level
        echo "[RESULT] global=$(level_name $overall) token=$(level_name $token_level) mirror=$(level_name $mirror_level) refs=$(level_name $refs_level)"
        exit "$overall"
        ;;
    --update)
        echo "[STOP] --update non implémenté dans cette version" >&2
        exit 1
        ;;
    *) usage ;;
esac
