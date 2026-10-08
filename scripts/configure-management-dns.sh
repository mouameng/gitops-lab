#!/usr/bin/env bash
# configure-management-dns.sh — fait répondre le CoreDNS du cluster management pour
# gitea.local avec l'adresse du Service Traefik, et non plus 127.0.0.1.
#
# Pourquoi : gitea.local résout vers 127.0.0.1 (hosts Windows relayé par WSL). C'est juste pour
# le navigateur, faux pour un pod ou un conteneur de job. Voir le cadrage v1.3.2.
#
# Principe : insère UNE ligne « rewrite name exact … answer auto » dans le Corefile EXISTANT
# (jamais de remplacement complet). Sauvegarde, dry-run serveur, patch de la seule clé Corefile,
# redémarrage contrôlé de CoreDNS (c'est ce démarrage qui valide la syntaxe du Corefile), puis
# retour arrière automatique si CoreDNS ne redémarre pas correctement. Idempotent.
#
# Usage :
#   configure-management-dns.sh --render-check    outils + transformation d'un Corefile de référence ;
#                                                 AUCUN accès au cluster
#   configure-management-dns.sh --preflight       lit le cluster, affiche le diff, dry-run serveur ;
#                                                 AUCUNE écriture (mode par défaut)
#   configure-management-dns.sh --apply           sauvegarde, patch, redémarrage, contrôle
#   configure-management-dns.sh --status          0 = entrée en place, 2 = absente ou différente
#   configure-management-dns.sh --rollback [fic]  restaure le Corefile d'une sauvegarde
#                                                 (défaut : la plus récente du contexte)
#
# Variables : MGMT_CONTEXT (kind-gitops-management), DNS_NAME (gitea.local),
#   DNS_TARGET (traefik.traefik.svc.cluster.local), DNS_BACKUP_DIR, DNS_ROLLOUT_TIMEOUT (180s),
#   DNS_WAIT_CM_SECONDS (90).
# Codes retour : 0 OK | 1 erreur ([STOP]) | 2 (--status seulement) absente ou différente.

set -euo pipefail

MGMT_CONTEXT="${MGMT_CONTEXT:-kind-gitops-management}"
DNS_NAME="${DNS_NAME:-gitea.local}"
DNS_TARGET="${DNS_TARGET:-traefik.traefik.svc.cluster.local}"
BACKUP_DIR="${DNS_BACKUP_DIR:-${HOME}/.local/share/gitops-lab/dns-backups}"
ROLLOUT_TIMEOUT="${DNS_ROLLOUT_TIMEOUT:-180s}"
WAIT_CM_SECONDS="${DNS_WAIT_CM_SECONDS:-90}"

die() { echo "[STOP] $*" >&2; exit 1; }

name_re='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'
[[ "$DNS_NAME" =~ $name_re ]] || die "DNS_NAME invalide : $DNS_NAME"
[[ "$DNS_TARGET" =~ $name_re ]] || die "DNS_TARGET invalide : $DNS_TARGET"
[[ "$MGMT_CONTEXT" =~ ^[A-Za-z0-9._@:/-]+$ ]] || die "MGMT_CONTEXT invalide : $MGMT_CONTEXT"

REWRITE_LINE="rewrite name exact ${DNS_NAME} ${DNS_TARGET} answer auto"
KUBECTL=(kubectl --context "$MGMT_CONTEXT" -n kube-system)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------------ Corefile

# Corefile par défaut relevé sur les trois clusters le 8 octobre 2026 (CoreDNS v1.14.6).
reference_corefile() {
  cat <<'EOF'
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30 {
       disable success cluster.local
       disable denial cluster.local
    }
    loop
    reload
    loadbalance
}
EOF
}

norm() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

# Affiche present | absent | foreign:<raison>. N'agit que sur un Corefile reconnu.
classify() {
  local f="$1" total exact kube server fwd
  total="$(grep -cF -- "$DNS_NAME" "$f" || true)"
  exact="$(norm <"$f" | grep -cxF -- "$REWRITE_LINE" || true)"
  if (( exact == 1 && total == 1 )); then echo present; return 0; fi
  if (( total > 0 )); then
    echo "foreign:$DNS_NAME apparaît déjà dans le Corefile sous une autre forme ; intervention manuelle"
    return 0
  fi
  kube="$(grep -cE '^[[:space:]]*kubernetes[[:space:]]+cluster\.local' "$f" || true)"
  server="$(grep -cE '^\.:53[[:space:]]*\{' "$f" || true)"
  fwd="$(grep -cE '^[[:space:]]*forward[[:space:]]+\.[[:space:]]+/etc/resolv\.conf' "$f" || true)"
  if (( kube != 1 || server != 1 || fwd != 1 )); then
    echo "foreign:Corefile inattendu (kubernetes=$kube, serveur .:53=$server, forward=$fwd) ; rien n'a été modifié"
    return 0
  fi
  echo absent
}

# Insère la ligne juste avant « kubernetes cluster.local », avec la même indentation.
render() {
  awk -v line="$REWRITE_LINE" '
    !done && /^[[:space:]]*kubernetes[[:space:]]+cluster\.local/ {
      match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) line; done = 1
    }
    { print }' "$1"
}

