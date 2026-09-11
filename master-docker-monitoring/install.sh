#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Master Docker Monitoring - Universal Bootstrap
# ============================================================================
# Deploys:
#   - Zabbix 7.4 + PostgreSQL 16
#   - phpIPAM 1.8x + MariaDB 11.4
#
# Supported use cases:
#   1. Fresh Ubuntu Server installation.
#   2. Restore/migration where /opt/master-docker was copied from another
#      server, including its hidden .env files and database data.
#
# Portable application root:
#   /opt/master-docker
#
# This script intentionally NEVER recursively chowns /opt/master-docker.
# Database data directories must retain the ownership required by PostgreSQL
# and MariaDB.
# ============================================================================

APP_ROOT="${APP_ROOT:-/opt/master-docker}"
ZABBIX_DIR="${APP_ROOT}/zabbix"
PHPIPAM_DIR="${APP_ROOT}/phpipam"
MASTER_COMPOSE="${APP_ROOT}/compose.yml"
LOG_FILE="${LOG_FILE:-/var/log/master-docker-bootstrap.log}"

ZABBIX_WEB_PORT="${ZABBIX_WEB_PORT:-8080}"
PHPIPAM_WEB_PORT="${PHPIPAM_WEB_PORT:-8081}"

POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11.4}"
ZABBIX_SERVER_IMAGE="${ZABBIX_SERVER_IMAGE:-zabbix/zabbix-server-pgsql:alpine-7.4-latest}"
ZABBIX_WEB_IMAGE="${ZABBIX_WEB_IMAGE:-zabbix/zabbix-web-nginx-pgsql:alpine-7.4-latest}"
PHPIPAM_WEB_IMAGE="${PHPIPAM_WEB_IMAGE:-phpipam/phpipam-www:1.8x}"
PHPIPAM_CRON_IMAGE="${PHPIPAM_CRON_IMAGE:-phpipam/phpipam-cron:1.8x}"

# ----------------------------- helper functions ------------------------------

say() {
  printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

warn() {
  printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*" >&2
}

die() {
  printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2
  exit 1
}

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
  DEPLOY_HOME="$(getent passwd "$DEPLOY_USER" 2>/dev/null | cut -d: -f6)"
  [[ -n "$DEPLOY_HOME" ]] || DEPLOY_HOME="/root"
  HOME_COMPOSE="${DEPLOY_HOME}/compose.yml"
}

detect_timezone() {
  if [[ -n "${TZ_VALUE:-}" ]]; then
    return
  fi

  if [[ -s /etc/timezone ]]; then
    TZ_VALUE="$(tr -d '[:space:]' </etc/timezone)"
  fi

  if [[ -z "${TZ_VALUE:-}" ]] && command -v timedatectl >/dev/null 2>&1; then
    TZ_VALUE="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  fi

  TZ_VALUE="${TZ_VALUE:-UTC}"
}

check_ubuntu() {
  [[ -f /etc/os-release ]] || die "/etc/os-release not found."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu Server is required. Detected: ${ID:-unknown}"
  say "Detected Ubuntu ${VERSION_ID:-unknown} (${VERSION_CODENAME:-unknown})"
}

dir_has_data() {
  local d="$1"
  [[ -d "$d" ]] && find "$d" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}

random_secret() {
  openssl rand -hex 32
}

port_in_use() {
  local port="$1"
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
}

check_ports_for_fresh_build() {
  # If our own Compose files already exist, this may be a restore/re-run and
  # the existing containers may legitimately own these ports.
  if [[ ! -s "$MASTER_COMPOSE" ]]; then
    if port_in_use "$ZABBIX_WEB_PORT"; then
      die "TCP port ${ZABBIX_WEB_PORT} is already in use. Override it, e.g. ZABBIX_WEB_PORT=9080."
    fi
    if port_in_use "$PHPIPAM_WEB_PORT"; then
      die "TCP port ${PHPIPAM_WEB_PORT} is already in use. Override it, e.g. PHPIPAM_WEB_PORT=9081."
    fi
  fi
}

