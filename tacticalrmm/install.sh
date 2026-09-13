#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# TacticalRMM - Standalone / Coexistence-Friendly Docker Installer
# ==============================================================================
# Goals:
#   - Prefer a dedicated server/VM for TacticalRMM.
#   - If installed on an existing Docker host (for example the Master Docker
#     Monitoring server), do NOT modify /opt/master-docker or its Compose stack.
#   - Preserve an existing /opt/tacticalrmm installation on re-runs.
#   - Use TacticalRMM's upstream Docker Compose file and keep this deployment
#     in its own Compose project, lifecycle, volumes and helper command.
#
# IMPORTANT:
# TacticalRMM upstream currently considers Docker installs unsupported for
# production. Their supported install expects a fresh dedicated VM/server.
# This installer intentionally uses Docker only to make coexistence possible.
# ==============================================================================

APP_ROOT="${APP_ROOT:-/opt/tacticalrmm}"
COMPOSE_FILE="${APP_ROOT}/compose.yml"
ENV_FILE="${APP_ROOT}/.env"
UPSTREAM_COMPOSE_URL="${UPSTREAM_COMPOSE_URL:-https://raw.githubusercontent.com/amidaware/tacticalrmm/master/docker/docker-compose.yml}"
LOG_FILE="${LOG_FILE:-/var/log/tacticalrmm-bootstrap.log}"
PROJECT_NAME="${PROJECT_NAME:-tacticalrmm}"

TRMM_HTTP_PORT="${TRMM_HTTP_PORT:-80}"
TRMM_HTTPS_PORT="${TRMM_HTTPS_PORT:-443}"
TRMM_DOCKER_SUBNET="${TRMM_DOCKER_SUBNET:-172.31.240.0/24}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run with sudo/root."
}

random_secret() {
  openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-'
}

detect_deploy_user() {
  if [[ -n "${DEPLOY_USER:-}" ]]; then
    :
  elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    DEPLOY_USER="$SUDO_USER"
  else
    DEPLOY_USER="$(logname 2>/dev/null || true)"
    [[ -n "$DEPLOY_USER" ]] || DEPLOY_USER="root"
  fi

  DEPLOY_GROUP="$(id -gn "$DEPLOY_USER" 2>/dev/null || echo "$DEPLOY_USER")"
}

check_os() {
  [[ -f /etc/os-release ]] || die "/etc/os-release not found."
  # shellcheck disable=SC1091
  source /etc/os-release

  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "This installer expects Ubuntu or Debian. Detected: ${ID:-unknown}" ;;
  esac

  say "Detected ${PRETTY_NAME:-$ID}"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    say "Docker Engine and Docker Compose already installed; preserving existing Docker environment"
    systemctl enable --now docker >/dev/null 2>&1 || true
    return
  fi

  say "Installing Docker Engine and Docker Compose"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg openssl iproute2

  install -m 0755 -d /etc/apt/keyrings

  if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL "https://download.docker.com/linux/${ID}" \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  local codename
  codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  [[ -n "$codename" ]] || die "Could not determine OS codename for Docker repository."

  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker

  if [[ "$DEPLOY_USER" != "root" ]]; then
    usermod -aG docker "$DEPLOY_USER" || true
  fi
}

port_in_use() {
  local port="$1"
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
}

check_ports() {
  # If our own TRMM nginx container already exists, a re-run is allowed.
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'trmm-nginx'; then
    say "Existing TacticalRMM container detected; skipping fresh port ownership check"
    return
  fi

  if port_in_use "$TRMM_HTTP_PORT"; then
    die "TCP port ${TRMM_HTTP_PORT} is already in use. TacticalRMM needs its HTTP listener. Set TRMM_HTTP_PORT to an unused port only if you understand the impact."
  fi

  if port_in_use "$TRMM_HTTPS_PORT"; then
    die "TCP port ${TRMM_HTTPS_PORT} is already in use. TacticalRMM normally needs HTTPS/443. Resolve the conflict before continuing."
  fi
}

