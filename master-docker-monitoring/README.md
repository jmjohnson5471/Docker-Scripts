# Master Docker Monitoring

One-command Ubuntu deployment of:

- **Zabbix 7.4** with PostgreSQL 16
- **phpIPAM 1.8x** with MariaDB 11.4
- Persistent application state under `/opt/master-docker`
- A master Docker Compose file
- Automatic random database credentials
- A `master-docker` management helper
- First-build and disaster-recovery support using the same installer

## Intended platform

Fresh **Ubuntu Server** installation with Internet access and a sudo-capable administrator account.

The installer detects the administrator username automatically. It does **not** assume a username such as `topadmin`.

It also detects the Ubuntu server's configured timezone automatically.

## One-line install

After this repository is published on GitHub, replace the values below with your actual GitHub account/repository:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPOSITORY/main/install.sh | sudo bash
```

For example, if the repository is named `master-docker-monitoring`:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/master-docker-monitoring/main/install.sh | sudo bash
```

## What happens automatically

The installer:

1. Confirms the server is Ubuntu.
2. Detects the sudo user's username and home directory.
3. Detects the server timezone.
4. Installs Docker Engine from Docker's official Ubuntu repository.
5. Installs Docker Compose.
6. Adds the administrator to the `docker` group.
7. Creates `/opt/master-docker`.
8. Generates strong random database credentials.
9. Creates the Zabbix/PostgreSQL Compose project.
10. Creates the phpIPAM/MariaDB Compose project.
11. Creates a master Compose configuration.
12. Creates `~/compose.yml` for the administrator when safe to do so.
13. Pulls the required container images.
14. Starts the complete stack.
15. Waits for the databases/web service health checks.
16. Performs basic PostgreSQL/MariaDB smoke tests.
17. Displays the URLs to open.

## Default URLs

Assuming the server address is `10.0.0.20`:

```text
Zabbix:
http://10.0.0.20:8080

phpIPAM:
http://10.0.0.20:8081
```

Fresh Zabbix login:

```text
Username: Admin
Password: zabbix
```

Change the Zabbix password immediately after logging in.

phpIPAM will display its first-run setup on a fresh database.

## After installation

Log out of SSH and reconnect so the new `docker` group membership is active.

Then:

```bash
docker ps
master-docker ps
```

Everyday commands:

```bash
master-docker ps
master-docker up -d
master-docker down
master-docker logs --tail=100
master-docker logs -f
master-docker pull
master-docker up -d
```

The installer also creates a managed Compose file in the deployment user's home directory when there is no conflicting existing file:

```bash
cd ~
docker compose ps
docker compose up -d
```

## Portable server data

The complete application is designed around:

```text
/opt/master-docker/
├── compose.yml
├── zabbix/
│   ├── compose.yml
│   ├── .env
│   └── data/
│       ├── postgres/
│       ├── snmptraps/
│       ├── mibs/
│       ├── alertscripts/
│       └── externalscripts/
└── phpipam/
    ├── compose.yml
    ├── .env
    └── data/
        └── mariadb/
```

The `.env` files contain generated secrets and are intentionally excluded from Git.

## Disaster recovery / migration

The same installer supports restoring to a replacement Ubuntu server.

### On the old server

For a consistent file-level database copy, stop the stack:

```bash
master-docker down
```

Copy the entire application root while preserving ownership and permissions:

```bash
sudo rsync -aHAX --numeric-ids /opt/master-docker/ NEW_SERVER:/opt/master-docker/
```

### On the replacement server

Run the same one-line installer again:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPOSITORY/main/install.sh | sudo bash
```

It detects the existing configuration/data, preserves the existing `.env` secrets, installs Docker if necessary, and starts the restored stack.

### Critical restore rules

Do **not** copy only the database directories.

Copy all of `/opt/master-docker`, including hidden `.env` files.

Do **not** run:

```bash
sudo chown -R youruser:youruser /opt/master-docker
```

That can break PostgreSQL/MariaDB database permissions.

The installer intentionally changes ownership only on management/configuration files and never recursively changes the database storage tree.

## Custom ports

Defaults:

```text
Zabbix web: 8080
phpIPAM web: 8081
Zabbix server: 10051
```

Override the web ports during installation:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPOSITORY/main/install.sh \
  | sudo ZABBIX_WEB_PORT=9080 PHPIPAM_WEB_PORT=9081 bash
```

## Override timezone

Normally the installer uses the Linux server's timezone.

To override it:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPOSITORY/main/install.sh \
  | sudo TZ_VALUE=America/Chicago bash
```

## Security

Do not commit:

- `.env`
- database files
- backups
- SQL dumps
- secrets

The included `.gitignore` blocks the common sensitive paths.

Database ports are not published to the host.

Zabbix/phpIPAM should normally be available only on trusted internal/VPN networks unless a properly secured reverse proxy is added.

## Repository files

```text
master-docker-monitoring/
├── install.sh
├── README.md
└── .gitignore
```

## Fresh-install reset

This destroys all Zabbix/phpIPAM application data. Use only when intentionally starting over:

```bash
master-docker down || true
sudo rm -rf /opt/master-docker
rm -f ~/compose.yml
sudo rm -f /usr/local/sbin/master-docker
```

Then rerun the installer.

## Important

This project automates deployment, but it does not replace backups. Back up Zabbix/PostgreSQL, phpIPAM/MariaDB, and `/opt/master-docker` to off-host storage.
