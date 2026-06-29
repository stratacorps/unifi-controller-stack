#!/usr/bin/env bash
set -euo pipefail

IMAGE_REPO="lscr.io/linuxserver/unifi-network-application"
HUB_API="https://hub.docker.com/v2/repositories/linuxserver/unifi-network-application/tags?page_size=100&ordering=last_updated"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"

say() { printf "\n==> %s\n" "$*"; }

usage() {
  cat <<EOF
Usage:
  $0 --info
  $0 --check
  sudo $0 <version-or-tag>

Examples:
  $0 --info
  $0 --check
  sudo $0 10.4.57
  sudo $0 10.4.57-ls134
EOF
}

current_compose_image() {
  grep -E "lscr.io/linuxserver/unifi-network-application:" "${COMPOSE_FILE}" \
    | head -1 \
    | sed -E 's/.*(lscr\.io\/linuxserver\/unifi-network-application:[^[:space:]"]+).*/\1/'
}

current_compose_tag() {
  current_compose_image | sed -E 's#^lscr.io/linuxserver/unifi-network-application:##'
}

fetch_tags() {
  curl -fsSL "${HUB_API}" \
    | python3 -c '
import json, sys
data=json.load(sys.stdin)
for item in data.get("results", []):
    name=item.get("name")
    if name:
        print(name)
'
}

resolve_tag() {
  local requested="$1"
  local tags
  tags="$(fetch_tags)"

  # Exact tag exists
  if printf "%s\n" "${tags}" | grep -Fxq "${requested}"; then
    echo "${requested}"
    return 0
  fi

  # Clean app version supplied; find highest LinuxServer suffix
  local resolved
  resolved="$(
    printf "%s\n" "${tags}" \
      | grep -E "^${requested}-ls[0-9]+$" \
      | sed -E 's/.*-ls([0-9]+)$/\1 &/' \
      | sort -n \
      | tail -1 \
      | cut -d' ' -f2-
  )"

  if [[ -n "${resolved}" ]]; then
    echo "${resolved}"
    return 0
  fi

  echo "ERROR: Could not find Docker tag for '${requested}'." >&2
  exit 1
}

show_info() {
  say "Current deployment"

  echo "Compose image:"
  echo "  $(current_compose_image)"

  echo
  echo "Compose tag:"
  echo "  $(current_compose_tag)"

  echo
  echo "Running container image:"
  docker ps --filter name=unifi-network --format '  {{.Image}}' || true

  say "Recent available tags"
  fetch_tags | grep -E '^(latest|[0-9]+\.[0-9]+\.[0-9]+(-ls[0-9]+)?)$' | head -25
}

show_check() {
  local current latest
  current="$(current_compose_tag)"
  latest="$(fetch_tags | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"

  say "Update check"
  echo "Current: ${current}"
  echo "Latest clean version tag: ${latest:-unknown}"

  if [[ -n "${latest}" && "${current}" != "${latest}" && "${current}" != "${latest}"-ls* ]]; then
    echo "Update may be available."
  else
    echo "No obvious update detected."
  fi
}

do_update() {
  local requested="$1"
  local new_tag
  new_tag="$(resolve_tag "${requested}")"

  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run updates with sudo:" >&2
    echo "  sudo $0 ${requested}" >&2
    exit 1
  fi

  cd "${ROOT_DIR}"

  [[ -f "${COMPOSE_FILE}" ]] || {
    echo "ERROR: docker-compose.yml not found at ${COMPOSE_FILE}" >&2
    exit 1
  }

  say "Current UniFi image"
  grep -n "lscr.io/linuxserver/unifi-network-application" "${COMPOSE_FILE}" || true

  say "Creating backup before update"
  [[ -x "${ROOT_DIR}/scripts/backup.sh" ]] || {
    echo "ERROR: scripts/backup.sh not found or not executable." >&2
    exit 1
  }
  "${ROOT_DIR}/scripts/backup.sh"

  say "Updating docker-compose.yml to UniFi tag: ${new_tag}"
  cp -a "${COMPOSE_FILE}" "${COMPOSE_FILE}.pre-update.$(date +"%Y%m%d-%H%M%S").bak"

  sed -i -E \
    "s#(lscr.io/linuxserver/unifi-network-application:)[^[:space:]\"']+#\1${new_tag}#" \
    "${COMPOSE_FILE}"

  say "Pulling updated image"
  docker compose pull unifi-network

  say "Recreating UniFi Network Application container"
  docker compose up -d unifi-network

  say "Stack status"
  docker compose ps

  say "Recent UniFi logs"
  docker logs --tail 80 unifi-network

  say "Update complete"
}

case "${1:-}" in
  --info|-i)
    show_info
    ;;
  --check|-c)
    show_check
    ;;
  --help|-h|"")
    usage
    ;;
  *)
    do_update "$1"
    ;;
esac