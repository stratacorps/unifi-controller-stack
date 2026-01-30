#!/usr/bin/env bash
set -euo pipefail

# UniFi Controller Stack Installer
# - Installs into /home/<user> (no subfolder) if user provided
# - Installs into /opt/unifi-controller if user is <none>
# - Optional: certbot DNS-01 via Cloudflare token (no :443 required)

REPO_SLUG_DEFAULT="stratacorps/unifi-controller-stack"
BRANCH_DEFAULT="main"

say() { printf "\n==> %s\n" "$*"; }
die() { printf "\nERROR: %s\n\n" "$*" >&2; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this as root (or with sudo). Example: sudo bash -c \"$(basename "$0")\" (or use the curl|bash one-liner as root)."
  fi
}

prompt() {
  local var="$1" default="$2" msg="$3"
  local val
  read -r -p "${msg} [${default}]: " val </dev/tty || true
  val="${val:-$default}"
  printf -v "$var" '%s' "$val"
}

confirm() {
  local msg="$1" default="${2:-N}"
  local yn
  read -r -p "${msg} (y/n) [${default}]: " yn </dev/tty || true
  yn="${yn:-$default}"
  [[ "$yn" =~ ^[Yy]$ ]]
}

fetch_repo_tarball() {
  local slug="$1" branch="$2" dest="$3"
  local url="https://github.com/${slug}/archive/refs/heads/${branch}.tar.gz"
  say "Downloading stack from: ${url}"
  mkdir -p "$dest"
  curl -fsSL "$url" -o /tmp/unifi-stack.tar.gz
  tar -xzf /tmp/unifi-stack.tar.gz -C /tmp
  local folder="/tmp/$(basename "${slug}")-${branch}"

  # Copy repo contents into dest (dest is the final install directory)
  # We DO NOT use rsync (per your preference). We only copy known files/dirs.
  # If those paths already exist, we back them up first.
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  local backup_dir="${dest}/pre-install-${ts}"
  mkdir -p "$backup_dir"

  for item in docker-compose.yml README.md scripts backups unifi-data mongo-data backup.sh restore.sh; do
    if [[ -e "${dest}/${item}" ]]; then
      mv "${dest}/${item}" "${backup_dir}/" || true
    fi
  done

  # Copy in fresh content
  for item in docker-compose.yml README.md scripts backups unifi-data mongo-data backup.sh restore.sh; do
    if [[ -e "${folder}/${item}" ]]; then
      cp -a "${folder}/${item}" "${dest}/"
    fi
  done

  # Ensure required dirs exist even if not in repo
  mkdir -p "${dest}/scripts" "${dest}/backups" "${dest}/unifi-data" "${dest}/mongo-data"

  say "Repo files installed into: ${dest}"
  say "Any previous items (if present) were moved into: ${backup_dir}"
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1; then
    say "Docker already installed."
    return
  fi

  say "Docker not found. Installing Docker Engine (Ubuntu/Debian style)..."

  if ! command -v apt-get >/dev/null 2>&1; then
    die "apt-get not found. This installer currently supports Debian/Ubuntu via apt."
  fi

  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    ${codename} stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  say "Docker installed and started."
}

ensure_user_can_docker() {
  local app_user="$1"

  if [[ "$app_user" == "<none>" ]]; then
    say "System install selected (<none>). Docker commands will be run as root."
    return
  fi

  getent passwd "$app_user" >/dev/null || die "User '${app_user}' does not exist."

  # Ensure docker group exists and user is a member
  if ! getent group docker >/dev/null; then
    say "Creating docker group..."
    groupadd docker
  fi

  if id -nG "$app_user" | tr ' ' '\n' | grep -qx docker; then
    say "User '${app_user}' is already in docker group."
  else
    say "Adding '${app_user}' to docker group..."
    usermod -aG docker "$app_user"
    say "NOTE: '${app_user}' may need to log out/in for docker group to take effect (or use newgrp docker)."
  fi
}

