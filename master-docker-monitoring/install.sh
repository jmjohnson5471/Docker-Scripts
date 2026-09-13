#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# Master Docker Monitoring - Universal Bootstrap
# ============================================================================
# Deploys:
#   - Zabbix 7.4 + PostgreSQL 16
#   - phpIPAM 1.8x + MariaDB 11.4
#   - Grafana OSS 13.2.1
#   - Uptime Kuma 2.x
#   - Greenbone Community Edition / OpenVAS (official Community containers)
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
GRAFANA_DIR="${APP_ROOT}/grafana"
UPTIME_KUMA_DIR="${APP_ROOT}/uptime-kuma"
GREENBONE_DIR="${APP_ROOT}/greenbone"
MASTER_COMPOSE="${APP_ROOT}/compose.yml"
LOG_FILE="${LOG_FILE:-/var/log/master-docker-bootstrap.log}"

ZABBIX_WEB_PORT="${ZABBIX_WEB_PORT:-8080}"
PHPIPAM_WEB_PORT="${PHPIPAM_WEB_PORT:-8081}"
GRAFANA_WEB_PORT="${GRAFANA_WEB_PORT:-3000}"
UPTIME_KUMA_WEB_PORT="${UPTIME_KUMA_WEB_PORT:-3001}"
GREENBONE_WEB_PORT="${GREENBONE_WEB_PORT:-9392}"

POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11.4}"
ZABBIX_SERVER_IMAGE="${ZABBIX_SERVER_IMAGE:-zabbix/zabbix-server-pgsql:alpine-7.4-latest}"
ZABBIX_WEB_IMAGE="${ZABBIX_WEB_IMAGE:-zabbix/zabbix-web-nginx-pgsql:alpine-7.4-latest}"
PHPIPAM_WEB_IMAGE="${PHPIPAM_WEB_IMAGE:-phpipam/phpipam-www:1.8x}"
PHPIPAM_CRON_IMAGE="${PHPIPAM_CRON_IMAGE:-phpipam/phpipam-cron:1.8x}"
GRAFANA_IMAGE="${GRAFANA_IMAGE:-grafana/grafana:13.2.1}"
UPTIME_KUMA_IMAGE="${UPTIME_KUMA_IMAGE:-louislam/uptime-kuma:2}"
GREENBONE_COMPOSE_URL="${GREENBONE_COMPOSE_URL:-https://greenbone.github.io/docs/latest/_static/compose.yaml}"

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
  # Existing components are left alone. Only check a port when that component
  # does not already have a Compose definition managed under APP_ROOT.
  if [[ ! -s "${ZABBIX_DIR}/compose.yml" ]] && port_in_use "$ZABBIX_WEB_PORT"; then
    die "TCP port ${ZABBIX_WEB_PORT} is already in use. Override it, e.g. ZABBIX_WEB_PORT=9080."
  fi

  if [[ ! -s "${PHPIPAM_DIR}/compose.yml" ]] && port_in_use "$PHPIPAM_WEB_PORT"; then
    die "TCP port ${PHPIPAM_WEB_PORT} is already in use. Override it, e.g. PHPIPAM_WEB_PORT=9081."
  fi

  if [[ ! -s "${GRAFANA_DIR}/compose.yml" ]] && port_in_use "$GRAFANA_WEB_PORT"; then
    die "TCP port ${GRAFANA_WEB_PORT} is already in use. Override it, e.g. GRAFANA_WEB_PORT=3300."
  fi

  if [[ ! -s "${UPTIME_KUMA_DIR}/compose.yml" ]] && port_in_use "$UPTIME_KUMA_WEB_PORT"; then
    die "TCP port ${UPTIME_KUMA_WEB_PORT} is already in use. Override it, e.g. UPTIME_KUMA_WEB_PORT=3301."
  fi

  if [[ ! -s "${GREENBONE_DIR}/compose.yml" ]] && port_in_use "$GREENBONE_WEB_PORT"; then
    die "TCP port ${GREENBONE_WEB_PORT} is already in use. Override it, e.g. GREENBONE_WEB_PORT=9393."
  fi
}

# ------------------------------- Docker setup --------------------------------

