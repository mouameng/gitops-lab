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
            if (!(($1 == "dev" && $2 == "gitops-dev" && $3 == "workload-dev") ||
          ($1 == "prod" && $2 == "gitops-prod" && $3 == "workload-prod"))) bad = 1
            if ($1 !~ /^[a-z0-9-]+$/ || $2 !~ /^[a-z0-9-]+$/ || $3 !~ /^[a-z0-9-]+$/) bad = 1
            count++
        }
        END { if (bad || count != 2) exit 1 }
    ' "$inventory" || { echo "[STOP] Inventaire ou configurations invalides"; exit 1; }

    while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
        [[ "$environment" == "environment" ]] && continue
        test -f "$root/clusters/workload-${environment}/kind-config.yaml" || {
            echo "[STOP] Configuration Kind absente : $environment"
            exit 1
        }
    done < "$inventory"

    echo "[PLAN] kind create cluster --name gitops-management --config clusters/management/kind-config.yaml"
    awk -F '\t' 'NR > 1 {
        printf "[PLAN] kind create cluster --name %s --config clusters/workload-%s/kind-config.yaml\n", $2, $1
    }' "$inventory"
    echo "[OK] Plan affiché ; aucune action Kubernetes ou Docker exécutée"
    exit 0
fi

PREFLIGHT_ONLY=0
if [[ "${1:-}" == "--preflight" && "$#" -eq 1 ]]; then
    PREFLIGHT_ONLY=1
else
    echo "[STOP] Bootstrap plateforme à trois clusters non finalisé ; ne pas exécuter."
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
    if (!(($1 == "dev" && $2 == "gitops-dev" && $3 == "workload-dev") ||
          ($1 == "prod" && $2 == "gitops-prod" && $3 == "workload-prod"))) bad = 1
  }
  { count++ }
  END { if (bad || count != 2) exit 1 }
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
for name in workload-dev workload-prod; do
    candidate="${candidate_dir}/${name}-sealedsecret.yaml"
    if [[ -e "$candidate" || -L "$candidate" ]]; then
        echo "[STOP] Chemin candidat déjà occupé : $name" >&2
        exit 1
    fi
done

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
        echo "[STOP] Suppression non activée : reconstruction du PRA incomplète"
        exit 1
        ;;
    *)
        echo "[STOP] Choix invalide ; aucun cluster supprimé" >&2
        exit 1
        ;;
esac

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

# TODO BLOQUANT : générer et valider les nouveaux accès Argo CD
# pour chaque cluster recréé, avant activation de la Root App.
echo "[STOP] Nouveaux enregistrements dev/prod et transition GitOps non implémentés" >&2
exit 1
