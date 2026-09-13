# Wazuh Standalone Docker Stack

This folder follows the same design philosophy as the other `Docker-Scripts` projects:

```text
Docker-Scripts/
├── master-docker-monitoring/
├── tacticalrmm/
└── wazuh/
```

## Recommended architecture

**Wazuh is recommended to run on its own dedicated VM/server.**

Wazuh is considerably heavier than the Master Docker Monitoring stack because a single-node deployment includes:

- Wazuh Manager
- Wazuh Indexer
- Wazuh Dashboard
- Filebeat and supporting persistent data
- TLS certificates between the Wazuh components

However, if an organization only has one Docker server available, this installer is deliberately written so Wazuh can coexist with the existing monitoring and TacticalRMM deployments without being merged into them.

On a shared host:

```text
/opt/
├── master-docker/
│   ├── zabbix/
│   ├── phpipam/
│   ├── grafana/
│   └── uptime-kuma/
│
├── tacticalrmm/
│
└── wazuh/
    ├── .env
    ├── backups/
    └── wazuh-docker/
```

The installer never adds Wazuh to the `master-docker` Compose file and never modifies `/opt/tacticalrmm`.

## Wazuh version

This installer is pinned to:

```text
Wazuh 4.14.7
```

Pinning the release makes the deployment repeatable and prevents a future re-run from silently moving the server to a newer Wazuh version.

Existing installations are preserved rather than silently upgraded.

## Requirements

For a single-node Docker deployment, Wazuh currently requires at least:

```text
4 CPU cores
8 GB RAM
50 GB disk
```

For a production deployment, additional RAM and disk are recommended as agent count and event retention grow.

The installer configures the required Linux kernel setting:

```text
vm.max_map_count=262144
```

persistently in:

```text
/etc/sysctl.d/99-wazuh.conf
```

## Dashboard port: 8444 by default

The official Wazuh single-node Compose publishes its dashboard on host TCP port `443`.

TacticalRMM also normally uses port `443`, so this installer intentionally changes only the **host-side** Wazuh dashboard mapping to:

```text
8444 -> 5601
```

This allows Wazuh to coexist with TacticalRMM or another HTTPS service on the same Docker host.

After installation:

```text
https://SERVER-IP:8444
```

The container still listens internally on its normal Wazuh Dashboard port.

### Intentionally use another dashboard port

Override it at first installation:

```bash
sudo WAZUH_DASHBOARD_PORT=9443 ./install.sh
```

If you have a dedicated Wazuh server and want the standard HTTPS port:

```bash
sudo WAZUH_DASHBOARD_PORT=443 ./install.sh
```

The installer checks whether the requested host port is already in use and stops rather than taking the port away from another application.

## Other Wazuh ports

Defaults:

```text
1514/tcp   Agent communication
1515/tcp   Agent enrollment
514/udp    Syslog collector
55000/tcp  Wazuh API
9200/tcp   Wazuh Indexer API
8444/tcp   Wazuh Dashboard (host-side override in this project)
```

The installer checks these ports before the first start.

If one conflicts, the installer stops instead of interrupting another service.

Intentional overrides are supported:

```bash
sudo \
  WAZUH_DASHBOARD_PORT=8444 \
  WAZUH_AGENT_PORT=1514 \
  WAZUH_ENROLLMENT_PORT=1515 \
  WAZUH_SYSLOG_PORT=514 \
  WAZUH_API_PORT=55000 \
  WAZUH_INDEXER_PORT=9200 \
  ./install.sh
```

Do not change the agent/enrollment ports casually because agents and network devices will need to use the matching external ports.

## Installation

Place this folder in:

```text
Docker-Scripts/wazuh/
```

Then:

```bash
curl -fsSL https://raw.githubusercontent.com/jmjohnson5471/Docker-Scripts/main/wazuh/install.sh \
  -o /tmp/wazuh-install.sh

chmod +x /tmp/wazuh-install.sh

sudo /tmp/wazuh-install.sh
```

The installer will:

