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

### Uninstalling the Stack (`--purge`)

`setup.sh` also supports a fully destructive teardown that reverses everything above, **including all data**:

```bash
# Interactive: asks you to type the configured domain (or "DESINSTALAR") to confirm
sudo bash setup.sh --purge

# Non-interactive (automation): skips the confirmation prompt
sudo bash setup.sh --purge --force
```

`--purge` cannot be combined with `--only`. It walks its own reverse sequence (`confirm → apps → postgres → redis → certbot → firewall → fail2ban → repo_apt → state`) and is idempotent — running it twice in a row, or against a partially-provisioned host, does not error out.

What it removes:
- **Every application's data first**: all per-app PostgreSQL databases/roles and all per-app Redis instances (`redis@<app>`, their config, systemd overrides, and `/var/lib/redis/<app>` data), before touching the base stack.
- **PostgreSQL, Redis, Certbot, and Fail2Ban**, via `apt purge` plus explicit cleanup of any directories the package removal doesn't catch (`/var/lib/postgresql`, `/etc/postgresql`, `/var/lib/redis`, `/etc/redis`, `/etc/ssl/redis`).
- **The Let's Encrypt certificate and all of `/etc/letsencrypt`** (including the renewal deploy-hook).
- **All UFW rules, including SSH/80/443** (`ufw --force reset`), followed by `ufw disable`. This is intentional: `--purge` is meant to leave nothing behind. **Make sure you have out-of-band access to the VPS (e.g. your provider's web console) before running it**, since disabling UFW removes all packet filtering, and any assumption that firewall rules were your only access control is no longer true afterward.
- The apt repositories/keyrings added for Redis and PGDG, followed by `apt autoremove`.
- The stack's own state file, `/etc/vps-setup.conf`.

What it deliberately keeps: `/var/log/vps-setup.log` (audit trail of the purge itself) and the self-extracted repo copy at `/opt/awesome-vps` (only a warning is logged — the running script may itself be executing from there).

> ⚠️ There is no dry-run mode. Test `--purge` on a disposable VM before ever running it against a production VPS.

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

### 4. Full, Reversible Teardown (`--purge`)
**Decision:** Give `setup.sh` its own destructive counterpart to provisioning, rather than expecting operators to manually reverse-engineer every file/package/service it touches.
**Rationale:** An idempotent installer that can never be cleanly undone forces operators to either keep stale test VPSes around indefinitely or manually hunt down every artifact (packages, systemd units, `/etc/redis/*`, UFW rules, Let's Encrypt state) before reprovisioning. `--purge` inverts the same mental model as the install flow — an explicit, ordered sequence of steps — instead of ad-hoc cleanup, and tears down per-application data first (while services are still controllable) before removing the base stack and packages. The confirmation gate (typing the domain or `DESINSTALAR`) and full UFW reset are deliberately aggressive: this is a one-way operation, not a partial rollback.

---

## Security Model

The stack adopts a defense-in-depth approach:
- **Authentication:** `scram-sha-256` is mandated for all PostgreSQL connections.
- **Encryption in Transit:** Both PostgreSQL and all Redis instances are configured to require TLS using valid Let's Encrypt certificates.
- **Authorization & Network:** UFW drops all traffic to database ports by default. Access is exclusively granted to predefined `TRUSTED_IPS`.
- **System Hardening:** Fail2Ban continuously monitors for SSH brute-force attempts.

---

## Testing Connections from Another VPS

After provisioning, verify PostgreSQL and Redis are actually reachable and TLS-encrypted from an external machine (a workstation or a second VPS) — not just from `localhost` on the DB server itself.

**Prerequisites on the client machine:**
- `psql` (`postgresql-client`) and `redis-cli` (`redis-tools`) installed.
- The client's public IP must be inside `TRUSTED_IPS` (set during `setup.sh`, or added afterward — see below).
- Use the exact `DOMAIN` configured during setup, not the bare IP: the Let's Encrypt certificate is only valid for that hostname.

### PostgreSQL

```bash
# Quick check: any certificate is accepted, connection just needs to be encrypted
psql "sslmode=require host=db.example.com user=postgres dbname=postgres"

# Full check: validates the certificate chain AND that the hostname matches.
# Works out of the box on most clients because Let's Encrypt is a public,
# widely-trusted CA — no extra --cacert/sslrootcert needed.
psql "sslmode=verify-full host=db.example.com user=postgres dbname=postgres"

# Testing a specific application's database/role (created by create_app_user.sh)
psql "sslmode=verify-full host=db.example.com user=myapp dbname=myapp"
```

If you saved credentials with `create_app_user.sh -o <file>`, that file already contains a ready-to-use `DATABASE_URL`.

To confirm the TLS endpoint itself is up before even touching PostgreSQL auth (no `psql` required, uses `openssl`'s built-in Postgres STARTTLS support):

```bash
openssl s_client -starttls postgres -connect db.example.com:5432 -brief
```

A clean handshake showing the Let's Encrypt chain confirms TLS is served correctly, independent of whether the credentials you'll use afterward are valid.

### Redis

```bash
# TLS against the per-app instance's port (see create_app_redis.sh output / credentials file)
redis-cli --tls -h db.example.com -p <port> -a '<password>' PING
```

Unlike the local smoke test `create_app_redis.sh` runs against `127.0.0.1` (which needs `--insecure` because the cert's hostname doesn't match `127.0.0.1`), connecting via the real `DOMAIN` from another host validates the certificate normally — no `--insecure` needed.

Raw handshake check, no Redis client required:

```bash
openssl s_client -connect db.example.com:<port> -brief
```

### Troubleshooting connectivity

- **Connection refused / times out:** the client's IP isn't in `TRUSTED_IPS`. Check with `sudo ufw status verbose` on the DB server, and allow the missing IP with `sudo scripts/setup_bd_firewall.sh -t <new-ip> enable` — `enable` only adds rules for the IPs you pass, it doesn't remove previously trusted ones (use `disable -t <ip>` to revoke a specific IP).
- **TLS handshake failure or hostname mismatch:** make sure you're connecting to the `DOMAIN` from `setup.sh`, not the server's bare IP address.
- **PostgreSQL auth failed:** confirm you're using the `scram-sha-256` password generated by `create_app_user.sh` (or `change_db_user_password.sh` if rotated) for that role.
- **Redis auth failed / wrong instance:** each app has its own port and password (`/etc/redis/redis-<app>.conf`'s `requirepass`) — confirm you're pointing at the port assigned to that specific app, from `create_app_redis.sh`'s output banner or its `-o` credentials file.

---

## Troubleshooting & Maintenance

- **Certbot Renewal Failures:** Ensure that port 80 is not blocked or used by another process. The standalone authenticator requires it.
- **Redis Connection Refused:** Verify that the per-app instance is running (`systemctl status redis@<app>`) and that you are connecting with the `--tls` flag.
- **Logs:** Review the main setup log at `/var/log/vps-setup.log`. PostgreSQL logs are rotated daily in `/var/lib/postgresql/17/main/log/`. This log is preserved across `--purge` runs, so it also holds the record of any teardown performed.
- **Starting over from scratch:** if the host ends up in a broken/partial state (e.g. a failed step midway through provisioning) and resuming with a plain re-run of `setup.sh` doesn't recover it, `sudo bash setup.sh --purge --force` followed by `sudo bash setup.sh` gives you a clean slate — see [Uninstalling the Stack](#uninstalling-the-stack---purge) above.
