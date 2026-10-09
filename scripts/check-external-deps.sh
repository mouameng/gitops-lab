#!/usr/bin/env bash
# check-external-deps.sh — inventaire et contrôle (lecture seule) des éléments
# nécessaires au PRA qui ne sont PAS dans la source de vérité (Gitea / Git).
#
# L'inventaire est le manifeste versionné scripts/external-deps.tsv
# (6 colonnes séparées par des tabulations : id, niveau, contrôle, cible, attendu, note).
#
# Usage :
#   check-external-deps.sh --list             inventaire complet, sans rien évaluer
#   check-external-deps.sh --check            évalue les contrôles (aucun secret affiché)
#   check-external-deps.sh --check --offline  idem, sans test réseau
#
# Codes retour : 0 OK | 2 avertissement | 3 critique | 1 erreur d'usage ou manifeste invalide
#
# Niveaux :
#   BLOCK  l'absence rend le PRA irrécupérable (CRIT si un contrôle évalué échoue)
#   WARN   l'absence dégrade le PRA ou l'usage (WARN si un contrôle évalué échoue)
#   INFO   informatif : affiché, sans effet sur le code retour
# Pour les contrôles « covered » et « manual », le niveau n'indique que la criticité.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${EXTERNAL_DEPS_MANIFEST:-${ROOT_DIR}/scripts/external-deps.tsv}"
HOSTS_FILE="${HOSTS_FILE:-/mnt/c/Windows/System32/drivers/etc/hosts}"
SYSTEM_CA_BUNDLE="${SYSTEM_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
URL_TIMEOUT="${URL_TIMEOUT:-5}"

VALID_LEVELS=" BLOCK WARN INFO "
VALID_CHECKS=" covered manual path file-newer hosts ca-trust disk-free cmd argocd-repos registry-digests "

E_ID=(); E_LEVEL=(); E_CHECK=(); E_TARGET=(); E_EXPECTED=(); E_NOTE=()
OK_N=0; WARN_N=0; CRIT_N=0; COUV_N=0; MAN_N=0
MSG=""
HOSTS_STATE=""; HOSTS_CONTENT=""; HOSTS_WARNED=0
OFFLINE=0

die() { echo "[STOP] $*" >&2; exit 1; }

