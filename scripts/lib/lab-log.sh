# Bibliothèque de journalisation du lab. À charger avec « . », jamais à exécuter.
# lab_log_start ouvre une session ; lab_log_finish la finalise.
# Les scripts enfants écrivent dans les descripteurs hérités et ne créent pas
# leur propre journal lorsqu'une session est déjà active.

lab_log_start() {
    local mode="${1:-}"
    local commit="${2:-unknown}"
    local component="${3:-lab-recovery}"
    local timestamp run_id log_file fifo old_umask tee_pid unique_suffix

    [[ -n "$mode" && "$mode" =~ ^[a-z0-9-]+$ ]] || {
        printf '[STOP] Mode de journalisation invalide : %s\n' "$mode" >&2
        return 1
    }

    [[ "$component" =~ ^[a-z0-9-]+$ ]] || {
        printf '[STOP] Composant de journalisation invalide : %s\n' \
            "$component" >&2
        return 1
    }

    [[ "$commit" =~ ^([0-9a-f]{7,40}|unknown)$ ]] || {
        printf '[STOP] Commit de journalisation invalide : %s\n' \
            "$commit" >&2
        return 1
    }

    [[ "${LAB_LOG_ACTIVE:-0}" != "1" ]] || {
        printf '[STOP] Une session de journalisation est déjà active : %s\n' \
            "${LAB_LOG_FILE:-inconnue}" >&2
        return 1
    }

    [[ -n "${LAB_LOG_DIR:-}" && "$LAB_LOG_DIR" == /* ]] || {
        printf '[STOP] LAB_LOG_DIR doit être un chemin absolu\n' >&2
        return 1
    }

    if [[ -e "$LAB_LOG_DIR" || -L "$LAB_LOG_DIR" ]]; then
        [[ -d "$LAB_LOG_DIR" && ! -L "$LAB_LOG_DIR" ]] || {
            printf '[STOP] LAB_LOG_DIR existe mais n’est pas un répertoire sûr : %s\n' \
                "$LAB_LOG_DIR" >&2
            return 1
        }

        [[ "$(stat -c %a "$LAB_LOG_DIR")" == "700" ]] || {
            printf '[STOP] LAB_LOG_DIR doit être en mode 700 : %s\n' \
                "$LAB_LOG_DIR" >&2
            return 1
        }
    else
        old_umask="$(umask)"
        umask 077

        mkdir -m 700 -- "$LAB_LOG_DIR" || {
            umask "$old_umask"
            printf '[STOP] Création de LAB_LOG_DIR impossible : %s\n' \
                "$LAB_LOG_DIR" >&2
            return 1
        }

        umask "$old_umask"
    fi

    timestamp="$(date '+%Y%m%d-%H%M%S')" || return 1
    old_umask="$(umask)"
    umask 077

    log_file="$(
        mktemp "${LAB_LOG_DIR}/${component}-${mode}-${timestamp}-p$$-XXXXXX.log"
    )" || {
        umask "$old_umask"
        printf '[STOP] Création du journal impossible dans : %s\n' \
            "$LAB_LOG_DIR" >&2
        return 1
    }

    unique_suffix="${log_file%.log}"
    unique_suffix="${unique_suffix: -6}"
    run_id="${timestamp}-p$$-${unique_suffix}"
    fifo="${LAB_LOG_DIR}/.${component}-${run_id}.fifo"

    chmod 600 -- "$log_file" || {
        rm -f -- "$log_file"
        umask "$old_umask"
        printf '[STOP] Impossible de protéger le journal : %s\n' \
            "$log_file" >&2
        return 1
    }

    if ! mkfifo -m 600 -- "$fifo"; then
        rm -f -- "$log_file"
        umask "$old_umask"
        printf '[STOP] Création du canal de journalisation impossible\n' >&2
        return 1
    fi

    umask "$old_umask"

    exec 8>&1 9>&2

    tee -a "$log_file" < "$fifo" >&8 &
    tee_pid=$!

    if ! exec > "$fifo" 2>&1; then
        kill "$tee_pid" 2>/dev/null || true
        wait "$tee_pid" 2>/dev/null || true
        rm -f -- "$fifo" "$log_file"
        exec 8>&- 9>&-
        printf '[STOP] Activation de la journalisation impossible\n' >&2
        return 1
    fi

    rm -f -- "$fifo"

    LAB_RUN_ID="$run_id"
    LAB_RUN_MODE="$mode"
    LAB_LOG_FILE="$log_file"
    LAB_LOG_ACTIVE=1
    LAB_LOG_FINISHED=0
    LAB_LOG_OWNER_PID="$$"
    LAB_LOG_TEE_PID="$tee_pid"
    LAB_LOG_STARTED_AT="$(date '+%Y-%m-%dT%H:%M:%S%:z')"
    LAB_LOG_STARTED_EPOCH="$(date '+%s')"

    export \
        LAB_RUN_ID \
        LAB_RUN_MODE \
        LAB_LOG_FILE \
        LAB_LOG_ACTIVE \
        LAB_LOG_FINISHED \
        LAB_LOG_OWNER_PID \
        LAB_LOG_STARTED_AT

    printf '[LOG] event=start run=%s mode=%s pid=%s commit=%s started_at=%s\n' \
        "$LAB_RUN_ID" \
        "$LAB_RUN_MODE" \
        "$LAB_LOG_OWNER_PID" \
        "$commit" \
        "$LAB_LOG_STARTED_AT"

    printf '[LOG] file=%s\n' "$LAB_LOG_FILE"
}

lab_log_finish() {
    local rc="${1:-0}"
    local ended_at ended_epoch duration tee_rc=0

    [[ "$rc" =~ ^[0-9]+$ ]] && ((rc >= 0 && rc <= 255)) || {
        printf '[STOP] Code retour de journalisation invalide : %s\n' \
            "$rc" >&2
        return 1
    }

    if [[ "${LAB_LOG_FINISHED:-0}" == "1" ]]; then
        return "$rc"
    fi

    [[ "${LAB_LOG_ACTIVE:-0}" == "1" ]] || {
        printf '[STOP] Aucune session de journalisation active\n' >&2
        return 1
    }

    [[ "${LAB_LOG_OWNER_PID:-}" == "$$" ]] || {
        printf '[STOP] Seul le processus propriétaire peut finaliser le journal\n' >&2
        return 1
    }

    ended_at="$(date '+%Y-%m-%dT%H:%M:%S%:z')"
    ended_epoch="$(date '+%s')"
    duration=$((ended_epoch - LAB_LOG_STARTED_EPOCH))

    printf '[LOG] event=finish run=%s ended_at=%s duration_seconds=%s exit_code=%s\n' \
        "$LAB_RUN_ID" \
        "$ended_at" \
        "$duration" \
        "$rc"

    exec 1>&8 2>&9
    exec 8>&- 9>&-

    wait "$LAB_LOG_TEE_PID" || tee_rc=$?

    LAB_LOG_ACTIVE=0
    LAB_LOG_FINISHED=1

    export LAB_LOG_ACTIVE LAB_LOG_FINISHED

    if ((tee_rc != 0)); then
        printf '[STOP] Collecteur du journal terminé avec le code %s\n' \
            "$tee_rc" >&2
        return 1
    fi

    printf '[OK] Journal finalisé : %s\n' "$LAB_LOG_FILE"
    return "$rc"
}
