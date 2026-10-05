#!/usr/bin/env bash
set -euo pipefail
MGMT_CONTEXT="${MGMT_CONTEXT:?Definir MGMT_CONTEXT explicitement}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="$ROOT_DIR/clusters/workloads.tsv"
CANDIDATE_DIR="${CANDIDATE_DIR:-$HOME/.config/gitops-lab/registration-candidates}"

[[ -f "$INVENTORY" && -d "$CANDIDATE_DIR" ]] || {
  echo "[ERROR] Inventaire ou répertoire candidat absent" >&2
  exit 1
}

awk -F '\t' '
  NR == 1 {
    if ($0 != "environment\tkind_cluster\targocd_cluster") bad = 1
    next
  }
  NF != 3 || $1 == "" || $2 == "" || $3 == "" {
    bad = 1
    next
  }
  {
    if (seen_env[$1]++) bad = 1
    if (seen_kind[$2]++) bad = 1
    if (seen_argo[$3]++) bad = 1
    if ($1 !~ /^[a-z0-9-]+$/ || $2 !~ /^[a-z0-9-]+$/ || $3 !~ /^[a-z0-9-]+$/) bad = 1
    count++
  }
  END { exit (bad || count == 0) ? 1 : 0 }
' "$INVENTORY" || {
  echo "[ERROR] Inventaire invalide" >&2
  exit 1
}

missing=0
while IFS=$'\t' read -r environment kind_cluster argocd_cluster; do
  [[ "$environment" == "environment" ]] && continue
  file="$CANDIDATE_DIR/${argocd_cluster}-sealedsecret.yaml"
  if [[ -f "$file" ]]; then
    if EXPECTED_NAME="$argocd_cluster" yq -e '
      .apiVersion == "bitnami.com/v1alpha1" and
      .kind == "SealedSecret" and
      .metadata.name == strenv(EXPECTED_NAME) and
      .metadata.namespace == "argocd" and
      .spec.template.metadata.name == strenv(EXPECTED_NAME) and
      .spec.template.metadata.namespace == "argocd"
    ' "$file" >/dev/null 2>&1; then
      echo "[OK] Identité conforme : $argocd_cluster"
      if kubeseal --validate \
          --context "$MGMT_CONTEXT" \
          --controller-name sealed-secrets-controller \
          --controller-namespace sealed-secrets \
          < "$file" >/dev/null 2>&1; then
        echo "[OK] Déchiffrement validé : $argocd_cluster"
      else
        echo "[ERROR] Déchiffrement non validé : $argocd_cluster" >&2
        missing=1
      fi
    else
      echo "[ERROR] Identité invalide : $argocd_cluster" >&2
      missing=1
    fi
  else
    echo "[ERROR] Candidat absent : $argocd_cluster" >&2
    missing=1
  fi
done < "$INVENTORY"

(( missing == 0 )) || exit 1
echo "[OK] Identité et déchiffrement vérifiés ; accès Argo CD non testé"
