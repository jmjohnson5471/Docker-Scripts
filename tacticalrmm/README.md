# TacticalRMM Standalone Docker Installer

This folder is intentionally separate from the `master-docker-monitoring` stack.

## Design goal

**Preferred:** install TacticalRMM on its own dedicated VM/server.

**Fallback:** if the only available server is already running the Zabbix/phpIPAM/Grafana/Uptime Kuma Docker stack, this installer can share the Docker host without being merged into or modifying that existing Compose project.

It installs TacticalRMM under:

```text
/opt/tacticalrmm/
├── compose.yml
└── .env
```

and creates the helper:

```bash
tacticalrmm
```

The installer does **not** modify:

```text
/opt/master-docker
```

and does not add TacticalRMM to the `master-docker` Compose file.

## Important upstream support warning

TacticalRMM's official documentation currently says its Docker installation is **not officially supported** and is not recommended for production unless you are an advanced Docker administrator.

The officially supported traditional installer expects a **fresh dedicated Linux VM/server** and explicitly warns that running the traditional installer against a server with existing services can break things.

This repository therefore uses TacticalRMM's Docker deployment specifically to provide isolation when coexistence is necessary.

For production, a dedicated VM/server using TacticalRMM's supported traditional installation remains the preferred design.

## Requirements

TacticalRMM requires three DNS names at the same subdomain level, for example:

```text
rmm.example.com
api.example.com
mesh.example.com
```

Point all three names to the TacticalRMM server.

The normal externally reachable ports are:

```text
80/tcp
443/tcp
```

The installer refuses to take those ports away from an existing service.

## TLS certificate

A trusted wildcard certificate covering the three names is strongly recommended:

```text
*.example.com
```

TacticalRMM's Docker documentation warns that if a trusted Let's Encrypt/wildcard certificate is not provided, self-signed certificates are generated and most agent functions will not work correctly.

Recommended invocation with an existing wildcard certificate:

```bash
sudo \
  TRMM_ROOT_DOMAIN=example.com \
  TRMM_CERT_FULLCHAIN=/etc/letsencrypt/live/example.com/fullchain.pem \
  TRMM_CERT_PRIVKEY=/etc/letsencrypt/live/example.com/privkey.pem \
  ./install.sh
```

If you run the installer interactively, it will ask for the base domain and certificate paths.

## GitHub one-line installation

After placing this folder in:

```text
Docker-Scripts/tacticalrmm/
```

run:

```bash
curl -fsSL https://raw.githubusercontent.com/jmjohnson5471/Docker-Scripts/main/tacticalrmm/install.sh -o /tmp/tacticalrmm-install.sh
chmod +x /tmp/tacticalrmm-install.sh
sudo /tmp/tacticalrmm-install.sh
```

Downloading first instead of piping directly to Bash is intentional because the setup may need interactive domain/certificate input.

## What the installer does

On a fresh TacticalRMM deployment it:

- installs Docker only if Docker/Compose are missing;
- leaves an existing Docker installation intact;
- creates `/opt/tacticalrmm`;
- generates strong TacticalRMM, MeshCentral, MongoDB and PostgreSQL secrets;
- downloads TacticalRMM's current upstream Docker Compose definition;
- keeps TacticalRMM in a separate Compose project;
- uses its own Docker networks and Docker-managed volumes;
- checks ports 80 and 443 before starting;
- chooses a less collision-prone Docker subnet (`172.31.240.0/24` by default);
- validates the Compose configuration before startup;
- starts only the TacticalRMM project;
- creates `/usr/local/sbin/tacticalrmm`.

For security, the generated configuration defaults these TacticalRMM features to disabled:

```text
TRMM_DISABLE_WEB_TERMINAL=True
TRMM_DISABLE_SERVER_SCRIPTS=True
```

You can deliberately change them later in `/opt/tacticalrmm/.env` if you need those functions.

## Existing TacticalRMM installation

Re-running the installer preserves:

```text
/opt/tacticalrmm/.env
/opt/tacticalrmm/compose.yml
```

It does not generate new credentials over an existing `.env`.

The existing TacticalRMM Docker volumes are also left intact.

## Coexisting with the Master Docker Monitoring stack

The two deployments remain separate:

```text
/opt/
├── master-docker/
│   ├── zabbix/
│   ├── phpipam/
│   ├── grafana/
│   └── uptime-kuma/
│
└── tacticalrmm/
    ├── compose.yml
    └── .env
```

Commands remain independent:

```bash
master-docker ps
tacticalrmm ps
```

Stopping TacticalRMM:

```bash
tacticalrmm down
```

does not issue a Compose command against the Master Docker Monitoring project.

Likewise:

```bash
master-docker down
```

does not target TacticalRMM.

## Docker subnet

The TacticalRMM upstream Docker file currently defines a fixed proxy network. This installer rewrites only that network/subnet value on first installation to reduce the chance of colliding with another Docker stack.

Default:

```text
172.31.240.0/24
```

Override it if necessary:

```bash
sudo TRMM_DOCKER_SUBNET=172.31.241.0/24 ./install.sh
```

Use an unused `/24` ending in `.0/24`.

## Ports

Defaults:

```text
HTTP  = 80
HTTPS = 443
```

If another service owns port 80 or 443, the installer stops instead of changing or interrupting that service.

TacticalRMM supports Docker host-port overrides, but using a nonstandard HTTPS port should be a deliberate decision because agents and URLs may need to account for it.

Example:

```bash
sudo TRMM_HTTP_PORT=8088 TRMM_HTTPS_PORT=8443 ./install.sh
```

A dedicated server using normal 80/443 is strongly preferred.

## Credentials

The generated secrets are stored only in:

```text
/opt/tacticalrmm/.env
```

Permissions are set to `600`.

To display the initial TacticalRMM password locally:

```bash
sudo grep '^TRMM_PASS=' /opt/tacticalrmm/.env
```

Do not commit this `.env` file to GitHub.

## Management

```bash
tacticalrmm ps
tacticalrmm logs --tail=100
tacticalrmm logs -f
tacticalrmm pull
tacticalrmm up -d
tacticalrmm down
```

## Updating

TacticalRMM's Docker update procedure can change its upstream Compose definition between releases.

This installer deliberately **preserves the local Compose file on re-runs** rather than silently replacing it.

Review TacticalRMM's current Docker update documentation and take a backup before updating.

## Backup

TacticalRMM's upstream Docker deployment uses Docker-managed persistent volumes for PostgreSQL, MongoDB, Redis, MeshCentral and TacticalRMM application data.

Back up both:

```text
/opt/tacticalrmm
```

and the TacticalRMM Docker volumes.

Do not treat `/opt/tacticalrmm` by itself as a complete data backup.

## Repository contents

```text
tacticalrmm/
├── .gitignore
├── README.md
└── install.sh
```

## Recommended architecture

For this environment:

```text
Dedicated monitoring server
└── Zabbix + phpIPAM + Grafana + Uptime Kuma

Dedicated RMM server (preferred)
└── TacticalRMM
```

If only one server is available, both can coexist because they remain separate Docker Compose projects, provided there are no port or Docker-network conflicts.