# Le rendu doit être une insertion pure d'une seule ligne.
check_render() {
  local old="$1" new="$2" n_old n_new removed
  n_old="$(wc -l <"$old")"; n_new="$(wc -l <"$new")"
  removed="$(diff "$old" "$new" | grep -c '^<' || true)"
  (( n_new == n_old + 1 && removed == 0 ))
}

# ------------------------------------------------------------------ cluster

wait_cm() {
  local i
  for (( i = 0; i < WAIT_CM_SECONDS; i += 3 )); do
    "${KUBECTL[@]}" get cm coredns >/dev/null 2>&1 && return 0
    sleep 3
  done
  die "ConfigMap coredns introuvable (contexte $MGMT_CONTEXT, ${WAIT_CM_SECONDS}s)"
}

read_cm() { # $1 : fichier JSON de sortie ; $2 : fichier Corefile de sortie
  "${KUBECTL[@]}" get cm coredns -o json >"$1" || die "ConfigMap coredns illisible (contexte $MGMT_CONTEXT)"
  jq -e '.data.Corefile | type == "string"' "$1" >/dev/null || die "Clé data.Corefile absente de la ConfigMap"
  jq -j '.data.Corefile' "$1" >"$2"
}

patch_corefile() { # $1 : fichier Corefile ; reste : options kubectl (ex. --dry-run=server)
  local f="$1"; shift
  jq -Rs '{data: {Corefile: .}}' <"$f" >"$WORK/patch.json" || return 1
  "${KUBECTL[@]}" patch cm coredns --type merge --patch-file "$WORK/patch.json" "$@" >/dev/null
}

restart_and_wait() {
  "${KUBECTL[@]}" rollout restart deployment/coredns >/dev/null || return 1
  "${KUBECTL[@]}" rollout status deployment/coredns --timeout="$ROLLOUT_TIMEOUT" || return 1
}

restore_from() { # $1 : sauvegarde JSON
  jq -e '.data.Corefile | type == "string"' "$1" >/dev/null || return 1
  jq -j '.data.Corefile' "$1" >"$WORK/restore.corefile" || return 1
  patch_corefile "$WORK/restore.corefile" || return 1
  restart_and_wait
}

# ------------------------------------------------------------------ modes

do_render_check() {
  local t="$WORK/rc" c
  mkdir -p "$t"
  for c in kubectl jq awk grep sed diff; do
    command -v "$c" >/dev/null 2>&1 || die "outil absent du PATH : $c"
  done
  echo "[OK] Outils présents : kubectl jq awk grep sed diff"

  reference_corefile >"$t/ref"
  [[ "$(classify "$t/ref")" == absent ]] || die "le Corefile de référence n'est pas reconnu comme « absent »"
  render "$t/ref" >"$t/new"
  check_render "$t/ref" "$t/new" || die "le rendu n'est pas une insertion pure d'une ligne"
  [[ "$(classify "$t/new")" == present ]] || die "le rendu n'est pas reconnu comme « present » (non idempotent)"
  render "$t/new" >"$t/new2"
  # Un second rendu, s'il était appliqué, ajouterait une 2e ligne : classify doit alors refuser.
  [[ "$(classify "$t/new2")" == foreign:* ]] || die "un doublon de la ligne n'est pas refusé"
  echo "[OK] Rendu : 1 ligne insérée, aucune ligne modifiée ni supprimée ; idempotent"

  { cat "$t/ref"; echo "# $DNS_NAME 10.0.0.1"; } >"$t/f1"
  grep -v '^    kubernetes ' "$t/ref" >"$t/f2"
  cat "$t/ref" "$t/ref" >"$t/f3"
  sed "s/${DNS_TARGET//./\\.}/autre.ns.svc.cluster.local/" "$t/new" >"$t/f4"
  for c in f1 f2 f3 f4; do
    [[ "$(classify "$t/$c")" == foreign:* ]] || die "Corefile inattendu non refusé (cas $c)"
  done
  echo "[OK] Refus conformes : nom déjà présent autrement, sans plugin kubernetes, deux serveurs, autre cible"

  echo "--- Rendu sur le Corefile de référence ---"
  diff -u "$t/ref" "$t/new" | tail -n +3 || true
  echo "[OK] Contrôle de rendu terminé ; aucun accès au cluster"
}

show_state() { # $1 : fichier Corefile ; affiche l'état, retourne 0 present / 2 absent / 1 foreign
  local state
  state="$(classify "$1")"
  case "$state" in
    present) echo "[OK] Entrée DNS en place : $REWRITE_LINE"; return 0 ;;
    absent)  echo "[INFO] Entrée DNS absente du Corefile"; return 2 ;;
    *)       echo "[WARN] ${state#foreign:}"; return 1 ;;
  esac
}

do_status() {
  local rc=0
  read_cm "$WORK/live.json" "$WORK/live.corefile"
  show_state "$WORK/live.corefile" || rc=$?
  "${KUBECTL[@]}" get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | sed 's/^/[INFO] pod : /' || true
  (( rc == 0 )) && return 0
  return 2
}

