#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Wazuh - Standalone / Coexistence-Friendly Docker Installer
# ==============================================================================
# Preferred design:
#   Run Wazuh on its own dedicated server/VM.
#
# Shared-host fallback:
#   If this is the only Docker server available, this installer keeps Wazuh
#   completely separate from the existing Master Docker Monitoring and
#   TacticalRMM stacks.
#
# It NEVER modifies:
#   /opt/master-docker
#   /opt/tacticalrmm
#
# Wazuh installation root:
#   /opt/wazuh
# ==============================================================================

WAZUH_VERSION="${WAZUH_VERSION:-4.14.7}"
APP_ROOT="${APP_ROOT:-/opt/wazuh}"
SOURCE_DIR="${APP_ROOT}/wazuh-docker"
STACK_DIR="${SOURCE_DIR}/single-node"
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
CERT_COMPOSE="${STACK_DIR}/generate-indexer-certs.yml"
ENV_FILE="${APP_ROOT}/.env"
LOG_FILE="${LOG_FILE:-/var/log/wazuh-bootstrap.log}"
PROJECT_NAME="${PROJECT_NAME:-wazuh}"

# Dashboard intentionally defaults to 8444 so it can coexist with TacticalRMM
# or another service already using host TCP/443.
WAZUH_DASHBOARD_PORT="${WAZUH_DASHBOARD_PORT:-8444}"

WAZUH_AGENT_PORT="${WAZUH_AGENT_PORT:-1514}"
WAZUH_ENROLLMENT_PORT="${WAZUH_ENROLLMENT_PORT:-1515}"
WAZUH_SYSLOG_PORT="${WAZUH_SYSLOG_PORT:-514}"
WAZUH_API_PORT="${WAZUH_API_PORT:-55000}"
WAZUH_INDEXER_PORT="${WAZUH_INDEXER_PORT:-9200}"

REPO_URL="${REPO_URL:-https://github.com/wazuh/wazuh-docker.git}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run with sudo/root."
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

