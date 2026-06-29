#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf "\n==> %s\n" "$*"; }

cd "$ROOT_DIR"

[[ -f docker-compose.yml ]] || {
  echo "ERROR: docker-compose.yml not found. Run from stack directory." >&2
  exit 1
}

[[ -f .env ]] || {
  echo "ERROR: .env not found." >&2
  exit 1
}

say "Current containers"
docker compose ps

say "Creating backup before update"
if [[ -x ./backup.sh ]]; then
  ./backup.sh
else
  echo "WARN: backup.sh not found or not executable; skipping backup."
fi

say "Pulling updated images"
docker compose pull unifi-network

say "Recreating UniFi Network Application container"
docker compose up -d unifi-network

say "Stack status"
docker compose ps

say "Recent UniFi logs"
docker logs --tail 80 unifi-network

say "Update complete"
echo "Open: https://<server-ip>:8443"