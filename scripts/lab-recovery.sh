#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

. "$SCRIPT_DIR/lib/lab-paths.sh" || {
    echo "[ERREUR] lab-paths.sh illisible" >&2
    exit 1
}

. "$SCRIPT_DIR/lib/lab-log.sh" || {
    echo "[ERREUR] lab-log.sh illisible" >&2
    exit 1
}

GITEA_RECOVERY_PORT="${GITEA_RECOVERY_PORT:-13001}"
GITEA_RECOVERY_PF_PID=""

lab_recovery_stop_gitea_channel() {
    if [[ -n "$GITEA_RECOVERY_PF_PID" ]]; then
        kill "$GITEA_RECOVERY_PF_PID" 2>/dev/null || true
        wait "$GITEA_RECOVERY_PF_PID" 2>/dev/null || true
        GITEA_RECOVERY_PF_PID=""
        echo "[OK] Canal de reprise Gitea fermé"
    fi

    unset \
        GITEA_URL \
        GITEA_API_URL \
        GITEA_GIT_BASE_URL \
        REGISTRY_BASE_URL
}

lab_recovery_check_gitea_direct() {
    local direct_url=""

    if [[ -n "${GITEA_DIRECT_URL:-}" ]]; then
        direct_url="$GITEA_DIRECT_URL"
    else
        printf -v direct_url '%s%s' 'https://' 'gitea.local'
    fi

    if curl --noproxy '*' --max-time 10 -fsS \
        "${direct_url}/api/healthz" >/dev/null 2>&1; then
        echo "[OK] Gitea accessible directement : $direct_url"
        return 0
    fi

    echo "[WARN] Gitea inaccessible directement : $direct_url"
    return 1
}

lab_recovery_start_gitea_channel() {
    local ready=0
    local attempt

    [[ -z "$GITEA_RECOVERY_PF_PID" ]] || return 0

    if ss -ltn "( sport = :${GITEA_RECOVERY_PORT} )" |
       grep -q LISTEN; then
        echo "[WARN] Port de reprise déjà utilisé : $GITEA_RECOVERY_PORT" >&2
        return 1
    fi

    kubectl --context "${MGMT_CONTEXT:-kind-gitops-management}" \
        -n gitea port-forward \
        --address 127.0.0.1 \
        deployment/gitea \
        "${GITEA_RECOVERY_PORT}:3000" >/dev/null 2>&1 &

    GITEA_RECOVERY_PF_PID=$!

    for attempt in {1..30}; do
        if ! kill -0 "$GITEA_RECOVERY_PF_PID" 2>/dev/null; then
            echo "[WARN] Canal de reprise Gitea interrompu" >&2
            GITEA_RECOVERY_PF_PID=""
            return 1
        fi

        if curl -fsS \
            "http://127.0.0.1:${GITEA_RECOVERY_PORT}/api/healthz" \
            >/dev/null 2>&1; then
            ready=1
            break
        fi

        sleep 1
    done

    if ((ready != 1)); then
        echo "[WARN] Gitea indisponible sur le canal de reprise" >&2
        lab_recovery_stop_gitea_channel
        return 1
    fi

    GITEA_URL="http://127.0.0.1:${GITEA_RECOVERY_PORT}"
    GITEA_API_URL="${GITEA_URL}/api/v1"
    GITEA_GIT_BASE_URL="$GITEA_URL"
    REGISTRY_BASE_URL="$GITEA_URL"

    export \
        GITEA_URL \
        GITEA_API_URL \
        GITEA_GIT_BASE_URL \
        REGISTRY_BASE_URL

    echo "[OK] Canal de reprise Gitea actif : 127.0.0.1:${GITEA_RECOVERY_PORT}"
}

lab_recovery_log_on_exit() {
    local rc=$?
    local finish_rc=0

    trap - EXIT INT TERM
    set +e

    lab_recovery_stop_gitea_channel

    if [[ "${LAB_LOG_ACTIVE:-0}" == "1" &&
          "${LAB_LOG_OWNER_PID:-}" == "$$" ]]; then
        lab_log_finish "$rc"
        finish_rc=$?
    fi

    if ((rc == 0 && finish_rc != 0)); then
        rc="$finish_rc"
    fi

    exit "$rc"
}

lab_recovery_log_on_signal() {
    local signal="$1"
    local rc="$2"

    trap - "$signal"

    printf '[WARN] Signal reçu : %s ; arrêt avec le code %s\n'         "$signal" "$rc" >&2

    exit "$rc"
}

lab_recovery_install_log_traps() {
    trap lab_recovery_log_on_exit EXIT
    trap 'lab_recovery_log_on_signal INT 130' INT
    trap 'lab_recovery_log_on_signal TERM 143' TERM
}

usage() {
    cat <<EOF
Usage :
  $0 --help
  $0 --plan
  $0 --preflight
  $0

Modes :
  --help       Afficher cette aide sans effectuer de contrôle
  --plan       Afficher le plan de reconstruction sans modifier le lab
  --preflight  Exécuter uniquement les contrôles préalables au PRA
  sans option  Exécuter le PRA interactif complet

Le mode interactif affiche le périmètre avant toute destruction et
demande une confirmation explicite.
EOF
}

if [[ "${1:-}" == "--help" && "$#" -eq 1 ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == "--plan" && "$#" -eq 1 ]]; then
    LAB_RECOVERY_MODE="plan"

    lab_log_start \
        "$LAB_RECOVERY_MODE" \
        "$(git -C "$ROOT_DIR" rev-parse HEAD)" \
        "lab-recovery" || exit 1

    lab_recovery_install_log_traps

    root="$ROOT_DIR"
    inventory="$root/clusters/workloads.tsv"
    test -f "$inventory" || { echo "[STOP] Inventaire absent"; exit 1; }
    test -f "$root/clusters/management/kind-config.yaml" || {
        echo "[STOP] Configuration management absente"; exit 1;
    }
    awk -F '\t' -v root="$root" '
        NR == 1 {
            if (NF != 3 || $1 != "environment" ||
                $2 != "kind_cluster" || $3 != "argocd_cluster") bad = 1
            next
        }
        NF != 3 || $1 == "" || $2 == "" || $3 == "" { bad = 1; next }
        {
            if (seen_env[$1]++ || seen_kind[$2]++ || seen_argo[$3]++) bad = 1
            if ($1 !~ /^[a-z0-9-]+$/ || $2 !~ /^[a-z0-9-]+$/ || $3 !~ /^[a-z0-9-]+$/) bad = 1
            count++
        }
        END { if (bad || count < 1) exit 1 }
    ' "$inventory" || { echo "[STOP] Inventaire ou configurations invalides"; exit 1; }

    while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
        [[ "$environment" == "environment" ]] && continue
        test -f "$root/clusters/workload-${environment}/kind-config.yaml" || {
            echo "[STOP] Configuration Kind absente : $environment"
            exit 1
        }
        grep -q 'config_path = "/etc/containerd/certs.d"' "$root/clusters/workload-${environment}/kind-config.yaml" || {
            echo "[STOP] config_path containerd absent du kind-config : $environment"
            exit 1
        }
    done < "$inventory"

    test -x "$root/scripts/config/workload-registry.sh" || {
        echo "[STOP] Script absent ou non exécutable : scripts/config/workload-registry.sh"
        exit 1
    }
    echo "[PLAN] kind create cluster --name gitops-management --config clusters/management/kind-config.yaml"
    awk -F '\t' 'NR > 1 {
        printf "[PLAN] kind create cluster --name %s --config clusters/workload-%s/kind-config.yaml\n", $2, $1
    }' "$inventory"
    echo "[PLAN] bash scripts/config/workload-registry.sh (gitea.local, CA et hosts.toml sur les nœuds workload)"
    echo "[PLAN] bash scripts/ensure-games-pull-secret.sh --apply (namespace game-2048 et Secret games-registry-pull sur les workloads)"
    echo "[OK] Plan affiché ; aucune action Kubernetes ou Docker exécutée"
    exit 0
fi

PREFLIGHT_ONLY=0
if [[ "${1:-}" == "--preflight" && "$#" -eq 1 ]]; then
    PREFLIGHT_ONLY=1
    LAB_RECOVERY_MODE="preflight"

    lab_log_start \
        "$LAB_RECOVERY_MODE" \
        "$(git -C "$ROOT_DIR" rev-parse HEAD)" \
        "lab-recovery" || exit 1

    lab_recovery_install_log_traps
