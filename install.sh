#!/usr/bin/env bash
set -euo pipefail

# UniFi Controller Stack installer
#
# Intended workflow:
# 1) Extract this template into the target directory (or git clone).
# 2) Run this script. It will:
#    - Install Docker Engine + Compose plugin if missing (Ubuntu/Debian)
#    - Create/overwrite .env based on prompts
#    - Ensure directories exist + permissions are correct
#    - docker compose up -d
#    - Optionally install certbot (snap) and show DNS-01 notes (Cloudflare)
#
# Run as:
#   - root, OR
#   - the 'unifi' user with sudo privileges (recommended)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"
REPO_RAW_BASE_DEFAULT="https://raw.githubusercontent.com/stratacorps/unifi-controller-stack/main"
STACK_USER=""
STACK_UID=""
STACK_GID=""
STACK_HOME=""

# What we consider the "template" that must exist for a working stack
TEMPLATE_DIRS=(
  "scripts"
  "backups"
  "mongo-data"
  "unifi-data"
)

TEMPLATE_FILES_REQUIRED=(
  "docker-compose.yml"
  "scripts/first-run-mongo.sh"
)

# Optional-but-part-of-template (helpful, but not required to boot containers)
TEMPLATE_FILES_OPTIONAL=(
  "backup.sh"
  "restore.sh"
  "update.sh"
  ".env.template"
  "README.md"
  "scripts/unifi-cert-deploy.sh"
)

have() { command -v "$1" >/dev/null 2>&1; }

say() { printf "\n==> %s\n" "$*"; }

prompt() {
  local __var="$1"; local __default="$2"; local __msg="$3"
  local __val=""
  read -r -p "${__msg} [${__default}]: " __val </dev/tty || true
  __val="${__val:-$__default}"
  printf -v "${__var}" "%s" "${__val}"
}

confirm() {
  local __var="$1"; local __default="$2"; local __msg="$3"
  local __val=""
  read -r -p "${__msg} (y/n) [${__default}]: " __val </dev/tty || true
  __val="${__val:-$__default}"
  __val="$(echo "${__val}" | tr '[:upper:]' '[:lower:]')"
  [[ "${__val}" == "y" || "${__val}" == "yes" ]] && __val="y" || __val="n"
  printf -v "${__var}" "%s" "${__val}"
}

