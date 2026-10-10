#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../lib/lab-paths.sh" || { echo "[ERREUR] lab-paths.sh illisible" >&2; exit 1; }

BACKUP_DIR="${GITEA_BACKUP_DIR:-${LAB_GITEA_BACKUP_DIR}}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
READER_MANIFEST="$SCRIPTS_DIR/manifests/gitea-backup-reader.yaml"

validate_game() {
    local dir="$1"
    local name expected actual key member size

    [[ -d "$dir" && ! -L "$dir" ]] || {
        echo "[STOP] Dossier de jeu invalide" >&2
        return 1
    }

    for name in manifest.json data.tar.gz admin-secret.json; do
        [[ -f "$dir/$name" && ! -L "$dir/$name" ]] || {
            echo "[STOP] Fichier absent ou invalide : $name" >&2
            return 1
        }
    done

    jq -e '
        .format_version == 1 and
        (.created_at | type == "string" and length > 0) and
        .data_file == "data.tar.gz" and
        .admin_file == "admin-secret.json" and
        (.data_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.admin_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    ' "$dir/manifest.json" >/dev/null || {
        echo "[STOP] Manifeste invalide" >&2
        return 1
    }

    for name in data.tar.gz admin-secret.json; do
        if [[ "$name" == "data.tar.gz" ]]; then
            key="data_sha256"
        else
            key="admin_sha256"
        fi
        expected="$(jq -r --arg key "$key" '.[$key]' "$dir/manifest.json")"
        actual="$(sha256sum "$dir/$name" | cut -d ' ' -f 1)"
        [[ "$actual" == "$expected" ]] || {
            echo "[STOP] Empreinte incorrecte : $name" >&2
            return 1
        }
    done

    gzip -t "$dir/data.tar.gz" &&
    tar -tzf "$dir/data.tar.gz" >/dev/null || {
        echo "[STOP] Archive illisible" >&2
        return 1
    }

    if ! tar -tzf "$dir/data.tar.gz" | awk '
        $0 == "./gitea.db" { db=1 }
        $0 == "./gitea/conf/app.ini" { config=1 }
        $0 == "./git/gitea-repositories/" { repos=1 }
        END { exit !(db && config && repos) }
    '; then
        echo "[STOP] Données Gitea indispensables absentes de l'archive" >&2
        return 1
    fi

    for member in ./gitea.db ./gitea/conf/app.ini; do
        if ! size="$(tar -xOzf "$dir/data.tar.gz" "$member" | wc -c)"; then
            echo "[STOP] Lecture impossible : $member" >&2
            return 1
        fi
        if (( size == 0 )); then
            echo "[STOP] Fichier vide dans l'archive : $member" >&2
            return 1
        fi
    done

    jq -e '
        .kind == "Secret" and
        .metadata.name == "gitea-admin-secret" and
        .metadata.namespace == "gitea" and
        (.data.username | type == "string" and length > 0) and
        (.data.password | type == "string" and length > 0)
    ' "$dir/admin-secret.json" >/dev/null || {
        echo "[STOP] Structure du Secret administrateur invalide" >&2
        return 1
    }

    echo "[OK] Jeu contrôlé : $(basename "$dir")"
}

check_live_gitea() {
    local context="kind-gitops-management"
    local namespace="gitea"
    local state pvc secret

    state="$(kubectl --context "$context" -n "$namespace" \
        get deployment gitea -o json |
        jq -r '[.spec.replicas, (.status.readyReplicas // 0),
                .spec.strategy.type] | @tsv')"

    [[ "$state" == $'1\t1\tRecreate' ]] || {
        echo "[STOP] Gitea doit avoir un réplica prêt en Recreate" >&2
        return 1
    }

    pvc="$(kubectl --context "$context" -n "$namespace" \
        get pvc gitea-shared-storage -o jsonpath='{.status.phase}')"
    [[ "$pvc" == "Bound" ]] || {
        echo "[STOP] PVC Gitea non lié" >&2
        return 1
    }

    secret="$(kubectl --context "$context" -n "$namespace" \
        get secret gitea-admin-secret -o name)"
    [[ "$secret" == "secret/gitea-admin-secret" ]] || {
        echo "[STOP] Secret administrateur absent" >&2
        return 1
    }

    echo "[OK] Gitea prête pour une sauvegarde contrôlée"
}