elif (($# != 0)); then
    echo "[STOP] Argument invalide" >&2
    usage >&2
    exit 1
else
    LAB_RECOVERY_MODE="pra"

    lab_log_start \
        "$LAB_RECOVERY_MODE" \
        "$(git -C "$ROOT_DIR" rev-parse HEAD)" \
        "lab-recovery" || exit 1

    lab_recovery_install_log_traps
fi

echo "=================================================="
echo "GitOps Platform Bootstrap"
echo "=================================================="

# Inventaire des workloads à traiter lors du futur bootstrap.
# Ce bloc reste inaccessible tant que la garde [STOP] est présente.
INVENTORY="${ROOT_DIR}/clusters/workloads.tsv"
KEY_BACKUP="${KEY_BACKUP:-${LAB_CONFIG_DIR}/sealed-secrets-keyx9rjr-2026-09-29.yaml}"

[[ -f "$INVENTORY" ]] || {
    echo "[ERROR] Inventaire absent : $INVENTORY" >&2
    exit 1
}

# Accès au registre Gitea : refuser AVANT toute destruction si le patch containerd
# ou le script d'accès manque (sinon l'échec surviendrait après la recréation).
[[ -x "${ROOT_DIR}/scripts/config/workload-registry.sh" ]] || {
    echo "[STOP] Script absent ou non exécutable : scripts/config/workload-registry.sh" >&2
    exit 1
}
while IFS=$'\t' read -r -u 3 environment _kind_cluster _argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue
    [[ -n "$environment" ]] || continue
    grep -qF 'config_path = "/etc/containerd/certs.d"' \
        "${ROOT_DIR}/clusters/workload-${environment}/kind-config.yaml" || {
        echo "[STOP] config_path containerd absent du kind-config : ${environment}" >&2
        exit 1
    }
done 3< "$INVENTORY"
echo "[OK] Garde registre : script présent, config_path dans les kind-config workload"
[[ -f "$KEY_BACKUP" && -r "$KEY_BACKUP" ]] || {
    echo "[ERROR] Sauvegarde de clé absente ou illisible" >&2
    exit 1
}

# Valider la sauvegarde sans afficher ni écrire la clé privée.
key_json="$(kubectl create --dry-run=client --validate=false -f "$KEY_BACKUP" -o json)"
jq -e '
  .kind == "Secret" and
  .metadata.namespace == "sealed-secrets" and
  .type == "kubernetes.io/tls" and
  .metadata.labels["sealedsecrets.bitnami.com/sealed-secrets-key"] == "active" and
  (.data["tls.crt"] | type == "string" and length > 0) and
  (.data["tls.key"] | type == "string" and length > 0)
' >/dev/null <<< "$key_json" || {
    echo "[ERROR] Structure de la sauvegarde invalide" >&2
    exit 1
}

cert_pub="$(jq -r '.data["tls.crt"]' <<< "$key_json" |
  base64 -d | openssl x509 -pubkey -noout |
  openssl pkey -pubin -outform DER | openssl dgst -sha256)"
key_pub="$(jq -r '.data["tls.key"]' <<< "$key_json" |
  base64 -d | openssl pkey -pubout -outform DER |
  openssl dgst -sha256)"
KEY_NAME="$(jq -er .metadata.name <<< "$key_json")"
unset key_json

[[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || {
    echo "[ERROR] Certificat et clé privée incohérents" >&2
    exit 1
}
echo "[OK] Sauvegarde de clé validée localement"

# Valider toutes les lignes avant de traiter un cluster.
awk -F '\t' '
  NR == 1 {
    if (NF != 3 || $1 != "environment" ||
        $2 != "kind_cluster" || $3 != "argocd_cluster") bad = 1
    next
  }
  NF != 3 || $1 == "" || $2 == "" || $3 == "" { bad = 1; next }
  {
    if (seen_env[$1]++) bad = 1
    if (seen_kind[$2]++) bad = 1
    if (seen_argo[$3]++) bad = 1
    if ($1 !~ /^[a-z0-9-]+$/ || $2 !~ /^[a-z0-9-]+$/ ||
        $3 !~ /^[a-z0-9-]+$/) bad = 1
  }
  { count++ }
  END { if (bad || count < 1) exit 1 }
' "$INVENTORY" || {
    echo "[ERROR] Inventaire invalide" >&2
    exit 1
}

while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue
    [[ -f "${ROOT_DIR}/clusters/workload-${environment}/kind-config.yaml" ]] || {
        echo "[ERROR] Configuration Kind absente pour ${environment}" >&2
        exit 1
    }
done < "$INVENTORY"

while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue
    for path in \
        "${ROOT_DIR}/applications/whoami/overlays/${environment}/kustomization.yaml" \
        "${ROOT_DIR}/argocd/applications/${argocd_cluster}-cluster.yaml"; do
        [[ -f "$path" ]] || {
            echo "[STOP] Prérequis GitOps absent : $path" >&2
            exit 1
        }
    done
    if ! kubectl kustomize \
        "${ROOT_DIR}/applications/whoami/overlays/${environment}" \
        >/dev/null; then
        echo "[STOP] Overlay Whoami invalide : $environment" >&2
        exit 1
    fi
    ingress_matches=0
    for app in "${ROOT_DIR}"/argocd/applications/ingress-nginx*.yaml; do
        [[ -f "$app" ]] || continue
        [[ "$(yq -r '.spec.destination.name' "$app")" == "$argocd_cluster" ]] ||
            continue
        ((ingress_matches += 1))
    done
    if ((ingress_matches != 1)); then
        echo "[STOP] Application Ingress absente ou ambiguë : $argocd_cluster" >&2
        exit 1
    fi
done < "$INVENTORY"

while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue
    [[ -z "$environment" ]] && continue
    config="${ROOT_DIR}/clusters/workload-${environment}/kind-config.yaml"
    echo "[PREVIEW] ${environment}: ${kind_cluster} -> ${argocd_cluster} (${config})"
done < "$INVENTORY"


# TODO : précontrôles, création des clusters inventoriés, restauration
# de la clé, renouvellement des accès, puis activation de la Root App.

# Prévol du manifeste Argo CD avant toute confirmation destructive.
ARGOCD_MANIFEST="${LAB_PRA_ISOLATED_DIR}/argocd-v3.5.3-install.yaml"
EXPECTED_ARGOCD_SHA256="7efe2d6bbc03f63623640f1e4198f16c84009d510fb810ef71e56df1b7614ba9"
[[ -f "$ARGOCD_MANIFEST" && -r "$ARGOCD_MANIFEST" ]] || {
    echo "[STOP] Manifeste Argo CD absent ou illisible" >&2
    exit 1
}
actual_argocd_sha256="$(sha256sum "$ARGOCD_MANIFEST" | cut -d ' ' -f 1)"
[[ "$actual_argocd_sha256" == "$EXPECTED_ARGOCD_SHA256" ]] || {
    echo "[STOP] Empreinte du manifeste Argo CD inattendue" >&2
    exit 1
}
echo "[OK] Manifeste Argo CD vérifié avant le menu PRA"

candidate_dir="${LAB_REGISTRATION_CANDIDATES_DIR}"
[[ -d "$candidate_dir" ]] || {
    echo "[STOP] Répertoire de candidats absent" >&2
    exit 1
}
while IFS=$'\t' read -r environment kind_cluster name; do
    [[ "$environment" == "environment" ]] && continue
    candidate="${candidate_dir}/${name}-sealedsecret.yaml"
    if [[ -L "$candidate" || ( -e "$candidate" && ! -f "$candidate" ) ]]; then
        echo "[STOP] Chemin candidat invalide : $name" >&2
        exit 1
    fi
done < "$INVENTORY"

inotify_instances="$(sysctl -n fs.inotify.max_user_instances)"
[[ "$inotify_instances" =~ ^[0-9]+$ ]] || {
    echo "[STOP] Valeur inotify illisible" >&2
    exit 1
}

if (( inotify_instances < 512 )); then
    echo "[INFO] Limite inotify à ${inotify_instances} ; passage à 512"
    sudo -n sysctl -w fs.inotify.max_user_instances=512 >/dev/null || {
        echo "[STOP] Ajustement inotify impossible ; droits sudo nécessaires" >&2
        exit 1
    }
fi

inotify_instances="$(sysctl -n fs.inotify.max_user_instances)"
if [[ ! "$inotify_instances" =~ ^[0-9]+$ ]] ||
   (( inotify_instances < 512 )); then
    echo "[STOP] Limite inotify toujours insuffisante" >&2
    exit 1
fi
echo "[OK] Limite inotify : $inotify_instances"

[[ "$(git -C "$ROOT_DIR" branch --show-current)" == "main" ]] || {
    echo "[STOP] PRA automatique autorisé uniquement depuis la branche main" >&2
    exit 1
}

MGMT_CONTEXT="${MGMT_CONTEXT:-kind-gitops-management}" \
    bash "${ROOT_DIR}/scripts/gitea/install-direct.sh" --render-check

LAB_RECOVERY_PATH=""
LAB_RECOVERY_GITEA_ACCESS=""

if lab_recovery_check_gitea_direct; then
    LAB_RECOVERY_GITEA_ACCESS="direct"
elif lab_recovery_start_gitea_channel; then
    LAB_RECOVERY_GITEA_ACCESS="recovery-channel"
else
    LAB_RECOVERY_GITEA_ACCESS="unavailable"
fi

case "$LAB_RECOVERY_GITEA_ACCESS" in
    direct|recovery-channel)
        LAB_RECOVERY_PATH="nominal"
        echo "[INFO] Mode de reprise disponible : nominal"
        echo "[INFO] Accès Gitea retenu : $LAB_RECOVERY_GITEA_ACCESS"
        ;;
    unavailable)
        LAB_RECOVERY_PATH="degraded"
        echo "[WARN] Aucun accès opérationnel à Gitea"
        echo "[INFO] La cause de l'indisponibilité n'est pas déterminée par le script"
        echo "[INFO] Évaluation des garanties locales du mode dégradé"
        ;;
    *)
        echo "[STOP] État d'accès Gitea invalide : $LAB_RECOVERY_GITEA_ACCESS" >&2
        exit 1
        ;;