# ------------------------------- Docker setup --------------------------------

install_docker() {
  say "Installing/validating Docker Engine and Docker Compose"

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg openssl rsync git iproute2

  install -m 0755 -d /etc/apt/keyrings

  if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker

  docker --version
  docker compose version

  local compose_version major minor
  compose_version="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
  if [[ -n "$compose_version" ]]; then
    major="$(cut -d. -f1 <<<"$compose_version")"
    minor="$(cut -d. -f2 <<<"$compose_version")"
    if (( major < 2 || (major == 2 && minor < 20) )); then
      die "Docker Compose 2.20+ is required. Installed: ${compose_version}"
    fi
  fi
}

# ----------------------------- filesystem setup -------------------------------

prepare_root() {
  say "Preparing ${APP_ROOT}"

  mkdir -p "$ZABBIX_DIR" "$PHPIPAM_DIR"

  # Only directory traversal permissions are set here.
  # DO NOT recursively chown this tree.
  chmod 755 /opt "$APP_ROOT" "$ZABBIX_DIR" "$PHPIPAM_DIR"

  if [[ "$DEPLOY_USER" != "root" ]]; then
    usermod -aG docker "$DEPLOY_USER" || true
  fi
}

guard_restore_secrets() {
  if dir_has_data "${ZABBIX_DIR}/data/postgres" && [[ ! -s "${ZABBIX_DIR}/.env" ]]; then
    die "Existing Zabbix PostgreSQL data was found but ${ZABBIX_DIR}/.env is missing. Restore the matching .env before continuing."
  fi

  if dir_has_data "${PHPIPAM_DIR}/data/mariadb" && [[ ! -s "${PHPIPAM_DIR}/.env" ]]; then
    die "Existing phpIPAM MariaDB data was found but ${PHPIPAM_DIR}/.env is missing. Restore the matching .env before continuing."
  fi
}

create_data_dirs() {
  say "Creating persistent data directories (existing data is preserved)"

  mkdir -p \
    "${ZABBIX_DIR}/data/postgres" \
    "${ZABBIX_DIR}/data/snmptraps" \
    "${ZABBIX_DIR}/data/mibs" \
    "${ZABBIX_DIR}/data/alertscripts" \
    "${ZABBIX_DIR}/data/externalscripts" \
    "${PHPIPAM_DIR}/data/mariadb"

  # Do not chown database directories here. On a fresh build, the official
  # database images initialize them. On a restore, their existing ownership
  # must be preserved.
}

# --------------------------------- secrets -----------------------------------

create_zabbix_env() {
  if [[ -s "${ZABBIX_DIR}/.env" ]]; then
    say "Preserving existing Zabbix .env"
    return
  fi

  say "Creating Zabbix secrets"
  umask 077
  cat >"${ZABBIX_DIR}/.env" <<EOF
TZ=${TZ_VALUE}
ZABBIX_WEB_PORT=${ZABBIX_WEB_PORT}
POSTGRES_DB=zabbix
POSTGRES_USER=zabbix
POSTGRES_PASSWORD=$(random_secret)
EOF
  chmod 600 "${ZABBIX_DIR}/.env"
}

create_phpipam_env() {
  if [[ -s "${PHPIPAM_DIR}/.env" ]]; then
    say "Preserving existing phpIPAM .env"
    return
  fi

  say "Creating phpIPAM secrets"
  umask 077
  cat >"${PHPIPAM_DIR}/.env" <<EOF
TZ=${TZ_VALUE}
PHPIPAM_WEB_PORT=${PHPIPAM_WEB_PORT}
PHPIPAM_DB_NAME=phpipam
PHPIPAM_DB_USER=phpipam
PHPIPAM_DB_PASSWORD=$(random_secret)
PHPIPAM_DB_ROOT_PASSWORD=$(random_secret)
EOF
  chmod 600 "${PHPIPAM_DIR}/.env"
}

# ------------------------------- Zabbix stack --------------------------------

