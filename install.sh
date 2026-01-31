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
  if [[ "$(id -u)" -ne 0 ]]; then
    have sudo || { echo "ERROR: sudo not found and not running as root." >&2; exit 1; }
  fi
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
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
  say "Ensuring user '${user}' is in the docker group..."
  run_root groupadd -f docker
  run_root usermod -aG docker "${user}" || true
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

ensure_dirs() {
  say "Ensuring directories exist..."
  mkdir -p "${ROOT_DIR}/scripts" "${ROOT_DIR}/backups" "${ROOT_DIR}/mongo-data" "${ROOT_DIR}/unifi-data"
  # Only set ownership if we can read stack user from .env
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    local puid pgid
    puid="$(grep -E '^PUID=' "${ROOT_DIR}/.env" | cut -d= -f2 || true)"
    pgid="$(grep -E '^PGID=' "${ROOT_DIR}/.env" | cut -d= -f2 || true)"
    if [[ -n "${puid}" && -n "${pgid}" ]]; then
      run_root chown -R "${puid}:${pgid}" "${ROOT_DIR}/backups" "${ROOT_DIR}/mongo-data" "${ROOT_DIR}/unifi-data" "${ROOT_DIR}/scripts" || true
    fi
  fi
}

bring_up() {
  say "Starting stack..."
  ( cd "${ROOT_DIR}" && docker compose up -d )

  say "Stack status:"
  ( cd "${ROOT_DIR}" && docker compose ps )

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
  confirm do_certbot "n" "Install certbot via snap now?"
  if [[ "${do_certbot}" == "n" ]]; then
    say "Skipping certbot."
    return
  fi

  need_sudo
  say "Installing snapd + certbot..."
  run_root apt-get update -y
  run_root apt-get install -y snapd
  run_root snap install core || true
  run_root snap refresh core || true
  run_root snap install --classic certbot

  say "Certbot installed."
  cat <<'EOF'

DNS-01 note:
- For shared hosting / no port 80/443 access, DNS-01 is the right approach.
- If using Cloudflare, you'll typically use a Cloudflare API token + certbot-dns-cloudflare plugin.
- This installer does NOT run cert issuance automatically yet (because tokens/domains vary).
- After issuance, you can use:
    sudo DOMAIN=your.fqdn ./scripts/unifi-cert-deploy.sh
EOF
}

main() {
  say "UniFi Controller Stack Installer"
  echo "Working directory: ${ROOT_DIR}"

  ensure_docker

  # Ensure docker group membership for the current user (or they will need sudo for docker)
  ensure_user_in_docker_group "$(id -un)"

  # Create/update .env
  write_env

  ensure_dirs

  certbot_optional

  bring_up

  say "Done ✅"
  echo "Open:"
  echo "  https://<server-ip>:8443"
  echo "Inform:"
  echo "  http://<server-ip>:8080/inform"
}

main "$@"
