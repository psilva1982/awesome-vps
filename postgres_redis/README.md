# PostgreSQL & Redis Stack Architecture

## Executive Summary

The `postgres_redis` stack is a purpose-built deployment script designed to transform a fresh Ubuntu 26.04 LTS Virtual Private Server (VPS) into a high-performance, secure, and production-ready database backend. 

This stack automatically installs and configures **PostgreSQL 17**, **Redis 8**, and an array of security tools (Certbot, UFW, Fail2Ban). It emphasizes idempotent execution, automatic TLS provisioning, per-application isolation, and aggressive performance tuning optimized for NVMe storage environments.

---

## Requirements and Prerequisites

- **OS**: Ubuntu 26.04 LTS (Strictly enforced by the preflight checks).
- **DNS**: The target domain must have an A/AAAA record pointing to the public IP of the VPS *before* executing the setup (required for Certbot standalone validation).
- **Network**: Port 80 must be temporarily free during the initial certificate provisioning.
- **Permissions**: Root access or `sudo` privileges.

---

## Getting Started

To deploy the `postgres_redis` stack on a fresh Ubuntu 26.04 LTS VPS, execute the following command as a user with `sudo` privileges:

```bash
curl -fsSL https://raw.githubusercontent.com/psilva1982/awesome-vps/main/postgres_redis/setup.sh -o setup.sh
sudo bash setup.sh
```

### Installation Workflow

1. **Preflight Checks**: Validates the operating system version and dependencies.
2. **Interactive Inputs**: Prompts for:
   - Server Domain (e.g., `db.yourdomain.com`) - *Must resolve to the VPS IP*.
   - Let's Encrypt Email (for expiration notices).
   - Trusted IPs/CIDRs (space-separated, authorized to access the DBs).
3. **Service Installation**: Installs PostgreSQL, Redis, Certbot, UFW, and Fail2Ban.
4. **Configuration & Tuning**: Applies the optimized `custom.conf` for PostgreSQL and sets up systemd templates for Redis.
5. **TLS Provisioning**: Obtains certificates via Certbot standalone mode and injects them into the respective database services.

---

## Operational Scripts

Once the base infrastructure is provisioned, the repository provides utility scripts in `/opt/awesome-vps/postgres_redis/scripts/` to manage the day-to-day operations of your services.

| Script | Description |
|--------|-------------|
| `create_app_user.sh` | Provisions a new PostgreSQL database and a dedicated role/user for an application. |
| `create_app_redis.sh` | Spawns a new, isolated Redis instance for an application, fully configured with TLS and systemd integration. |
| `delete_app_user.sh` | Safely removes an application's database and role. |
| `list_app_users.sh` | Lists all application users and their associated databases. |
| `change_db_user_password.sh` | Updates the credentials for an existing PostgreSQL role. |
| `setup_bd_firewall.sh` | Helper to manage UFW rules specifically for database access. |
| `setup_web_firewall.sh` | Helper to manage UFW rules for web servers (HTTP/HTTPS). |

### Example: Provisioning a New Application

After running the main `setup.sh`, you will typically provision resources for a specific application (e.g., "myapp"):

```bash
# Create a PostgreSQL database 'myapp' and user 'myapp'
sudo /opt/awesome-vps/postgres_redis/scripts/create_app_user.sh myapp

# Create a dedicated Redis instance for 'myapp'
sudo /opt/awesome-vps/postgres_redis/scripts/create_app_redis.sh myapp
```

---

## Architecture Overview

At a high level, the system establishes a secure network perimeter and provisions the databases. It uses a state-driven approach (`/etc/vps-setup.conf`) to ensure that subsequent executions of the script can resume from the last successful step without duplicating work.

**System Boundaries & Key Interactions:**
- **External Network:** Only explicitly trusted IP addresses (`TRUSTED_IPS`) can reach the PostgreSQL (5432) and Redis ports via UFW.
- **Let's Encrypt (Certbot):** Operates on port 80 during initial setup (Standalone mode) to fetch TLS certificates, which are then distributed to the database services.
- **Fail2Ban:** Monitors system logs (`systemd` journal backend) to dynamically ban brute-force attackers.

---

## Core Components

1. **PostgreSQL 17 (PGDG)**
   - Installed via the official PostgreSQL Global Development Group (PGDG) repository.
   - Configured for encrypted-only remote connections via `hostssl` and `scram-sha-256` password hashing.
   - Integrated with `pg_stat_statements` for query monitoring.

2. **Redis 8**
   - Installed via `packages.redis.io`.
   - Re-architected to avoid a single shared instance. The default global service is disabled.
   - Instead, a `redis@.service` systemd template allows spinning up isolated Redis instances on unique ports per application.

3. **Security Infrastructure**
   - **UFW**: Strict, IP-based access control.
   - **Fail2Ban**: SSH protection against brute-force attacks.
   - **Certbot**: Automated TLS certificate lifecycle management.

---

## Design Decisions

### 1. Per-Application Redis Isolation
**Decision:** Disable the default Redis server and use a systemd template (`redis@.service`) for per-app instances.
**Rationale:** Redis is single-threaded. Sharing a single Redis instance among multiple applications can lead to "noisy neighbor" problems, where a blocking command from one app stalls all others. Furthermore, if a single instance is compromised, all data is at risk. Running isolated instances ensures fault isolation and better multi-core utilization on the VPS.

### 2. Aggressive PostgreSQL Hardware Tuning
**Decision:** Configure PostgreSQL specifically for 4 vCPUs, 8 GB RAM, and NVMe SSDs via a dedicated `custom.conf`.
**Rationale:** The default PostgreSQL configuration is extremely conservative. We set `shared_buffers = 2GB` (25% of RAM) and `effective_cache_size = 6GB`. For NVMe SSDs, `random_page_cost` is lowered to `1.1` and `effective_io_concurrency` is raised to `200` to inform the query planner about the fast random I/O capabilities of the storage.

### 3. Automated Certificate Distribution
**Decision:** Implement a custom deploy-hook `/etc/letsencrypt/renewal-hooks/deploy/vps-db-certs.sh`.
**Rationale:** Let's Encrypt certificates renew every 60-90 days. Manually copying these to the databases is prone to error. The deploy-hook ensures that every time Certbot renews a certificate, it is automatically copied to the correct PostgreSQL and Redis directories with the correct file permissions (`0600` / `0640`), followed by a seamless service reload.

---

## Security Model

The stack adopts a defense-in-depth approach:
- **Authentication:** `scram-sha-256` is mandated for all PostgreSQL connections.
- **Encryption in Transit:** Both PostgreSQL and all Redis instances are configured to require TLS using valid Let's Encrypt certificates.
- **Authorization & Network:** UFW drops all traffic to database ports by default. Access is exclusively granted to predefined `TRUSTED_IPS`.
- **System Hardening:** Fail2Ban continuously monitors for SSH brute-force attempts.

---

## Troubleshooting & Maintenance

- **Certbot Renewal Failures:** Ensure that port 80 is not blocked or used by another process. The standalone authenticator requires it.
- **Redis Connection Refused:** Verify that the per-app instance is running (`systemctl status redis@<app>`) and that you are connecting with the `--tls` flag.
- **Logs:** Review the main setup log at `/var/log/vps-setup.log`. PostgreSQL logs are rotated daily in `/var/lib/postgresql/17/main/log/`.
