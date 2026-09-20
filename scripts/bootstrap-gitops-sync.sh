#!/usr/bin/env bash

set -euo pipefail

echo "==================================="
echo " GitOps Sync"
echo "==================================="

# Vérification dépôt Git
git rev-parse --is-inside-work-tree >/dev/null

# Rien à faire ?
if git diff --quiet && git diff --cached --quiet; then
    echo "[INFO] Aucun changement à publier"
    exit 0
fi

echo "[INFO] Ajout des fichiers"
git add .

echo "[INFO] Commit"

if git commit -m "GitOps bootstrap $(date '+%Y-%m-%d %H:%M:%S')"; then
    echo "[OK] Commit créé"
else
    echo "[INFO] Aucun changement à commiter"
    exit 0
fi

echo "[INFO] Push"

git push

echo "[OK] Synchronisation Git terminée"