validate_subnet() {
  [[ "$TRMM_DOCKER_SUBNET" =~ ^([0-9]{1,3}\.){3}0/24$ ]] \
    || die "TRMM_DOCKER_SUBNET must be an IPv4 /24 ending in .0/24 (example 172.31.240.0/24)."

  local network_subnets
  network_subnets="$(
    docker network ls -q 2>/dev/null | xargs -r docker network inspect \
      --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null || true
  )"

  if grep -qx "$TRMM_DOCKER_SUBNET" <<<"$network_subnets"; then
    # Existing Tactical project may own it, which is fine.
    if ! docker network ls --format '{{.Name}}' | grep -q "^${PROJECT_NAME}_proxy$"; then
      die "Docker subnet ${TRMM_DOCKER_SUBNET} is already in use. Re-run with a different TRMM_DOCKER_SUBNET."
    fi
  fi
}

prepare_root() {
  say "Preparing ${APP_ROOT}"
  mkdir -p "$APP_ROOT"
  chmod 755 /opt "$APP_ROOT"

  if [[ -s "$ENV_FILE" || -s "$COMPOSE_FILE" ]]; then
    say "Existing TacticalRMM files detected; preserving them"
  fi
}

valid_hostname() {
  local h="$1"
  [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] &&
  [[ "$h" == *.* ]] &&
  [[ "$h" != *"_"* ]]
}

