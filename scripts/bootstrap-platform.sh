#!/usr/bin/env bash

set -euo pipefail

if [[ "${1:-}" == "--plan" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

    test -x "$root/scripts/configure-workload-registry.sh" || {
        echo "[STOP] Script absent ou non exécutable : scripts/configure-workload-registry.sh"
        exit 1
    }
    echo "[PLAN] kind create cluster --name gitops-management --config clusters/management/kind-config.yaml"
    awk -F '\t' 'NR > 1 {
        printf "[PLAN] kind create cluster --name %s --config clusters/workload-%s/kind-config.yaml\n", $2, $1
    }' "$inventory"
    echo "[PLAN] bash scripts/configure-workload-registry.sh (gitea.local, CA et hosts.toml sur les nœuds workload)"
    echo "[OK] Plan affiché ; aucune action Kubernetes ou Docker exécutée"
    exit 0
fi

PREFLIGHT_ONLY=0
if [[ "${1:-}" == "--preflight" && "$#" -eq 1 ]]; then
    PREFLIGHT_ONLY=1
elif (($# != 0)); then
    echo "[STOP] Usage : $0 [--plan|--preflight]" >&2
    exit 1
fi

echo "=================================================="
echo "GitOps Platform Bootstrap"
echo "=================================================="

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Inventaire des workloads à traiter lors du futur bootstrap.
# Ce bloc reste inaccessible tant que la garde [STOP] est présente.
INVENTORY="${ROOT_DIR}/clusters/workloads.tsv"
KEY_BACKUP="${KEY_BACKUP:-${HOME}/.config/gitops-lab/sealed-secrets-keyx9rjr-2026-09-29.yaml}"

[[ -f "$INVENTORY" ]] || {
    echo "[ERROR] Inventaire absent : $INVENTORY" >&2
    exit 1
}

# Accès au registre Gitea : refuser AVANT toute destruction si le patch containerd
# ou le script d'accès manque (sinon l'échec surviendrait après la recréation).
[[ -x "${ROOT_DIR}/scripts/configure-workload-registry.sh" ]] || {
    echo "[STOP] Script absent ou non exécutable : scripts/configure-workload-registry.sh" >&2
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
ARGOCD_MANIFEST="${HOME}/.config/gitops-lab/pra-isolated/argocd-v3.5.3-install.yaml"
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

candidate_dir="${HOME}/.config/gitops-lab/registration-candidates"
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

local_head="$(git -C "$ROOT_DIR" rev-parse HEAD)"
remote_head="$(git -C "$ROOT_DIR" ls-remote gitea refs/heads/main | cut -f1)"
[[ -n "$remote_head" && "$local_head" == "$remote_head" ]] || {
    echo "[STOP] main local et gitea/main diffèrent ou Gitea est inaccessible" >&2
    exit 1
}
echo "[OK] Branche main alignée avec le dépôt distant"
MGMT_CONTEXT="${MGMT_CONTEXT:-kind-gitops-management}" bash "${ROOT_DIR}/scripts/gitea-publish.sh" --check
MGMT_CONTEXT="${MGMT_CONTEXT:-kind-gitops-management}" bash "${ROOT_DIR}/scripts/install-gitea-direct.sh" --render-check

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

# Éléments hors source de vérité (inventaire scripts/external-deps.tsv) : contrôle seul.
# Codes 0 et 2 : le prévol continue ; codes 1 (inventaire invalide) et 3 : arrêt avant le menu PRA.
EXTERNAL_DEPS_SCRIPT="${ROOT_DIR}/scripts/check-external-deps.sh"
[[ -f "$EXTERNAL_DEPS_SCRIPT" && -x "$EXTERNAL_DEPS_SCRIPT" ]] || {
    echo "[STOP] Script absent ou non exécutable : $EXTERNAL_DEPS_SCRIPT" >&2
    exit 1
}
external_deps_args=(--check)
if [[ "${EXTERNAL_DEPS_OFFLINE:-0}" == "1" ]]; then
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

for script in backup-gitea.sh restore-gitea.sh; do
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

export ARGOCD_ADMIN_HASH_FILE="${ARGOCD_ADMIN_HASH_FILE:-$HOME/.config/gitops-lab/argocd-admin-password.bcrypt}"

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

CA_DIR="${HOME}/.config/gitops-lab"
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

if ((${#clusters_to_delete[@]} > 0)); then
    echo
    if [[ ! -t 0 ]]; then
        echo "[STOP] Confirmation interactive requise ; aucun cluster supprimé" >&2
        exit 1
    fi
    read -r -p "Choix PRA [1=refuser (défaut), 2=détruire le périmètre affiché] : " choice
    case "${choice:-1}" in
        1)
            echo "[STOP] PRA refusé ; aucun cluster supprimé"
            exit 1
            ;;
        2)
            printf "[PREVIEW] Destruction demandée pour %s cluster(s) du périmètre PRA\n" "${#clusters_to_delete[@]}"
            ;;
        *)
            echo "[STOP] Choix invalide ; aucun cluster supprimé" >&2
            exit 1
            ;;
    esac
else
    echo "[OK] Aucun cluster du périmètre PRA à détruire ; confirmation inutile"
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
GITEA_BACKUP_SCRIPT="${ROOT_DIR}/scripts/backup-gitea.sh"

if grep -Fxq -- gitops-management <<< "$existing_clusters"; then
    echo "[INFO] Sauvegarde fraiche de Gitea avant destruction"

    gitea_backup_output="$(
        bash "$GITEA_BACKUP_SCRIPT" --backup
    )"
else
    echo "[INFO] Management absent ; selection du dernier jeu valide"

    gitea_backup_output="$(
        bash "$GITEA_BACKUP_SCRIPT" --latest
    )"
fi


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
bash "${ROOT_DIR}/scripts/configure-workload-registry.sh"

# Installer Argo CD sur le management recréé, sans activer la Root App.
CLUSTER_NAME=gitops-management \
ARGOCD_MANIFEST="${HOME}/.config/gitops-lab/pra-isolated/argocd-v3.5.3-install.yaml" \
    bash "${ROOT_DIR}/scripts/bootstrap-management.sh"

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
candidate_dir="${HOME}/.config/gitops-lab/registration-candidates"
while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue
    MGMT_CONTEXT="$MGMT_CONTEXT" \
    KIND_CLUSTER="$kind_cluster" \
    ARGOCD_CLUSTER="$argocd_cluster" \
    OUTPUT="${candidate_dir}/${argocd_cluster}-sealedsecret.yaml" \
        bash "${ROOT_DIR}/scripts/bootstrap-workload.sh"
done < "$INVENTORY"

MGMT_CONTEXT="$MGMT_CONTEXT" \
CANDIDATE_DIR="$candidate_dir" \
    bash "${ROOT_DIR}/scripts/validate-registration-candidates.sh"

# v1.3.0 : Gitea est la source de verite. Il doit etre restaure et installe
# AVANT le commit des enregistrements et AVANT cluster-registration / Root App.
echo "[INFO] Restauration Gitea avant activation de la Root App"

bash "${ROOT_DIR}/scripts/restore-gitea.sh" \
    --preflight "$GITEA_GAME"

bash "${ROOT_DIR}/scripts/restore-gitea.sh" \
    --restore "$GITEA_GAME"

echo "[OK] Donnees Gitea restaurees avant la Root App"

# Installation directe de Gitea (helm template + kubectl apply) ; Argo CD
# reprend la main a la synchronisation de l'Application gitea.
MGMT_CONTEXT="${MGMT_CONTEXT:-kind-gitops-management}" bash "${ROOT_DIR}/scripts/install-gitea-direct.sh" --preflight
MGMT_CONTEXT="${MGMT_CONTEXT:-kind-gitops-management}" bash "${ROOT_DIR}/scripts/install-gitea-direct.sh" --install
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

MGMT_CONTEXT="${MGMT_CONTEXT:-kind-gitops-management}" bash "${ROOT_DIR}/scripts/gitea-publish.sh" --push "$published_head"

actual_remote_head="$published_head"  # main distant relu et compare par gitea-publish.sh apres le push
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

    log_dir="$HOME/.local/share/gitops-lab/logs"
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
echo "[INFO] Connexion et contenu des depots encore a verifier"