write_stack_files() {
  local dest="$1" puid="$2" pgid="$3"

  say "Writing stack files into: ${dest}"

  mkdir -p "${dest}/scripts" "${dest}/backups" "${dest}/unifi-data" "${dest}/mongo-data"

  # first-run-mongo.sh
  cat > "${dest}/scripts/first-run-mongo.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Creates the UniFi DB user on first Mongo init.
# Environment variables expected (from docker-compose):
#   MONGO_USER, MONGO_PASS, MONGO_DBNAME, MONGO_AUTHSOURCE

mongosh --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin <<EOS
db = db.getSiblingDB("${MONGO_AUTHSOURCE:-admin}");

if (db.getUser("${MONGO_USER}") == null) {
  db.createUser({
    user: "${MONGO_USER}",
    pwd:  "${MONGO_PASS}",
    roles: [
      { role: "dbOwner", db: "${MONGO_DBNAME}" }
    ]
  });
  print("Created user '${MONGO_USER}' for db '${MONGO_DBNAME}'.");
} else {
  print("User '${MONGO_USER}' already exists; skipping.");
}
EOS
EOF
  chmod +x "${dest}/scripts/first-run-mongo.sh"

  # docker-compose.yml (baseline: publish needed ports; Mongo is internal only)
  cat > "${dest}/docker-compose.yml" <<EOF
services:
  unifi-db:
    image: docker.io/mongo:8
    container_name: unifi-db
    environment:
      - MONGO_INITDB_ROOT_USERNAME=root
      - MONGO_INITDB_ROOT_PASSWORD=unifi
      - MONGO_USER=unifi
      - MONGO_PASS=unifi
      - MONGO_DBNAME=unifi
      - MONGO_AUTHSOURCE=admin
    volumes:
      - ./mongo-data:/data/db
      - ./scripts/first-run-mongo.sh:/docker-entrypoint-initdb.d/init-mongo.sh:ro
    restart: unless-stopped

  unifi-network:
    image: lscr.io/linuxserver/unifi-network-application:10.0.162-ls113
    container_name: unifi-network
    depends_on:
      - unifi-db
    environment:
      - PUID=${puid}
      - PGID=${pgid}
      - TZ=America/Chicago
      - MONGO_HOST=unifi-db
      - MONGO_PORT=27017
      - MONGO_DBNAME=unifi
      - MONGO_USER=unifi
      - MONGO_PASS=unifi
      - MONGO_AUTHSOURCE=admin
    volumes:
      - ./unifi-data:/config
    ports:
      - "8443:8443"        # UniFi UI (https)
      - "8080:8080"        # Inform
      - "3478:3478/udp"    # STUN
      - "10001:10001/udp"  # Device discovery
      - "8843:8843"        # Guest portal (https) - optional
      - "8880:8880"        # Guest portal (http)  - optional
    restart: unless-stopped
EOF

  # backup.sh
  cat > "${dest}/scripts/backup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${ROOT_DIR}/backups"
TS="$(date +"%Y-%m-%d_%H%M%S")"
OUT="${BACKUP_DIR}/unifi-controller-${TS}.tar.gz"

mkdir -p "${BACKUP_DIR}"

echo "Creating backup: ${OUT}"
tar -czf "${OUT}" -C "${ROOT_DIR}" \
  docker-compose.yml scripts unifi-data mongo-data

echo "Creating checksum..."
( cd "${BACKUP_DIR}" && shasum -a 256 "$(basename "${OUT}")" > "$(basename "${OUT}").sha256" )

echo "Backup complete."
echo "  ${OUT}"
EOF
  chmod +x "${dest}/scripts/backup.sh"

  # restore.sh (staging by default)
  cat > "${dest}/scripts/restore.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

RESTORE_MODE="${RESTORE_MODE:-staging}"  # staging|inplace
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_TARBALL="${1:-}"

if [[ -z "${BACKUP_TARBALL}" ]]; then
  echo "Usage:"
  echo "  ${SCRIPT_DIR}/restore.sh /path/to/unifi-controller-YYYY-MM-DD_HHMMSS.tar.gz"
  exit 1
fi
if [[ ! -f "${BACKUP_TARBALL}" ]]; then
  echo "ERROR: backup not found: ${BACKUP_TARBALL}" >&2
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
  echo "WARNING: checksum not found; skipping verification."
fi

TIMESTAMP="$(date +"%Y-%m-%d_%H%M%S")"
RESTORE_ROOT="${RESTORE_ROOT:-${HOME}/restores}"
STAGING_DIR="${RESTORE_ROOT}/${TIMESTAMP}"

if [[ "${RESTORE_MODE}" == "staging" ]]; then
  mkdir -p "${STAGING_DIR}"
  echo "Extracting into staging folder:"
  echo "  ${STAGING_DIR}"
  tar -xzf "${BACKUP_TARBALL}" -C "${STAGING_DIR}"
  echo
  echo "Staging restore complete."
  echo "Run it with:"
  echo "  cd \"${STAGING_DIR}\""
  echo "  docker compose up -d"
  exit 0
elif [[ "${RESTORE_MODE}" == "inplace" ]]; then
  echo "Restoring IN PLACE into ${ROOT_DIR} (destructive)."
  echo "Press Ctrl+C now if this is not intended."
  sleep 5
else
  echo "ERROR: RESTORE_MODE must be 'staging' or 'inplace'." >&2
  exit 1
fi

echo "Stopping containers..."
( cd "${ROOT_DIR}" && docker compose down ) || true

SAFETY_DIR="${ROOT_DIR}/pre-restore-${TIMESTAMP}"
mkdir -p "${SAFETY_DIR}"
for item in docker-compose.yml scripts unifi-data mongo-data; do
  if [[ -e "${ROOT_DIR}/${item}" ]]; then
    mv "${ROOT_DIR}/${item}" "${SAFETY_DIR}/"
  fi
done

mkdir -p "${ROOT_DIR}/scripts" "${ROOT_DIR}/unifi-data" "${ROOT_DIR}/mongo-data"

echo "Extracting backup..."
tar -xzf "${BACKUP_TARBALL}" -C "${ROOT_DIR}"

echo "Starting containers..."
( cd "${ROOT_DIR}" && docker compose up -d )

echo "Restore complete."
echo "Previous state (if any) moved to: ${SAFETY_DIR}"
EOF
  chmod +x "${dest}/scripts/restore.sh"

  # Cert deploy script (host side): builds p12 + imports into container
  cat > "${dest}/scripts/unifi-cert-deploy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Assumes certs are made available to this stack in:
#   ./unifi-data/certs/fullchain.pem
#   ./unifi-data/certs/privkey.pem
#
# This builds:
#   ./unifi-data/certs/unifi.p12
# And imports into:
#   /config/data/keystore inside container (alias: unifi)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${ROOT_DIR}/unifi-data/certs"
FULLCHAIN="${CERT_DIR}/fullchain.pem"
PRIVKEY="${CERT_DIR}/privkey.pem"
P12="${CERT_DIR}/unifi.p12"

P12_PASS="${P12_PASS:-temppass}"
KEYSTORE_PASS="${KEYSTORE_PASS:-aircontrolenterprise}"

[[ -f "${FULLCHAIN}" ]] || { echo "Missing: ${FULLCHAIN}" >&2; exit 1; }
[[ -f "${PRIVKEY}"   ]] || { echo "Missing: ${PRIVKEY}" >&2; exit 1; }

echo "Building PKCS12 bundle at: ${P12}"
openssl pkcs12 -export \
  -in "${FULLCHAIN}" \
  -inkey "${PRIVKEY}" \
  -out "${P12}" \
  -name unifi \
  -password "pass:${P12_PASS}"

chmod 600 "${P12}"

echo "Importing ${P12} into UniFi keystore inside container..."
docker exec unifi-network bash -lc "
set -e
KEYSTORE='/config/data/keystore'
P12='/config/certs/unifi.p12'
keytool -importkeystore \
  -deststorepass '${KEYSTORE_PASS}' \
  -destkeypass '${KEYSTORE_PASS}' \
  -destkeystore \"\$KEYSTORE\" \
  -srckeystore \"\$P12\" \
  -srcstoretype PKCS12 \
  -srcstorepass '${P12_PASS}' \
  -alias unifi \
  -noprompt
"

echo "Restarting UniFi container..."
docker restart unifi-network >/dev/null
echo "Done."
EOF
  chmod +x "${dest}/scripts/unifi-cert-deploy.sh"
}