esac

export LAB_RECOVERY_PATH LAB_RECOVERY_GITEA_ACCESS

if [[ "$LAB_RECOVERY_PATH" == "nominal" ]]; then
    MGMT_CONTEXT="${MGMT_CONTEXT:-kind-gitops-management}" \
        bash "${ROOT_DIR}/scripts/gitea/publish.sh" --check-aligned

    echo "[OK] Branche main strictement alignée avec Gitea"
else
    echo "[INFO] Contrôle d'alignement Gitea différé après restauration"
fi

# Dépôt de secours GitHub.
mirror_status=0

if [[ "$LAB_RECOVERY_PATH" == "nominal" ]]; then
    # Dépôt de secours GitHub : contrôle seul (aucune écriture, aucune question).
    # La décision (profil lab / exploit) est prise plus bas, après confirmation du PRA.
    MIRROR_PROFILE="${MIRROR_PROFILE:-lab}"
    case "$MIRROR_PROFILE" in
        lab|exploit) ;;
        *)
            echo "[STOP] MIRROR_PROFILE invalide : $MIRROR_PROFILE (attendu : lab ou exploit)" >&2
            exit 1
            ;;
    esac
    MIRROR_CHECK_SCRIPT="${ROOT_DIR}/scripts/check-github-mirror.sh"
    [[ -f "$MIRROR_CHECK_SCRIPT" && -x "$MIRROR_CHECK_SCRIPT" ]] || {
        echo "[STOP] Script absent ou non exécutable : $MIRROR_CHECK_SCRIPT" >&2
        exit 1
    }
    mirror_status=0
    "$MIRROR_CHECK_SCRIPT" --check || mirror_status=$?
    case "$mirror_status" in
        0) echo "[OK] Dépôt de secours GitHub conforme (profil $MIRROR_PROFILE)" ;;
        2) echo "[WARN] Dépôt de secours en avertissement ; traitement avant sauvegarde Gitea (profil $MIRROR_PROFILE)" ;;
        3) echo "[WARN] Dépôt de secours critique ; remédiation requise avant destruction (profil $MIRROR_PROFILE)" ;;
        *) echo "[WARN] Contrôle du dépôt de secours en erreur ($mirror_status) ; le PRA s'arrêtera avant destruction" ;;
    esac

else
    echo "[WARN] Contrôle du dépôt de secours différé : Gitea indisponible"
    echo "[INFO] Aucune remédiation du mirror ne sera exécutée avant restauration"
fi

# Éléments hors source de vérité (inventaire scripts/external-deps.tsv) : contrôle seul.
# Codes 0 et 2 : le prévol continue ; codes 1 (inventaire invalide) et 3 : arrêt avant le menu PRA.
EXTERNAL_DEPS_SCRIPT="${ROOT_DIR}/scripts/check-external-deps.sh"
[[ -f "$EXTERNAL_DEPS_SCRIPT" && -x "$EXTERNAL_DEPS_SCRIPT" ]] || {
    echo "[STOP] Script absent ou non exécutable : $EXTERNAL_DEPS_SCRIPT" >&2
    exit 1
}
external_deps_args=(--check)
if [[ "$LAB_RECOVERY_PATH" == "degraded" ]]; then
    external_deps_args+=(--offline)
    echo "[WARN] Dépendances externes contrôlées hors ligne en mode dégradé"
elif [[ "${EXTERNAL_DEPS_OFFLINE:-0}" == "1" ]]; then
    external_deps_args+=(--offline)
fi
external_deps_status=0
"$EXTERNAL_DEPS_SCRIPT" "${external_deps_args[@]}" || external_deps_status=$?
case "$external_deps_status" in
    0) echo "[OK] Éléments hors source de vérité conformes" ;;
    2) echo "[WARN] Éléments hors source de vérité en avertissement (voir ci-dessus) ; le prévol continue" ;;
    *)
        echo "[STOP] Éléments hors source de vérité critiques ou inventaire invalide (code $external_deps_status)" >&2
        exit 1
        ;;
esac

# Sauvegarde Git des dépôts inventoriés : découverte et contrôle seuls.
# Aucun push n'est effectué pendant le prévol.
GIT_BACKUP_SCRIPT="${ROOT_DIR}/scripts/backup-git-repositories.sh"
GIT_BACKUP_MANIFEST="${ROOT_DIR}/scripts/git-backup-repositories.tsv"

[[ -f "$GIT_BACKUP_SCRIPT" &&
   -x "$GIT_BACKUP_SCRIPT" &&
   ! -L "$GIT_BACKUP_SCRIPT" ]] || {
    echo "[STOP] Script de sauvegarde Git absent ou invalide : $GIT_BACKUP_SCRIPT" >&2
    exit 1
}

[[ -f "$GIT_BACKUP_MANIFEST" &&
   ! -L "$GIT_BACKUP_MANIFEST" ]] || {
    echo "[STOP] Inventaire des sauvegardes Git absent ou invalide : $GIT_BACKUP_MANIFEST" >&2
    exit 1
}

if [[ "$LAB_RECOVERY_PATH" == "nominal" ]]; then
    "$GIT_BACKUP_SCRIPT" --preflight || {
        echo "[STOP] Prévol des sauvegardes Git en échec ; PRA non autorisé" >&2
        exit 1
    }

    echo "[OK] Dépôts Git à sauvegarder inventoriés et destinations accessibles"
else
    "$GIT_BACKUP_SCRIPT" --validate || {
        echo "[STOP] Inventaire local des sauvegardes Git invalide" >&2
        exit 1
    }

    echo "[OK] Inventaire local des sauvegardes Git valide"
    echo "[WARN] Découverte Gitea et destinations GitHub différées"
fi

# v1.3.6 : jeton et lecture du registre games (Secret de pull des workloads).
PULL_SECRET_SCRIPT="${ROOT_DIR}/scripts/ensure-games-pull-secret.sh"

[[ -f "$PULL_SECRET_SCRIPT" &&
   -x "$PULL_SECRET_SCRIPT" &&
   ! -L "$PULL_SECRET_SCRIPT" ]] || {
    echo "[STOP] Script du Secret de pull absent ou invalide : $PULL_SECRET_SCRIPT" >&2
    exit 1
}

if [[ "$LAB_RECOVERY_PATH" == "nominal" ]]; then
    "$PULL_SECRET_SCRIPT" --check || {
        echo "[STOP] Contrôle du Secret de pull games en échec ; PRA non autorisé" >&2
        exit 1
    }

    echo "[OK] Jeton et lecture du registre games conformes"
else
    EXTERNAL_DEPS_OFFLINE=1 \
        "$PULL_SECRET_SCRIPT" --check || {
            echo "[STOP] Contrôle local du Secret de pull games en échec" >&2
            exit 1
        }

    echo "[OK] Jeton local de pull games conforme"
    echo "[WARN] Lecture du registre games différée"