install_prereqs_and_docker() {
  say "Installing/validating prerequisites"

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg git openssl iproute2 rsync tar

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    say "Docker Engine and Docker Compose already installed; preserving existing Docker environment"
    systemctl enable --now docker >/dev/null 2>&1 || true
    return
  fi

  say "Installing Docker Engine and Docker Compose"

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

configure_sysctl() {
  say "Configuring Wazuh indexer kernel requirement"

  cat >/etc/sysctl.d/99-wazuh.conf <<EOF
vm.max_map_count=262144
EOF

  sysctl -w vm.max_map_count=262144 >/dev/null

  local current
  current="$(sysctl -n vm.max_map_count)"
  [[ "$current" -ge 262144 ]] || die "vm.max_map_count could not be set to 262144."
  echo "vm.max_map_count=${current}"
}

tcp_port_in_use() {
  local port="$1"
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
}

udp_port_in_use() {
  local port="$1"
  ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"
}

wazuh_project_exists() {
  docker ps -a \
    --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
    --format '{{.Names}}' 2>/dev/null | grep -q .
}

check_ports() {
  if wazuh_project_exists; then
    say "Existing Wazuh Compose project detected; skipping fresh host-port checks"
    return
  fi

  local conflicts=()

  tcp_port_in_use "$WAZUH_DASHBOARD_PORT" && conflicts+=("TCP ${WAZUH_DASHBOARD_PORT} (dashboard)")
  tcp_port_in_use "$WAZUH_AGENT_PORT" && conflicts+=("TCP ${WAZUH_AGENT_PORT} (agent traffic)")
  tcp_port_in_use "$WAZUH_ENROLLMENT_PORT" && conflicts+=("TCP ${WAZUH_ENROLLMENT_PORT} (agent enrollment)")
  tcp_port_in_use "$WAZUH_API_PORT" && conflicts+=("TCP ${WAZUH_API_PORT} (Wazuh API)")
  tcp_port_in_use "$WAZUH_INDEXER_PORT" && conflicts+=("TCP ${WAZUH_INDEXER_PORT} (indexer API)")
  udp_port_in_use "$WAZUH_SYSLOG_PORT" && conflicts+=("UDP ${WAZUH_SYSLOG_PORT} (syslog)")

  if ((${#conflicts[@]})); then
    printf '\nConflicting host ports:\n' >&2
    printf '  - %s\n' "${conflicts[@]}" >&2
    echo >&2
    die "Wazuh was not started. Resolve the conflict or deliberately override the corresponding WAZUH_*_PORT variable."
  fi
}

prepare_root() {
  say "Preparing ${APP_ROOT}"
  mkdir -p "$APP_ROOT" "${APP_ROOT}/backups"
  chmod 755 /opt "$APP_ROOT"
}

clone_wazuh() {
  if [[ -d "${SOURCE_DIR}/.git" ]]; then
    say "Existing Wazuh source tree detected; preserving it"
    local current_tag
    current_tag="$(git -C "$SOURCE_DIR" describe --tags --exact-match 2>/dev/null || true)"
    if [[ -n "$current_tag" && "$current_tag" != "v${WAZUH_VERSION}" ]]; then
      warn "Existing source is ${current_tag}; requested version is v${WAZUH_VERSION}."
      warn "Installer will NOT silently upgrade an existing Wazuh deployment."
    fi
    return
  fi

  if [[ -e "$SOURCE_DIR" ]]; then
    die "${SOURCE_DIR} exists but is not a Git repository. Refusing to overwrite it."
  fi

  say "Cloning Wazuh Docker v${WAZUH_VERSION}"
  git clone --depth 1 --branch "v${WAZUH_VERSION}" "$REPO_URL" "$SOURCE_DIR"
}

write_env() {
  if [[ -s "$ENV_FILE" ]]; then
    say "Preserving existing ${ENV_FILE}"
    return
  fi

  umask 077
  cat >"$ENV_FILE" <<EOF
WAZUH_VERSION=${WAZUH_VERSION}
WAZUH_DASHBOARD_PORT=${WAZUH_DASHBOARD_PORT}
WAZUH_AGENT_PORT=${WAZUH_AGENT_PORT}
WAZUH_ENROLLMENT_PORT=${WAZUH_ENROLLMENT_PORT}
WAZUH_SYSLOG_PORT=${WAZUH_SYSLOG_PORT}
WAZUH_API_PORT=${WAZUH_API_PORT}
WAZUH_INDEXER_PORT=${WAZUH_INDEXER_PORT}
EOF
  chmod 600 "$ENV_FILE"
}

patch_compose_ports() {
  [[ -s "$COMPOSE_FILE" ]] || die "Missing ${COMPOSE_FILE}"

  # Save the pristine upstream file exactly once.
  if [[ ! -s "${COMPOSE_FILE}.upstream" ]]; then
    cp -a "$COMPOSE_FILE" "${COMPOSE_FILE}.upstream"
  fi

  # shellcheck disable=SC1090
  source "$ENV_FILE"

  say "Applying coexistence-friendly host port mappings"

  python3 - "$COMPOSE_FILE" \
    "$WAZUH_AGENT_PORT" \
    "$WAZUH_ENROLLMENT_PORT" \
    "$WAZUH_SYSLOG_PORT" \
    "$WAZUH_API_PORT" \
    "$WAZUH_INDEXER_PORT" \
    "$WAZUH_DASHBOARD_PORT" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
agent, enroll, syslog, api, indexer, dashboard = sys.argv[2:]
text = path.read_text()

replacements = {
    r'(?m)^\s*-\s*["\']?1514:1514["\']?\s*$': f'      - "{agent}:1514"',
    r'(?m)^\s*-\s*["\']?1515:1515["\']?\s*$': f'      - "{enroll}:1515"',
    r'(?m)^\s*-\s*["\']?514:514/udp["\']?\s*$': f'      - "{syslog}:514/udp"',
    r'(?m)^\s*-\s*["\']?55000:55000["\']?\s*$': f'      - "{api}:55000"',
    r'(?m)^\s*-\s*["\']?9200:9200["\']?\s*$': f'      - "{indexer}:9200"',
    r'(?m)^\s*-\s*["\']?443:5601["\']?\s*$': f'      - "{dashboard}:5601"',
}

for pattern, repl in replacements.items():
    text, count = re.subn(pattern, repl, text)
    if count != 1:
        raise SystemExit(f"Expected exactly one match for {pattern!r}, found {count}")

path.write_text(text)
PY
}

generate_certificates_if_needed() {
  local cert_dir="${STACK_DIR}/config/wazuh_indexer_ssl_certs"

  if [[ -s "${cert_dir}/root-ca.pem" && -s "${cert_dir}/wazuh.indexer.pem" && -s "${cert_dir}/wazuh.dashboard.pem" ]]; then
    say "Existing Wazuh certificates detected; preserving them"
    return
  fi

  say "Generating Wazuh indexer/manager/dashboard certificates"
  cd "$STACK_DIR"
  docker compose -f "$CERT_COMPOSE" run --rm generator
}

validate_compose() {
  say "Validating Wazuh Compose configuration"
  cd "$STACK_DIR"
  docker compose --project-name "$PROJECT_NAME" -f "$COMPOSE_FILE" config >/dev/null
  echo "Compose validation: OK"
}

write_helper() {
  cat >/usr/local/sbin/wazuh-stack <<EOF
#!/usr/bin/env bash
set -e
cd "${STACK_DIR}"
exec docker compose --project-name "${PROJECT_NAME}" -f "${COMPOSE_FILE}" "\$@"
EOF
  chmod 755 /usr/local/sbin/wazuh-stack
}

write_backup_helper() {
  cat >/usr/local/sbin/wazuh-backup <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="/opt/wazuh"
STACK_DIR="${APP_ROOT}/wazuh-docker/single-node"
PROJECT_NAME="wazuh"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${APP_ROOT}/backups/${STAMP}"

[[ "${EUID}" -eq 0 ]] || { echo "Run with sudo/root."; exit 1; }

mkdir -p "${DEST}/volumes"

echo "This creates a COLD Wazuh backup and temporarily stops only the Wazuh Compose project."
read -r -p "Continue? [y/N]: " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 0

cd "$STACK_DIR"

docker compose --project-name "$PROJECT_NAME" down

restart_stack() {
  docker compose --project-name "$PROJECT_NAME" up -d || true
}
trap restart_stack EXIT

tar -C "$APP_ROOT" \
  --exclude='./backups' \
  -czf "${DEST}/wazuh-opt-config.tar.gz" .

mapfile -t volumes < <(
  docker volume ls \
    --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
    --format '{{.Name}}'
)

for volume in "${volumes[@]}"; do
  echo "Backing up Docker volume: ${volume}"
  docker run --rm \
    -v "${volume}:/source:ro" \
    -v "${DEST}/volumes:/backup" \
    alpine:3.22 \
    sh -c "cd /source && tar czf /backup/${volume}.tar.gz ."
done

echo "Backup complete:"
echo "  ${DEST}"
EOF
  chmod 755 /usr/local/sbin/wazuh-backup
}

set_management_permissions() {
  if [[ "$DEPLOY_USER" != "root" ]]; then
    chown "$DEPLOY_USER:$DEPLOY_GROUP" "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
}

start_stack() {
  say "Pulling Wazuh v${WAZUH_VERSION} images"
  cd "$STACK_DIR"
  docker compose --project-name "$PROJECT_NAME" -f "$COMPOSE_FILE" pull

  say "Starting Wazuh only; existing Docker stacks are not modified"
  docker compose --project-name "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d
}

show_summary() {
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ip" ]] || ip="SERVER-IP"

  cat <<EOF

==============================================================================
 WAZUH DOCKER INSTALL COMPLETE
==============================================================================

Preferred architecture:
  Wazuh should normally run on its OWN dedicated VM/server.

Shared-host mode:
  This deployment remains a completely separate Docker Compose project and does
  not modify /opt/master-docker or /opt/tacticalrmm.

Wazuh Dashboard:
  https://${ip}:${WAZUH_DASHBOARD_PORT}

Dashboard host port:
  ${WAZUH_DASHBOARD_PORT}

Agent traffic:
  TCP ${WAZUH_AGENT_PORT}

Agent enrollment:
  TCP ${WAZUH_ENROLLMENT_PORT}

Syslog:
  UDP ${WAZUH_SYSLOG_PORT}

Wazuh API:
  TCP ${WAZUH_API_PORT}

Indexer API:
  TCP ${WAZUH_INDEXER_PORT}

Management:
  wazuh-stack ps
  wazuh-stack logs --tail=100
  wazuh-stack logs -f
  wazuh-stack pull
  wazuh-stack up -d
  wazuh-stack down

Cold backup helper:
  sudo wazuh-backup

IMPORTANT:
  This installer pins Wazuh to v${WAZUH_VERSION}.
  Re-running it preserves the existing Wazuh source/configuration/certificates
  and does not silently upgrade an installed Wazuh deployment.

Application root:
  ${APP_ROOT}

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
  install_prereqs_and_docker
  configure_sysctl
  prepare_root
  check_ports
  clone_wazuh
  write_env
  patch_compose_ports
  generate_certificates_if_needed
  validate_compose
  write_helper
  write_backup_helper
  set_management_permissions
  start_stack

  say "Wazuh container status"
  wazuh-stack ps

  show_summary
}

main "$@"