usage() {
  sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

expand_path() {
  local p="$1"
  p="${p/#\~/$HOME}"
  p="${p/#\$\{HOME\}/$HOME}"
  p="${p/#\$HOME/$HOME}"
  printf '%s' "$p"
}

# ---------------------------------------------------------------- manifeste

load_manifest() {
  [[ -f "$MANIFEST" && -r "$MANIFEST" ]] || die "Manifeste introuvable ou illisible : $MANIFEST"
  local line n=0 bad=0 sep nf
  local id level check target expected note seen=" "
  sep=$'\037'
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
    nf="$(awk -F'\t' '{print NF}' <<<"$line")"
    if [[ "$nf" -ne 6 ]]; then
      echo "[STOP] manifeste ligne $n : $nf champ(s) au lieu de 6" >&2
      bad=1
      continue
    fi
    IFS="$sep" read -r id level check target expected note <<<"$(tr '\t' "$sep" <<<"$line")"
    [[ "$target" == "-" ]] && target=""
    [[ "$expected" == "-" ]] && expected=""
    [[ "$note" == "-" ]] && note=""
    if [[ ! "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "[STOP] manifeste ligne $n : identifiant invalide « $id »" >&2; bad=1
    fi
    if [[ "$seen" == *" $id "* ]]; then
      echo "[STOP] manifeste ligne $n : identifiant en double « $id »" >&2; bad=1
    fi
    seen+="$id "
    if [[ "$VALID_LEVELS" != *" $level "* ]]; then
      echo "[STOP] manifeste ligne $n ($id) : niveau inconnu « $level »" >&2; bad=1
    fi
    if [[ "$VALID_CHECKS" != *" $check "* ]]; then
      echo "[STOP] manifeste ligne $n ($id) : contrôle inconnu « $check »" >&2; bad=1
    fi
    E_ID+=("$id"); E_LEVEL+=("$level"); E_CHECK+=("$check")
    E_TARGET+=("$target"); E_EXPECTED+=("$expected"); E_NOTE+=("$note")
  done <"$MANIFEST"
  (( bad == 0 )) || exit 1
  (( ${#E_ID[@]} > 0 )) || die "Manifeste vide : $MANIFEST"
}

# ------------------------------------------------------------------ contrôles
# Chaque contrôle renseigne MSG et retourne : 0 = OK, 1 = échec,
# 2 = non évaluable (affiché en INFO), 3 = ignoré en silence.

check_path() {
  local p mode="$2" actual
  p="$(expand_path "$1")"
  if [[ -d "$p" ]]; then
    :
  elif [[ -f "$p" ]]; then
    [[ -r "$p" ]] || { MSG="illisible : $1"; return 1; }
    [[ -s "$p" ]] || { MSG="vide : $1"; return 1; }
  else
    MSG="absent : $1"; return 1
  fi
  if [[ -n "$mode" ]]; then
    actual="$(stat -c '%a' "$p")"
    actual="${actual: -3}"   # ignore setuid/setgid/sticky : seuls les droits rwx comptent ici
    [[ "$actual" == "$mode" ]] || { MSG="mode $actual au lieu de $mode : $1"; return 1; }
  fi
  MSG="présent${mode:+ (mode $mode)} : $1"
}

check_file_newer() {
  local t r
  t="$(expand_path "$1")"; r="$(expand_path "$2")"
  [[ -f "$t" ]] || { MSG="absent : $1"; return 1; }
  [[ -f "$r" ]] || { MSG="référence absente, comparaison impossible : $2"; return 2; }
  if [[ "$r" -nt "$t" ]]; then
    MSG="plus ancien que $(basename "$r") : $1 (à régénérer)"; return 1
  fi
  MSG="au moins aussi récent que $(basename "$r") : $1"
}

load_hosts() {
  [[ -n "$HOSTS_STATE" ]] && return 0
  if [[ -r "$HOSTS_FILE" ]]; then
    HOSTS_CONTENT="$(tr -d '\r' <"$HOSTS_FILE")"
    HOSTS_STATE="ok"
  else
    HOSTS_STATE="unreadable"
  fi
}

check_hosts() {
  local name="$1" ip="$2" ips
  load_hosts
  if [[ "$HOSTS_STATE" != "ok" ]]; then
    if (( HOSTS_WARNED == 0 )); then
      HOSTS_WARNED=1
      MSG="hosts Windows illisible ($HOSTS_FILE) : entrées non vérifiées"
      return 2
    fi
    return 3
  fi
  ips="$(awk -v h="$name" '{ sub(/#.*/, ""); for (i = 2; i <= NF; i++) if (tolower($i) == tolower(h)) print $1 }' <<<"$HOSTS_CONTENT")"
  if grep -qxF -- "$ip" <<<"$ips"; then
    MSG="hosts Windows : $name -> $ip"
  elif [[ -n "$ips" ]]; then
    MSG="hosts Windows : $name pointe vers $(tr '\n' ' ' <<<"$ips")au lieu de $ip"; return 1
  else
    MSG="hosts Windows : $name absent (attendu : $ip)"; return 1
  fi
}

check_ca_trust() {
  local c
  c="$(expand_path "$1")"
  [[ -f "$c" ]] || { MSG="certificat de la CA absent : $1"; return 1; }
  command -v openssl >/dev/null 2>&1 || { MSG="openssl absent : magasin de confiance non vérifié"; return 2; }
  [[ -r "$SYSTEM_CA_BUNDLE" ]] || { MSG="bundle système illisible ($SYSTEM_CA_BUNDLE)"; return 2; }
  if openssl verify -CAfile "$SYSTEM_CA_BUNDLE" "$c" 2>&1 | grep -q ': OK$'; then
    MSG="CA du lab reconnue par le magasin de confiance WSL"
  else
    MSG="CA du lab absente du magasin de confiance WSL"; return 1
  fi
}

check_disk_free() {
  local d free min="$2"
  d="$(expand_path "$1")"
  [[ -d "$d" ]] || { MSG="dossier absent : $1"; return 1; }
  [[ "$min" =~ ^[0-9]+$ ]] || { MSG="seuil invalide « $min » (Mo attendus)"; return 2; }
  free="$(df -Pm "$d" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ "$free" =~ ^[0-9]+$ ]] || { MSG="espace libre illisible : $1"; return 2; }
  if (( free < min )); then
    MSG="espace libre ${free} Mo < ${min} Mo : $1"; return 1
  fi
  MSG="espace libre ${free} Mo (minimum ${min} Mo) : $1"
}

check_cmd() {
  local c missing=()
  local -a arr
  IFS=',' read -ra arr <<<"$1"
  for c in "${arr[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    MSG="outil(s) absent(s) du PATH : ${missing[*]}"; return 1
  fi
  MSG="outils présents : ${arr[*]}"
}

check_url() {
  local url="$1" code
  if (( OFFLINE == 1 )); then MSG="test réseau ignoré (--offline) : $url"; return 3; fi
  command -v curl >/dev/null 2>&1 || { MSG="curl absent : $url non testé"; return 2; }
  code="$(curl -sS -o /dev/null --max-time "$URL_TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null)"
  if [[ -n "$code" && "$code" != "000" ]]; then
    MSG="joignable (HTTP $code) : $url"
  else
    MSG="injoignable : $url"; return 1
  fi
}

check_registry_digests() {
  local rel="$1" token_file="$2"
  local root="${ROOT_DIR}/${rel}"
  local registry="${REGISTRY_BASE_URL:-https://gitea.local}"
  local acc='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
  local f image digest repo headers code got
  local checked=0 failed=0
  local -a failures=()

  if (( OFFLINE == 1 )); then
    MSG="digests du registre ignorés (--offline) : ${rel}"
    return 3
  fi

  command -v curl >/dev/null 2>&1 || {
    MSG="curl absent : digests du registre non vérifiés"
    return 2
  }

  token_file="$(expand_path "$token_file")"
  [[ -f "$token_file" && ! -L "$token_file" && -r "$token_file" ]] || {
    MSG="jeton du registre absent, illisible ou lien : $2"
    return 2
  }

  [[ -d "$root" ]] || {
    MSG="dossier des overlays absent : $rel"
    return 2
  }

  while IFS= read -r -d '' f; do
    image="$(
      grep -m1 -E '^[[:space:]]*-[[:space:]]*name:[[:space:]]*gitea\.local/' "$f" |
        sed -E 's#^[[:space:]]*-[[:space:]]*name:[[:space:]]*gitea\.local/##' ||
        true
    )"

    digest="$(
      grep -m1 -E '^[[:space:]]*digest:[[:space:]]*sha256:[0-9a-f]{64}$' "$f" |
        sed -E 's#^[[:space:]]*digest:[[:space:]]*##' ||
        true
    )"

    [[ -n "$image" && -n "$digest" ]] || continue
    checked=$((checked + 1))
    repo="${image#/}"

    headers="$(
      printf 'user = "gitea_admin:%s"\n' "$(cat "$token_file")" |
        curl -sS -K - --max-time "$URL_TIMEOUT" \
          -D - -o /dev/null \
          -H "Accept: $acc" \
          "${registry}/v2/${repo}/manifests/${digest}" 2>/dev/null |
        tr -d '\r'
    )"

    code="$(head -n1 <<<"$headers" | awk '{print $2}')"
    got="$(grep -i '^docker-content-digest:' <<<"$headers" |
      awk '{print $2; exit}')"

    if [[ "$code" != "200" || "$got" != "$digest" ]]; then
      failed=$((failed + 1))
      failures+=("$(realpath --relative-to="$ROOT_DIR" "$f")=${digest:0:19} http=${code:-aucun}")
    fi
  done < <(find "$root" -type f -name kustomization.yaml -print0 | sort -z)

  if (( checked == 0 )); then
    MSG="aucun digest OCI Gitea trouvé dans ${rel}"
    return 2
  fi

  if (( failed > 0 )); then
    MSG="${failed}/${checked} digest(s) absent(s) ou incohérent(s) : ${failures[*]}"
    return 1
  fi

  MSG="${checked} digest(s) OCI référencé(s) servi(s) dans ${rel}"
  return 0
}

# Hôtes https externes déclarés comme repoURL dans le dossier $1 du dépôt.
external_repo_hosts() {
  local d="${ROOT_DIR}/$1"
  [[ -d "$d" ]] || return 1
  grep -rhE '^[[:space:]-]*repoURL:[[:space:]]*"?https?://' "$d" --include='*.yaml' --include='*.yml' 2>/dev/null |
    sed -E 's#.*repoURL:[[:space:]]*"?(https?://[^"[:space:]/]+).*#\1#' |
    grep -v '\.svc\.cluster\.local' | sort -u
}

# ------------------------------------------------------------------ sortie

report() { # statut(ok|fail|info) niveau message
  case "$1" in
    ok)
      OK_N=$((OK_N + 1)); echo "[OK] $3" ;;
    info)
      echo "[INFO] $3" ;;
    fail)
      case "$2" in
        BLOCK) CRIT_N=$((CRIT_N + 1)); echo "[CRIT] $3" ;;
        WARN)  WARN_N=$((WARN_N + 1)); echo "[WARN] $3" ;;
        *)     echo "[INFO] $3" ;;
      esac ;;
  esac
}