check_reader_manifest() {
    [[ -f "$READER_MANIFEST" && ! -L "$READER_MANIFEST" ]] || {
        echo "[STOP] Manifeste du pod lecteur absent ou invalide" >&2
        return 1
    }

    yq -e '
        .kind == "Pod" and
        .metadata.name == "gitea-backup-reader" and
        .metadata.namespace == "gitea" and
        .spec.containers[0].name == "reader" and
        .spec.containers[0].volumeMounts[0].mountPath == "/data" and
        .spec.containers[0].volumeMounts[0].readOnly == true and
        .spec.volumes[0].persistentVolumeClaim.claimName == "gitea-shared-storage" and
        .spec.volumes[0].persistentVolumeClaim.readOnly == true
    ' "$READER_MANIFEST" >/dev/null || {
        echo "[STOP] Manifeste du pod lecteur non conforme" >&2
        return 1
    }

    kubectl --context kind-gitops-management \
        apply --dry-run=server -f "$READER_MANIFEST" >/dev/null
    echo "[OK] Manifeste du pod lecteur contrôlé"
}

wait_gitea_pods_gone() {
    local selector='app.kubernetes.io/instance=gitea,app.kubernetes.io/name=gitea'
    local count attempt

    for ((attempt = 1; attempt <= 60; attempt++)); do
        count="$(kubectl --context kind-gitops-management -n gitea \
            get pods -l "$selector" -o json |
            jq '.items | length')" || return 1

        if (( count == 0 )); then
            echo "[OK] Pods Gitea disparus"
            return 0
        fi
        sleep 3
    done

    echo "[STOP] Pods Gitea encore présents après 180 secondes" >&2
    return 1
}

prepare_backup_game() {
    local game_name="$1"

    [[ "$game_name" =~ ^[0-9]{8}-[0-9]{6}$ ]] || {
        echo "[STOP] Nom de jeu invalide" >&2
        return 1
    }

    [[ -d "$BACKUP_DIR" && ! -L "$BACKUP_DIR" ]] || {
        echo "[STOP] Répertoire de sauvegarde invalide" >&2
        return 1
    }

    [[ ! -e "$BACKUP_DIR/$game_name" &&
       ! -L "$BACKUP_DIR/$game_name" ]] || {
        echo "[STOP] Jeu déjà présent : $game_name" >&2
        return 1
    }

    umask 077
    mktemp -d "$BACKUP_DIR/.gitea-backup-XXXXXXXX"
}

restart_gitea_after_backup() {
    local context="kind-gitops-management"

    echo "[INFO] Remise en service de Gitea"
    kubectl --context "$context" -n gitea \
        scale deployment/gitea --replicas=1
    kubectl --context "$context" -n gitea \
        rollout status deployment/gitea --timeout=180s
}

backup_stopped_gitea=0

recover_failed_backup() {
    local original_status="$1"

    if (( backup_stopped_gitea )); then
        echo "[WARN] Sauvegarde interrompue ; remise en service de Gitea" >&2

        if ! kubectl --context kind-gitops-management -n gitea \
            delete pod gitea-backup-reader \
            --ignore-not-found --wait=true >&2; then
            echo "[STOP] Pod lecteur non retiré ; redémarrage automatique suspendu, intervention nécessaire" >&2
            return 1
        fi

        if ! restart_gitea_after_backup; then
            echo "[STOP] Remise en service de Gitea échouée : intervention nécessaire" >&2
            return 1
        fi
    fi

    return "$original_status"
}

export_admin_secret() {
    local destination="$1"

    kubectl --context kind-gitops-management -n gitea \
        get secret gitea-admin-secret -o json |
        jq -e '
            select(
                .kind == "Secret" and
                .metadata.name == "gitea-admin-secret" and
                .metadata.namespace == "gitea" and
                (.data.username | type == "string" and length > 0) and
                (.data.password | type == "string" and length > 0)
            )
            | {
                kind: "Secret",
                metadata: {
                    name: .metadata.name,
                    namespace: .metadata.namespace
                },
                data: {
                    username: .data.username,
                    password: .data.password
                }
            }
        ' > "$destination"

    if [[ ! -s "$destination" ]]; then
        echo "[STOP] Export du Secret administrateur vide" >&2
        return 1
    fi

    chmod 600 "$destination"
}

write_backup_manifest() {
    local dir="$1"
    local created_at="$2"
    local data_sha admin_sha

    data_sha="$(sha256sum "$dir/data.tar.gz" | cut -d ' ' -f 1)"
    admin_sha="$(sha256sum "$dir/admin-secret.json" | cut -d ' ' -f 1)"

    jq -n \
        --arg created_at "$created_at" \
        --arg data_sha "$data_sha" \
        --arg admin_sha "$admin_sha" \
        '{
            format_version: 1,
            created_at: $created_at,
            data_file: "data.tar.gz",
            data_sha256: $data_sha,
            admin_file: "admin-secret.json",
            admin_sha256: $admin_sha
        }' > "$dir/manifest.json"

    chmod 600 "$dir/manifest.json"
}