maybe_setup_ssl_dns01() {
  local domain="$1" email="$2" cf_token="$3" dest="$4"

  # We do NOT touch :443. DNS-01 only.
  # We do not auto-install snap if you don't want it; but this is the simplest.
  # If snap isn't present, we install it.
  say "Setting up Let's Encrypt via DNS-01 (Cloudflare) for ${domain}"

  if ! command -v snap >/dev/null 2>&1; then
    say "snap not found -> installing snapd..."
    apt-get update
    apt-get install -y snapd
    systemctl enable --now snapd
  fi

  if ! snap list 2>/dev/null | awk '{print $1}' | grep -qx certbot; then
    say "Installing certbot via snap..."
    snap install core >/dev/null || true
    snap refresh core >/dev/null || true
    snap install --classic certbot
    ln -sf /snap/bin/certbot /usr/bin/certbot
  fi

  say "Installing Cloudflare DNS plugin..."
  snap set certbot trust-plugin-with-root=ok >/dev/null || true
  snap install certbot-dns-cloudflare >/dev/null || true

  local secrets="/root/.secrets"
  mkdir -p "$secrets"
  local ini="${secrets}/cloudflare.ini"
  cat > "$ini" <<EOF
dns_cloudflare_api_token = ${cf_token}
EOF
  chmod 600 "$ini"

  say "Requesting certificate (DNS-01)..."
  certbot certonly \
    --non-interactive --agree-tos \
    --email "$email" \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$ini" \
    -d "$domain"

  # Make certs available inside container by placing them under ./unifi-data/certs
  mkdir -p "${dest}/unifi-data/certs"

  ln -sf "/etc/letsencrypt/live/${domain}/fullchain.pem" "${dest}/unifi-data/certs/fullchain.pem"
  ln -sf "/etc/letsencrypt/live/${domain}/privkey.pem"   "${dest}/unifi-data/certs/privkey.pem"

  say "Deploying certificate into UniFi keystore (container)..."
  ( cd "$dest" && "${dest}/scripts/unifi-cert-deploy.sh" )

  say "Installing deploy-hook so renewals update UniFi automatically..."
  local hook="/etc/letsencrypt/renewal-hooks/deploy/unifi-cert-deploy.sh"
  cat > "$hook" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${dest}"
"${dest}/scripts/unifi-cert-deploy.sh" >/dev/null 2>&1 || true
EOF
  chmod +x "$hook"

  say "Testing renewal hook (dry run)..."
  certbot renew --dry-run --run-deploy-hooks

  say "SSL setup complete."
  say "NOTE: This is DNS-01 based; Cloudflare DNS must remain authoritative for this record."
}

