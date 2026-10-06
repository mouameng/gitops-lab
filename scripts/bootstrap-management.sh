#!/usr/bin/env bash

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:?Définir CLUSTER_NAME explicitement}"
ARGOCD_NAMESPACE="argocd"
ARGOCD_MANIFEST="${ARGOCD_MANIFEST:?Définir ARGOCD_MANIFEST explicitement}"
EXPECTED_SHA256="7efe2d6bbc03f63623640f1e4198f16c84009d510fb810ef71e56df1b7614ba9"
ARGOCD_ADMIN_HASH_FILE="${ARGOCD_ADMIN_HASH_FILE:-$HOME/.config/gitops-lab/argocd-admin-password.bcrypt}"

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

echo "[OK] Fichier bcrypt administrateur controle"

[[ -f "$ARGOCD_MANIFEST" && -r "$ARGOCD_MANIFEST" ]] || {
  echo "[STOP] Manifeste Argo CD absent ou illisible" >&2
  exit 1
}
ACTUAL_SHA256="$(sha256sum "$ARGOCD_MANIFEST" | cut -d ' ' -f 1)"
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || {
  echo "[STOP] Empreinte du manifeste Argo CD inattendue" >&2
  exit 1
}
echo "[OK] Manifeste Argo CD v3.5.3 vérifié"

echo "==================================="
echo " Bootstrap cluster management"
echo "==================================="

#
# Vérifications préalables
#
for cmd in kubectl helm git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERREUR: commande absente: $cmd"
    exit 1
  fi
done

echo "[OK] outils présents"

#
# Vérification contexte
#
MGMT_CONTEXT="kind-${CLUSTER_NAME}"

#
# Namespace ArgoCD
#
kubectl --context "$MGMT_CONTEXT" create namespace argocd \
  --dry-run=client -o yaml \
  | kubectl --context "$MGMT_CONTEXT" apply -f -

#
# Installation ArgoCD
#
ARGOCD_FRESH_INSTALL=false
if ! kubectl --context "$MGMT_CONTEXT" get deployment argocd-server \
  -n argocd >/dev/null 2>&1; then

  echo "[INFO] installation ArgoCD"
  ARGOCD_FRESH_INSTALL=true
  kubectl --context "$MGMT_CONTEXT" apply \
    --server-side \
    -n argocd \
    -f "$ARGOCD_MANIFEST"

else

  echo "[INFO] ArgoCD déjà installé"

fi

# Le manifeste d'installation crée ce ConfigMap sans server.insecure.
# Appliquer la configuration Git avant de vérifier la disponibilité du serveur.
kubectl --context "$MGMT_CONTEXT" -n argocd apply \
  -f "${ROOT_DIR}/applications/argocd/argocd-cmd-params-cm.yaml"

# Lors d'une installation neuve, le pod a pu démarrer avant cette application.
if [[ "$ARGOCD_FRESH_INSTALL" == "true" ]]; then
  kubectl --context "$MGMT_CONTEXT" -n argocd \
    rollout restart deployment/argocd-server
  kubectl --context "$MGMT_CONTEXT" -n argocd \
    rollout status deployment/argocd-server --timeout=300s
fi

#
# Attente pods ArgoCD
#
echo "[INFO] attente ArgoCD"

kubectl --context "$MGMT_CONTEXT" wait \
  --for=condition=available \
  deployment/argocd-server \
  -n argocd \
  --timeout=300s

kubectl --context "$MGMT_CONTEXT" wait \
  --for=condition=available \
  deployment/argocd-repo-server \
  -n argocd \
  --timeout=300s

if ! insecure_value="$(kubectl --context "$MGMT_CONTEXT" -n argocd \
  exec deployment/argocd-server -- printenv ARGOCD_SERVER_INSECURE)"; then
  echo "[STOP] Impossible de lire ARGOCD_SERVER_INSECURE dans argocd-server" >&2
  exit 1
fi

[[ "$insecure_value" == "true" ]] || {
  echo "[STOP] argocd-server n'a pas chargé ARGOCD_SERVER_INSECURE=true" >&2
  exit 1
}

if [[ "$ARGOCD_FRESH_INSTALL" == "true" ]]; then
    (
        set -euo pipefail
        set +x
        umask 077

        patch_file="$(mktemp)"
        trap 'rm -f "$patch_file"' EXIT

        jq -n --rawfile hash "$ARGOCD_ADMIN_HASH_FILE" \
            --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{stringData: {
                "admin.password": ($hash | rtrimstr("\n")),
                "admin.passwordMtime": $timestamp
            }}' > "$patch_file"

        kubectl --context "$MGMT_CONTEXT" -n argocd \
            patch secret argocd-secret --type=merge \
            --patch-file "$patch_file" \
            --dry-run=server -o name

        kubectl --context "$MGMT_CONTEXT" -n argocd \
            patch secret argocd-secret --type=merge \
            --patch-file "$patch_file" -o name

        echo "[OK] Mot de passe admin configure depuis le hash hors Git"
    )
else
    echo "[INFO] Instance existante : mot de passe admin inchange"
fi

echo "[OK] ArgoCD disponible avec ARGOCD_SERVER_INSECURE=true"
echo "[OK] Argo CD disponible ; Root App non appliquée par ce script"
