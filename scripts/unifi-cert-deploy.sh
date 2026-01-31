#!/usr/bin/env bash
set -euo pipefail

# Deploy Let's Encrypt certs into UniFi's Java keystore (linuxserver/unifi).
#
# Assumptions:
# - Host has certs at /etc/letsencrypt/live/<DOMAIN>/{fullchain.pem,privkey.pem}
# - Container has /etc/letsencrypt mounted read-only
# - This script runs as root (or via sudo), because it reads /etc/letsencrypt
#
# Usage:
#   sudo DOMAIN=unifi.example.com ./scripts/unifi-cert-deploy.sh

DOMAIN="${DOMAIN:-}"
if [[ -z "${DOMAIN}" ]]; then
  echo "ERROR: set DOMAIN=your.fqdn" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${ROOT_DIR}/unifi-data/certs"
LE_LIVE="/etc/letsencrypt/live/${DOMAIN}"

mkdir -p "${CERT_DIR}"

echo "Copying certs from ${LE_LIVE} -> ${CERT_DIR}"
cp -f "${LE_LIVE}/fullchain.pem" "${CERT_DIR}/fullchain.pem"
cp -f "${LE_LIVE}/privkey.pem"   "${CERT_DIR}/privkey.pem"
chmod 600 "${CERT_DIR}/privkey.pem" || true

P12="${CERT_DIR}/unifi.p12"
P12_PASS="${P12_PASS:-temppass}"

echo "Building PKCS12 bundle at: ${P12}"
openssl pkcs12 -export   -in "${CERT_DIR}/fullchain.pem"   -inkey "${CERT_DIR}/privkey.pem"   -out "${P12}"   -name unifi   -password "pass:${P12_PASS}"

echo "Importing ${P12} into UniFi keystore inside container..."
docker exec unifi-network bash -lc "
set -e
KEYSTORE='/config/data/keystore'
keytool -importkeystore   -deststorepass aircontrolenterprise   -destkeypass aircontrolenterprise   -destkeystore "\$KEYSTORE"   -srckeystore /config/certs/unifi.p12   -srcstoretype PKCS12   -srcstorepass '${P12_PASS}'   -alias unifi   -noprompt
"

echo "Restarting UniFi container..."
( cd "${ROOT_DIR}" && docker compose restart unifi-network )

echo "Done ✅"