1. Install prerequisite packages.
2. Install Docker only if Docker/Compose are missing.
3. Leave an existing Docker installation alone.
4. Persist `vm.max_map_count=262144`.
5. Check Wazuh host ports before starting.
6. Create `/opt/wazuh`.
7. Clone the official Wazuh Docker repository at tag `v4.14.7`.
8. Preserve a copy of the original upstream Compose file.
9. Change only the host-side port mappings needed by this deployment.
10. Generate Wazuh certificates only when they do not already exist.
11. Validate the Compose configuration.
12. Pull the pinned Wazuh images.
13. Start only the Wazuh Compose project.
14. Create the `wazuh-stack` management helper.
15. Create the `wazuh-backup` cold-backup helper.

## Existing server safety

This installer is specifically designed so it can be run on an existing Docker host.

It does **not** run:

```bash
docker compose down
```

against some unrelated directory or global stack.

It uses an explicit Compose project:

```text
wazuh
```

and an explicit source directory:

```text
/opt/wazuh/wazuh-docker/single-node
```

So these remain independent:

```bash
master-docker ps
tacticalrmm ps
wazuh-stack ps
```

Stopping Wazuh:

```bash
wazuh-stack down
```

does not stop Zabbix, phpIPAM, Grafana, Uptime Kuma, or TacticalRMM.

Likewise, stopping the Master Docker Monitoring stack does not target Wazuh.

## First login

Open:

```text
https://SERVER-IP:8444
```

The upstream Wazuh Docker deployment contains its initial authentication configuration. After the first login, immediately follow the current Wazuh password-hardening procedure and replace default credentials before treating the deployment as production.

Do not expose the dashboard, API, or indexer directly to the public Internet.

## Certificates

Wazuh's official Docker repository includes its certificate generator.

On a fresh installation, this installer runs the certificate generator only when the required Wazuh certificates are missing.

On a re-run:

```text
Existing certificates -> preserved
Missing certificates  -> generated
```

## Management

The installer creates:

```bash
wazuh-stack
```

Examples:

```bash
wazuh-stack ps
wazuh-stack logs --tail=100
wazuh-stack logs -f
wazuh-stack pull
wazuh-stack up -d
wazuh-stack down
```

## Safe re-runs

The installer is designed to preserve an existing Wazuh deployment.

A re-run does not intentionally:

- delete Wazuh Docker volumes;
- replace existing certificates;
- replace the cloned Wazuh source tree;
- change the installed Wazuh release;
- upgrade Wazuh automatically;
- modify either of the other Docker stacks.

If the existing source tree is on a different tag than the requested installer version, the installer warns rather than silently upgrading it.

## Backup helper

A cold-backup helper is installed as:

```bash
sudo wazuh-backup
```

The backup intentionally stops **only the Wazuh Compose project** while the backup is taken.

It stores backups beneath:

```text
/opt/wazuh/backups/
```

Each backup includes:

- the `/opt/wazuh` configuration/source tree, excluding previous backups;
- all Docker volumes carrying the `wazuh` Compose project label.

After the backup completes, Wazuh is started again.

Because the indexer is database-like storage, a cold backup is safer than blindly copying its live Docker volume.

## Updating Wazuh

Do not use this installer as an automatic upgrade mechanism.

Wazuh upgrades can include changes to:

- Docker image versions;
- Compose definitions;
- manager configuration;
- indexer configuration;
- dashboard configuration.

Take a backup first and follow the Wazuh upgrade documentation for the target release.

The install script deliberately preserves an existing source tree rather than silently replacing it.

## Security recommendations

Keep Wazuh on trusted internal/VPN networks whenever possible.

At minimum, tightly restrict:

```text
8444/tcp
55000/tcp
9200/tcp
```

The indexer API on `9200/tcp` generally does not need to be broadly reachable by end-user networks.

Only expose agent/enrollment/syslog ports to networks that actually need them.

## Final architecture

The completed server-script collection becomes:

```text
Monitoring Stack
└── Zabbix + phpIPAM + Grafana + Uptime Kuma

RMM Stack
└── TacticalRMM

Security / SIEM Stack
└── Wazuh
    ├── Manager
    ├── Indexer
    ├── Dashboard
    ├── Certificates
    └── Cold-backup helper
```

Dedicated servers/VMs are preferred for TacticalRMM and Wazuh, but both installers are structured to coexist safely with an existing Docker host when that is the only practical option.