prepare_change() { # lit le cluster ; retourne 0 si un changement est nécessaire, 10 si déjà en place
  local state
  read_cm "$WORK/live.json" "$WORK/live.corefile"
  state="$(classify "$WORK/live.corefile")"
  case "$state" in
    present)   return 10 ;;
    foreign:*) die "${state#foreign:}" ;;
  esac
  render "$WORK/live.corefile" >"$WORK/new.corefile"
  check_render "$WORK/live.corefile" "$WORK/new.corefile" || die "rendu incohérent ; rien n'a été modifié"
  return 0
}

do_preflight() {
  local rc=0
  prepare_change || rc=$?
  if (( rc == 10 )); then
    echo "[OK] Entrée DNS déjà en place ; --apply ne ferait rien"
    return 0
  fi
  echo "--- Diff du Corefile (contexte $MGMT_CONTEXT) ---"
  diff -u "$WORK/live.corefile" "$WORK/new.corefile" | tail -n +3 || true
  patch_corefile "$WORK/new.corefile" --dry-run=server || die "dry-run serveur refusé ; rien n'a été modifié"
  echo "[OK] Dry-run serveur accepté ; rien n'a été modifié"
}

do_apply() {
  local rc=0 backup
  wait_cm
  prepare_change || rc=$?
  if (( rc == 10 )); then
    echo "[OK] Entrée DNS déjà en place ; aucune écriture"
    return 0
  fi
  patch_corefile "$WORK/new.corefile" --dry-run=server || die "dry-run serveur refusé ; rien n'a été modifié"
  echo "[OK] Dry-run serveur accepté"

  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  backup="${BACKUP_DIR}/coredns-${MGMT_CONTEXT}-$(date +%Y%m%d-%H%M%S).json"
  cp "$WORK/live.json" "$backup"; chmod 600 "$backup"
  echo "[OK] Sauvegarde : $backup"

  patch_corefile "$WORK/new.corefile" || die "patch refusé ; la sauvegarde est dans $backup"
  echo "[OK] Corefile modifié ; redémarrage de CoreDNS (c'est lui qui valide la syntaxe)"
  if ! restart_and_wait; then
    echo "[ROLLBACK] CoreDNS n'a pas redémarré correctement ; restauration du Corefile précédent" >&2
    if restore_from "$backup"; then
      echo "[ROLLBACK] Corefile restauré depuis $backup ; l'état précédent est rétabli" >&2
    else
      echo "[STOP] Retour arrière automatique échoué : $0 --rollback \"$backup\"" >&2
    fi
    exit 1
  fi

  read_cm "$WORK/live2.json" "$WORK/live2.corefile"
  [[ "$(classify "$WORK/live2.corefile")" == present ]] || die "l'entrée n'est pas lue après modification ; voir $backup"
  echo "[OK] CoreDNS redémarré avec l'entrée DNS : $DNS_NAME -> $DNS_TARGET"
  echo "[INFO] La résolution se contrôle depuis un pod (le Service cible doit exister)"
}

do_rollback() {
  local file="${1:-}" rc=0
  if [[ -z "$file" ]]; then
    file="$(ls -1t "${BACKUP_DIR}/coredns-${MGMT_CONTEXT}-"*.json 2>/dev/null | head -n 1 || true)"
    [[ -n "$file" ]] || die "aucune sauvegarde trouvée dans $BACKUP_DIR pour $MGMT_CONTEXT"
  fi
  [[ -f "$file" ]] || die "sauvegarde introuvable : $file"
  jq -e '.data.Corefile | type == "string"' "$file" >/dev/null || die "sauvegarde invalide (pas de data.Corefile) : $file"
  read_cm "$WORK/live.json" "$WORK/live.corefile"
  jq -j '.data.Corefile' "$file" >"$WORK/backup.corefile"
  if cmp -s "$WORK/live.corefile" "$WORK/backup.corefile"; then
    echo "[OK] Le Corefile actuel est déjà identique à la sauvegarde ; aucune écriture"
    return 0
  fi
  echo "--- Diff actuel -> sauvegarde ---"
  diff -u "$WORK/live.corefile" "$WORK/backup.corefile" | tail -n +3 || true
  restore_from "$file" || rc=$?
  (( rc == 0 )) || die "restauration échouée depuis $file"
  echo "[OK] Corefile restauré depuis $file"
}

# ------------------------------------------------------------------ principal

MODE="${1:---preflight}"
case "$MODE" in
  --render-check) [[ $# -le 1 ]] || die "usage : $0 --render-check"; do_render_check ;;
  --preflight)    [[ $# -le 1 ]] || die "usage : $0 --preflight"; do_preflight ;;
  --apply)        [[ $# -le 1 ]] || die "usage : $0 --apply"; do_apply ;;
  --status)       [[ $# -le 1 ]] || die "usage : $0 --status"; do_status || exit $? ;;
  --rollback)     [[ $# -le 2 ]] || die "usage : $0 --rollback [sauvegarde.json]"; do_rollback "${2:-}" ;;
  -h|--help)      sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *)              die "option inconnue : $MODE (voir --help)" ;;
esac