fi

# DNS du cluster management : contrôle du rendu seul, sans accès au cluster
# (script présent, outils, transformation du Corefile de référence).
MGMT_DNS_SCRIPT="${ROOT_DIR}/scripts/config/management-dns.sh"
[[ -f "$MGMT_DNS_SCRIPT" && -x "$MGMT_DNS_SCRIPT" ]] || {
    echo "[STOP] Script absent ou non exécutable : $MGMT_DNS_SCRIPT" >&2
    exit 1
}
"$MGMT_DNS_SCRIPT" --render-check >/dev/null || {
    echo "[STOP] Contrôle de rendu du DNS management en échec : $MGMT_DNS_SCRIPT --render-check" >&2
    exit 1
}
echo "[OK] DNS du management : script et rendu conformes (aucun accès au cluster)"

if ! git -C "$ROOT_DIR" diff --quiet ||
   ! git -C "$ROOT_DIR" diff --cached --quiet; then
    echo "[STOP] Fichiers Git suivis ou index déjà modifiés" >&2
    exit 1
fi
echo "[OK] Fichiers Git suivis et index propres avant le menu PRA"

registration_dir="${ROOT_DIR}/clusters/management/cluster-registration"
while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue
    relative_path="clusters/management/cluster-registration/${argocd_cluster}-sealedsecret.yaml"
    destination="${ROOT_DIR}/${relative_path}"

    if [[ -L "$destination" ]] ||
       [[ -n "$(git -C "$ROOT_DIR" status --porcelain -- "$relative_path")" ]]; then
        echo "[STOP] Destination Git non disponible : $relative_path" >&2
        exit 1
    fi
done < "$INVENTORY"
echo "[OK] Destinations Git disponibles avant le menu PRA"

# Prerequis Gitea avant le menu destructif.
for tool in argocd mktemp; do
    command -v "$tool" >/dev/null || {
        echo "[STOP] Outil absent : $tool" >&2
        exit 1
    }
done

for script in gitea/backup.sh gitea/restore.sh; do
    path="${ROOT_DIR}/scripts/$script"
    [[ -f "$path" && ! -L "$path" ]] || {
        echo "[STOP] Script absent ou invalide : $script" >&2
        exit 1
    }
    bash -n "$path"
done

for file in gitea-restore-pvc.yaml gitea-restore-pod.yaml; do
    [[ -f "${ROOT_DIR}/scripts/manifests/$file" &&
       ! -L "${ROOT_DIR}/scripts/manifests/$file" ]] || {
        echo "[STOP] Manifeste absent ou invalide : $file" >&2
        exit 1
    }
done

export ARGOCD_ADMIN_HASH_FILE="${ARGOCD_ADMIN_HASH_FILE:-${LAB_CONFIG_DIR}/argocd-admin-password.bcrypt}"

[[ -f "$ARGOCD_ADMIN_HASH_FILE" &&
   -r "$ARGOCD_ADMIN_HASH_FILE" &&
   ! -L "$ARGOCD_ADMIN_HASH_FILE" ]] || {
    echo "[STOP] Fichier bcrypt administrateur absent ou invalide" >&2
    exit 1
}

[[ "$(wc -l < "$ARGOCD_ADMIN_HASH_FILE")" -eq 1 ]] &&
grep -Eq '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$' \
    "$ARGOCD_ADMIN_HASH_FILE" || {
    echo "[STOP] Format bcrypt administrateur invalide" >&2
    exit 1
}

echo "[OK] Hash administrateur Argo CD controle avant destruction"

CA_DIR="${LAB_CONFIG_DIR}"
CA_CERT="${CA_DIR}/gitops-lab-root-ca.crt"
CA_KEY="${CA_DIR}/gitops-lab-root-ca.key"

for file in "$CA_CERT" "$CA_KEY"; do
    [[ -f "$file" && -r "$file" && ! -L "$file" ]] || {
        echo "[STOP] Fichier CA absent, illisible ou lien symbolique" >&2
        exit 1
    }
done

openssl x509 -in "$CA_CERT" -noout -checkend 0 >/dev/null || {
    echo "[STOP] Certificat CA expiré ou invalide" >&2
    exit 1
}

openssl x509 -in "$CA_CERT" -noout -ext basicConstraints |
    grep -Fq 'CA:TRUE' || {
    echo "[STOP] Certificat sans contrainte CA:TRUE" >&2
    exit 1
}

ca_cert_pub="$(openssl x509 -in "$CA_CERT" -pubkey -noout |
    openssl pkey -pubin -outform DER | openssl dgst -sha256)"
ca_key_pub="$(openssl pkey -in "$CA_KEY" -pubout -outform DER |
    openssl dgst -sha256)"

[[ -n "$ca_cert_pub" && "$ca_cert_pub" == "$ca_key_pub" ]] || {
    echo "[STOP] Paire CA incohérente" >&2
    exit 1
}
unset ca_cert_pub ca_key_pub
echo "[OK] Paire CA locale validée avant destruction"

if [[ "$PREFLIGHT_ONLY" -eq 1 ]]; then
    if [[ "$LAB_RECOVERY_PATH" == "degraded" ]]; then
        echo "[INFO] Évaluation non modifiante des sauvegardes locales Gitea"

        if ! preflight_backup_output="$(
            bash "${ROOT_DIR}/scripts/gitea/backup.sh" --latest 2>&1
        )"; then
            printf '%s\n' "$preflight_backup_output"
            echo "[STOP] Mode dégradé indisponible : aucun jeu Gitea local valide" >&2
            exit 1
        fi

        printf '%s\n' "$preflight_backup_output"

        preflight_game="$(
            printf '%s\n' "$preflight_backup_output" |
                awk '$1 == "[SELECT]" { print $2 }'
        )"

        preflight_selection="$(
            printf '%s\n' "$preflight_backup_output" |
                awk '
                    $1 == "[RESULT]" {
                        for (i = 2; i <= NF; i++) {
                            if ($i ~ /^selection=/) {
                                sub(/^selection=/, "", $i)
                                print $i
                            }
                        }
                    }
                '
        )"

        if [[ ! "$preflight_game" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
            echo "[STOP] Jeu Gitea de prévol absent ou ambigu" >&2
            exit 1
        fi

        case "$preflight_selection" in
            latest)
                echo "[OK] Mode dégradé disponible avec le jeu local le plus récent"
                ;;
            fallback)
                echo "[WARN] Mode dégradé disponible avec un jeu antérieur"
                echo "[WARN] Une confirmation renforcée sera requise pendant le PRA réel"
                ;;
            *)
                echo "[STOP] Sélection Gitea de prévol invalide : $preflight_selection" >&2
                exit 1
                ;;
        esac

        echo "[RESULT] preflight_path=degraded backup=$preflight_game selection=$preflight_selection"
    fi

    echo "[OK] Prévol terminé ; aucune action Kind ou Kubernetes appliquée"
    exit 0
fi

# Prévisualisation du périmètre PRA ; aucune suppression à ce stade.
existing_clusters="$(kind get clusters)"
clusters_to_delete=()
mapfile -t workload_clusters < <(cut -f2 "$INVENTORY" | tail -n +2)

for cluster in gitops-management "${workload_clusters[@]}"; do
    if grep -Fxq -- "$cluster" <<< "$existing_clusters"; then
        clusters_to_delete+=("$cluster")
    fi
done

