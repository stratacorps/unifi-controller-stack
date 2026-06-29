#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run with sudo:"
  echo "  sudo $0"
  exit 1
fi

# Backup UniFi Network Application + Mongo (docker-compose folder)
# - Stores backups in ../backups
# - Creates a .tar.gz and a matching .sha256 checksum
# - Optionally prunes backups older than N days

# -------- Settings --------
KEEP_DAYS="${KEEP_DAYS:-60}"   # set KEEP_DAYS=0 to disable pruning
BACKUP_PREFIX="${BACKUP_PREFIX:-unifi-controller}"
# --------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_DIR="${ROOT_DIR}/backups"

TIMESTAMP="$(date +"%Y-%m-%d_%H%M%S")"
ARCHIVE="${BACKUP_DIR}/${BACKUP_PREFIX}-${TIMESTAMP}.tar.gz"

# Ensure directory layout exists
mkdir -p "${BACKUP_DIR}"

# Sanity checks
for p in "${ROOT_DIR}/docker-compose.yml" "${ROOT_DIR}/scripts" "${ROOT_DIR}/unifi-data" "${ROOT_DIR}/mongo-data"; do
  if [[ ! -e "${p}" ]]; then
    echo "ERROR: Missing expected path: ${p}" >&2
    exit 1
  fi
done

echo "Stopping containers (optional safety)..."
# If you prefer "hot" backups, comment these two lines out.
if command -v docker >/dev/null 2>&1; then
  (cd "${ROOT_DIR}" && docker compose down) || true
fi

echo "Creating backup: ${ARCHIVE}"
# Use relative paths inside tar for portability
(
  cd "${ROOT_DIR}"
  tar -czf "${ARCHIVE}" \
    docker-compose.yml \
    scripts \
    unifi-data \
    mongo-data
)

echo "Generating checksum..."
(
  cd "${BACKUP_DIR}"
  sha256sum "$(basename "${ARCHIVE}")" > "$(basename "${ARCHIVE}").sha256"
)

echo "Starting containers again..."
if command -v docker >/dev/null 2>&1; then
  (cd "${ROOT_DIR}" && docker compose up -d) || true
fi

# Optional pruning
if [[ "${KEEP_DAYS}" != "0" ]]; then
  echo "Pruning backups older than ${KEEP_DAYS} days..."
  # macOS find syntax is slightly different: -mtime works fine
  find "${BACKUP_DIR}" -type f \( -name "${BACKUP_PREFIX}-*.tar.gz" -o -name "${BACKUP_PREFIX}-*.tar.gz.sha256" \) -mtime +"${KEEP_DAYS}" -print -delete || true
fi

echo "Done."
echo "Backup created:"
echo "  ${ARCHIVE}"
echo "  ${ARCHIVE}.sha256"