create_zabbix_compose() {
  if [[ -s "${ZABBIX_DIR}/compose.yml" ]]; then
    say "Preserving existing Zabbix compose.yml"
    return
  fi

  say "Creating Zabbix Compose project"
  cat >"${ZABBIX_DIR}/compose.yml" <<EOF
services:
  zabbix-db:
    image: ${POSTGRES_IMAGE}
    container_name: zabbix-db
    restart: unless-stopped
    env_file: .env
    environment:
      POSTGRES_DB: \${POSTGRES_DB}
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 20s
    networks:
      - zabbix-backend

  zabbix-server:
    image: ${ZABBIX_SERVER_IMAGE}
    container_name: zabbix-server
    restart: unless-stopped
    env_file: .env
    environment:
      DB_SERVER_HOST: zabbix-db
      POSTGRES_DB: \${POSTGRES_DB}
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    depends_on:
      zabbix-db:
        condition: service_healthy
    ports:
      - "10051:10051"
    volumes:
      - ./data/snmptraps:/var/lib/zabbix/snmptraps
      - ./data/mibs:/var/lib/zabbix/mibs
      - ./data/alertscripts:/usr/lib/zabbix/alertscripts
      - ./data/externalscripts:/usr/lib/zabbix/externalscripts
    networks:
      - zabbix-backend
      - zabbix-frontend

  zabbix-web:
    image: ${ZABBIX_WEB_IMAGE}
    container_name: zabbix-web
    restart: unless-stopped
    env_file: .env
    environment:
      DB_SERVER_HOST: zabbix-db
      POSTGRES_DB: \${POSTGRES_DB}
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      ZBX_SERVER_HOST: zabbix-server
      PHP_TZ: \${TZ}
    depends_on:
      zabbix-db:
        condition: service_healthy
      zabbix-server:
        condition: service_started
    ports:
      - "\${ZABBIX_WEB_PORT}:8080"
    networks:
      - zabbix-backend
      - zabbix-frontend

networks:
  zabbix-backend:
    driver: bridge
    internal: true
  zabbix-frontend:
    driver: bridge
EOF
}

# ------------------------------- phpIPAM stack -------------------------------

create_phpipam_compose() {
  if [[ -s "${PHPIPAM_DIR}/compose.yml" ]]; then
    say "Preserving existing phpIPAM compose.yml"
    return
  fi

  say "Creating phpIPAM Compose project"
  cat >"${PHPIPAM_DIR}/compose.yml" <<EOF
services:
  phpipam-db:
    image: ${MARIADB_IMAGE}
    container_name: phpipam-db
    restart: unless-stopped
    env_file: .env
    environment:
      MARIADB_ROOT_PASSWORD: \${PHPIPAM_DB_ROOT_PASSWORD}
      MARIADB_DATABASE: \${PHPIPAM_DB_NAME}
      MARIADB_USER: \${PHPIPAM_DB_USER}
      MARIADB_PASSWORD: \${PHPIPAM_DB_PASSWORD}
    volumes:
      - ./data/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    networks:
      - phpipam-backend

  phpipam-web:
    image: ${PHPIPAM_WEB_IMAGE}
    container_name: phpipam-web
    restart: unless-stopped
    env_file: .env
    environment:
      TZ: \${TZ}
      IPAM_DATABASE_HOST: phpipam-db
      IPAM_DATABASE_USER: \${PHPIPAM_DB_USER}
      IPAM_DATABASE_PASS: \${PHPIPAM_DB_PASSWORD}
      IPAM_DATABASE_NAME: \${PHPIPAM_DB_NAME}
      IPAM_DATABASE_WEBHOST: "%"
    depends_on:
      phpipam-db:
        condition: service_healthy
    ports:
      - "\${PHPIPAM_WEB_PORT}:80"
    cap_add:
      - NET_ADMIN
      - NET_RAW
    networks:
      - phpipam-backend
      - phpipam-frontend

  phpipam-cron:
    image: ${PHPIPAM_CRON_IMAGE}
    container_name: phpipam-cron
    restart: unless-stopped
    env_file: .env
    environment:
      TZ: \${TZ}
      IPAM_DATABASE_HOST: phpipam-db
      IPAM_DATABASE_USER: \${PHPIPAM_DB_USER}
      IPAM_DATABASE_PASS: \${PHPIPAM_DB_PASSWORD}
      IPAM_DATABASE_NAME: \${PHPIPAM_DB_NAME}
      SCAN_INTERVAL: 1h
    depends_on:
      phpipam-db:
        condition: service_healthy
    cap_add:
      - NET_ADMIN
      - NET_RAW
    networks:
      - phpipam-backend

networks:
  phpipam-backend:
    driver: bridge
    internal: true
  phpipam-frontend:
    driver: bridge
EOF
}