dispatch() { # résultat d'un contrôle -> report
  local rc="$1" level="$2"
  case "$rc" in
    0) report ok "$level" "$MSG" ;;
    1) report fail "$level" "$MSG" ;;
    2) report info "$level" "$MSG" ;;
    *) : ;;
  esac
}

do_list() {
  local i
  echo "Inventaire : $MANIFEST (${#E_ID[@]} entrées)"
  echo
  for i in "${!E_ID[@]}"; do
    printf '%-5s %-13s %-22s %s%s\n' "${E_LEVEL[$i]}" "${E_CHECK[$i]}" "${E_ID[$i]}" \
      "${E_TARGET[$i]}" "$([[ -n "${E_EXPECTED[$i]}" && "${E_CHECK[$i]}" != covered ]] && printf ' (attendu : %s)' "${E_EXPECTED[$i]}")"
    [[ -n "${E_NOTE[$i]}" ]] && printf '      - %s\n' "${E_NOTE[$i]}"
  done
}

do_check() {
  local i id level check target expected url urls
  echo "=== Éléments hors source de vérité (lecture seule) ==="
  for i in "${!E_ID[@]}"; do
    id="${E_ID[$i]}"; level="${E_LEVEL[$i]}"; check="${E_CHECK[$i]}"
    target="${E_TARGET[$i]}"; expected="${E_EXPECTED[$i]}"
    case "$check" in
      covered)
        COUV_N=$((COUV_N + 1))
        if [[ -n "$expected" ]] && ! grep -rqF --include='*.sh' -e "$expected" "${ROOT_DIR}/scripts" 2>/dev/null; then
          MSG="garde introuvable dans scripts/ pour « $id » : « $expected » (renommée ? inventaire à revoir)"
          report fail WARN "$MSG"
        fi ;;
      manual)
        MAN_N=$((MAN_N + 1)) ;;
      path)
        check_path "$target" "$expected"; dispatch $? "$level" ;;
      file-newer)
        check_file_newer "$target" "$expected"; dispatch $? "$level" ;;
      hosts)
        check_hosts "$target" "$expected"; dispatch $? "$level" ;;
      ca-trust)
        check_ca_trust "$target"; dispatch $? "$level" ;;
      disk-free)
        check_disk_free "$target" "$expected"; dispatch $? "$level" ;;
      cmd)
        check_cmd "$target"; dispatch $? "$level" ;;
      registry-digests)
        check_registry_digests "$target" "$expected"
        dispatch $? "$level"
        ;;
      argocd-repos)
        if ! urls="$(external_repo_hosts "$target")"; then
          report info "$level" "dossier $target absent du dépôt : dépôts de charts non listés"
        elif [[ -z "$urls" ]]; then
          report info "$level" "aucun repoURL externe trouvé dans $target/"
        else
          while IFS= read -r url; do
            check_url "$url"; dispatch $? "$level"
          done <<<"$urls"
        fi ;;
    esac
  done

  local global="OK" code=0
  if (( CRIT_N > 0 )); then global="CRIT"; code=3
  elif (( WARN_N > 0 )); then global="WARN"; code=2; fi
  echo "[INFO] ${COUV_N} élément(s) couvert(s) par une garde existante, ${MAN_N} contrôle(s) manuel(s) non évalué(s) (voir --list)"
  echo "[RESULT] global=${global} ok=${OK_N} warn=${WARN_N} crit=${CRIT_N}"
  return "$code"
}

# ------------------------------------------------------------------ principal

MODE=""
for arg in "$@"; do
  case "$arg" in
    --list|--check) MODE="$arg" ;;
    --offline) OFFLINE=1 ;;
    -h|--help) usage ;;
    *) echo "Option inconnue : $arg" >&2; usage ;;
  esac
done
[[ -n "$MODE" ]] || usage

load_manifest
case "$MODE" in
  --list)  do_list ;;
  --check) do_check; exit $? ;;
esac