echo "[PREVIEW] Clusters existants dans le périmètre PRA :"
if ((${#clusters_to_delete[@]} == 0)); then
    echo "  aucun"
else
    printf "  %s\n" "${clusters_to_delete[@]}"
fi

if ((${#clusters_to_delete[@]} > 0)) && [[ ! -t 0 ]]; then
    echo "[STOP] Terminal interactif requis avant les sauvegardes préparatoires" >&2
    exit 1
fi

# Dépôt de secours GitHub : remédiation selon le profil, AVANT la sauvegarde fraîche
# de Gitea (la configuration du mirror est sauvegardée avec gitea.db).
#   lab     : WARN/CRIT -> rotation lancée d'office ; arrêt si elle échoue ou reste critique.
#   exploit : WARN -> proposition (60 s, défaut non, non bloquant) ;
#             CRIT -> proposition sans délai, refus = annulation du PRA.
#   erreur interne du contrôle : arrêt quel que soit le profil.
if ((mirror_status != 0)); then
    mirror_run_update=0
    mirror_answer=""
    case "${MIRROR_PROFILE}:${mirror_status}" in
        lab:2|lab:3)
            mirror_run_update=1
            ;;
        exploit:2)
            read -r -t 60 -p "[WARN] Lancer la rotation du jeton du dépôt de secours ? [o/N] (60 s, défaut non) : " mirror_answer || mirror_answer=""
            echo
            [[ "$mirror_answer" =~ ^[oO]$ ]] && mirror_run_update=1
            ;;
        exploit:3)
            read -r -p "[CRIT] Lancer la rotation du jeton du dépôt de secours ? [o/N] (refus = annulation du PRA) : " mirror_answer || mirror_answer=""
            if [[ "$mirror_answer" =~ ^[oO]$ ]]; then
                mirror_run_update=1
            else
                echo "[STOP] Remédiation refusée en état critique ; aucun cluster supprimé" >&2
                exit 1
            fi
            ;;
        *)
            echo "[STOP] Contrôle du dépôt de secours en erreur ; aucun cluster supprimé" >&2
            exit 1
            ;;
    esac

    if ((mirror_run_update == 1)); then
        mirror_update_rc=0
        "$MIRROR_CHECK_SCRIPT" --update || mirror_update_rc=$?
        mirror_final_rc=0
        "$MIRROR_CHECK_SCRIPT" --check || mirror_final_rc=$?
        if ((mirror_update_rc != 0 || (mirror_final_rc != 0 && mirror_final_rc != 2))); then
            echo "[STOP] Remédiation du dépôt de secours en échec ; aucun cluster supprimé" >&2
            exit 1
        fi
        echo "[OK] Dépôt de secours GitHub traité avant sauvegarde Gitea"
    else
        echo "[WARN] Rotation non lancée (refus ou délai écoulé) ; PRA poursuivi avec avertissement"
    fi
    unset mirror_run_update mirror_answer mirror_update_rc mirror_final_rc
fi

# Choisir et figer le jeu Gitea avant toute destruction.
GITEA_BACKUP_SCRIPT="${ROOT_DIR}/scripts/gitea/backup.sh"

GITEA_BACKUP_SELECTION="fresh"

if [[ "$LAB_RECOVERY_PATH" == "nominal" ]]; then
    echo "[INFO] Sauvegarde Git fraiche des depots inventories avant destruction"

    "$GIT_BACKUP_SCRIPT" --sync || {
        echo "[STOP] Sauvegarde Git des depots inventories en echec ; aucun cluster supprime" >&2
        exit 1
    }

    echo "[OK] Depots Git inventories synchronises vers GitHub"

    lab_recovery_stop_gitea_channel

    echo "[INFO] Sauvegarde fraiche de Gitea avant destruction"

    gitea_backup_output="$(
        bash "$GITEA_BACKUP_SCRIPT" --backup
    )"
else
    echo "[WARN] Gitea indisponible ; aucune synchronisation Git fraiche"
    echo "[WARN] Aucune sauvegarde Gitea fraiche ne sera créée"
    echo "[INFO] Sélection du premier jeu Gitea local valide"

    if ! gitea_backup_output="$(
        bash "$GITEA_BACKUP_SCRIPT" \
            --latest --quarantine-invalid 2>&1
    )"; then
        printf '%s\n' "$gitea_backup_output"
        echo "[STOP] Aucun jeu Gitea local restaurable" >&2
        exit 1
    fi

    GITEA_BACKUP_SELECTION="$(
        printf '%s\n' "$gitea_backup_output" |
            awk '
                $1 == "[RESULT]" {
                    for (i = 2; i <= NF; i++) {
                        if ($i ~ /^selection=/) {
                            sub(/^selection=/, "", $i)
                            print $i
                        }
                    }
                }
            '
    )"
fi

case "${LAB_RECOVERY_PATH}:${GITEA_BACKUP_SELECTION}" in
    nominal:fresh|degraded:latest|degraded:fallback)
        ;;
    *)
        echo "[STOP] État de sélection Gitea invalide : ${LAB_RECOVERY_PATH}:${GITEA_BACKUP_SELECTION}" >&2
        exit 1
        ;;
esac

printf '%s\n' "$gitea_backup_output"

GITEA_GAME="$(
    printf '%s\n' "$gitea_backup_output" |
        awk '$1 == "[SELECT]" { print $2 }'
)"

