#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/lab-paths.sh" || { echo "[ERREUR] lab-paths.sh illisible" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_MANIFEST="$SCRIPT_DIR/git-backup-repositories.tsv"
MANIFEST="${GIT_BACKUP_MANIFEST:-$DEFAULT_MANIFEST}"
GITEA_GIT_BASE_URL="${GITEA_GIT_BASE_URL:-https://gitea.local}"

usage() {
  cat <<'USAGE'
Usage:
  backup-git-repositories.sh --validate
  backup-git-repositories.sh --preflight
  backup-git-repositories.sh --sync
  backup-git-repositories.sh --help

Modes:
  --validate    Valide localement le manifeste TSV, sans accès réseau.
  --preflight   Compare l'inventaire aux dépôts présents dans Gitea.
  --sync        Synchronise les branches et tags de Gitea vers GitHub.
  --help        Affiche cette aide.

Variable:
  GIT_BACKUP_MANIFEST   Utiliser un autre manifeste, notamment pour les tests.
USAGE
}

validate_manifest() {
  local manifest="$1"

  if [[ ! -f "$manifest" ]]; then
    printf '[STOP] Manifeste absent : %s\n' "$manifest" >&2
    return 1
  fi

  if [[ -L "$manifest" ]]; then
    printf '[STOP] Le manifeste ne doit pas être un lien symbolique : %s\n' \
      "$manifest" >&2
    return 1
  fi

  if grep -q $'\r' "$manifest"; then
    printf '[STOP] Fins de ligne CRLF détectées : %s\n' "$manifest" >&2
    return 1
  fi

  awk -F '\t' '
  BEGIN {
    errors = 0
    entries = 0
  }

  $0 ~ /^#/ || $0 ~ /^[[:space:]]*$/ {
    next
  }

  {
    entries++

    if (NF != 7) {
      printf "[ERREUR] ligne %d : 7 colonnes attendues, %d reçues\n", NR, NF
      errors++
      next
    }

    id = $1
    status = $2
    gitea_owner = $3
    gitea_repo = $4
    github_owner = $5
    github_repo = $6
    refs = $7

    if (id !~ /^[a-z0-9][a-z0-9._-]*$/) {
      printf "[ERREUR] ligne %d : id invalide : %s\n", NR, id
      errors++
    }

    if (status != "REQUIRED" && status != "OPTIONAL") {
      printf "[ERREUR] ligne %d : statut invalide : %s\n", NR, status
      errors++
    }

    if (gitea_owner !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) {
      printf "[ERREUR] ligne %d : propriétaire Gitea invalide : %s\n",
             NR, gitea_owner
      errors++
    }

    if (gitea_repo !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) {
      printf "[ERREUR] ligne %d : dépôt Gitea invalide : %s\n",
             NR, gitea_repo
      errors++
    }

    if (github_owner !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) {
      printf "[ERREUR] ligne %d : propriétaire GitHub invalide : %s\n",
             NR, github_owner
      errors++
    }

    if (github_repo !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) {
      printf "[ERREUR] ligne %d : dépôt GitHub invalide : %s\n",
             NR, github_repo
      errors++
    }

    if (refs != "heads-tags") {
      printf "[ERREUR] ligne %d : politique refs inconnue : %s\n",
             NR, refs
      errors++
    }

    source = gitea_owner "/" gitea_repo
    destination = github_owner "/" github_repo

    if (seen_id[id]++) {
      printf "[ERREUR] ligne %d : id dupliqué : %s\n", NR, id
      errors++
    }

    if (seen_source[source]++) {
      printf "[ERREUR] ligne %d : source dupliquée : %s\n", NR, source
      errors++
    }

    if (seen_destination[destination]++) {
      printf "[ERREUR] ligne %d : destination dupliquée : %s\n",
             NR, destination
      errors++
    }

    printf "[OK] %s : %s -> %s (%s, %s)\n",
           id, source, destination, status, refs
  }

  END {
    if (entries == 0) {
      print "[ERREUR] aucune entrée dans le manifeste"
      exit 1
    }

    if (errors > 0) {
      printf "[RESULT] manifeste invalide : %d erreur(s)\n", errors
      exit 1
    }

    printf "[RESULT] manifeste valide : %d entrée(s)\n", entries
  }
  ' "$manifest"
}


