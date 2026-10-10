#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../lib/lab-paths.sh" || { echo "[ERREUR] lab-paths.sh illisible" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"

restore_admin_secret() {
    local backup_dir secret_file

    backup_dir="${GITEA_BACKUP_DIR:-${LAB_GITEA_BACKUP_DIR}}"
    secret_file="$backup_dir/$GAME/admin-secret.json"

    # Le prévol commun doit avoir réussi avant tout appel.
    if [[ -z "$namespace_json" ]]; then
        kubectl --context "$CONTEXT" --request-timeout=15s \
            create namespace gitea
    fi

    # Projection limitée : aucune métadonnée de l'ancien cluster.
    # Le contenu sensible circule uniquement dans le pipeline.
    jq -e '
        {
            apiVersion: "v1",
            kind: "Secret",
            metadata: {
                name: "gitea-admin-secret",
                namespace: "gitea"
            },
            type: "Opaque",
            data: {
                username: .data.username,
                password: .data.password
            }
        }
    ' "$secret_file" |
        kubectl --context "$CONTEXT" --request-timeout=15s \
            create --dry-run=server -f - -o name

    jq -e '
        {
            apiVersion: "v1",
            kind: "Secret",
            metadata: {
                name: "gitea-admin-secret",
                namespace: "gitea"
            },
            type: "Opaque",
            data: {
                username: .data.username,
                password: .data.password
            }
        }
    ' "$secret_file" |
        kubectl --context "$CONTEXT" --request-timeout=15s \
            create -f - -o name

    echo "[OK] Secret administrateur créé"
}

verify_restored_admin_secret() {
    local backup_dir secret_file expected actual

    backup_dir="${GITEA_BACKUP_DIR:-${LAB_GITEA_BACKUP_DIR}}"
    secret_file="$backup_dir/$GAME/admin-secret.json"

    expected="$(
        jq -cS '{username: .data.username, password: .data.password}' \
            "$secret_file" |
            sha256sum | cut -d ' ' -f 1
    )"

    actual="$(
        kubectl --context "$CONTEXT" --request-timeout=15s \
            -n gitea get secret gitea-admin-secret -o json |
            jq -cS '{username: .data.username, password: .data.password}' |
            sha256sum | cut -d ' ' -f 1
    )"

    if [[ "$actual" != "$expected" ]]; then
        echo "[STOP] Secret restaure different de la sauvegarde" >&2
        return 1
    fi

    echo "[OK] Donnees du Secret restaure conformes"
}

prepare_restore_volume() {
    local pvc_manifest pod_manifest

    pvc_manifest="$SCRIPT_DIR/manifests/gitea-restore-pvc.yaml"
    pod_manifest="$SCRIPT_DIR/manifests/gitea-restore-pod.yaml"

    kubectl --context "$CONTEXT" --request-timeout=15s \
        create --dry-run=server -f "$pvc_manifest" -o name

    kubectl --context "$CONTEXT" --request-timeout=15s \
        create --dry-run=server -f "$pod_manifest" -o name

    # create refuse une ressource existante, sans la modifier.
    kubectl --context "$CONTEXT" --request-timeout=15s \
        create -f "$pvc_manifest" -o name

    # Le consommateur déclenche le provisionnement du volume.
    kubectl --context "$CONTEXT" --request-timeout=15s \
        create -f "$pod_manifest" -o name
    restore_pod_created=1

    kubectl --context "$CONTEXT" -n gitea \
        wait --for=condition=Ready pod/gitea-restore \
        --timeout=180s

    kubectl --context "$CONTEXT" -n gitea \
        wait --for=jsonpath='{.status.phase}'=Bound \
        pvc/gitea-shared-storage --timeout=60s

    echo "[OK] Pod de restauration prêt et PVC lié"
}