prompt_value() {
  local var_name="$1" prompt="$2" default="${3:-}" secret="${4:-0}"
  local current="${!var_name:-}" value

  if [[ -n "$current" ]]; then
    return
  fi

  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    [[ -n "$default" ]] || die "${var_name} is required in NONINTERACTIVE mode."
    printf -v "$var_name" '%s' "$default"
    return
  fi

  if [[ "$secret" == "1" ]]; then
    read -r -s -p "${prompt}: " value
    echo
  elif [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " value
    value="${value:-$default}"
  else
    read -r -p "${prompt}: " value
  fi

  printf -v "$var_name" '%s' "$value"
}

collect_settings() {
  # Existing .env always wins; never replace credentials/settings on a re-run.
  if [[ -s "$ENV_FILE" ]]; then
    say "Preserving existing TacticalRMM .env"
    return
  fi

  say "Collecting TacticalRMM settings"

  prompt_value TRMM_ROOT_DOMAIN "Base DNS domain (example: example.com)" "${TRMM_ROOT_DOMAIN:-}"
  [[ "$TRMM_ROOT_DOMAIN" == *.* ]] || die "Enter a valid base DNS domain."

  APP_HOST="${APP_HOST:-rmm.${TRMM_ROOT_DOMAIN}}"
  API_HOST="${API_HOST:-api.${TRMM_ROOT_DOMAIN}}"
  MESH_HOST="${MESH_HOST:-mesh.${TRMM_ROOT_DOMAIN}}"

  valid_hostname "$APP_HOST" || die "Invalid APP_HOST: ${APP_HOST}"
  valid_hostname "$API_HOST" || die "Invalid API_HOST: ${API_HOST}"
  valid_hostname "$MESH_HOST" || die "Invalid MESH_HOST: ${MESH_HOST}"

  TRMM_USER="${TRMM_USER:-tactical}"
  TRMM_PASS="${TRMM_PASS:-$(random_secret)}"
  MESH_USER="${MESH_USER:-tactical}"
  MESH_PASS="${MESH_PASS:-$(random_secret)}"
  MONGODB_USER="${MONGODB_USER:-mongouser}"
  MONGODB_PASSWORD="${MONGODB_PASSWORD:-$(random_secret)}"
  POSTGRES_USER="${POSTGRES_USER:-postgres}"
  POSTGRES_PASS="${POSTGRES_PASS:-$(random_secret)}"

  CERT_PUB_KEY=""
  CERT_PRIV_KEY=""

  if [[ -n "${TRMM_CERT_FULLCHAIN:-}" || -n "${TRMM_CERT_PRIVKEY:-}" ]]; then
    [[ -f "${TRMM_CERT_FULLCHAIN:-}" ]] || die "TRMM_CERT_FULLCHAIN does not exist."
    [[ -f "${TRMM_CERT_PRIVKEY:-}" ]] || die "TRMM_CERT_PRIVKEY does not exist."
    CERT_PUB_KEY="$(base64 -w 0 "$TRMM_CERT_FULLCHAIN")"
    CERT_PRIV_KEY="$(base64 -w 0 "$TRMM_CERT_PRIVKEY")"
  elif [[ "${ALLOW_SELF_SIGNED:-0}" != "1" ]]; then
    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
      die "Provide TRMM_CERT_FULLCHAIN and TRMM_CERT_PRIVKEY, or explicitly set ALLOW_SELF_SIGNED=1."
    fi

    echo
    echo "TacticalRMM Docker works best with a valid trusted wildcard certificate."
    echo "Expected coverage: *.${TRMM_ROOT_DOMAIN}"
    read -r -p "Full-chain certificate path (leave blank to use TacticalRMM self-signed certificates): " TRMM_CERT_FULLCHAIN

    if [[ -n "$TRMM_CERT_FULLCHAIN" ]]; then
      read -r -p "Private-key path: " TRMM_CERT_PRIVKEY
      [[ -f "$TRMM_CERT_FULLCHAIN" ]] || die "Certificate file not found."
      [[ -f "$TRMM_CERT_PRIVKEY" ]] || die "Private key file not found."
      CERT_PUB_KEY="$(base64 -w 0 "$TRMM_CERT_FULLCHAIN")"
      CERT_PRIV_KEY="$(base64 -w 0 "$TRMM_CERT_PRIVKEY")"
    else
      warn "Proceeding without a trusted certificate. TacticalRMM documentation warns most agent functions will not work correctly with self-signed certificates."
      read -r -p "Type SELF-SIGNED to continue: " confirm
      [[ "$confirm" == "SELF-SIGNED" ]] || die "Installation cancelled."
    fi
  else
    warn "ALLOW_SELF_SIGNED=1 was supplied. No trusted certificate will be configured."
  fi

  umask 077
  cat >"$ENV_FILE" <<EOF
IMAGE_REPO=tacticalrmm/
VERSION=latest

TRMM_USER=${TRMM_USER}
TRMM_PASS=${TRMM_PASS}

TRMM_HTTP_PORT=${TRMM_HTTP_PORT}
TRMM_HTTPS_PORT=${TRMM_HTTPS_PORT}

APP_HOST=${APP_HOST}
API_HOST=${API_HOST}
MESH_HOST=${MESH_HOST}

CSRF_COOKIE_DOMAIN=${TRMM_ROOT_DOMAIN}
SESSION_COOKIE_DOMAIN=${TRMM_ROOT_DOMAIN}

MESH_USER=${MESH_USER}
MESH_PASS=${MESH_PASS}
MONGODB_USER=${MONGODB_USER}
MONGODB_PASSWORD=${MONGODB_PASSWORD}
MESH_PERSISTENT_CONFIG=1

POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASS=${POSTGRES_PASS}

TRMM_DISABLE_WEB_TERMINAL=True
TRMM_DISABLE_SERVER_SCRIPTS=True
TRMM_DISABLE_SSO=False

CERT_PUB_KEY=${CERT_PUB_KEY}
CERT_PRIV_KEY=${CERT_PRIV_KEY}
EOF

  chmod 600 "$ENV_FILE"
}

create_compose() {
  if [[ -s "$COMPOSE_FILE" ]]; then
    say "Preserving existing TacticalRMM compose.yml"
    return
  fi

  say "Downloading TacticalRMM upstream Docker Compose"
  curl -fsSL "$UPSTREAM_COMPOSE_URL" -o "${COMPOSE_FILE}.tmp"

  # The upstream file currently hard-codes 172.20.0.0/24 and 172.20.0.20.
  # Patch only those two network values so this standalone project is less
  # likely to overlap an existing Docker host.
  local base fixed_ip
  base="${TRMM_DOCKER_SUBNET%0/24}"
  fixed_ip="${base}20"

  sed \
    -e "s#subnet: 172\\.20\\.0\\.0/24#subnet: ${TRMM_DOCKER_SUBNET}#" \
    -e "s#ipv4_address: 172\\.20\\.0\\.20#ipv4_address: ${fixed_ip}#" \
    "${COMPOSE_FILE}.tmp" >"$COMPOSE_FILE"

  rm -f "${COMPOSE_FILE}.tmp"
  chmod 644 "$COMPOSE_FILE"
}

set_permissions() {
  if [[ "$DEPLOY_USER" != "root" ]]; then
    chown "$DEPLOY_USER:$DEPLOY_GROUP" "$COMPOSE_FILE" "$ENV_FILE"
  fi
  chmod 644 "$COMPOSE_FILE"
  chmod 600 "$ENV_FILE"
}

validate_compose() {
  say "Validating TacticalRMM Compose configuration"
  docker compose \
    --project-name "$PROJECT_NAME" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" config >/dev/null
  echo "Compose validation: OK"
}

write_helper() {
  cat >/usr/local/sbin/tacticalrmm <<EOF
#!/usr/bin/env bash
set -e
cd "${APP_ROOT}"
exec docker compose --project-name "${PROJECT_NAME}" --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "\$@"
EOF
  chmod 755 /usr/local/sbin/tacticalrmm
}

start_stack() {
  say "Pulling TacticalRMM images"
  docker compose \
    --project-name "$PROJECT_NAME" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" pull

  say "Starting TacticalRMM without touching other Docker Compose projects"
  docker compose \
    --project-name "$PROJECT_NAME" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" up -d
}

show_summary() {
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  cat <<EOF

==============================================================================
 TACTICALRMM DOCKER INSTALL COMPLETE
==============================================================================

Application directory:
  ${APP_ROOT}

TacticalRMM:
  https://${APP_HOST}

API:
  https://${API_HOST}

MeshCentral:
  https://${MESH_HOST}

Initial TacticalRMM username:
  ${TRMM_USER}

The generated TacticalRMM password is stored in:
  ${ENV_FILE}

View only the login value locally:
  sudo grep '^TRMM_PASS=' ${ENV_FILE}

Management commands:
  tacticalrmm ps
  tacticalrmm logs --tail=100
  tacticalrmm logs -f
  tacticalrmm pull
  tacticalrmm up -d
  tacticalrmm down

COEXISTENCE:
  This deployment is intentionally separate from:
    /opt/master-docker

  It does not add itself to the monitoring stack's compose.yml and does not
  restart Zabbix, phpIPAM, Grafana or Uptime Kuma.

BACKUP:
  TacticalRMM's upstream Docker Compose uses Docker-managed named volumes.
  Back up the TacticalRMM Docker volumes plus:
    ${APP_ROOT}

IMPORTANT:
  TacticalRMM's documentation currently labels Docker installs unsupported for
  production and recommends a fresh dedicated VM/server for the supported
  installation method.

Installer log:
  ${LOG_FILE}

==============================================================================
EOF
}

main() {
  require_root

  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap 'echo; echo "ERROR: Installer stopped on line $LINENO. Review '"$LOG_FILE"'."' ERR

  detect_deploy_user
  check_os
  install_docker
  prepare_root
  check_ports
  validate_subnet
  collect_settings
  create_compose
  set_permissions
  validate_compose
  write_helper
  start_stack

  say "TacticalRMM container status"
  docker compose \
    --project-name "$PROJECT_NAME" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" ps

  show_summary
}

main "$@"
