#!/usr/bin/env bash
set -euo pipefail

# Back up UniFi docker folder + Mongo data volume directory.
# Usage:
#   ./scripts/backup.sh
#
# Creates:
#   ./backups/unifi-controller-YYYY-MM-DD_HHMMSS.tar.gz
#   ./backups/<file>.sha256

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${ROOT_DIR}/backups"
TS="$(date +"%Y-%m-%d_%H%M%S")"
OUT="${BACKUP_DIR}/unifi-controller-${TS}.tar.gz"

mkdir -p "${BACKUP_DIR}"

echo "Stopping stack (to get a consistent backup)..."
( cd "${ROOT_DIR}" && docker compose down ) || true

echo "Creating backup: ${OUT}"
tar -czf "${OUT}" -C "${ROOT_DIR}"   docker-compose.yml .env scripts unifi-data mongo-data

echo "Checksumming..."
( cd "${BACKUP_DIR}" && shasum -a 256 "$(basename "${OUT}")" > "$(basename "${OUT}").sha256" )

echo "Bringing stack back up..."
( cd "${ROOT_DIR}" && docker compose up -d )

echo "Backup complete ✅"
echo "  ${OUT}"
