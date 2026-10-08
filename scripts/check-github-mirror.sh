#!/usr/bin/env bash
# check-github-mirror.sh — contrôle du push mirror Gitea -> GitHub (dépôt de secours).
#
# Modes :
#   --check   lecture seule : expiration du PAT GitHub, état du mirror (API Gitea),
#             égalité des branches et tags Gitea / GitHub. Aucune écriture, aucune question.
#   --update  remédiation interactive (TTY requis) selon le résultat de --check :
#             - tout OK                  : rien à faire ;
#             - PAT WARN/CRIT ou mirror CRIT : rotation du PAT sans coupure
#               (création d'un second mirror, synchro, contrôle, puis suppression de l'ancien) ;
#             - seules les références diffèrent : arrêt, inspection manuelle (pas de push forcé aveugle).
#             Codes retour : 0 = remédié et contrôle final OK, 3 = échec ou abandon.
#
# Codes retour (--check) :
#   0 = OK   2 = AVERTISSEMENT   3 = CRITIQUE   1 = usage ou erreur interne
# La politique (profil lab / exploit) appartient au bootstrap, pas à ce script.
#
# Secrets : le jeton Gitea est lu dans un fichier 600 et transmis à curl par stdin
# (jamais en argument). Le PAT GitHub n'est jamais lu par --check ; --update le saisit
# en masqué et ne l'écrit que dans un fichier temporaire 600, supprimé en sortie.

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
        | "\(length) \(map(select((.last_error // "") != "")) | length) \(map(select(.last_update == null or ((.last_update // "") | startswith("0001-")))) | length) \(map(select(.sync_on_commit == true)) | length)"
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

# ---------------------------------------------------------------------------
# --update : rotation du PAT GitHub sans période sans mirror
# ---------------------------------------------------------------------------
TMPDIR_UPD=""
NEW_MIRROR=""
cleanup_update() {
    local rc=$?
    if [[ -n "$NEW_MIRROR" ]]; then
        echo "[ROLLBACK] Suppression du nouveau mirror $NEW_MIRROR ; l'ancien reste en place"
        api DELETE "/push_mirrors/${NEW_MIRROR}" >/dev/null 2>&1 ||
            echo "[WARN] Rollback impossible : supprimer $NEW_MIRROR dans Gitea > Réglages Miroir"
    fi
    [[ -n "$TMPDIR_UPD" ]] && rm -rf -- "$TMPDIR_UPD"
    exit "$rc"
}

# api METHOD CHEMIN [fichier_corps] : appel API Gitea, en-tête lu depuis un fichier 600
api() {
    local method="$1" path="$2" body="${3:-}"
    local args=(--silent --show-error --fail --connect-timeout 10 --max-time 30
                --request "$method" --header "@${TMPDIR_UPD}/auth.hdr")
    [[ -n "$body" ]] && args+=(--header 'Content-Type: application/json' --data "@${body}")
    curl "${args[@]}" "${GITEA_URL}/api/v1/repos/${GITEA_OWNER}/${GITEA_REPO}${path}"
}