archive_gitea_data() {
    local destination="$1"

    kubectl --context kind-gitops-management -n gitea \
        exec gitea-backup-reader -c reader -- \
        tar -C /data -cf - . |
        gzip -c > "$destination"

    chmod 600 "$destination"
}

if [[ "${1:-}" == "--backup" && "$#" -eq 1 ]]; then
    check_live_gitea
    check_reader_manifest

    if kubectl --context kind-gitops-management -n gitea \
        get pod gitea-backup-reader >/dev/null 2>&1; then
        echo "[STOP] Pod lecteur déjà présent" >&2
        exit 1
    fi

    game_name="$(date +%Y%m%d-%H%M%S)"
    created_at="$(date --iso-8601=seconds)"
    temporary_game="$(prepare_backup_game "$game_name")"

    finish_backup() {
        local status="$?"
        trap - EXIT

        if (( backup_stopped_gitea )); then
            if ! kubectl --context kind-gitops-management -n gitea \
                delete pod gitea-backup-reader \
                --ignore-not-found --wait=true >&2; then
                echo "[STOP] Pod lecteur non retiré ; intervention nécessaire" >&2
                status=1
            elif ! restart_gitea_after_backup; then
                echo "[STOP] Gitea non revenue en service ; intervention nécessaire" >&2
                status=1
            fi
        fi

        if [[ -n "${temporary_game:-}" && -d "$temporary_game" ]]; then
            rm -rf -- "$temporary_game" || status=1
        fi
        exit "$status"
    }
    trap finish_backup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    export_admin_secret "$temporary_game/admin-secret.json"

    # Activer la reprise avant la commande susceptible d'arrêter Gitea.
    backup_stopped_gitea=1
    kubectl --context kind-gitops-management -n gitea \
        scale deployment/gitea --replicas=0
    wait_gitea_pods_gone

    kubectl --context kind-gitops-management \
        apply -f "$READER_MANIFEST"
    kubectl --context kind-gitops-management -n gitea \
        wait --for=condition=Ready pod/gitea-backup-reader --timeout=120s

    archive_gitea_data "$temporary_game/data.tar.gz"
    write_backup_manifest "$temporary_game" "$created_at"
    validate_game "$temporary_game"

    kubectl --context kind-gitops-management -n gitea \
        delete pod gitea-backup-reader --wait=true

    # Le trap garde la responsabilité de la reprise si ce premier essai échoue.
    if ! restart_gitea_after_backup; then
        echo "[STOP] Premier redémarrage échoué ; reprise de secours par le trap" >&2
        exit 1
    fi
    backup_stopped_gitea=0

    mv -- "$temporary_game" "$BACKUP_DIR/$game_name"
    temporary_game=""
    echo "[SELECT] $game_name"
    exit 0
fi

if [[ "${1:-}" == "--backup-test-failure" && "$#" -eq 1 ]]; then
    game_name="$(date +%Y%m%d-%H%M%S)"
    temporary_game="$(prepare_backup_game "$game_name")"

    on_test_exit() {
        local status="$?"
        trap - EXIT
        rm -rf -- "$temporary_game"
        recover_failed_backup "$status"
    }
    trap on_test_exit EXIT

    echo "[TEST] Échec simulé avant tout arrêt de Gitea"
    exit 7
fi

if [[ "${1:-}" == "--backup-plan" && "$#" -eq 1 ]]; then
    check_live_gitea
    check_reader_manifest

    [[ -d "$BACKUP_DIR" && ! -L "$BACKUP_DIR" ]] || {
        echo "[STOP] Répertoire de sauvegarde absent ou invalide" >&2
        exit 1
    }

    game_name="$(date +%Y%m%d-%H%M%S)"
    [[ ! -e "$BACKUP_DIR/$game_name" &&
       ! -L "$BACKUP_DIR/$game_name" ]] || {
        echo "[STOP] Nom de jeu déjà utilisé : $game_name" >&2
        exit 1
    }

    temporary_game="$(prepare_backup_game "$game_name")"
    trap 'rm -rf -- "$temporary_game"' EXIT

    [[ -d "$temporary_game" ]] || {
        echo "[STOP] Dossier temporaire absent" >&2
        exit 1
    }
    echo "[OK] Dossier temporaire créé hors des jeux sélectionnables"

    echo "[PLAN] Nouveau jeu : $game_name"
    echo "[OK] Aucun jeu de sauvegarde publié ; Gitea reste en service"
    exit 0
