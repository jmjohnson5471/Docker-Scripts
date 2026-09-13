# Master Docker Monitoring Stack

A reusable Docker-based infrastructure monitoring stack for Ubuntu Server.

## Included applications

| Application | Purpose | Default Port |
|---|---|---:|
| Zabbix 7.4 | Infrastructure, server, network and SNMP monitoring | 8080 |
| phpIPAM 1.8x | IP address, subnet and VLAN management | 8081 |
| Grafana OSS | Dashboards and visualization | 3000 |
| Uptime Kuma 2 | Simple uptime, service and status monitoring | 3001 |

Persistent application data is stored under:

```text
/opt/master-docker/
├── compose.yml
├── zabbix/
│   ├── compose.yml
│   ├── .env
│   └── data/
├── phpipam/
│   ├── compose.yml
│   ├── .env
│   └── data/
├── grafana/
│   ├── compose.yml
│   ├── .env
│   └── data/
└── uptime-kuma/
    ├── compose.yml
    ├── .env
    └── data/
```

Each application has its own Compose file and `.env`. The master Compose file uses Docker Compose `include` so the entire stack can be managed together.

## One-line installation

Run on Ubuntu Server:

```bash
curl -fsSL https://raw.githubusercontent.com/jmjohnson5471/Docker-Scripts/main/master-docker-monitoring/install.sh | sudo bash
```

The installer installs/validates Docker Engine and Docker Compose, creates missing application directories and configuration, generates secrets where required, validates the combined Compose configuration, pulls required images, and starts missing services.

## Safe re-runs and existing environments

The installer is designed to be re-run.

If Zabbix, phpIPAM, Grafana, or Uptime Kuma already exists in this managed layout, its existing Compose file, `.env`, and persistent data are preserved.

If a component is missing, the installer creates and starts that component.

This allows the same installer to be used for:

- a brand-new Ubuntu Server;
- adding Grafana or Uptime Kuma to an existing managed Zabbix/phpIPAM installation;
- rebuilding a server after restoring `/opt/master-docker`;
- future re-runs without intentionally replacing existing application data.

The installer refuses unsafe restore conditions where existing database/application data is detected but its matching `.env` is missing.

## Web access

After installation, browse to:

```text
Zabbix       http://SERVER-IP:8080
phpIPAM      http://SERVER-IP:8081
Grafana      http://SERVER-IP:3000
Uptime Kuma  http://SERVER-IP:3001
```

### Zabbix

Fresh-install default:

```text
Username: Admin
Password: zabbix
```

Change the password immediately.

### phpIPAM

Fresh-install default:

```text
Username: admin
Password: ipamadmin
```

Change the password immediately.

### Grafana

Username:

```text
admin
```

The installer generates a random Grafana administrator password in:

```text
/opt/master-docker/grafana/.env
```

View it locally:

```bash
sudo grep '^GRAFANA_ADMIN_PASSWORD=' /opt/master-docker/grafana/.env
```

### Uptime Kuma

Open port 3001 and complete the initial web setup to create the administrator account.

Uptime Kuma data is stored locally under `/opt/master-docker/uptime-kuma/data` and mapped to `/app/data`.

## Master commands

The installer creates the `master-docker` helper:

```bash
master-docker ps
master-docker up -d
master-docker down
master-docker logs --tail=100
master-docker logs -f
master-docker pull
```

A master Compose file is also maintained at:

```text
/opt/master-docker/compose.yml
```

When safe to do so, a convenient managed `~/compose.yml` is created for the deployment user.

## Important data-safety rule

**Never recursively change ownership of `/opt/master-docker` to the administrator account.**

Do not run:

```bash
sudo chown -R USER:USER /opt/master-docker
```

PostgreSQL, MariaDB, Grafana, and other application data must retain the ownership required by their containers. The installer changes ownership only on management/configuration files where appropriate.

## Backup / migration

Preserve the entire application root, including hidden `.env` files:

```text
/opt/master-docker
```

For a cold migration, stop the stack first and preserve numeric ownership:

```bash
master-docker down
sudo rsync -aHAX --numeric-ids /opt/master-docker/ NEW_SERVER:/opt/master-docker/
```

Then run this installer on the replacement Ubuntu server.

Database-aware backups are recommended for PostgreSQL and MariaDB during normal production operation.

Treat `.env` files and any backup containing them as secrets.

## Ports

Default ports can be overridden when invoking the installer:

```bash
sudo ZABBIX_WEB_PORT=9080 \
     PHPIPAM_WEB_PORT=9081 \
     GRAFANA_WEB_PORT=3300 \
     UPTIME_KUMA_WEB_PORT=3301 \
     ./install.sh
```

## Repository contents

```text
master-docker-monitoring/
├── README.md
└── install.sh
```

The generated `/opt/master-docker` configuration is intentionally not stored in GitHub because the `.env` files contain deployment-specific secrets.

## Security

Keep the management interfaces internal or VPN-only unless you intentionally place them behind an approved HTTPS reverse proxy.

Do not expose PostgreSQL or MariaDB directly to the Internet.

Restrict membership in the Docker group because Docker access is effectively root-equivalent.

## Completed stack

This repository intentionally stops at four core services:

- **Zabbix** — detailed infrastructure monitoring and alerting
- **phpIPAM** — IPAM and network documentation
- **Grafana** — dashboards and visualization
- **Uptime Kuma** — lightweight availability/status monitoring

Security/SIEM platforms such as Wazuh should be deployed separately so their lifecycle, storage, updates and recovery are independent of this monitoring stack.
