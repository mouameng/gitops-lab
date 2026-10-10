#!/usr/bin/env bash
# Donne aux nœuds workload (dev, prod) l'accès au registre Gitea :
#   - résolution de gitea.local vers le Traefik du management ;
#   - confiance dans la CA du lab pour containerd (hosts.toml).
# Rejouable : peut être relancé seul (ex. après redémarrage d'un nœud).
# Prérequis : config_path actif dans containerd (containerdConfigPatches du kind-config).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/lab-paths.sh" || { echo "[ERREUR] lab-paths.sh illisible" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="${ROOT_DIR}/clusters/workloads.tsv"
CA_CRT="${LAB_CONFIG_DIR}/gitops-lab-root-ca.crt"
MGMT_NODE="gitops-management-control-plane"
REGISTRY_HOST="gitea.local"
CERTS_DIR="/etc/containerd/certs.d/${REGISTRY_HOST}"

die() { echo "[STOP] $*" >&2; exit 1; }

[[ -f "$INVENTORY" ]] || die "inventaire absent : $INVENTORY"
[[ -f "$CA_CRT" && ! -L "$CA_CRT" && -r "$CA_CRT" ]] \
    || die "certificat CA absent, illisible ou lien symbolique : $CA_CRT"
openssl x509 -in "$CA_CRT" -noout -checkend 0 >/dev/null \
    || die "certificat CA invalide ou expiré"

mgmt_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$MGMT_NODE" 2>/dev/null || true)"
[[ "$mgmt_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "IP du nœud management introuvable (${MGMT_NODE})"

nodes=()
while IFS=$'\t' read -r -u 3 environment kind_cluster _argocd_cluster; do
    [[ "$environment" == "environment" ]] && continue
    [[ -n "$kind_cluster" ]] || continue
    nodes+=("${kind_cluster}-control-plane")
done 3< "$INVENTORY"
((${#nodes[@]} > 0)) || die "aucun cluster workload dans l'inventaire"

# Phase 1 : contrôles sur tous les nœuds, sans aucune modification.
for node in "${nodes[@]}"; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$node" 2>/dev/null || true)" == "true" ]] \
        || die "nœud absent ou arrêté : $node"
    dump="$(docker exec "$node" containerd config dump 2>/dev/null || true)"
    grep -Eq "^[[:space:]]*config_path = '/etc/containerd/certs\.d'$" <<<"$dump" \
        || die "config_path absent de containerd sur $node (kind-config non patché à la création du cluster)"
done
echo "[OK] Contrôles préalables : ${#nodes[@]} nœud(s), management ${mgmt_ip}"

# Phase 2 : application, idempotente.
for node in "${nodes[@]}"; do
    echo "== ${node}"
    # /etc/hosts est monté par Docker : pas de sed -i, réécriture en place.
    docker exec "$node" sh -c '
        { grep -vE "[[:space:]]$2([[:space:]]|\$)" /etc/hosts || true; } > /tmp/hosts.new
        printf "%s %s\n" "$1" "$2" >> /tmp/hosts.new
        cat /tmp/hosts.new > /etc/hosts
        rm -f /tmp/hosts.new
    ' _ "$mgmt_ip" "$REGISTRY_HOST"

    docker exec "$node" mkdir -p "$CERTS_DIR"
    docker cp "$CA_CRT" "${node}:${CERTS_DIR}/ca.crt"
    docker exec "$node" chown root:root "${CERTS_DIR}/ca.crt"
    docker exec "$node" chmod 644 "${CERTS_DIR}/ca.crt"
    docker exec -i "$node" sh -c "cat > ${CERTS_DIR}/hosts.toml" <<EOF
server = "https://${REGISTRY_HOST}"

[host."https://${REGISTRY_HOST}"]
  capabilities = ["pull", "resolve"]
  ca = "${CERTS_DIR}/ca.crt"
EOF

    resolved="$(docker exec "$node" getent hosts "$REGISTRY_HOST" | awk '{print $1; exit}' || true)"
    [[ "$resolved" == "$mgmt_ip" ]] \
        || die "résolution inattendue sur $node : ${resolved:-vide} (attendu ${mgmt_ip})"
    docker exec "$node" cat "${CERTS_DIR}/ca.crt" | cmp -s - "$CA_CRT" \
        || die "CA différente sur $node"
    docker exec "$node" test -s "${CERTS_DIR}/hosts.toml" \
        || die "hosts.toml absent sur $node"
    echo "[OK] ${node} : ${REGISTRY_HOST} -> ${resolved}, CA et hosts.toml en place"
done