if [[ ! "$GITEA_GAME" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
    echo "[STOP] Selection Gitea absente ou ambigue ; destruction suspendue" >&2
    exit 1
fi

bash "$GITEA_BACKUP_SCRIPT" --validate "$GITEA_GAME"
echo "[OK] Jeu Gitea fige pour ce PRA : $GITEA_GAME"

echo "[PREVIEW] Jeu Gitea préparatoire validé : $GITEA_GAME"

if [[ "$LAB_RECOVERY_PATH" == "degraded" ]]; then
    echo "[PREVIEW] Mode de reprise : dégradé"
    echo "[PREVIEW] Accès Gitea : indisponible"
    echo "[PREVIEW] Jeu Gitea retenu : $GITEA_GAME"
    echo "[PREVIEW] Sélection du jeu : $GITEA_BACKUP_SELECTION"
    echo "[WARN] Aucune sauvegarde Gitea fraîche n'a été créée"
    echo "[WARN] Aucune synchronisation Git fraîche n'a été garantie"
    echo "[WARN] Les contrôles Gitea, mirror et registre sont différés"

    if [[ "$GITEA_BACKUP_SELECTION" == "fallback" ]]; then
        echo "[WARN] Un ou plusieurs jeux plus récents ont été rejetés"
        echo "[WARN] Le jeu retenu est antérieur au dernier jeu disponible"
        echo "[WARN] Risque accru de régression des données et de la plateforme"
    fi

    echo "[PREVIEW] Périmètre PRA :"
    if ((${#clusters_to_delete[@]} == 0)); then
        echo "  aucun cluster à détruire"
    else
        printf "  %s\n" "${clusters_to_delete[@]}"
    fi

    expected_confirmation="RESTAURER $GITEA_GAME EN MODE DEGRADE"

    echo
    echo "[CHOICE] Poursuivre : $expected_confirmation"
    echo "[CHOICE] Annuler    : ANNULER ou Entrée"
    read -r -p "> " degraded_confirmation

    case "$degraded_confirmation" in
        "$expected_confirmation")
            echo "[PREVIEW] Reprise dégradée explicitement confirmée"
            ;;
        ""|ANNULER)
            echo "[INFO] Reprise dégradée refusée par l'administrateur"
            echo "[OK] Jeu Gitea conservé : $GITEA_GAME"
            echo "[RESULT] PRA dégradé annulé avant reconstruction"
            exit 0
            ;;
        *)
            echo "[WARN] Choix non reconnu ; annulation par sécurité"
            echo "[OK] Jeu Gitea conservé : $GITEA_GAME"
            echo "[RESULT] PRA dégradé annulé avant reconstruction"
            exit 0
            ;;
    esac
elif ((${#clusters_to_delete[@]} > 0)); then
    echo "[PREVIEW] Sauvegardes préparatoires terminées ; périmètre prêt à être détruit :"
    printf "  %s\n" "${clusters_to_delete[@]}"
    echo

    read -r -p "Choix PRA [1=refuser (défaut), 2=détruire le périmètre affiché] : " choice

    case "${choice:-1}" in
        1)
            echo "[INFO] Destruction refusée par l'utilisateur"
            echo "[OK] Jeu Gitea conservé : $GITEA_GAME"
            echo "[RESULT] PRA annulé avant destruction ; sauvegardes préparatoires conservées"
            exit 0
            ;;
        2)
            printf "[PREVIEW] Destruction confirmée pour %s cluster(s) du périmètre PRA\n" "${#clusters_to_delete[@]}"
            ;;
        *)
            echo "[STOP] Choix invalide ; aucun cluster supprimé" >&2
            exit 1
            ;;
    esac
else
    echo "[OK] Aucun cluster du périmètre PRA à détruire ; confirmation nominale inutile"
fi


# Inaccessible tant que les verrous PRA restent actifs.
for cluster in "${clusters_to_delete[@]}"; do
    kind delete cluster --name "$cluster"
done

remaining_clusters="$(kind get clusters)"
for cluster in gitops-management "${workload_clusters[@]}"; do
    if grep -Fxq -- "$cluster" <<< "$remaining_clusters"; then
        echo "[STOP] Cluster du périmètre encore présent : $cluster" >&2
        exit 1
    fi
done
echo "[OK] Périmètre PRA absent ; reconstruction possible"

# Reconstruction Kind : inaccessible tant que les arrêts PRA restent actifs.
for cluster in gitops-management "${workload_clusters[@]}"; do
    if kind get clusters | grep -Fxq -- "$cluster"; then
        echo "[STOP] Cluster déjà présent : $cluster" >&2
        exit 1
    fi
done

kind create cluster --name gitops-management \
    --config "${ROOT_DIR}/clusters/management/kind-config.yaml"
kubectl --context kind-gitops-management wait \
    --for=condition=Ready node/gitops-management-control-plane --timeout=300s

while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue
    kind create cluster --name "$kind_cluster" \
        --config "${ROOT_DIR}/clusters/workload-${environment}/kind-config.yaml"
    kubectl --context "kind-${kind_cluster}" wait \
        --for=condition=Ready "node/${kind_cluster}-control-plane" --timeout=300s
done < "$INVENTORY"

# Accès des nœuds workload au registre Gitea (résolution, CA, hosts.toml).
# Une seule fois, après création de tous les workloads ; rejouable seul.
bash "${ROOT_DIR}/scripts/config/workload-registry.sh"

# v1.3.6 : Secret de lecture du registre games (jeton games-puller) sur les workloads.
# Les clusters existent, Argo CD n'a encore rien déployé. Le namespace game-2048 est créé
# s'il est absent ; Argo CD l'adopte ensuite (à confirmer au PRA).
bash "${ROOT_DIR}/scripts/ensure-games-pull-secret.sh" --apply

# DNS du cluster management : gitea.local -> Service Traefik pour les pods, le DinD et les jobs CI.
# Le Corefile par défaut de Kind est recréé avec le cluster : l'entrée est donc rejouée à chaque PRA.
# Un échec n'arrête pas la reconstruction (le DNS ne sert qu'à la CI) ; rejouable seul.
if MGMT_CONTEXT=kind-gitops-management bash "${ROOT_DIR}/scripts/config/management-dns.sh" --apply; then
    echo "[OK] DNS du management : gitea.local -> Service Traefik"
else
    echo "[WARN] DNS du management non appliqué ; rejouer : bash scripts/config/management-dns.sh --apply" >&2
fi

# Installer Argo CD sur le management recréé, sans activer la Root App.
CLUSTER_NAME=gitops-management \
ARGOCD_MANIFEST="${LAB_PRA_ISOLATED_DIR}/argocd-v3.5.3-install.yaml" \
    bash "${ROOT_DIR}/scripts/bootstrap/management.sh"

# À exécuter uniquement après création du management neuf.
MGMT_CONTEXT="kind-gitops-management"
kubectl --context "$MGMT_CONTEXT" get --raw=/readyz >/dev/null || {
    echo "[ERROR] API management inaccessible ; restauration refusée" >&2
    exit 1
}
# Restaurer la CA avant que la Root App ne déploie son ClusterIssuer.
kubectl --context "$MGMT_CONTEXT" create namespace cert-manager \
    --dry-run=client -o yaml |
    kubectl --context "$MGMT_CONTEXT" apply -f -

if ! existing_ca="$(kubectl --context "$MGMT_CONTEXT" -n cert-manager \
    get secret gitops-lab-root-ca --ignore-not-found -o name)"; then
    echo "[STOP] Lecture du Secret CA impossible ; restauration refusée" >&2
    exit 1
fi

if [[ -n "$existing_ca" ]]; then
    echo "[STOP] Secret CA déjà présent ; restauration refusée" >&2
    exit 1
fi
unset existing_ca

kubectl --context "$MGMT_CONTEXT" -n cert-manager \
    create secret tls gitops-lab-root-ca \
    --cert="$CA_CERT" --key="$CA_KEY" \
    --dry-run=client -o yaml |
    kubectl --context "$MGMT_CONTEXT" create -f - >/dev/null

restored_ca_fingerprint="$(
    kubectl --context "$MGMT_CONTEXT" -n cert-manager \
        get secret gitops-lab-root-ca -o jsonpath='{.data.tls\.crt}' |
        base64 -d | openssl x509 -noout -fingerprint -sha256
)"
local_ca_fingerprint="$(
    openssl x509 -in "$CA_CERT" -noout -fingerprint -sha256
)"

[[ "$restored_ca_fingerprint" == "$local_ca_fingerprint" ]] || {
    echo "[STOP] Certificat CA restauré différent de la source locale" >&2
    exit 1
}

restored_ca_pub="$(
    kubectl --context "$MGMT_CONTEXT" -n cert-manager \
        get secret gitops-lab-root-ca -o jsonpath='{.data.tls\.key}' |
        base64 -d |
        openssl pkey -pubout -outform DER |
        openssl dgst -sha256
)"
local_ca_pub="$(
    openssl pkey -in "$CA_KEY" -pubout -outform DER |
        openssl dgst -sha256
)"

[[ -n "$restored_ca_pub" && "$restored_ca_pub" == "$local_ca_pub" ]] || {
    echo "[STOP] Clé CA restaurée différente de la source locale" >&2
    exit 1
}
unset restored_ca_pub local_ca_pub

unset restored_ca_fingerprint local_ca_fingerprint
echo "[OK] Certificat et clé CA restaurés et vérifiés avant la Root App"

kubectl --context "$MGMT_CONTEXT" create namespace sealed-secrets \
    --dry-run=client -o yaml |
    kubectl --context "$MGMT_CONTEXT" apply -f -

if ! existing_key="$(kubectl --context "$MGMT_CONTEXT" -n sealed-secrets \
    get secret "$KEY_NAME" --ignore-not-found -o name)"; then
    echo "[ERROR] Lecture de la clé impossible ; restauration refusée" >&2
    exit 1
fi
[[ -z "$existing_key" ]] || {
    echo "[ERROR] Clé déjà présente ; restauration refusée" >&2
    exit 1
}

# Restaurer la clé validée avant de démarrer le contrôleur.
# Ne jamais afficher le manifeste : il contient la clé privée encodée.
kubectl create --dry-run=client --validate=false -f "$KEY_BACKUP" -o json |
    jq -e '{
        apiVersion, kind,
        metadata: {
            name: .metadata.name,
            namespace: .metadata.namespace,
            labels: .metadata.labels
        },
        type, data
    }' |
    kubectl --context "$MGMT_CONTEXT" create -f - >/dev/null

echo "[OK] Clé restaurée sur le management"

saved_data="$(kubectl create --dry-run=client --validate=false     -f "$KEY_BACKUP" -o json | jq -ce .data)"
restored_data="$(kubectl --context "$MGMT_CONTEXT" -n sealed-secrets     get secret "$KEY_NAME" -o json | jq -ce .data)"
if [[ "$saved_data" != "$restored_data" ]]; then
    unset saved_data restored_data
    echo "[ERROR] Données de la clé restaurée différentes de la sauvegarde" >&2
    exit 1
fi
unset saved_data restored_data
echo "[OK] Données de la clé restaurée vérifiées"
# Jalon de reconstruction : Sealed Secrets.
# Inaccessible tant que la garde et l arrêt de l option 2 sont présents.
MGMT_CONTEXT="kind-gitops-management"
kubectl --context "$MGMT_CONTEXT" apply \
    -f "${ROOT_DIR}/argocd/projects/infrastructure-project.yaml"
kubectl --context "$MGMT_CONTEXT" apply \
    -f "${ROOT_DIR}/argocd/applications/00-sealed-secrets.yaml"
kubectl --context "$MGMT_CONTEXT" -n sealed-secrets wait \
    --for=create deployment/sealed-secrets-controller --timeout=300s
kubectl --context "$MGMT_CONTEXT" -n sealed-secrets rollout status \
    deployment/sealed-secrets-controller --timeout=300s
kubectl --context "$MGMT_CONTEXT" -n argocd wait \
    --for=jsonpath={.status.sync.status}=Synced \
    application/sealed-secrets --timeout=300s
kubectl --context "$MGMT_CONTEXT" -n argocd wait \
    --for=jsonpath={.status.health.status}=Healthy \
    application/sealed-secrets --timeout=300s

