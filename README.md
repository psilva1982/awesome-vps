# Awesome VPS Setup Scripts

## Executive Summary

**Awesome VPS** is a curated repository of production-ready bootstrap scripts designed to provision, configure, and secure Virtual Private Servers (VPS). The primary goal of this repository is to automate the deployment of reliable, high-performance infrastructure with built-in security, intelligent resource tuning, and idempotent execution.

Whether you are setting up a standalone database server, a web application host, or a specialized microservice environment, these scripts encapsulate industry best practices to take a fresh OS installation to a production-ready state in minutes.

---

## Architecture Overview

The repository is organized into isolated "stacks", each representing a cohesive set of services tailored for a specific workload. 

Each stack is designed to be:
- **Idempotent**: Scripts can be safely re-run. If a step fails, you can fix the issue and re-execute; it will resume where it left off.
- **Interactive yet Automatable**: Collects necessary inputs (domains, emails, IPs) upfront, saves them to a configuration file (`/etc/vps-setup.conf`), and reuses them for subsequent runs.
- **Secure by Default**: Automatically integrates firewall rules (UFW), brute-force protection (Fail2Ban), and TLS encryption (Let's Encrypt).
- **Self-Bootstrapping**: Scripts can be executed directly via `curl | bash`, which will automatically clone the repository to `/opt/awesome-vps` and execute the setup locally.

---

## Example Stack: `postgres_redis`

The `postgres_redis` stack is designed to provision a dedicated, high-performance database and caching server. It targets a standard configuration (e.g., 4 vCPU, 8 GB RAM, NVMe SSD) running **Ubuntu 26.04 LTS**.

### Core Components

1. **PostgreSQL 17 (PGDG)**: The primary relational database, configured with aggressive performance tuning tailored for modern NVMe storage and parallel query execution.
2. **Redis 8**: In-memory data store, configured to run isolated, per-application instances rather than a single shared instance.
3. **Certbot (Let's Encrypt)**: Automatically provisions and renews TLS certificates for secure, encrypted connections to both PostgreSQL and Redis.
4. **Security Layer**: UFW (Uncomplicated Firewall) for strict port-level access control, and Fail2Ban for proactive SSH protection.

### Design Decisions

- **Per-Application Redis Instances**: Instead of using a single global Redis server with numbered databases (which share a single thread and block each other), the setup creates a systemd template (`redis@.service`). Each application gets its own dedicated Redis instance running on a distinct port.
- **Mandatory TLS**: PostgreSQL is configured to enforce `hostssl` with `scram-sha-256` authentication. Passwords are not sent in plaintext, and all remote traffic is encrypted.
- **Hardware-Aware Tuning**: The PostgreSQL configuration is heavily customized for 8GB RAM and 4 vCPUs, allocating appropriate `shared_buffers` (2GB), `work_mem` (16MB), and optimizing for NVMe SSDs (`random_page_cost = 1.1`).
- **Idempotency and State Management**: State is maintained via `/etc/vps-setup.conf`. The script tracks progression through a defined `STEP_SEQUENCE` (e.g., `preflight`, `postgres`, `certbot`, `pg_tls`), making it resilient to transient failures (like APT repository unavailability).

### Security Model

1. **Firewall (UFW)**: The database ports are implicitly blocked to the public internet. Access is exclusively restricted to the `TRUSTED_IPS` provided during the initial setup.
2. **Brute-force Prevention**: Fail2Ban monitors authentication logs and automatically bans IPs exhibiting malicious SSH login attempts.
3. **Certificate Distribution**: A custom deploy-hook (`/etc/letsencrypt/renewal-hooks/deploy/vps-db-certs.sh`) automatically distributes renewed Let's Encrypt certificates to the PostgreSQL data directory and the shared Redis TLS directory, applying correct permissions (`0600` for Postgres, `0640` for Redis) and reloading the services seamlessly.

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

## Requirements and Prerequisites

- **OS**: Ubuntu 26.04 LTS (Strictly enforced by the preflight checks).
- **DNS**: The target domain must have an A/AAAA record pointing to the public IP of the VPS *before* executing the setup (required for Certbot standalone validation).
- **Network**: Port 80 must be temporarily free during the initial certificate provisioning.
- **Permissions**: Root access or `sudo` privileges.

## Contributing

We welcome contributions to expand the available stacks and improve existing configurations. Please ensure any new scripts adhere to the core principles of idempotency, security by default, and clear user communication.

Ensure you test all changes on a fresh VPS environment before submitting a Pull Request.

---
*Built with ❤️ for reliable infrastructure.*