install_docker() {
  say "Installing/validating Docker Engine and Docker Compose"

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gnupg openssl rsync git iproute2 python3 python3-yaml

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

  mkdir -p "$ZABBIX_DIR" "$PHPIPAM_DIR" "$GRAFANA_DIR" "$UPTIME_KUMA_DIR" "$GREENBONE_DIR"

  # Only directory traversal permissions are set here.
  # DO NOT recursively chown this tree.
  chmod 755 /opt "$APP_ROOT" "$ZABBIX_DIR" "$PHPIPAM_DIR" "$GRAFANA_DIR" "$UPTIME_KUMA_DIR" "$GREENBONE_DIR"

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

  if dir_has_data "${GRAFANA_DIR}/data/grafana" && [[ ! -s "${GRAFANA_DIR}/.env" ]]; then
    die "Existing Grafana data was found but ${GRAFANA_DIR}/.env is missing. Restore the matching .env before continuing."
  fi

  if dir_has_data "${UPTIME_KUMA_DIR}/data" && [[ ! -s "${UPTIME_KUMA_DIR}/.env" ]]; then
    die "Existing Uptime Kuma data was found but ${UPTIME_KUMA_DIR}/.env is missing. Restore the matching .env before continuing."
  fi

  if dir_has_data "${GREENBONE_DIR}/data" && [[ ! -s "${GREENBONE_DIR}/.env" ]]; then
    die "Existing Greenbone data was found but ${GREENBONE_DIR}/.env is missing. Restore the matching .env before continuing."
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
    "${PHPIPAM_DIR}/data/mariadb" \
    "${GRAFANA_DIR}/data/grafana" \
    "${UPTIME_KUMA_DIR}/data" \
    "${GREENBONE_DIR}/data"

  # Grafana runs as UID 472. Only set ownership on a brand-new/empty Grafana
  # data directory. Never recursively change ownership of restored data.
  if ! dir_has_data "${GRAFANA_DIR}/data/grafana"; then
    chown 472:0 "${GRAFANA_DIR}/data/grafana"
    chmod 775 "${GRAFANA_DIR}/data/grafana"
  fi

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

create_grafana_env() {
  if [[ -s "${GRAFANA_DIR}/.env" ]]; then
    say "Preserving existing Grafana .env"
    return
  fi

  say "Creating Grafana settings and admin secret"
  umask 077
  cat >"${GRAFANA_DIR}/.env" <<EOF
TZ=${TZ_VALUE}
GRAFANA_WEB_PORT=${GRAFANA_WEB_PORT}
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=$(random_secret)
EOF
  chmod 600 "${GRAFANA_DIR}/.env"
}

create_uptime_kuma_env() {
  if [[ -s "${UPTIME_KUMA_DIR}/.env" ]]; then
    say "Preserving existing Uptime Kuma .env"
    return
  fi

  say "Creating Uptime Kuma settings"
  umask 077
  cat >"${UPTIME_KUMA_DIR}/.env" <<EOF
TZ=${TZ_VALUE}
UPTIME_KUMA_WEB_PORT=${UPTIME_KUMA_WEB_PORT}
EOF
  chmod 600 "${UPTIME_KUMA_DIR}/.env"
}

create_greenbone_env() {
  if [[ -s "${GREENBONE_DIR}/.env" ]]; then
    say "Preserving existing Greenbone .env"
    return
  fi

  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$host_ip" ]] || host_ip="localhost"

  say "Creating Greenbone settings and admin secret"
  umask 077
  cat >"${GREENBONE_DIR}/.env" <<EOF
TZ=${TZ_VALUE}
GREENBONE_HOST=${host_ip}
GREENBONE_WEB_PORT=${GREENBONE_WEB_PORT}
GREENBONE_DATA_ROOT=${GREENBONE_DIR}/data
GREENBONE_ADMIN_USER=admin
GREENBONE_ADMIN_PASSWORD=$(random_secret)
EOF
  chmod 600 "${GREENBONE_DIR}/.env"
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
      IPAM_DISABLE_INSTALLER: "1"
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

# ------------------------------- Grafana stack -------------------------------

create_grafana_compose() {
  if [[ -s "${GRAFANA_DIR}/compose.yml" ]]; then
    say "Preserving existing Grafana compose.yml"
    return
  fi

  say "Creating Grafana Compose project"
  cat >"${GRAFANA_DIR}/compose.yml" <<EOF
services:
  grafana:
    image: ${GRAFANA_IMAGE}
    container_name: grafana
    restart: unless-stopped
    env_file: .env
    environment:
      TZ: \${TZ}
      GF_SECURITY_ADMIN_USER: \${GRAFANA_ADMIN_USER}
      GF_SECURITY_ADMIN_PASSWORD: \${GRAFANA_ADMIN_PASSWORD}
      GF_USERS_ALLOW_SIGN_UP: "false"
    ports:
      - "\${GRAFANA_WEB_PORT}:3000"
    volumes:
      - ./data/grafana:/var/lib/grafana
    networks:
      - grafana-frontend

networks:
  grafana-frontend:
    driver: bridge
EOF
}

# ---------------------------- Uptime Kuma stack -------------------------------

create_uptime_kuma_compose() {
  if [[ -s "${UPTIME_KUMA_DIR}/compose.yml" ]]; then
    say "Preserving existing Uptime Kuma compose.yml"
    return
  fi

  say "Creating Uptime Kuma Compose project"
  cat >"${UPTIME_KUMA_DIR}/compose.yml" <<EOF
services:
  uptime-kuma:
    image: ${UPTIME_KUMA_IMAGE}
    container_name: uptime-kuma
    restart: unless-stopped
    env_file: .env
    environment:
      TZ: \${TZ}
    ports:
      - "\${UPTIME_KUMA_WEB_PORT}:3001"
    volumes:
      - ./data:/app/data
    networks:
      - uptime-kuma-frontend

networks:
  uptime-kuma-frontend:
    driver: bridge
EOF
}

# ------------------------------ Greenbone stack ------------------------------

create_greenbone_compose() {
  if [[ -s "${GREENBONE_DIR}/compose.yml" ]]; then
    say "Preserving existing Greenbone compose.yml"
    return
  fi

  say "Downloading current official Greenbone Community Compose definition"
  local tmp_compose
  tmp_compose="$(mktemp)"
  curl -fsSL "$GREENBONE_COMPOSE_URL" -o "$tmp_compose" \
    || die "Could not download the official Greenbone Compose file from ${GREENBONE_COMPOSE_URL}."

  GREENBONE_DIR="$GREENBONE_DIR" python3 - "$tmp_compose" "${GREENBONE_DIR}/compose.yml" <<'PY'
import os
import sys
from pathlib import Path
import yaml

src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f)

if not isinstance(cfg, dict) or "services" not in cfg:
    raise SystemExit("Downloaded Greenbone compose file is not valid.")

cfg.pop("name", None)

services = cfg["services"]
for required in ("gvm-config", "nginx", "gvmd", "ospd-openvas"):
    if required not in services:
        raise SystemExit(f"Official Greenbone compose is missing expected service: {required}")

gvm_env = services["gvm-config"].setdefault("environment", {})
gvm_env["NGINX_HOST"] = "${GREENBONE_HOST}"
gvm_env["NGINX_ACCESS_CONTROL_ALLOW_ORIGIN_HEADER"] = "https://${GREENBONE_HOST}:${GREENBONE_WEB_PORT}"
services["nginx"]["ports"] = ["${GREENBONE_WEB_PORT}:443"]

data_root = os.path.join(os.environ["GREENBONE_DIR"], "data")
volumes = cfg.setdefault("volumes", {})
for volume_name in list(volumes.keys()):
    host_path = os.path.join(data_root, volume_name)
    Path(host_path).mkdir(parents=True, exist_ok=True)
    volumes[volume_name] = {
        "driver": "local",
        "driver_opts": {
            "type": "none",
            "o": "bind",
            "device": host_path,
        },
    }

with open(dst, "w", encoding="utf-8") as f:
    f.write("# MASTER-DOCKER-MANAGED GREENBONE\n")
    f.write("# Generated from Greenbone's current official Community compose file.\n")
    yaml.safe_dump(cfg, f, sort_keys=False, default_flow_style=False)
PY

  rm -f "$tmp_compose"
  chmod 644 "${GREENBONE_DIR}/compose.yml"
}

# ------------------------------ master Compose -------------------------------

create_master_compose() {
  if [[ ! -s "$MASTER_COMPOSE" ]]; then
    say "Creating master Compose file"
    cat >"$MASTER_COMPOSE" <<EOF
# MASTER-DOCKER-MANAGED
include:
  - path: ./zabbix/compose.yml
    env_file: ./zabbix/.env

  - path: ./phpipam/compose.yml
    env_file: ./phpipam/.env

  - path: ./grafana/compose.yml
    env_file: ./grafana/.env

  - path: ./uptime-kuma/compose.yml
    env_file: ./uptime-kuma/.env

  - path: ./greenbone/compose.yml
    env_file: ./greenbone/.env
EOF
    return
  fi

  if ! grep -q "MASTER-DOCKER-MANAGED" "$MASTER_COMPOSE" 2>/dev/null; then
    die "${MASTER_COMPOSE} already exists but is not marked MASTER-DOCKER-MANAGED. Refusing to modify it automatically."
  fi

  if grep -qE 'grafana/compose\.ya?ml' "$MASTER_COMPOSE"; then
    say "Master Compose already includes Grafana; preserving it"
  else
    say "Adding Grafana include to existing master Compose without changing Zabbix/phpIPAM"
    cat >>"$MASTER_COMPOSE" <<EOF

  - path: ./grafana/compose.yml
    env_file: ./grafana/.env
EOF
  fi

  if grep -qE 'uptime-kuma/compose\.ya?ml' "$MASTER_COMPOSE"; then
    say "Master Compose already includes Uptime Kuma; preserving it"
  else
    say "Adding Uptime Kuma include to existing master Compose without changing existing services"
    cat >>"$MASTER_COMPOSE" <<EOF

  - path: ./uptime-kuma/compose.yml
    env_file: ./uptime-kuma/.env
EOF
  fi

  if grep -qE 'greenbone/compose\.ya?ml' "$MASTER_COMPOSE"; then
    say "Master Compose already includes Greenbone; preserving it"
  else
    say "Adding Greenbone include to existing master Compose without changing existing services"
    cat >>"$MASTER_COMPOSE" <<EOF

  - path: ./greenbone/compose.yml
    env_file: ./greenbone/.env
EOF
  fi
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

  - path: ${GRAFANA_DIR}/compose.yml
    env_file: ${GRAFANA_DIR}/.env

  - path: ${UPTIME_KUMA_DIR}/compose.yml
    env_file: ${UPTIME_KUMA_DIR}/.env

  - path: ${GREENBONE_DIR}/compose.yml
    env_file: ${GREENBONE_DIR}/.env
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
      "$PHPIPAM_DIR/.env" \
      "$GRAFANA_DIR/compose.yml" \
      "$GRAFANA_DIR/.env" \
      "$UPTIME_KUMA_DIR/compose.yml" \
      "$UPTIME_KUMA_DIR/.env" \
      "$GREENBONE_DIR/compose.yml" \
      "$GREENBONE_DIR/.env"
  fi

  chmod 644 "$MASTER_COMPOSE" \
    "$ZABBIX_DIR/compose.yml" \
    "$PHPIPAM_DIR/compose.yml" \
    "$GRAFANA_DIR/compose.yml" \
    "$UPTIME_KUMA_DIR/compose.yml" \
    "$GREENBONE_DIR/compose.yml"

  chmod 600 "$ZABBIX_DIR/.env" "$PHPIPAM_DIR/.env" "$GRAFANA_DIR/.env" "$UPTIME_KUMA_DIR/.env" "$GREENBONE_DIR/.env"

  chmod 755 "$APP_ROOT" "$ZABBIX_DIR" "$PHPIPAM_DIR" "$GRAFANA_DIR" "$UPTIME_KUMA_DIR" "$GREENBONE_DIR"
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
  local services=()
  local greenbone_services=()

  [[ "$ZABBIX_WAS_PRESENT" -eq 0 ]] && services+=(zabbix-db zabbix-server zabbix-web)
  [[ "$PHPIPAM_WAS_PRESENT" -eq 0 ]] && services+=(phpipam-db phpipam-web phpipam-cron)
  [[ "$GRAFANA_WAS_PRESENT" -eq 0 ]] && services+=(grafana)
  [[ "$UPTIME_KUMA_WAS_PRESENT" -eq 0 ]] && services+=(uptime-kuma)

  cd "$APP_ROOT"

  if [[ "$GREENBONE_WAS_PRESENT" -eq 0 ]]; then
    mapfile -t greenbone_services < <(docker compose \
      --env-file "${GREENBONE_DIR}/.env" \
      -f "${GREENBONE_DIR}/compose.yml" config --services)
    services+=("${greenbone_services[@]}")
  fi

  if [[ "${#services[@]}" -eq 0 ]]; then
    say "All stack components already exist; no existing service will be recreated"
    return
  fi

  say "Pulling images only for new/missing components"
  docker compose -f "$MASTER_COMPOSE" pull "${services[@]}"

  say "Starting only new/missing components; existing services are left alone"
  docker compose -f "$MASTER_COMPOSE" up -d "${services[@]}"
}

wait_for_health() {
  say "Waiting for newly added services"

  local names=() i name status all_ok
  [[ "$ZABBIX_WAS_PRESENT" -eq 0 ]] && names+=(zabbix-db zabbix-web)
  [[ "$PHPIPAM_WAS_PRESENT" -eq 0 ]] && names+=(phpipam-db phpipam-web)
  [[ "$GRAFANA_WAS_PRESENT" -eq 0 ]] && names+=(grafana)
  [[ "$UPTIME_KUMA_WAS_PRESENT" -eq 0 ]] && names+=(uptime-kuma)
  [[ "$GREENBONE_WAS_PRESENT" -eq 0 ]] && names+=(gvmd nginx ospd-openvas)

  if [[ "${#names[@]}" -eq 0 ]]; then
    echo "No new services to wait for."
    return 0
  fi

  for i in $(seq 1 36); do
    all_ok=1

    for name in "${names[@]}"; do
      local cid
      cid="$(docker compose -f "$MASTER_COMPOSE" ps -q "$name" 2>/dev/null | head -n1)"
      if [[ -z "$cid" ]]; then
        status="missing"
      else
        status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo missing)"
      fi
      case "$status" in
        healthy|running) ;;
        *) all_ok=0 ;;
      esac
    done

    if [[ "$all_ok" -eq 1 ]]; then
      echo "New service health checks: OK"
      return 0
    fi

    sleep 5
  done

  warn "Timed out waiting for every new service to report healthy/running."
  docker compose -f "$MASTER_COMPOSE" ps || true
  warn "Review logs with: master-docker logs --tail=100"
  return 0
}