while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue
    sealed_file="${ROOT_DIR}/clusters/management/cluster-registration/${argocd_cluster}-sealedsecret.yaml"
    [[ ! -L "$sealed_file" ]] || {
        echo "[STOP] Lien symbolique historique interdit : $argocd_cluster" >&2
        exit 1
    }

    if [[ ! -e "$sealed_file" ]]; then
        echo "[INFO] Aucun SealedSecret historique : $argocd_cluster"
        continue
    fi
    [[ -f "$sealed_file" && ! -L "$sealed_file" ]] || {
        echo "[STOP] Fichier historique invalide : $argocd_cluster" >&2
        exit 1
    }

    kubeseal --validate \
        --context "$MGMT_CONTEXT" \
        --controller-name sealed-secrets-controller \
        --controller-namespace sealed-secrets \
        < "$sealed_file" >/dev/null 2>&1 || {
        echo "[STOP] Clé restaurée incapable de valider : $argocd_cluster" >&2
        exit 1
    }
    echo "[OK] SealedSecret historique déchiffrable : $argocd_cluster"
done < "$INVENTORY"

# Jalon PRA : candidats dev/prod, hors Git.
candidate_dir="${LAB_REGISTRATION_CANDIDATES_DIR}"
while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue
    MGMT_CONTEXT="$MGMT_CONTEXT" \
    KIND_CLUSTER="$kind_cluster" \
    ARGOCD_CLUSTER="$argocd_cluster" \
    OUTPUT="${candidate_dir}/${argocd_cluster}-sealedsecret.yaml" \
        bash "${ROOT_DIR}/scripts/bootstrap/workload.sh"
done < "$INVENTORY"

MGMT_CONTEXT="$MGMT_CONTEXT" \
CANDIDATE_DIR="$candidate_dir" \
    bash "${ROOT_DIR}/scripts/validate-registration-candidates.sh"

# v1.3.0 : Gitea est la source de verite. Il doit etre restaure et installe
# AVANT le commit des enregistrements et AVANT cluster-registration / Root App.
echo "[INFO] Restauration Gitea avant activation de la Root App"

bash "${ROOT_DIR}/scripts/gitea/restore.sh" \
    --preflight "$GITEA_GAME"

bash "${ROOT_DIR}/scripts/gitea/restore.sh" \
    --restore "$GITEA_GAME"

echo "[OK] Donnees Gitea restaurees avant la Root App"

# Installation directe de Gitea (helm template + kubectl apply) ; Argo CD
# reprend la main a la synchronisation de l'Application gitea.
MGMT_CONTEXT="${MGMT_CONTEXT:-kind-gitops-management}" bash "${ROOT_DIR}/scripts/gitea/install-direct.sh" --preflight
MGMT_CONTEXT="${MGMT_CONTEXT:-kind-gitops-management}" bash "${ROOT_DIR}/scripts/gitea/install-direct.sh" --install
echo "[OK] Gitea installe directement et pret avant la publication"

# Publication PRA : chemins derives exclusivement de l'inventaire valide.
registration_dir="${ROOT_DIR}/clusters/management/cluster-registration"
candidate_paths=()
registration_paths=()

while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue
    candidate_paths+=("${candidate_dir}/${argocd_cluster}-sealedsecret.yaml")
    registration_paths+=("${registration_dir}/${argocd_cluster}-sealedsecret.yaml")
done < "$INVENTORY"

printf '[PRA] %s enregistrement(s) a publier\n' "${#registration_paths[@]}"

for candidate in "${candidate_paths[@]}"; do
    if [[ ! -f "$candidate" || -L "$candidate" ]]; then
        echo "[STOP] Candidat absent ou lien symbolique : $candidate" >&2
        exit 1
    fi
done
echo "[OK] Tous les candidats de l'inventaire sont présents"

for destination in "${registration_paths[@]}"; do
    if [[ -L "$destination" ]]; then
        echo "[STOP] Destination Git sous forme de lien symbolique : $destination" >&2
        exit 1
    fi
done
echo "[OK] Destinations Git vérifiées"

for destination in "${registration_paths[@]}"; do
    relative_path="${destination#"$ROOT_DIR"/}"
    if [[ -n "$(git -C "$ROOT_DIR" status --porcelain -- "$relative_path")" ]]; then
        echo "[STOP] Destination Git déjà modifiée : $relative_path" >&2
        exit 1
    fi
done
echo "[OK] Destinations Git sans modification préalable"

[[ "$(git -C "$ROOT_DIR" branch --show-current)" == "main" ]] || {
    echo "[STOP] Publication PRA autorisée uniquement depuis la branche main" >&2
    exit 1
}

for i in "${!candidate_paths[@]}"; do
    cp -- "${candidate_paths[$i]}" "${registration_paths[$i]}"
done
echo "[OK] Enregistrements copiés vers les chemins Git de l'inventaire"

for i in "${!candidate_paths[@]}"; do
    if ! cmp -s -- "${candidate_paths[$i]}" "${registration_paths[$i]}"; then
        echo "[STOP] Copie différente du candidat validé : ${registration_paths[$i]}" >&2
        exit 1
    fi
done
echo "[OK] Copies identiques aux candidats validés"

relative_registration_paths=()
for destination in "${registration_paths[@]}"; do
    relative_registration_paths+=("${destination#"$ROOT_DIR"/}")
done

git -C "$ROOT_DIR" add -- "${relative_registration_paths[@]}"
git -C "$ROOT_DIR" diff --cached --check
echo "[OK] Enregistrements de l'inventaire préparés dans l'index Git"

mapfile -t staged_paths < <(
    git -C "$ROOT_DIR" diff --cached --name-only | LC_ALL=C sort
)
mapfile -t expected_paths < <(
    printf '%s\n' "${relative_registration_paths[@]}" | LC_ALL=C sort
)

for staged in "${staged_paths[@]}"; do
    allowed=0
    for expected in "${expected_paths[@]}"; do
        if [[ "$staged" == "$expected" ]]; then
            allowed=1
            break
        fi
    done
    if ((allowed == 0)); then
        echo "[STOP] Fichier inattendu dans l'index Git : $staged" >&2
        exit 1
    fi
done