bring_up_stack() {
  local dest="$1" app_user="$2"

  say "Starting UniFi stack..."
  if [[ "$app_user" == "<none>" ]]; then
    ( cd "$dest" && docker compose up -d )
  else
    # run docker compose as that user
    su - "$app_user" -c "cd \"$dest\" && docker compose up -d"
  fi

  say "Containers:"
  ( cd "$dest" && docker compose ps ) || true
}

main() {
  need_root

  say "UniFi Controller Stack Installer"
  echo "Repo: ${REPO_SLUG_DEFAULT} (${BRANCH_DEFAULT})"
  echo

  local app_user
  prompt app_user "unifi" "UNIX user to run/manage stack (enter <none> for system install)"

  local install_dir puid pgid home_dir
  if [[ "$app_user" == "<none>" ]]; then
    install_dir="/opt/unifi-controller"
    puid="0"
    pgid="0"
    say "System install selected -> ${install_dir}"
    mkdir -p "$install_dir"
  else
    getent passwd "$app_user" >/dev/null || die "User '${app_user}' does not exist."
    home_dir="$(getent passwd "$app_user" | cut -d: -f6)"
    [[ -d "$home_dir" ]] || die "Home directory not found: ${home_dir}"
    install_dir="$home_dir"
    puid="$(id -u "$app_user")"
    pgid="$(id -g "$app_user")"
    say "User install selected -> ${install_dir} (UID=${puid}, GID=${pgid})"
  fi

  local slug branch
  prompt slug "$REPO_SLUG_DEFAULT" "GitHub repo (owner/repo)"
  prompt branch "$BRANCH_DEFAULT"  "GitHub branch"

  # Fetch + lay down repo files (safe moves into pre-install-<ts>)
  fetch_repo_tarball "$slug" "$branch" "$install_dir"

  # Ensure stack files exist/updated with correct UID/GID
  write_stack_files "$install_dir" "$puid" "$pgid"

  install_docker_if_missing
  ensure_user_can_docker "$app_user"

  # Ownership: for user installs, ensure user owns its home stack files
  if [[ "$app_user" != "<none>" ]]; then
    chown -R "$app_user:$app_user" "$install_dir/docker-compose.yml" "$install_dir/scripts" "$install_dir/unifi-data" "$install_dir/mongo-data" "$install_dir/backups" || true
  fi

  # Optional SSL
  if confirm "Enable SSL via Let's Encrypt DNS-01 (Cloudflare token)? (No :443 required)" "N"; then
    local domain email token
    prompt domain "unifi.example.com" "FQDN for UniFi controller (must exist in Cloudflare DNS)"
    prompt email  "admin@example.com" "Email for Let's Encrypt"
    prompt token  "" "Cloudflare API Token (DNS edit for the zone) (input will be echoed)"
    [[ -n "$token" ]] || die "Cloudflare token cannot be blank if SSL is enabled."
    maybe_setup_ssl_dns01 "$domain" "$email" "$token" "$install_dir"
  else
    say "Skipping SSL setup."
    say "NOTE: This install assumes DNS-01 if/when you later enable SSL."
  fi

  bring_up_stack "$install_dir" "$app_user"

  say "Done."
  echo
  echo "Next steps:"
  echo "  - Visit: https://<your-host>:8443"
  echo "  - Inform URL typically: http://<your-host>:8080/inform"
  echo "  - Backups: ${install_dir}/scripts/backup.sh"
  echo "  - Restore: ${install_dir}/scripts/restore.sh"
}

main "$@"