phpipam_settings_table_exists() {
  docker exec phpipam-db sh -c \
    'mariadb -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE" -Nse "SHOW TABLES LIKE '\''settings'\'';"' \
    2>/dev/null | grep -qx "settings"
}

initialize_phpipam_schema_if_needed() {
  say "Checking phpIPAM database schema"

  if phpipam_settings_table_exists; then
    echo "phpIPAM schema already exists; preserving current database."
    return
  fi

  echo "Fresh/empty phpIPAM database detected."
  echo "Importing /phpipam/db/SCHEMA.sql ..."

  docker exec phpipam-web test -f /phpipam/db/SCHEMA.sql \
    || die "phpIPAM schema file /phpipam/db/SCHEMA.sql was not found in phpipam-web."

  docker exec phpipam-web cat /phpipam/db/SCHEMA.sql | \
    docker exec -i phpipam-db sh -c \
      'mariadb -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'

  if phpipam_settings_table_exists; then
    echo "phpIPAM schema import: OK"
  else
    die "phpIPAM schema import completed but the settings table was not detected."
  fi

  say "Restarting phpIPAM after schema initialization"
  cd "$APP_ROOT"
  docker compose -f "$MASTER_COMPOSE" restart phpipam-web phpipam-cron
}

verify_databases() {
  say "Performing database smoke tests"

  if docker exec phpipam-db sh -c \
    'mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -Nse "SHOW DATABASES LIKE '\''phpipam'\'';"' \
    2>/dev/null | grep -qx "phpipam"; then
    echo "phpIPAM MariaDB database: OK"
  else
    warn "phpIPAM database smoke test did not pass yet."
  fi

  if phpipam_settings_table_exists; then
    echo "phpIPAM schema/settings table: OK"
  else
    warn "phpIPAM settings table was not detected."
  fi

  if docker exec zabbix-db sh -c \
    'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
    >/dev/null 2>&1; then
    echo "Zabbix PostgreSQL database: OK"
  else
    warn "Zabbix PostgreSQL smoke test did not pass yet."
  fi
}