if ((${#staged_paths[@]} == 0)); then
    echo "[STOP] Aucun nouvel enregistrement à publier après reconstruction" >&2
    exit 1
fi
echo "[OK] Index Git limité aux enregistrements modifiés de l'inventaire"

git -C "$ROOT_DIR" commit -m "chore(pra): renew workload registrations"
published_head="$(git -C "$ROOT_DIR" rev-parse HEAD)"

MGMT_CONTEXT="${MGMT_CONTEXT:-kind-gitops-management}" bash "${ROOT_DIR}/scripts/gitea/publish.sh" --push "$published_head"

actual_remote_head="$published_head"  # main distant relu et compare par scripts/gitea/publish.sh apres le push
if [[ "$actual_remote_head" != "$published_head" ]]; then
    echo "[STOP] La révision distante ne correspond pas au commit PRA" >&2
    exit 1
fi
echo "[OK] Enregistrements publiés sur main : $published_head"

for i in "${!candidate_paths[@]}"; do
    relative_path="${relative_registration_paths[$i]}"
    if ! git -C "$ROOT_DIR" show "${published_head}:${relative_path}" |
         cmp -s -- "${candidate_paths[$i]}" -; then
        echo "[STOP] Le commit publié ne correspond pas au candidat : $relative_path" >&2
        exit 1
    fi
done
echo "[OK] Commit publié conforme aux candidats de l'inventaire"

registration_app="${ROOT_DIR}/argocd/applications/cluster-registration.yaml"

kubectl --context "$MGMT_CONTEXT" apply --dry-run=server -f "$registration_app"
kubectl --context "$MGMT_CONTEXT" apply -f "$registration_app"
echo "[OK] Application cluster-registration déclarée ; synchronisation à vérifier"

kubectl --context "$MGMT_CONTEXT" -n argocd wait \
    --for="jsonpath={.status.sync.revision}=${published_head}" \
    application/cluster-registration --timeout=300s
kubectl --context "$MGMT_CONTEXT" -n argocd wait \
    --for=jsonpath='{.status.sync.status}'=Synced \
    application/cluster-registration --timeout=300s
echo "[OK] cluster-registration synchronisée sur le commit PRA"

while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue

    kubectl --context "$MGMT_CONTEXT" -n argocd wait \
        --for=create "secret/${argocd_cluster}" --timeout=300s

    if ! kubectl --context "$MGMT_CONTEXT" -n argocd \
        get secret "$argocd_cluster" -o json |
        jq -e --arg name "$argocd_cluster" '
            .metadata.labels["argocd.argoproj.io/secret-type"] == "cluster" and
            any(.metadata.ownerReferences[]?;
                .kind == "SealedSecret" and .name == $name)
        ' >/dev/null; then
        echo "[STOP] Enregistrement Argo CD invalide : $argocd_cluster" >&2
        exit 1
    fi
    echo "[OK] Secret de cluster présent : $argocd_cluster"
done < "$INVENTORY"


root_app="${ROOT_DIR}/clusters/management/root-app/root-app.yaml"
kubectl --context "$MGMT_CONTEXT" apply --dry-run=server -f "$root_app"
kubectl --context "$MGMT_CONTEXT" apply -f "$root_app"
echo "[OK] Root App déclarée ; déploiements à vérifier"

while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue

    for attempt in {1..60}; do
        if kubectl --context "kind-${kind_cluster}" -n whoami \
            get deployment whoami >/dev/null 2>&1; then
            break
        fi
        sleep 5
    done

    if ! kubectl --context "kind-${kind_cluster}" -n whoami \
        get deployment whoami >/dev/null 2>&1; then
        echo "[STOP] Deployment Whoami absent : ${kind_cluster}" >&2
        exit 1
    fi

    kubectl --context "kind-${kind_cluster}" -n whoami \
        rollout status deployment/whoami --timeout=300s
    echo "[OK] Whoami disponible sur ${kind_cluster}"
done < "$INVENTORY"

while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue
    context="kind-${kind_cluster}"

    for attempt in {1..60}; do
        controller="$(kubectl --context "$context" -n ingress-nginx \
            get deployment -l app.kubernetes.io/name=ingress-nginx \
            -o name 2>/dev/null)" || controller=""
        [[ -n "$controller" ]] && break
        sleep 5
    done

    if [[ -z "$controller" || "$controller" == *$'\n'* ]]; then
        echo "[STOP] Contrôleur Ingress absent ou non unique : $kind_cluster" >&2
        exit 1
    fi

    kubectl --context "$context" -n ingress-nginx \
        rollout status "$controller" --timeout=300s
    echo "[OK] Ingress disponible : $kind_cluster"
done < "$INVENTORY"

while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue
    context="kind-${kind_cluster}"

    for attempt in {1..60}; do
        ingress_services="$(kubectl --context "$context" -n ingress-nginx \
            get svc -l app.kubernetes.io/name=ingress-nginx -o json |
            jq -c '[.items[] | select(.spec.type == "LoadBalancer")]')" || exit 1

        if [[ "$(jq 'length' <<< "$ingress_services")" == "1" ]] &&
           [[ -n "$(jq -r '.[0].status.loadBalancer.ingress[0].ip // empty' \
               <<< "$ingress_services")" ]]; then
            break
        fi
        sleep 5
    done

    if [[ "$(jq 'length' <<< "$ingress_services")" != "1" ]] ||
       [[ -z "$(jq -r '.[0].status.loadBalancer.ingress[0].ip // empty' \
           <<< "$ingress_services")" ]]; then
        echo "[STOP] Service Ingress ou IP indisponible : $kind_cluster" >&2
        exit 1
    fi
    actual_ip="$(jq -r '.[0].status.loadBalancer.ingress[0].ip' \
        <<< "$ingress_services")"
    expected_ip=""
    matches=0

    for app in "${ROOT_DIR}"/argocd/applications/ingress-nginx*.yaml; do
        app_destination="$(yq -r '.spec.destination.name' "$app")"
        [[ "$app_destination" == "$argocd_cluster" ]] || continue

        ((matches += 1))
        expected_ip="$(yq -r '.spec.source.helm.values' "$app" |
            yq -r '.controller.service.annotations."metallb.io/loadBalancerIPs"' -)"
    done

    if ((matches != 1)) || [[ -z "$expected_ip" || "$expected_ip" == "null" ||
                                "$actual_ip" != "$expected_ip" ]]; then
        echo "[STOP] IP Ingress incorrecte ou manifeste ambigu : $kind_cluster" >&2
        exit 1
    fi
    echo "[OK] IP Ingress conforme pour ${kind_cluster} : ${actual_ip}"
done < "$INVENTORY"

while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue

    host="$(kubectl kustomize \
        "${ROOT_DIR}/applications/whoami/overlays/${environment}" |
        yq -r 'select(.kind == "Ingress") | .spec.rules[].host')"

    if [[ -z "$host" || "$host" == *$'\n'* ]]; then
        echo "[STOP] Hôte Whoami absent ou ambigu : $environment" >&2
        exit 1
    fi

    response=""
    for attempt in {1..30}; do
        response="$(curl --noproxy '*' --max-time 10 -sS \
            -w $'\n%{http_code}' "http://${host}/")" || response=""
        [[ "${response##*$'\n'}" == "200" ]] && break
        sleep 5
    done
    http_code="${response##*$'\n'}"
    response="${response%$'\n'*}"
    [[ "$http_code" == "200" ]] || {
        echo "[STOP] Réponse HTTP $http_code : $host" >&2
        exit 1
    }
    pod="$(awk '/^Hostname: / { print $2 }' <<< "$response")"
    if [[ -z "$pod" || "$pod" == *$'\n'* ]] ||
       ! kubectl --context "kind-${kind_cluster}" -n whoami \
           wait --for=condition=Ready "pod/${pod}" --timeout=10s >/dev/null; then
        echo "[STOP] Pod répondant absent ou non prêt sur ${kind_cluster}" >&2
        exit 1
    fi
    echo "[OK] HTTP 200 : $host ; pod confirmé sur ${kind_cluster} : $pod"
done < "$INVENTORY"

# Synchronisation Gitea apres restauration des donnees.
(
    set -euo pipefail
    umask 077

    tmp_kubeconfig="$(mktemp)"
    trap 'rm -f "$tmp_kubeconfig"' EXIT

    kubectl --context "$MGMT_CONTEXT" \
        config view --minify --raw > "$tmp_kubeconfig"

    export KUBECONFIG="$tmp_kubeconfig"

    kubectl config set-context "$MGMT_CONTEXT" \
        --namespace=argocd >/dev/null

    log_dir="${LAB_LOG_DIR}"
    mkdir -p "$log_dir"
    sync_log="$(mktemp "$log_dir/argocd-sync.XXXXXXXX.log")"

    echo "[INFO] Journal detaille Argo CD : $sync_log"

    for app in gitea gitea-external; do
        kubectl --context "$MGMT_CONTEXT" -n argocd \
            wait --for=create "application/$app" \
            --timeout=300s

        echo "[INFO] Synchronisation : $app"

        if ! argocd --core --kube-context "$MGMT_CONTEXT" \
            app sync "$app" --timeout 300 \
            >> "$sync_log" 2>&1; then
            echo "[STOP] Synchronisation echouee : $app" >&2
            tail -n 80 "$sync_log" >&2
            exit 1
        fi

        if ! argocd --core --kube-context "$MGMT_CONTEXT" \
            app wait "$app" --sync --health --timeout 300 \
            >> "$sync_log" 2>&1; then
            echo "[STOP] Attente Synced/Healthy echouee : $app" >&2
            tail -n 80 "$sync_log" >&2
            exit 1
        fi

        echo "[OK] Application Synced/Healthy : $app"
    done
)

kubectl --context "$MGMT_CONTEXT" -n gitea \
    rollout status deployment/gitea --timeout=300s

kubectl --context "$MGMT_CONTEXT" -n gitea \
    wait --for=jsonpath='{.status.phase}'=Bound \
    pvc/gitea-shared-storage --timeout=60s

kubectl --context "$MGMT_CONTEXT" -n gitea \
    wait --for=condition=Ready \
    certificate/gitea-local --timeout=300s

echo "[OK] Gitea synchronisee, Deployment disponible, PVC lie et certificat pret"
POST_PRA_VALIDATOR="${ROOT_DIR}/scripts/validate-post-pra.sh"

[[ -f "$POST_PRA_VALIDATOR" &&
   -x "$POST_PRA_VALIDATOR" &&
   ! -L "$POST_PRA_VALIDATOR" ]] || {
    echo "[STOP] Validateur post-PRA absent ou invalide : $POST_PRA_VALIDATOR" >&2
    exit 1
}

echo "[INFO] Validation automatique de l'état restauré"

MGMT_CONTEXT="$MGMT_CONTEXT" \
    "$POST_PRA_VALIDATOR" --backup "$GITEA_GAME" || {
        echo "[STOP] Validation post-PRA automatique en échec" >&2
        exit 1
    }
