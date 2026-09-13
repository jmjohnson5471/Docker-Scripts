# Master Docker Monitoring Stack

A reusable Docker-based infrastructure monitoring stack for Ubuntu Server.

## Included applications

| Application | Purpose | Default Port |
|---|---|---:|
| Zabbix 7.4 | Infrastructure, server, network and SNMP monitoring | 8080 |
| phpIPAM 1.8x | IP address, subnet and VLAN management | 8081 |
| Grafana OSS | Dashboards and visualization | 3000 |
| Uptime Kuma 2 | Simple uptime, service and status monitoring | 3001 |
| Greenbone Community Edition / OpenVAS | Agentless vulnerability scanning | 9392 (HTTPS) |

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
├── uptime-kuma/
│   ├── compose.yml
│   ├── .env
│   └── data/
└── greenbone/
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

If Zabbix, phpIPAM, Grafana, Uptime Kuma, or Greenbone already exists in this managed layout, its existing Compose file, `.env`, and persistent data are preserved.

If a component is missing, the installer creates and starts that component.

This allows the same installer to be used for:

- a brand-new Ubuntu Server;
- adding Grafana, Uptime Kuma, or Greenbone to an existing managed Zabbix/phpIPAM installation;
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
Greenbone     https://SERVER-IP:9392
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

Open:

```text
http://SERVER-IP:3001
```

On the first visit, Uptime Kuma 2 will display a **Database Setup** page with three choices:

- Embedded MariaDB
- MariaDB/MySQL
- SQLite

For this stack, select **SQLite**.

Do **not** select MariaDB/MySQL just because phpIPAM already uses MariaDB. Uptime Kuma is intentionally kept independent from the phpIPAM database. SQLite is the simplest option for this deployment and keeps all Uptime Kuma application/database data inside its own persistent data directory.

After selecting **SQLite**:

1. Click **Next**.
2. Allow Uptime Kuma to initialize its database.
3. Create the Uptime Kuma administrator username and password when prompted.
4. Sign in and begin adding monitors.

The completed Uptime Kuma configuration is stored persistently under:

```text
/opt/master-docker/uptime-kuma/data
```

which is mapped into the container as:

```text
/app/data
```

The SQLite database is therefore preserved across container restarts, image updates, and normal installer re-runs.

**Important:** Back up the Uptime Kuma `data` directory as part of the overall `/opt/master-docker` backup. Do not delete this directory unless you intentionally want to reset Uptime Kuma and repeat the first-run setup.

## Greenbone / OpenVAS

Greenbone is installed as an **agentless network vulnerability scanner**. No Greenbone MSI is required on ordinary endpoints for standard network scans.

Open:

```text
https://SERVER-IP:9392
```

The installer uses Greenbone's current official Community container Compose definition, then adapts it to the master-stack layout. Greenbone is a multi-container application and includes the Greenbone Security Assistant web UI, `gvmd`, PostgreSQL, Redis, OpenVAS/OSPd, and vulnerability-feed containers.

On a fresh install, the username is:

```text
admin
```

The installer generates a random administrator password and stores it in:

```text
/opt/master-docker/greenbone/.env
```

View it locally:

```bash
sudo grep '^GREENBONE_ADMIN_PASSWORD=' /opt/master-docker/greenbone/.env
```

The installer attempts to apply that generated password automatically once `gvmd` becomes available. If Greenbone is still initializing and the password change cannot be completed yet, the installer prints the manual command to run after `gvmd` is ready.

### Initial feed synchronization

Do not expect useful vulnerability scans immediately after the containers first start. Greenbone must load vulnerability-test and security-feed data before the scanner is fully ready.

Check the stack with:

```bash
master-docker ps
master-docker logs --tail=100
```

Greenbone's web interface can become reachable before all feed data is ready.

### Persistent data

For consistency with this repository, the generated Greenbone Compose configuration maps Greenbone's named data volumes into:

```text
/opt/master-docker/greenbone/data/
```

Do not recursively `chown` this directory. Greenbone's database, scanner, socket, feed, and application containers require their own filesystem ownership and permissions.

### Scanning model

Greenbone can scan authorized subnets directly over the network. For this environment, create targets in the Greenbone GUI for only the networks you are authorized to assess.

A sensible starting schedule is:

```text
Critical servers / infrastructure: nightly
General workstation / device networks: weekly
Full/deeper authorized scan: monthly
```

Avoid continuously scanning every subnet. Vulnerability scans are substantially heavier than normal Zabbix polling and can trigger IPS/firewall detections.

Because Sophos routes traffic between VLANs in this environment, scans from the Greenbone host to other VLANs will pass through Sophos. Use a tightly scoped firewall policy for the scanner host rather than broadly disabling inspection for the whole network.

### Resource guidance

Greenbone's Community container documentation lists approximately:

```text
Minimum:      2 CPU / 4 GB RAM / 20 GB storage
Recommended:  4 CPU / 8 GB RAM / 60 GB storage
```

Those requirements are for Greenbone itself, so make sure the Docker host has capacity left over for Zabbix, phpIPAM, Grafana, and Uptime Kuma.

**Greenbone Community container note:** Greenbone currently describes its Community container deployment as suitable for testing/getting familiar with the Community Edition rather than as its recommended production deployment. Treat this accordingly when deciding whether to keep it on the shared monitoring host long-term.

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
     GREENBONE_WEB_PORT=9393 \
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

This repository now contains five core services:

- **Zabbix** — detailed infrastructure monitoring and alerting
- **phpIPAM** — IPAM and network documentation
- **Grafana** — dashboards and visualization
- **Uptime Kuma** — lightweight availability/status monitoring
- **Greenbone / OpenVAS** — agentless vulnerability discovery and assessment

Security/SIEM platforms such as Wazuh should still be deployed separately so their lifecycle, storage, updates and recovery are independent of this monitoring stack.