check_restore_volume_empty() {
    kubectl --context "$CONTEXT" --request-timeout=30s \
        -n gitea exec gitea-restore -c restore -- sh -ec '
            test -d /data || {
                echo "[STOP] Repertoire /data absent" >&2
                exit 1
            }

            for entry in /data/* /data/.[!.]* /data/..?*; do
                if [ -e "$entry" ] || [ -L "$entry" ]; then
                    echo "[STOP] Volume /data non vide : extraction refusee" >&2
                    exit 1
                fi
            done

            test -w /data || {
                echo "[STOP] Repertoire /data non accessible en ecriture" >&2
                exit 1
            }
        '

    echo "[OK] Volume vide et controle test -w reussi"
}

restore_data_archive() {
    local backup_dir archive

    backup_dir="${GITEA_BACKUP_DIR:-${LAB_GITEA_BACKUP_DIR}}"
    archive="$backup_dir/$GAME/data.tar.gz"

    # Revalider le jeu juste avant le transfert.
    bash "$BACKUP_SCRIPT" --validate "$GAME"
    check_restore_volume_empty

    # pipefail permet de detecter aussi un echec de decompression.
    if ! gzip -dc -- "$archive" |
        kubectl --context "$CONTEXT" -n gitea \
            exec -i gitea-restore -c restore -- \
            tar -C /data -xf -; then
        echo "[STOP] Transfert echoue ; PVC potentiellement partiellement rempli" >&2
        return 1
    fi

    echo "[OK] Extraction terminee ; contenu restaure encore a verifier"
}

verify_restored_files() {
    local backup_dir archive member expected actual

    backup_dir="${GITEA_BACKUP_DIR:-${LAB_GITEA_BACKUP_DIR}}"
    archive="$backup_dir/$GAME/data.tar.gz"

    for member in gitea.db gitea/conf/app.ini; do
        expected="$(
            tar -xOzf "$archive" "./$member" |
                sha256sum | cut -d ' ' -f 1
        )"

        actual="$(
            kubectl --context "$CONTEXT" --request-timeout=30s \
                -n gitea exec gitea-restore -c restore -- \
                sha256sum "/data/$member" |
                cut -d ' ' -f 1
        )"

        if [[ "$actual" != "$expected" ]]; then
            echo "[STOP] Empreinte restauree incorrecte : $member" >&2
            return 1
        fi

        echo "[OK] Empreinte restauree conforme : $member"
    done

    kubectl --context "$CONTEXT" --request-timeout=30s \
        -n gitea exec gitea-restore -c restore -- \
        test -d /data/git/gitea-repositories

    echo "[OK] Repertoire des depots present"
}

cleanup_restore() {
    local status="$?"
    trap - EXIT INT TERM

    if [[ "${restore_pod_created:-0}" == "1" ]]; then
        if ! kubectl --context "$CONTEXT" --request-timeout=30s \
            -n gitea delete pod gitea-restore \
            --ignore-not-found --wait=true --timeout=60s; then
            echo "[STOP] Nettoyage du pod temporaire echoue" >&2
            status=1
        fi
    fi

    if (( status != 0 )); then
        echo "[STOP] Restauration interrompue ; PVC et Secret conserves pour diagnostic" >&2
    fi

    exit "$status"
}

if [[ "$#" -ne 2 ]]; then
    echo "Usage : $0 --preflight|--restore AAAAMMJJ-HHMMSS" >&2
    exit 2
fi

MODE="$1"
case "$MODE" in
    --preflight|--restore) ;;
    *)
        echo "[STOP] Mode inconnu : $MODE" >&2
        exit 2
        ;;
esac

GAME="$2"
if [[ ! "$GAME" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
    echo "[STOP] Nom de jeu invalide" >&2
    exit 2
fi

for tool in bash jq sha256sum cut gzip tar awk wc basename; do
    command -v "$tool" >/dev/null || {
        echo "[STOP] Outil absent : $tool" >&2
        exit 1
    }
done

[[ -f "$BACKUP_SCRIPT" && ! -L "$BACKUP_SCRIPT" ]] || {
    echo "[STOP] Script de sauvegarde absent ou invalide" >&2
    exit 1
}

bash "$BACKUP_SCRIPT" --validate "$GAME"

echo "[OK] Prévol local terminé pour le jeu : $GAME"

command -v yq >/dev/null || {
    echo "[STOP] yq absent" >&2
    exit 1
}

for file in gitea-restore-pvc.yaml gitea-restore-pod.yaml; do
    [[ -f "$SCRIPT_DIR/manifests/$file" &&
       ! -L "$SCRIPT_DIR/manifests/$file" ]] || {
        echo "[STOP] Manifeste absent ou invalide : $file" >&2
        exit 1
    }
done

yq -e '
  .apiVersion == "v1" and
  .kind == "PersistentVolumeClaim" and
  .metadata.name == "gitea-shared-storage" and
  .metadata.namespace == "gitea" and
  (.spec.accessModes | length) == 1 and
  .spec.accessModes[0] == "ReadWriteOnce" and
  .spec.volumeMode == "Filesystem" and
  .spec.storageClassName == "standard" and
  .spec.resources.requests.storage == "2Gi"
' "$SCRIPT_DIR/manifests/gitea-restore-pvc.yaml" >/dev/null || {
    echo "[STOP] Manifeste PVC non conforme" >&2
    exit 1
}
echo "[OK] Manifeste PVC contrôlé"

yq -e '
  .apiVersion == "v1" and
  .kind == "Pod" and
  .metadata.name == "gitea-restore" and
  .metadata.namespace == "gitea" and
  .spec.restartPolicy == "Never" and
  .spec.securityContext.runAsUser == 1000 and
  .spec.securityContext.runAsGroup == 1000 and
  (.spec.containers | length) == 1 and
  .spec.containers[0].name == "restore" and
  .spec.containers[0].image == "docker.gitea.com/gitea:1.27.0-rootless" and
  (.spec.containers[0].command | length) == 3 and
  .spec.containers[0].command[0] == "sh" and
  .spec.containers[0].command[1] == "-c" and
  .spec.containers[0].command[2] == "sleep 3600" and
  (.spec.containers[0].volumeMounts | length) == 1 and
  .spec.containers[0].volumeMounts[0].name == "data" and
  .spec.containers[0].volumeMounts[0].mountPath == "/data" and
  (.spec.containers[0].volumeMounts[0].readOnly // false) == false and
  (.spec.volumes | length) == 1 and
  .spec.volumes[0].name == "data" and
  .spec.volumes[0].persistentVolumeClaim.claimName == "gitea-shared-storage" and
  (.spec.volumes[0].persistentVolumeClaim.readOnly // false) == false
' "$SCRIPT_DIR/manifests/gitea-restore-pod.yaml" >/dev/null || {
    echo "[STOP] Manifeste pod non conforme" >&2
    exit 1
}
echo "[OK] Manifeste pod contrôlé"

CONTEXT="kind-gitops-management"
command -v kubectl >/dev/null || {
    echo "[STOP] kubectl absent" >&2
    exit 1
}

nodes="$(
    kubectl --context "$CONTEXT" --request-timeout=15s \
        get nodes -o name
)"

if [[ "$nodes" != "node/gitops-management-control-plane" ]]; then
    echo "[STOP] Identité du management inattendue" >&2
    exit 1
fi

echo "[OK] Nœud management attendu confirmé"

storage="$(
    kubectl --context "$CONTEXT" --request-timeout=15s \
        get storageclass standard -o json
)"

if ! jq -e '
    .provisioner == "rancher.io/local-path" and
    .volumeBindingMode == "WaitForFirstConsumer" and
    .reclaimPolicy == "Delete"
' <<< "$storage" >/dev/null; then
    echo "[STOP] StorageClass standard non conforme au PRA attendu" >&2
    exit 1
fi

echo "[OK] StorageClass standard conforme"

namespace_json="$(
    kubectl --context "$CONTEXT" --request-timeout=15s \
        get namespace gitea --ignore-not-found -o json
)"

if [[ -z "$namespace_json" ]]; then
    echo "[OK] Namespace gitea absent : création prévue lors de la restauration"
else
    if ! jq -e '
        .metadata.deletionTimestamp == null and
        .status.phase == "Active"
    ' <<< "$namespace_json" >/dev/null; then
        echo "[STOP] Namespace gitea non actif ou en suppression" >&2
        exit 1
    fi
    echo "[OK] Namespace gitea actif"
fi

if [[ -n "$namespace_json" ]]; then
    # Conserver ici les contrôles existants :
    # blocked=0, ressources, pods et refus si blocked.

    blocked=0
    for resource in deployment/gitea secret/gitea-admin-secret \
                    pvc/gitea-shared-storage; do
        existing="$(
            kubectl --context "$CONTEXT" --request-timeout=15s \
                -n gitea get "$resource" --ignore-not-found -o name
        )"
        if [[ -n "$existing" ]]; then
            echo "[STOP] Ressource déjà présente : $existing" >&2
            blocked=1
        fi
    done

    pods="$(
        kubectl --context "$CONTEXT" --request-timeout=15s \
            -n gitea get pods -o name
    )"
    if [[ -n "$pods" ]]; then
        echo "[STOP] Pods présents dans le namespace gitea :" >&2
        printf '%s\n' "$pods" >&2
        blocked=1
    fi

    if (( blocked )); then
        echo "[STOP] Cible occupée : restauration refusée" >&2
        exit 1
    fi
fi

echo "[OK] Ressources bloquantes absentes"

if [[ "$MODE" == "--preflight" ]]; then
    echo "[OK] Prévol terminé ; aucune écriture Kubernetes"
    exit 0
fi

restore_pod_created=0
trap cleanup_restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

restore_admin_secret
verify_restored_admin_secret
prepare_restore_volume
restore_data_archive
verify_restored_files

# Retirer le pod avant de permettre le demarrage de Gitea.
kubectl --context "$CONTEXT" --request-timeout=30s \
    -n gitea delete pod gitea-restore \
    --wait=true --timeout=60s

restore_pod_created=0

echo "[OK] Transfert et controles termines pour le jeu : $GAME"
echo "[INFO] PVC conserve ; validation SQLite, depots et Gitea encore requise"
exit 0
