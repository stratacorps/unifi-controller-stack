#!/usr/bin/env bash
set -euo pipefail

# Restore from a backup created by scripts/backup.sh
#
# Usage:
#   ./scripts/restore.sh ./backups/unifi-controller-YYYY-MM-DD_HHMMSS.tar.gz
#
# Optional:
#   RESTORE_MODE=staging  (default)  -> restore into ./restores/<timestamp>/
#   RESTORE_MODE=inplace             -> restore into current folder (destructive)
#
# Notes:
# - If RESTORE_MODE=inplace, the stack is stopped and current state moved aside.
# - After restore (inplace), it validates 8443 + 8080 are listening.

RESTORE_MODE="${RESTORE_MODE:-staging}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_TARBALL="${1:-}"

if [[ -z "${BACKUP_TARBALL}" ]]; then
  echo "ERROR: specify a backup tar.gz" >&2
  exit 1
fi
if [[ ! -f "${BACKUP_TARBALL}" ]]; then
  echo "ERROR: not found: ${BACKUP_TARBALL}" >&2
  exit 1
fi

BACKUP_DIR="$(cd "$(dirname "${BACKUP_TARBALL}")" && pwd)"
BASENAME="$(basename "${BACKUP_TARBALL}")"
SHA_FILE="${BACKUP_DIR}/${BASENAME}.sha256"

echo "Restore mode: ${RESTORE_MODE}"
echo "Backup: ${BACKUP_TARBALL}"

if [[ -f "${SHA_FILE}" ]]; then
  echo "Verifying checksum..."
  (cd "${BACKUP_DIR}" && shasum -a 256 -c "$(basename "${SHA_FILE}")")
else
  echo "WARNING: no checksum file found; skipping verification."
fi

TS="$(date +"%Y-%m-%d_%H%M%S")"
RESTORE_ROOT="${ROOT_DIR}/restores"
STAGING_DIR="${RESTORE_ROOT}/${TS}"

if [[ "${RESTORE_MODE}" == "staging" ]]; then
  mkdir -p "${STAGING_DIR}"
  TARGET_DIR="${STAGING_DIR}"
  echo "Restoring into: ${TARGET_DIR}"
elif [[ "${RESTORE_MODE}" == "inplace" ]]; then
  TARGET_DIR="${ROOT_DIR}"
  echo "Restoring IN PLACE into: ${TARGET_DIR}"
  echo "Overwrites: docker-compose.yml .env scripts/ unifi-data/ mongo-data/"
  echo "Ctrl+C to abort. Continuing in 5 seconds..."
  sleep 5

  echo "Stopping containers..."
  (cd "${ROOT_DIR}" && docker compose down) || true

  SAFETY_DIR="${ROOT_DIR}/pre-restore-${TS}"
  mkdir -p "${SAFETY_DIR}"
  for item in docker-compose.yml .env scripts unifi-data mongo-data; do
    [[ -e "${ROOT_DIR}/${item}" ]] && mv "${ROOT_DIR}/${item}" "${SAFETY_DIR}/"
  done
else
  echo "ERROR: RESTORE_MODE must be 'staging' or 'inplace'." >&2
  exit 1
fi

echo "Extracting..."
tar -xzf "${BACKUP_TARBALL}" -C "${TARGET_DIR}"

if [[ "${RESTORE_MODE}" == "staging" ]]; then
  echo "Staging restore complete ✅"
  echo "Run it with:"
  echo "  cd "${TARGET_DIR}" && docker compose up -d"
  exit 0
fi

echo "Starting containers..."
(cd "${ROOT_DIR}" && docker compose up -d)

echo "Waiting briefly..."
sleep 5

echo "Validating ports..."
HOST_TO_TEST="${HOST_TO_TEST:-127.0.0.1}"

if ! curl -kfsS --max-time 5 "https://${HOST_TO_TEST}:8443" >/dev/null; then
  echo "ERROR: UniFi not reachable on https://${HOST_TO_TEST}:8443" >&2
  (cd "${ROOT_DIR}" && docker logs --tail 120 unifi-network) || true
  exit 1
fi

HTTP_CODE="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "http://${HOST_TO_TEST}:8080/inform" || true)"
if [[ "${HTTP_CODE}" == "000" ]]; then
  echo "ERROR: nothing listening on http://${HOST_TO_TEST}:8080/inform" >&2
  (cd "${ROOT_DIR}" && docker logs --tail 120 unifi-network) || true
  exit 1
fi

echo "Restore complete + validated ✅"