preflight_gitea() {
  local manifest="$1"
  local token_file="${GITEA_DISCOVERY_TOKEN_FILE:-${LAB_CONFIG_DIR}/gitea-repository-discovery.token}"
  local api="${GITEA_API_URL:-https://gitea.local/api/v1}"
  local org page response count repo source status
  local errors=0
  local warnings=0

  validate_manifest "$manifest" || return 1

  for command_name in curl jq; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      printf '[STOP] Commande absente : %s\n' "$command_name" >&2
      return 1
    fi
  done

  if [[ ! -f "$token_file" ]]; then
    printf '[STOP] Jeton Gitea absent : %s\n' "$token_file" >&2
    return 1
  fi

  if [[ -L "$token_file" ]]; then
    printf '[STOP] Le jeton Gitea ne doit pas être un lien symbolique : %s\n' \
      "$token_file" >&2
    return 1
  fi

  if [[ "$(stat -c '%a' "$token_file")" != "600" ]]; then
    printf '[STOP] Mode attendu 600 pour le jeton Gitea : %s\n' \
      "$token_file" >&2
    return 1
  fi

  if [[ ! -s "$token_file" ]]; then
    printf '[STOP] Jeton Gitea vide : %s\n' "$token_file" >&2
    return 1
  fi

  declare -A expected=()
  declare -A expected_status=()
  declare -A github_destination=()
  declare -A organizations=()
  declare -A discovered=()

  while IFS=$'\t' read -r id status gitea_owner gitea_repo \
                               github_owner github_repo refs; do
    [[ "$id" == \#* || -z "$id" ]] && continue

    source="$gitea_owner/$gitea_repo"
    expected["$source"]=1
    expected_status["$source"]="$status"
    github_destination["$source"]="$github_owner/$github_repo"
    organizations["$gitea_owner"]=1
  done < "$manifest"

  echo "[INFO] Découverte des dépôts Gitea"

  while IFS= read -r org; do
    page=1
    printf '[INFO] Organisation couverte : %s\n' "$org"

    while :; do
      if ! response="$(
        printf 'header = "Authorization: token %s"\n' "$(cat "$token_file")" |
          curl -fsS -K - \
            "$api/orgs/$org/repos?limit=50&page=$page"
      )"; then
        printf '[STOP] Impossible d’interroger l’organisation Gitea : %s\n' \
          "$org" >&2
        return 1
      fi

      if ! count="$(jq -er 'if type == "array" then length else error("not array") end' \
                         <<<"$response")"; then
        printf '[STOP] Réponse Gitea invalide pour l’organisation : %s\n' \
          "$org" >&2
        return 1
      fi

      while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        source="$org/$repo"
        discovered["$source"]=1
        printf '[OK] Dépôt découvert : %s\n' "$source"
      done < <(jq -r '.[].name' <<<"$response")

      (( count < 50 )) && break
      ((page += 1))
    done
  done < <(printf '%s\n' "${!organizations[@]}" | sort)

  while IFS= read -r source; do
    if [[ -z "${expected[$source]+x}" ]]; then
      printf '[STOP] Dépôt Gitea non inventorié : %s\n' "$source" >&2
      ((errors += 1))
    fi
  done < <(printf '%s\n' "${!discovered[@]}" | sort)

  while IFS= read -r source; do
    if [[ -z "${discovered[$source]+x}" ]]; then
      if [[ "${expected_status[$source]}" == "REQUIRED" ]]; then
        printf '[STOP] Dépôt REQUIRED absent de Gitea : %s\n' \
          "$source" >&2
        ((errors += 1))
      else
        printf '[WARN] Dépôt OPTIONAL absent de Gitea : %s\n' \
          "$source" >&2
        ((warnings += 1))
      fi
    else
      printf '[OK] Dépôt inventorié présent : %s\n' "$source"
    fi
  done < <(printf '%s\n' "${!expected[@]}" | sort)

  echo "[INFO] Contrôle des destinations GitHub"

  while IFS= read -r source; do
    destination="${github_destination[$source]}"
    github_url="git@github.com:${destination}.git"

    if GIT_TERMINAL_PROMPT=0 \
         git ls-remote "$github_url" HEAD >/dev/null 2>&1; then
      printf '[OK] Destination GitHub accessible : %s -> %s\n' \
        "$source" "$destination"
    else
      if [[ "${expected_status[$source]}" == "REQUIRED" ]]; then
        printf '[STOP] Destination GitHub absente ou inaccessible : %s\n' \
          "$destination" >&2
        ((errors += 1))
      else
        printf '[WARN] Destination GitHub OPTIONAL absente ou inaccessible : %s\n' \
          "$destination" >&2
        ((warnings += 1))
      fi
    fi
  done < <(printf '%s\n' "${!expected[@]}" | sort)

  if (( errors > 0 )); then
    printf '[RESULT] preflight=STOP errors=%d warnings=%d\n' \
      "$errors" "$warnings"
    return 1
  fi

  printf '[RESULT] preflight=OK repositories=%d warnings=%d\n' \
    "${#discovered[@]}" "$warnings"
}


sync_repositories() {
  local manifest="$1"
  local temp_root=""

  cleanup_sync_temp() {
    if [[ -n "$temp_root" && -d "$temp_root" ]]; then
      rm -rf -- "$temp_root"
    fi
  }

  trap cleanup_sync_temp EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local id status gitea_owner gitea_repo
  local github_owner github_repo refs
  local source destination source_url destination_url repo_dir
  local source_refs destination_refs
  local errors=0
  local synced=0
  local warnings=0

  validate_manifest "$manifest" || return 1

  if ! command -v git >/dev/null 2>&1; then
    printf '[STOP] Commande absente : git\n' >&2
    return 1
  fi

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/git-backup-sync.XXXXXXXX")" || {
    printf '[STOP] Impossible de créer le répertoire temporaire\n' >&2
    return 1
  }

  chmod 700 "$temp_root"

  echo "[INFO] Répertoire temporaire créé"

  while IFS=$'\t' read -r id status gitea_owner gitea_repo \
                               github_owner github_repo refs; do
    [[ "$id" == \#* || -z "$id" ]] && continue

    source="$gitea_owner/$gitea_repo"
    destination="$github_owner/$github_repo"
    source_url="${GITEA_GIT_BASE_URL}/${source}.git"
    destination_url="git@github.com:${destination}.git"
    repo_dir="$temp_root/$id.git"

    printf '[INFO] Synchronisation : %s -> %s\n' \
      "$source" "$destination"

    if ! GIT_TERMINAL_PROMPT=0 \
         git ls-remote "$source_url" HEAD >/dev/null 2>&1; then
      printf '[STOP] Source Gitea inaccessible : %s\n' "$source" >&2
      ((errors += 1))
      continue
    fi

    if ! GIT_TERMINAL_PROMPT=0 \
         git ls-remote "$destination_url" HEAD >/dev/null 2>&1; then
      if [[ "$status" == "REQUIRED" ]]; then
        printf '[STOP] Destination GitHub inaccessible : %s\n' \
          "$destination" >&2
        ((errors += 1))
      else
        printf '[WARN] Destination GitHub OPTIONAL inaccessible : %s\n' \
          "$destination" >&2
        ((warnings += 1))
      fi
      continue
    fi

    if [[ "$refs" != "heads-tags" ]]; then
      printf '[STOP] Politique de références non prise en charge : %s\n' \
        "$refs" >&2
      ((errors += 1))
      continue
    fi

    if ! GIT_TERMINAL_PROMPT=0 \
         git clone --bare "$source_url" "$repo_dir"; then
      printf '[STOP] Clone bare en échec : %s\n' "$source" >&2
      ((errors += 1))
      rm -rf "$repo_dir"
      continue
    fi

    if ! git -C "$repo_dir" remote add backup "$destination_url"; then
      printf '[STOP] Ajout du remote GitHub en échec : %s\n' \
        "$destination" >&2
      ((errors += 1))
      rm -rf "$repo_dir"
      continue
    fi

    if ! GIT_TERMINAL_PROMPT=0 \
         git -C "$repo_dir" push --prune backup \
           '+refs/heads/*:refs/heads/*' \
           '+refs/tags/*:refs/tags/*'; then
      printf '[STOP] Push GitHub en échec : %s\n' "$destination" >&2
      ((errors += 1))
      rm -rf "$repo_dir"
      continue
    fi

    if ! source_refs="$(
      GIT_TERMINAL_PROMPT=0 \
        git ls-remote --heads --tags "$source_url" |
        LC_ALL=C sort
    )"; then
      printf '[STOP] Relecture Gitea en échec : %s\n' "$source" >&2
      ((errors += 1))
      rm -rf "$repo_dir"
      continue
    fi

    if ! destination_refs="$(
      GIT_TERMINAL_PROMPT=0 \
        git ls-remote --heads --tags "$destination_url" |
        LC_ALL=C sort
    )"; then
      printf '[STOP] Relecture GitHub en échec : %s\n' \
        "$destination" >&2
      ((errors += 1))
      rm -rf "$repo_dir"
      continue
    fi

    if [[ "$source_refs" != "$destination_refs" ]]; then
      printf '[STOP] Références différentes après synchronisation : %s -> %s\n' \
        "$source" "$destination" >&2
      diff -u \
        <(printf '%s\n' "$source_refs") \
        <(printf '%s\n' "$destination_refs") || true
      ((errors += 1))
      rm -rf "$repo_dir"
      continue
    fi

    printf '[OK] Branches et tags identiques : %s -> %s\n' \
      "$source" "$destination"

    ((synced += 1))
    rm -rf "$repo_dir"
  done < "$manifest"

  cleanup_sync_temp
  trap - EXIT INT TERM
  echo "[OK] Répertoire temporaire nettoyé"

  if (( errors > 0 )); then
    printf '[RESULT] sync=STOP synced=%d errors=%d warnings=%d\n' \
      "$synced" "$errors" "$warnings"
    return 1
  fi

  printf '[RESULT] sync=OK synced=%d errors=0 warnings=%d\n' \
    "$synced" "$warnings"
}

main() {
  if [[ $# -ne 1 ]]; then
    usage >&2
    return 1
  fi

  case "$1" in
    --validate)
      validate_manifest "$MANIFEST"
      ;;
    --preflight)
      preflight_gitea "$MANIFEST"
      ;;
    --sync)
      sync_repositories "$MANIFEST"
      ;;
    --help|-h)
      usage
      ;;
    *)
      printf '[STOP] Mode inconnu : %s\n' "$1" >&2
      usage >&2
      return 1
      ;;
  esac
}

main "$@"