need_sudo() {
  # If not root, we must be able to sudo.
  if [[ "$(id -u)" -ne 0 ]]; then
    have sudo || { echo "ERROR: sudo not found and not running as root." >&2; exit 1; }
    # Validate sudo works (interactive is ok; non-interactive may fail on first run)
    if ! sudo -v; then
      echo "ERROR: sudo privileges required to run this installer as a user." >&2
      exit 1
    fi
  fi
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

preflight() {
  say "Preflight checks..."

  if [[ "$(id -u)" -eq 0 ]]; then
    say "Running as root."
  else
    say "Running as user: $(id -un)"
  fi

  need_sudo

  # Basic tools we rely on
  local missing=()
  for cmd in curl grep cut sed; do
    have "$cmd" || missing+=("$cmd")
  done

  if (( ${#missing[@]} )); then
    echo "ERROR: missing required commands: ${missing[*]}" >&2
    echo "Install them first (typically: apt-get install -y ${missing[*]})." >&2
    exit 1
  fi

  # Optional but used by your password generator
  if ! have python3; then
    say "NOTE: python3 not found. Password auto-generation will be weaker/fallback unless you install python3."
  fi

  say "Preflight OK."
}

install_docker_ubuntu_debian() {
  say "Installing Docker (Engine + Compose plugin)..."
  run_root apt-get update -y
  run_root apt-get install -y ca-certificates curl gnupg lsb-release

  # Install from Docker's official repo
  run_root install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | run_root gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    run_root chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" | run_root tee /etc/apt/sources.list.d/docker.list >/dev/null

  run_root apt-get update -y
  run_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_root systemctl enable --now docker
}

ensure_docker() {
  if have docker && docker info >/dev/null 2>&1; then
    say "Docker is already installed and running."
    return
  fi

  say "Docker is not installed on this system."

  local install_ok
  confirm install_ok "y" \
    "Install Docker Engine + Docker Compose system-wide now?"

  if [[ "${install_ok}" != "y" ]]; then
    echo "Aborting. Please install Docker manually, then re-run install.sh."
    exit 1
  fi
  
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "${ID}" in
      ubuntu|debian)
        install_docker_ubuntu_debian
        ;;
      *)
        echo "ERROR: unsupported distro for automatic Docker install: ${ID}" >&2
        echo "Install Docker manually, then rerun install.sh." >&2
        exit 1
        ;;
    esac
  else
    echo "ERROR: cannot detect OS. Install Docker manually." >&2
    exit 1
  fi
}

ensure_user_in_docker_group() {
  local user="$1"

  # Ensure docker group exists
  run_root groupadd -f docker

  # Is user already in docker group?
  if id -nG "${user}" | grep -qw docker; then
    say "User '${user}' is already in the docker group."
    return 0
  fi

  say "Adding user '${user}' to the docker group..."
  run_root usermod -aG docker "${user}"

  cat <<EOF

NOTE:
- User '${user}' was added to the docker group.
- This will NOT take effect until the user logs out and logs back in.
- Docker commands during install still work because this script uses sudo/root.

EOF
}

ensure_user_in_docker_group_optional() {
  local user="$1"

  # This is convenience only; not required because install uses run_root docker/compose.
  say "Optional: adding '${user}' to docker group (so you can run docker without sudo later)..."

  # Create docker group if it doesn't exist yet (safe)
  run_root groupadd -f docker

  # Add user (safe)
  run_root usermod -aG docker "${user}" || true

  cat <<EOF
NOTE:
- Group membership changes take effect after logout/login (or new shell).
- Installer uses sudo for docker commands, so this does NOT block installation.
EOF
}

write_env() {
  local envfile="${ROOT_DIR}/.env"

  say "Collecting configuration..."
  local stack_user
  prompt stack_user "unifi" "UNIX user that will own UniFi data (must exist)"

  if ! id "${stack_user}" >/dev/null 2>&1; then
    echo "ERROR: user '${stack_user}' does not exist. Create it, then rerun." >&2
    exit 1
  fi

  local puid pgid
  puid="$(id -u "${stack_user}")"
  pgid="$(id -g "${stack_user}")"

  STACK_USER="${stack_user}"
  STACK_UID="${puid}"
  STACK_GID="${pgid}"
  STACK_HOME="$(getent passwd "${STACK_USER}" | cut -d: -f6)"
  
  local bind_ip tz
  prompt bind_ip "0.0.0.0" "Bind services to IP (0.0.0.0 = all interfaces)"
  prompt tz "America/Chicago" "Timezone"

  # Ports
  local https_port inform_port stun_port discovery_port guest_https_port guest_http_port
  prompt https_port "8443" "UniFi HTTPS port"
  prompt inform_port "8080" "UniFi Inform port"
  prompt stun_port "3478" "UniFi STUN port (UDP)"
  prompt discovery_port "10001" "UniFi Discovery port (UDP)"
  prompt guest_https_port "8843" "Guest portal HTTPS (optional)"
  prompt guest_http_port "8880" "Guest portal HTTP (optional)"

  # Mongo creds
  local mongo_root_pass mongo_pass
  mongo_root_pass="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(18))
PY
)"
  mongo_pass="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(18))
PY
)"

  local use_defaults
  confirm use_defaults "y" "Auto-generate Mongo passwords? (recommended)"
  if [[ "${use_defaults}" == "n" ]]; then
    prompt mongo_root_pass "unifi" "Mongo ROOT password (init only)"
    prompt mongo_pass "unifi" "Mongo app user password"
  fi

  cat > "${envfile}" <<EOF
BIND_IP=${bind_ip}
PUID=${puid}
PGID=${pgid}
TZ=${tz}

UNIFI_IMAGE_TAG=10.0.162-ls113
MONGO_IMAGE_TAG=8

MONGO_INITDB_ROOT_USERNAME=root
MONGO_INITDB_ROOT_PASSWORD=${mongo_root_pass}

MONGO_USER=unifi
MONGO_PASS=${mongo_pass}

MONGO_DBNAME=unifi
MONGO_DB_STAT=unifi_stat
MONGO_DB_AUDIT=unifi_audit
MONGO_AUTHSOURCE=admin

UNIFI_HTTPS_PORT=${https_port}
UNIFI_INFORM_PORT=${inform_port}
UNIFI_STUN_PORT=${stun_port}
UNIFI_DISCOVERY_PORT=${discovery_port}
UNIFI_GUEST_HTTPS_PORT=${guest_https_port}
UNIFI_GUEST_HTTP_PORT=${guest_http_port}
EOF

  say "Wrote ${envfile}"
  echo "  Stack user: ${stack_user} (PUID=${puid}, PGID=${pgid})"
  echo "  Bind IP:    ${bind_ip}"
}