fi

if [[ "${1:-}" == "--backup-preflight" && "$#" -eq 1 ]]; then
    check_live_gitea
    exit 0
fi

if [[ "${1:-}" == "--latest" ]] &&
   { [[ "$#" -eq 1 ]] ||
     [[ "$#" -eq 2 && "${2:-}" == "--quarantine-invalid" ]]; }; then
    [[ -d "$BACKUP_DIR" ]] || {
        echo "[STOP] Répertoire de sauvegarde absent" >&2
        exit 1
    }

    quarantine_invalid=0
    [[ "${2:-}" == "--quarantine-invalid" ]] &&
        quarantine_invalid=1

    mapfile -t candidates < <(
        find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
            -printf '%f\n' |
        awk '/^[0-9]{8}-[0-9]{6}$/ { print }' |
        sort -r
    )

    ((${#candidates[@]} > 0)) || {
        echo "[STOP] Aucun jeu de sauvegarde au nouveau format" >&2
        echo "[RESULT] selection=unavailable rejected=0"
        exit 1
    }

    latest_name="${candidates[0]}"
    selected=""
    rejected=0

    for name in "${candidates[@]}"; do
        validation_output=""

        if validation_output="$(
            validate_game "$BACKUP_DIR/$name" 2>&1
        )"; then
            printf '%s\n' "$validation_output"
            selected="$name"
            break
        fi

        ((rejected += 1))
        echo "[WARN] Jeu Gitea invalide rejeté : $name" >&2

        while IFS= read -r validation_line; do
            [[ -n "$validation_line" ]] || continue
            validation_line="${validation_line#\[STOP\] }"
            echo "[WARN] $name : $validation_line" >&2
        done <<< "$validation_output"

        if ((quarantine_invalid == 1)); then
            invalid_dir="${GITEA_INVALID_BACKUP_DIR:-$(dirname -- "$BACKUP_DIR")/gitea-invalid}"
            mkdir -p "$invalid_dir"
            chmod 700 "$invalid_dir"

            destination="$invalid_dir/$name"
            [[ ! -e "$destination" ]] || {
                echo "[STOP] Destination de quarantaine déjà présente : $destination" >&2
                exit 1
            }

            mv -- "$BACKUP_DIR/$name" "$destination"
            echo "[OK] Jeu invalide placé en quarantaine : $destination"
        else
            echo "[PREVIEW] Jeu invalide à placer en quarantaine lors du PRA réel : $name"
        fi
    done

    if [[ -z "$selected" ]]; then
        echo "[STOP] Aucun jeu local valide disponible" >&2
        echo "[RESULT] selection=unavailable rejected=$rejected"
        exit 1
    fi

    if [[ "$selected" == "$latest_name" ]]; then
        selection="latest"
        echo "[OK] Jeu Gitea le plus récent valide : $selected"
    else
        selection="fallback"
        echo "[WARN] Repli vers un jeu Gitea antérieur : $selected"
        echo "[WARN] Des données et évolutions de plateforme postérieures peuvent être perdues"
    fi

    echo "[SELECT] $selected"
    echo "[RESULT] selection=$selection backup=$selected rejected=$rejected"
    exit 0
fi

if [[ "${1:-}" == "--validate" && "$#" -eq 2 ]]; then
    name="$2"
    [[ "$name" =~ ^[0-9]{8}-[0-9]{6}$ ]] || {
        echo "[STOP] Nom de jeu invalide" >&2
        exit 2
    }
    validate_game "$BACKUP_DIR/$name"
    exit
fi

if [[ "${1:-}" != "--list" || "$#" -ne 1 ]]; then
    echo "Usage : $0 --list | --latest [--quarantine-invalid] | --validate AAAAMMJJ-HHMMSS" >&2
    exit 2
fi

[[ -d "$BACKUP_DIR" ]] || {
    echo "[STOP] Répertoire de sauvegarde absent : $BACKUP_DIR" >&2
    exit 1
}

echo "[INFO] Jeux de sauvegarde Gitea :"
found=0
while IFS= read -r name; do
    found=1
    if [[ -f "$BACKUP_DIR/$name/manifest.json" ]]; then
        echo "  $name : manifeste présent (intégrité non vérifiée)"
    else
        echo "  $name : incomplet, manifeste absent"
    fi
done < <(
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' | grep -E '^[0-9]{8}-[0-9]{6}$' | sort || true
)

(( found )) || echo "  aucun jeu au nouveau format"
