#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run with sudo:"
  echo "  sudo $0 <backup.tar.gz>"
  exit 1
fi

RESTORE_MODE="${RESTORE_MODE:-staging}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_TARBALL="${1:-}"

if [[ -z "${BACKUP_TARBALL}" ]]; then
  echo "ERROR: You must specify a backup tar.gz file." >&2
  echo "Example:" >&2
  echo "  sudo ${SCRIPT_DIR}/restore.sh ${ROOT_DIR}/backups/unifi-controller-YYYY-MM-DD_HHMMSS.tar.gz" >&2
  exit 1
fi

if [[ ! -f "${BACKUP_TARBALL}" ]]; then
  echo "ERROR: Backup file not found: ${BACKUP_TARBALL}" >&2
  exit 1
fi

BACKUP_DIR="$(cd "$(dirname "${BACKUP_TARBALL}")" && pwd)"
BASENAME="$(basename "${BACKUP_TARBALL}")"
SHA_FILE="${BACKUP_DIR}/${BASENAME}.sha256"

echo "Restore mode: ${RESTORE_MODE}"
echo "Backup: ${BACKUP_TARBALL}"

if [[ -f "${SHA_FILE}" ]]; then
  echo "Verifying checksum..."
  (cd "${BACKUP_DIR}" && sha256sum -c "$(basename "${SHA_FILE}")")
else
  echo "WARNING: No checksum file found (${SHA_FILE}). Skipping verification."
fi

TIMESTAMP="$(date +"%Y-%m-%d_%H%M%S")"
RESTORE_ROOT="${ROOT_DIR}/restores"
STAGING_DIR="${RESTORE_ROOT}/${TIMESTAMP}"

if [[ "${RESTORE_MODE}" == "staging" ]]; then
  mkdir -p "${STAGING_DIR}"
  TARGET_DIR="${STAGING_DIR}"
  echo "Restoring into staging folder:"
  echo "  ${TARGET_DIR}"
elif [[ "${RESTORE_MODE}" == "inplace" ]]; then
  TARGET_DIR="${ROOT_DIR}"
  echo "Restoring IN PLACE into:"
  echo "  ${TARGET_DIR}"
  echo "This will overwrite docker-compose.yml, scripts/, unifi-data/, mongo-data/."
  echo
  echo "If you didn't mean to do this, press Ctrl+C now."
  sleep 5
else
  echo "ERROR: RESTORE_MODE must be 'staging' or 'inplace'." >&2
  exit 1
fi

if [[ "${RESTORE_MODE}" == "inplace" ]]; then
  echo "Stopping containers..."
  (cd "${ROOT_DIR}" && docker compose down) || true

  SAFETY_DIR="${ROOT_DIR}/pre-restore-${TIMESTAMP}"
  echo "Moving existing data to: ${SAFETY_DIR}"
  mkdir -p "${SAFETY_DIR}"

  for item in docker-compose.yml scripts unifi-data mongo-data; do
    if [[ -e "${ROOT_DIR}/${item}" ]]; then
      mv "${ROOT_DIR}/${item}" "${SAFETY_DIR}/"
    fi
  done

  mkdir -p "${ROOT_DIR}/scripts" "${ROOT_DIR}/unifi-data" "${ROOT_DIR}/mongo-data"
fi

echo "Extracting backup..."
tar -xzf "${BACKUP_TARBALL}" -C "${TARGET_DIR}"

if [[ "${RESTORE_MODE}" == "staging" ]]; then
  echo
  echo "Staging restore complete."
  echo "To inspect or run this restored controller:"
  echo "  cd \"${TARGET_DIR}\""
  echo "  sudo docker compose up -d"
  exit 0
fi

echo "Starting containers..."
(cd "${ROOT_DIR}" && docker compose up -d)

echo "Waiting briefly for services to come up..."
sleep 5

echo "Validating container status..."
(cd "${ROOT_DIR}" && docker compose ps)

HOST_TO_TEST="${HOST_TO_TEST:-127.0.0.1}"

echo "Validating UniFi web UI responds on https://${HOST_TO_TEST}:8443 ..."
if ! curl -kfsS --max-time 5 "https://${HOST_TO_TEST}:8443" >/dev/null; then
  echo "ERROR: UniFi does not appear reachable on https://${HOST_TO_TEST}:8443" >&2
  echo "Tail of unifi-network logs:" >&2
  (cd "${ROOT_DIR}" && docker logs --tail 80 unifi-network) || true
  exit 1
fi

echo "Validating UniFi inform endpoint responds on http://${HOST_TO_TEST}:8080/inform ..."
HTTP_CODE="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "http://${HOST_TO_TEST}:8080/inform" || true)"
if [[ "${HTTP_CODE}" == "000" ]]; then
  echo "ERROR: Nothing is listening on http://${HOST_TO_TEST}:8080/inform" >&2
  echo "Tail of unifi-network logs:" >&2
  (cd "${ROOT_DIR}" && docker logs --tail 80 unifi-network) || true
  exit 1
fi

echo "8080 /inform reachable (HTTP ${HTTP_CODE})."

echo "Validating MongoDB connectivity from UniFi container..."
MONGO_HOST_EXPECTED="${MONGO_HOST_EXPECTED:-unifi-db}"
if (cd "${ROOT_DIR}" && docker exec unifi-network bash -lc "nc -z -w 3 ${MONGO_HOST_EXPECTED} 27017"); then
  echo "Mongo connectivity OK (${MONGO_HOST_EXPECTED}:27017)."
else
  echo "WARNING: UniFi container could not reach Mongo at ${MONGO_HOST_EXPECTED}:27017" >&2
  echo "Tail of unifi-network logs:" >&2
  (cd "${ROOT_DIR}" && docker logs --tail 120 unifi-network) || true
  exit 1
fi

echo
echo "Restore complete + validated ✅"
echo "If something looks wrong, your previous state is preserved here:"
echo "  ${SAFETY_DIR}"