fetch_if_missing() {
  local rel="$1"
  local url_base="${REPO_RAW_BASE:-$REPO_RAW_BASE_DEFAULT}"
  local dst="${ROOT_DIR}/${rel}"

  if [[ -f "${dst}" ]]; then
    return 0
  fi

  say "Missing ${rel} — downloading from repo..."
  run_root mkdir -p "$(dirname "${dst}")"
  run_root curl -fsSL "${url_base}/${rel}" -o "${dst}"
}

fetch_template() {
  say "Ensuring UniFi template exists in: ${ROOT_DIR}"

  # 1) Directories
  for d in "${TEMPLATE_DIRS[@]}"; do
    run_root mkdir -p "${ROOT_DIR}/${d}"
  done

  # 2) Required files (fail hard if any cannot be fetched)
  for f in "${TEMPLATE_FILES_REQUIRED[@]}"; do
    fetch_if_missing "${f}"
  done

  # 3) Optional files (best-effort)
  for f in "${TEMPLATE_FILES_OPTIONAL[@]}"; do
    fetch_if_missing "${f}" || true
  done

  # 4) Executable bits (best-effort)
  run_root chmod +x "${ROOT_DIR}/backup.sh" "${ROOT_DIR}/restore.sh" 2>/dev/null || true
  run_root chmod +x "${ROOT_DIR}/scripts/"*.sh 2>/dev/null || true
}

apply_ownership() {
  say "Applying ownership for UniFi stack files..."

  local puid="${STACK_UID:-}"
  local pgid="${STACK_GID:-}"

  # Fallback: read from .env if needed
  if [[ -z "${puid}" || -z "${pgid}" ]]; then
    if [[ -f "${ROOT_DIR}/.env" ]]; then
      puid="$(grep -E '^PUID=' "${ROOT_DIR}/.env" | cut -d= -f2 || true)"
      pgid="$(grep -E '^PGID=' "${ROOT_DIR}/.env" | cut -d= -f2 || true)"
    fi
  fi

  if [[ -z "${puid}" || -z "${pgid}" ]]; then
    echo "WARN: Cannot determine PUID/PGID; skipping ownership changes." >&2
    return 0
  fi

  say "  Ownership: ${puid}:${pgid}"

  local target

  # .env file
  [[ -e "${ROOT_DIR}/.env" ]] && run_root chown "${puid}:${pgid}" "${ROOT_DIR}/.env" || true
  
  # install.sh and current directory
  run_root chown "${puid}:${pgid}" "${ROOT_DIR}/install.sh" 2>/dev/null || true
	##run_root chown "${puid}:${pgid}" "${ROOT_DIR}" 2>/dev/null || true
	
  # Directories (recursive)
  for target in "${TEMPLATE_DIRS[@]}"; do
    [[ -e "${ROOT_DIR}/${target}" ]] || continue
    run_root chown -R "${puid}:${pgid}" "${ROOT_DIR}/${target}" || true
  done

  # Files (non-recursive)
  for target in "${TEMPLATE_FILES_REQUIRED[@]}" "${TEMPLATE_FILES_OPTIONAL[@]}"; do
    [[ -e "${ROOT_DIR}/${target}" ]] || continue
    run_root chown "${puid}:${pgid}" "${ROOT_DIR}/${target}" || true
  done
}

