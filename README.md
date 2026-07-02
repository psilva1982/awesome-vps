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

## Available Stacks

Currently, the repository includes the following robust setup stacks:

| Stack | Description | Documentation |
|-------|-------------|---------------|
| **`postgres_redis`** | A high-performance, secure database and caching server stack. Provisions **PostgreSQL 17** and **Redis 8**, fully secured with Let's Encrypt TLS, UFW, and Fail2Ban. Features per-application Redis isolation and NVMe hardware tuning. | [🔗 Architecture & Ops Guide](./postgres_redis/README.md) |
| **`compose_n8n`** | A Docker Compose stack for **n8n** (main + worker, queue mode), routed by an external Traefik. Connects to external database services (`postgres_redis` on a separate VPS). Includes an interactive `setup.sh` to generate the `.env` automatically. | [🔗 Architecture & Ops Guide](./compose_n8n/README.md) |

---


## Contributing

We welcome contributions to expand the available stacks and improve existing configurations. Please ensure any new scripts adhere to the core principles of idempotency, security by default, and clear user communication.

Ensure you test all changes on a fresh VPS environment before submitting a Pull Request.

---
*Built with ❤️ for reliable infrastructure.*