# ------------------------------ master Compose -------------------------------

create_master_compose() {
  if [[ -s "$MASTER_COMPOSE" ]]; then
    say "Preserving existing ${MASTER_COMPOSE}"
    return
  fi

  say "Creating master Compose file"
  cat >"$MASTER_COMPOSE" <<EOF
# MASTER-DOCKER-MANAGED
include:
  - path: ./zabbix/compose.yml
    env_file: ./zabbix/.env

  - path: ./phpipam/compose.yml
    env_file: ./phpipam/.env
EOF
}

create_home_compose() {
  mkdir -p "$DEPLOY_HOME"

  if [[ -e "$HOME_COMPOSE" ]] && ! grep -q "MASTER-DOCKER-MANAGED" "$HOME_COMPOSE" 2>/dev/null; then
    warn "${HOME_COMPOSE} already exists and is not managed by this installer."
    warn "It will not be overwritten. Use 'master-docker' to manage the stack."
    return
  fi

  cat >"$HOME_COMPOSE" <<EOF
# MASTER-DOCKER-MANAGED
include:
  - path: ${ZABBIX_DIR}/compose.yml
    env_file: ${ZABBIX_DIR}/.env

  - path: ${PHPIPAM_DIR}/compose.yml
    env_file: ${PHPIPAM_DIR}/.env
EOF

  if [[ "$DEPLOY_USER" != "root" ]]; then
    chown "$DEPLOY_USER:$DEPLOY_GROUP" "$HOME_COMPOSE"
  fi
  chmod 644 "$HOME_COMPOSE"
}

set_management_permissions() {
  say "Setting safe management-file permissions"

  # Only management/configuration files belong to the deployment administrator.
  # Database storage is deliberately excluded.
  if [[ "$DEPLOY_USER" != "root" ]]; then
    chown "$DEPLOY_USER:$DEPLOY_GROUP" \
      "$MASTER_COMPOSE" \
      "$ZABBIX_DIR/compose.yml" \
      "$ZABBIX_DIR/.env" \
      "$PHPIPAM_DIR/compose.yml" \
      "$PHPIPAM_DIR/.env"
  fi

  chmod 644 "$MASTER_COMPOSE" \
    "$ZABBIX_DIR/compose.yml" \
    "$PHPIPAM_DIR/compose.yml"

  chmod 600 "$ZABBIX_DIR/.env" "$PHPIPAM_DIR/.env"

  chmod 755 "$APP_ROOT" "$ZABBIX_DIR" "$PHPIPAM_DIR"
}

validate_compose() {
  say "Validating Compose configuration"
  cd "$APP_ROOT"
  docker compose -f "$MASTER_COMPOSE" config >/dev/null
  echo "Compose validation: OK"
}

write_admin_helper() {
  cat >/usr/local/sbin/master-docker <<EOF
#!/usr/bin/env bash
set -e
cd "${APP_ROOT}"
exec docker compose -f "${MASTER_COMPOSE}" "\$@"
EOF
  chmod 755 /usr/local/sbin/master-docker
}

# -------------------------------- deployment ---------------------------------

start_stack() {
  say "Pulling container images"
  cd "$APP_ROOT"
  docker compose -f "$MASTER_COMPOSE" pull

  say "Starting the monitoring stack"
  docker compose -f "$MASTER_COMPOSE" up -d
}