bring_up() {
  say "Starting stack..."
  ( cd "${ROOT_DIR}" && run_root docker compose up -d )

  say "Stack status:"
  ( cd "${ROOT_DIR}" && run_root docker compose ps )

  say "Quick local checks (may take 30-90 seconds on first boot)..."
  sleep 5
  set +e
  curl -kfsS --max-time 5 "https://127.0.0.1:8443" >/dev/null
  local rc1=$?
  curl -fsS --max-time 5 "http://127.0.0.1:8080/inform" >/dev/null
  local rc2=$?
  set -e

  if [[ $rc1 -ne 0 ]]; then
    echo "NOTE: 8443 not responding yet. Check logs if it stays down:" >&2
    echo "  docker logs --tail 120 unifi-network" >&2
  fi
  if [[ $rc2 -ne 0 ]]; then
    echo "NOTE: 8080 /inform not responding yet. Check logs if it stays down." >&2
  fi
}

certbot_optional() {
  local do_certbot
  confirm do_certbot "n" "Enable certbot (DNS-01 / Cloudflare) setup now?"
  if [[ "${do_certbot}" == "n" ]]; then
    say "Skipping certbot."
    return
  fi

  need_sudo

  # Install snapd/certbot only if needed
  if ! have certbot; then
    say "Installing snapd + certbot..."
    run_root apt-get update -y
    run_root apt-get install -y snapd
    run_root snap install core || true
    run_root snap refresh core || true
    run_root snap install --classic certbot
  else
    say "certbot already installed; skipping install."
  fi

  # Cloudflare DNS plugin (required for DNS-01 automation with Cloudflare)
  if ! certbot plugins 2>/dev/null | grep -qi 'dns-cloudflare'; then
    local install_cf
    confirm install_cf "y" "Install Cloudflare DNS plugin (certbot-dns-cloudflare) via snap?"
    if [[ "${install_cf}" == "y" ]]; then
      say "Installing certbot-dns-cloudflare..."
      run_root snap set certbot trust-plugin-with-root=ok
      run_root snap install certbot-dns-cloudflare
    fi
  else
    say "certbot-dns-cloudflare plugin already present."
  fi

  cat <<'EOF'

DNS-01 note:
- This installer supports DNS-01 (Cloudflare) but does NOT automatically request a new cert by default.
- Your UniFi deploy helper is:
    ./scripts/unifi-cert-deploy.sh

To actually issue/renew:
- You need an existing certbot renewal config OR you need to run certbot certonly once.
- Once renewal works, you can run:
    certbot renew --run-deploy-hooks

EOF

  # Optional end-to-end test: renew dry-run + deploy hook
  local do_test
  confirm do_test "n" "Run certbot renew --dry-run and execute deploy hooks (if configured)?"
  if [[ "${do_test}" == "n" ]]; then
    say "Skipping certbot dry-run test."
    return
  fi

  say "Running: certbot renew --dry-run --run-deploy-hooks"
  say "NOTE: This will only fully test deployment if a renewal config already exists."
  run_root certbot renew --dry-run --run-deploy-hooks || {
    echo "ERROR: certbot dry-run failed." >&2
    echo "If this is a fresh box, you likely need to run 'certbot certonly' once to create the renewal config." >&2
    return 1
  }

  say "Certbot dry-run + deploy hooks completed."
}

main() {
  say "UniFi Controller Stack Installer"
  echo "Working directory: ${ROOT_DIR}"
  
  # preflight check
  preflight

  # Is Docker installed and running?
  ensure_docker

  # Make sure we have docker-compose.yml + scripts in place from repo
  fetch_template
  
  # Now collect config and write .env
  write_env

  # Ensure docker group membership for the current user (or they will need sudo for docker)
  ensure_user_in_docker_group_optional "${STACK_USER}"
  
  # Apply ownership to stack directories/files
  apply_ownership

  # Optional (TODO) certbot installation for SSL via DNS-01 (Cloudflare)
  certbot_optional

  # Now start the Unifi OS Server stack
  bring_up

  say "Done ✅"
  echo "Open:"
  echo "  https://<server-ip>:8443"
  echo "Inform:"
  echo "  http://<server-ip>:8080/inform"
}

main "$@"