run_update() {
    local rc=0
    trap cleanup_update EXIT
    echo "=== Remédiation du dépôt de secours GitHub ==="
    "$0" --check || rc=$?
    case "$rc" in
        0) echo "[OK] Aucun écart ; aucune remédiation nécessaire"; trap - EXIT; exit 0 ;;
        2|3) ;;
        *) echo "[STOP] --check en erreur interne ($rc)" >&2; exit 3 ;;
    esac
    # Re-lire les niveaux pour choisir l'action
    check_token_expiry >/dev/null
    check_mirror_api >/dev/null
    check_refs >/dev/null
    if ((token_level == 0 && mirror_level < 3)); then
        if ((refs_level == 3)); then
            echo "[STOP] Seules les références diffèrent : inspection manuelle requise (pas de push forcé automatique)" >&2
            exit 3
        fi
        echo "[OK] Avertissement non lié au jeton ; aucune rotation lancée"; trap - EXIT; exit 0
    fi

    [[ -t 0 && -r /dev/tty ]] || { echo "[STOP] Terminal interactif requis pour saisir le nouveau PAT" >&2; exit 3; }

    TMPDIR_UPD="$(mktemp -d)"; chmod 700 "$TMPDIR_UPD"
    local gitea_token
    gitea_token="$(tr -d '[:space:]' < "$GITEA_TOKEN_FILE")"
    ( umask 077; printf 'Authorization: token %s\n' "$gitea_token" > "${TMPDIR_UPD}/auth.hdr" )
    unset gitea_token

    echo "Créer d'abord le nouveau PAT dans GitHub (fine-grained, dépôt gitops-lab, Contents: Read and write)."
    local new_pat new_exp exp_epoch
    read -r -s -p "Nouveau PAT GitHub (saisie masquée, vide = abandon) : " new_pat < /dev/tty; echo
    [[ -n "$new_pat" ]] || { echo "[STOP] Saisie annulée ; mirror inchangé" >&2; exit 3; }
    [[ "$new_pat" =~ ^github_pat_[A-Za-z0-9_]+$ ]] ||
        { unset new_pat; echo "[STOP] Format de PAT inattendu (github_pat_...) ; mirror inchangé" >&2; exit 3; }
    read -r -p "Date d'expiration affichée par GitHub (AAAA-MM-JJ) : " new_exp < /dev/tty
    if [[ ! "$new_exp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
       ! exp_epoch="$(date -d "$new_exp" +%s 2>/dev/null)" ||
       ((exp_epoch - $(date +%s) <= CRIT_HOURS * 3600)); then
        unset new_pat; echo "[STOP] Date invalide ou trop proche ; mirror inchangé" >&2; exit 3
    fi

    # Corps JSON : le PAT ne contient que [A-Za-z0-9_], aucun échappement nécessaire.
    ( umask 077
      printf '{"remote_address":"%s","remote_username":"%s","remote_password":"%s","interval":"%s","sync_on_commit":true}\n' \
        "$GITHUB_URL" "${GITHUB_USER:-mouameng}" "$new_pat" "${MIRROR_INTERVAL:-1h0m0s}" > "${TMPDIR_UPD}/body.json" )
    unset new_pat

    local created
    if ! created="$(api POST /push_mirrors "${TMPDIR_UPD}/body.json")"; then
        echo "[STOP] Création du nouveau mirror refusée par Gitea ; ancien mirror inchangé" >&2; exit 3
    fi
    rm -f -- "${TMPDIR_UPD}/body.json"
    NEW_MIRROR="$(jq -er '.remote_name' <<< "$created")" ||
        { echo "[STOP] Réponse de création illisible" >&2; exit 3; }
    echo "[OK] Nouveau mirror créé : $NEW_MIRROR"

    api POST /push_mirrors-sync >/dev/null || { echo "[STOP] Synchronisation refusée" >&2; exit 3; }
    local i state ok=0
    for i in $(seq 1 18); do
        sleep 10
        state="$(api GET "/push_mirrors/${NEW_MIRROR}" | jq -r '
            if (.last_error // "") != "" then "error"
            elif .last_update == null or ((.last_update // "") | startswith("0001-")) then "pending"
            else "ok" end')" || state="pending"
        echo "[INFO] Synchronisation du nouveau mirror : $state ($((i * 10)) s)"
        [[ "$state" == "error" ]] && { echo "[STOP] Nouveau mirror en erreur (jeton ou droits ?)" >&2; exit 3; }
        [[ "$state" == "ok" ]] && { ok=1; break; }
    done
    ((ok == 1)) || { echo "[STOP] Nouveau mirror non synchronisé après 180 s" >&2; exit 3; }

    refs_level=0; check_refs
    ((refs_level == 0)) || { echo "[STOP] Références différentes après synchronisation" >&2; exit 3; }

    # Le nouveau mirror est validé : il ne doit plus être supprimé par le rollback.
    local keep="$NEW_MIRROR"; NEW_MIRROR=""
    local old
    while read -r old; do
        [[ -n "$old" ]] || continue
        api DELETE "/push_mirrors/${old}" >/dev/null &&
            echo "[OK] Ancien mirror supprimé : $old" ||
            echo "[WARN] Suppression impossible de $old : à faire dans Gitea > Réglages Miroir"
    done < <(api GET "/push_mirrors?limit=50" | jq -r --arg url "${GITHUB_URL#https://}" --arg keep "$keep" '
        .[] | select((.remote_address // "") | contains($url)) | select(.remote_name != $keep) | .remote_name')

    ( umask 077
      printf 'GITHUB_MIRROR_TOKEN_EXPIRES=%s\n' "$new_exp" > "${EXPIRY_FILE}.new" &&
      mv -f -- "${EXPIRY_FILE}.new" "$EXPIRY_FILE" )
    echo "[OK] Date d'expiration enregistrée : $new_exp"
    echo "[INFO] L'ancien PAT peut maintenant être révoqué dans GitHub"

    rc=0; "$0" --check || rc=$?
    ((rc != 3)) || { echo "[STOP] Contrôle final critique" >&2; exit 3; }
    ((rc == 0)) || echo "[WARN] Contrôle final en avertissement (seuils ou sync_on_commit à vérifier)"
    trap - EXIT; rm -rf -- "$TMPDIR_UPD"
    echo "[OK] Rotation terminée"
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
        check_tools
        run_update
        ;;
    *) usage ;;
esac