set_greenbone_admin_password() {
  [[ "$GREENBONE_WAS_PRESENT" -eq 0 ]] || return 0

  local password i
  password="$(grep '^GREENBONE_ADMIN_PASSWORD=' "${GREENBONE_DIR}/.env" | cut -d= -f2-)"
  [[ -n "$password" ]] || { warn "Greenbone admin password was not found in .env"; return 0; }

  say "Setting Greenbone admin password"
  for i in $(seq 1 24); do
    if docker compose -f "$MASTER_COMPOSE" exec -T -u gvmd gvmd \
      gvmd --user=admin --new-password="$password" >/dev/null 2>&1; then
      echo "Greenbone admin password: configured"
      return 0
    fi
    sleep 5
  done

  warn "Greenbone is still initializing; automatic admin password update did not complete yet."
  warn "After gvmd is ready, run: master-docker exec -T -u gvmd gvmd gvmd --user=admin --new-password='<new-password>'"
  return 0
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

  Fresh-install login:
    Username: admin
    Password: ipamadmin

  Change the phpIPAM password immediately.
  The phpIPAM installer is disabled automatically after schema initialization.

Grafana:
  http://${ip}:${GRAFANA_WEB_PORT}

  Fresh-install username:
    admin

  Fresh-install password is stored securely in:
    ${GRAFANA_DIR}/.env

  View it locally with:
    sudo grep '^GRAFANA_ADMIN_PASSWORD=' ${GRAFANA_DIR}/.env

Uptime Kuma:
  http://${ip}:${UPTIME_KUMA_WEB_PORT}

  On a fresh install, create the administrator account in the web setup wizard.
  Persistent data:
    ${UPTIME_KUMA_DIR}/data

Greenbone / OpenVAS:
  https://${ip}:${GREENBONE_WEB_PORT}

  Fresh-install username:
    admin

  Fresh-install password is stored securely in:
    ${GREENBONE_DIR}/.env

  View it locally with:
    sudo grep '^GREENBONE_ADMIN_PASSWORD=' ${GREENBONE_DIR}/.env

  IMPORTANT: Initial Greenbone feed loading can take a while. The GUI may be
  reachable before all vulnerability-test/feed data is ready for scanning.

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

detect_existing_components() {
  ZABBIX_WAS_PRESENT=0
  PHPIPAM_WAS_PRESENT=0
  GRAFANA_WAS_PRESENT=0
  UPTIME_KUMA_WAS_PRESENT=0
  GREENBONE_WAS_PRESENT=0

  [[ -s "${ZABBIX_DIR}/compose.yml" && -s "${ZABBIX_DIR}/.env" ]] && ZABBIX_WAS_PRESENT=1
  [[ -s "${PHPIPAM_DIR}/compose.yml" && -s "${PHPIPAM_DIR}/.env" ]] && PHPIPAM_WAS_PRESENT=1
  [[ -s "${GRAFANA_DIR}/compose.yml" && -s "${GRAFANA_DIR}/.env" ]] && GRAFANA_WAS_PRESENT=1
  [[ -s "${UPTIME_KUMA_DIR}/compose.yml" && -s "${UPTIME_KUMA_DIR}/.env" ]] && UPTIME_KUMA_WAS_PRESENT=1
  [[ -s "${GREENBONE_DIR}/compose.yml" && -s "${GREENBONE_DIR}/.env" ]] && GREENBONE_WAS_PRESENT=1

  say "Existing stack detection"
  echo "  Zabbix present : ${ZABBIX_WAS_PRESENT}"
  echo "  phpIPAM present: ${PHPIPAM_WAS_PRESENT}"
  echo "  Grafana present: ${GRAFANA_WAS_PRESENT}"
  echo "  Uptime Kuma present: ${UPTIME_KUMA_WAS_PRESENT}"
  echo "  Greenbone present: ${GREENBONE_WAS_PRESENT}"
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
  detect_existing_components
  prepare_root
  guard_restore_secrets
  check_ports_for_fresh_build
  create_data_dirs
  create_zabbix_env
  create_phpipam_env
  create_grafana_env
  create_uptime_kuma_env
  create_greenbone_env
  create_zabbix_compose
  create_phpipam_compose
  create_grafana_compose
  create_uptime_kuma_compose
  create_greenbone_compose
  create_master_compose
  create_home_compose
  set_management_permissions
  validate_compose
  write_admin_helper
  start_stack
  wait_for_health
  set_greenbone_admin_password

  if [[ "$PHPIPAM_WAS_PRESENT" -eq 0 ]]; then
    initialize_phpipam_schema_if_needed
  else
    say "Existing phpIPAM detected; skipping schema initialization to leave it untouched"
  fi

  if [[ "$ZABBIX_WAS_PRESENT" -eq 0 || "$PHPIPAM_WAS_PRESENT" -eq 0 ]]; then
    verify_databases
  else
    say "Existing Zabbix/phpIPAM detected; skipping database smoke tests"
  fi

  say "Container status"
  docker compose -f "$MASTER_COMPOSE" ps

  show_summary
}

main "$@"