wait_for_health() {
  say "Waiting for database/web services"

  local i name status all_ok
  for i in $(seq 1 36); do
    all_ok=1

    for name in zabbix-db zabbix-web phpipam-db; do
      status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo missing)"
      case "$status" in
        healthy|running) ;;
        *) all_ok=0 ;;
      esac
    done

    if [[ "$all_ok" -eq 1 ]]; then
      echo "Core service health checks: OK"
      return 0
    fi

    sleep 5
  done

  warn "Timed out waiting for every core service to report healthy."
  docker compose -f "$MASTER_COMPOSE" ps || true
  warn "Review logs with: master-docker logs --tail=100"
  return 0
}

verify_databases() {
  say "Performing database smoke tests"

  if docker exec phpipam-db sh -c \
    'mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -Nse "SHOW DATABASES LIKE '\''phpipam'\'';"' \
    2>/dev/null | grep -qx "phpipam"; then
    echo "phpIPAM MariaDB database: OK"
  else
    warn "phpIPAM database smoke test did not pass yet. Check: docker logs phpipam-db --tail=100"
  fi

  if docker exec zabbix-db sh -c \
    'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
    >/dev/null 2>&1; then
    echo "Zabbix PostgreSQL database: OK"
  else
    warn "Zabbix PostgreSQL smoke test did not pass yet. Check: docker logs zabbix-db --tail=100"
  fi
}

show_summary() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ip" ]] || ip="SERVER-IP"

  cat <<EOF

==============================================================================
 MASTER DOCKER MONITORING INSTALL COMPLETE
==============================================================================

Deployment user:
  ${DEPLOY_USER}

Detected timezone:
  ${TZ_VALUE}

Application root:
  ${APP_ROOT}

Zabbix:
  http://${ip}:${ZABBIX_WEB_PORT}

  Fresh-install login:
    Username: Admin
    Password: zabbix

  Change the default Zabbix password immediately.

phpIPAM:
  http://${ip}:${PHPIPAM_WEB_PORT}

  On a new installation, complete the phpIPAM first-run setup.

Master commands:
  master-docker ps
  master-docker up -d
  master-docker down
  master-docker logs --tail=100
  master-docker logs -f
  master-docker pull
  master-docker up -d

Home-folder management:
  ${HOME_COMPOSE}

Docker group:
  ${DEPLOY_USER} was added to the docker group.
  Log out and reconnect before expecting 'docker' commands to work without sudo.
  Or run:
    newgrp docker

DISASTER RECOVERY:
  Preserve the ENTIRE directory:
    ${APP_ROOT}

  Recommended migration command after stopping the stack:
    sudo rsync -aHAX --numeric-ids ${APP_ROOT}/ NEW_SERVER:${APP_ROOT}/

  Then run this same installer on the replacement Ubuntu server.

IMPORTANT:
  Never recursively chown ${APP_ROOT} to an administrator account.
  PostgreSQL and MariaDB data files require database-specific ownership.

Installer log:
  ${LOG_FILE}

==============================================================================
EOF
}

main() {
  require_root

  # Logging is initialized after root is confirmed.
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap 'echo; echo "ERROR: Installer stopped on line $LINENO. Review '"$LOG_FILE"'."' ERR

  detect_deploy_user
  detect_timezone
  check_ubuntu

  say "Deployment user: ${DEPLOY_USER}"
  say "Timezone: ${TZ_VALUE}"

  install_docker
  prepare_root
  guard_restore_secrets
  check_ports_for_fresh_build
  create_data_dirs
  create_zabbix_env
  create_phpipam_env
  create_zabbix_compose
  create_phpipam_compose
  create_master_compose
  create_home_compose
  set_management_permissions
  validate_compose
  write_admin_helper
  start_stack
  wait_for_health
  verify_databases

  say "Container status"
  docker compose -f "$MASTER_COMPOSE" ps

  show_summary
}

main "$@"
