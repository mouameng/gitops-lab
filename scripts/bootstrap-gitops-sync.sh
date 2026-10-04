#!/usr/bin/env bash

set -euo pipefail

echo "==================================="
echo " GitOps Sync"
echo "==================================="

# Vérification dépôt Git
git rev-parse --is-inside-work-tree >/dev/null

# Le bootstrap ne publie jamais implicitement dans Git.
# Les fichiers non suivis sont inclus dans le contrôle.
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    echo "[ERROR] Dépôt modifié : publication Git manuelle requise"
    git status --short
    exit 1
fi

echo "[OK] Dépôt propre ; aucune publication Git nécessaire"
