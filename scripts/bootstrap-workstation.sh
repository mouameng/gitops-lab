#!/usr/bin/env bash

set -euo pipefail

echo "=================================================="
echo "GitOps Lab - Workstation Bootstrap"
echo "=================================================="

install_if_missing() {
    local cmd="$1"
    local package="$2"

    if command -v "$cmd" >/dev/null 2>&1; then
        echo "[OK] $cmd déjà installé"
    else
        echo "[INFO] Installation de $package"
        sudo apt-get install -y "$package"
    fi
}

echo
echo "[INFO] Mise à jour des dépôts"

sudo apt-get update

echo
echo "[INFO] Installation outils de base"

install_if_missing git git
install_if_missing jq jq
install_if_missing curl curl
install_if_missing tar tar

echo
echo "[INFO] Vérification kubectl"

if ! command -v kubectl >/dev/null 2>&1; then
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
fi

echo
echo "[INFO] Vérification Helm"

if ! command -v helm >/dev/null 2>&1; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo
echo "[INFO] Vérification Kind"

if ! command -v kind >/dev/null 2>&1; then
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
    chmod +x kind
    sudo mv kind /usr/local/bin/
fi

echo
echo "[INFO] Vérification yq"

if ! command -v yq >/dev/null 2>&1; then
    sudo wget -qO /usr/local/bin/yq \
      https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64

    sudo chmod +x /usr/local/bin/yq
fi

echo
echo "[INFO] Vérification ArgoCD CLI"

if ! command -v argocd >/dev/null 2>&1; then
    sudo curl -sSL \
      -o /usr/local/bin/argocd \
      https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64

    sudo chmod +x /usr/local/bin/argocd
fi

echo
echo "[INFO] Vérification kubeseal"

if ! command -v kubeseal >/dev/null 2>&1; then

    VERSION="0.32.0"

    wget \
      https://github.com/bitnami-labs/sealed-secrets/releases/download/v${VERSION}/kubeseal-${VERSION}-linux-amd64.tar.gz

    tar -xzf kubeseal-${VERSION}-linux-amd64.tar.gz kubeseal

    sudo install -m 755 kubeseal /usr/local/bin/kubeseal

    rm -f kubeseal-${VERSION}-linux-amd64.tar.gz
fi

echo
echo "=================================================="
echo "Versions installées"
echo "=================================================="

kubectl version --client
helm version
kind version
kubeseal --version
argocd version --client

echo
echo "[OK] Workstation prête"
