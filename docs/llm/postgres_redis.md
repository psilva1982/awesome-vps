`setup.sh` is the entrypoint. It's a step-based orchestrator:

- `STEP_SEQUENCE` array defines an ordered pipeline of `step_<name>` functions (preflight → inputs → postgres → pg_tuning → redis → firewall → fail2ban → certbot → renew_hook → pg_tls → redis_tls → summary).
- **Idempotent by design**: each step checks whether its work is already done (package installed, file already matches, cert already issued) before acting, so re-running the whole script after a failure resumes safely.
- **Bootstrap-and-re-exec pattern**: if run standalone (e.g. via `curl | bash`), `bootstrap_if_needed()` downloads the full repo tarball to `/opt/awesome-vps` and re-execs itself from `postgres_redis/setup.sh`, so relative script references (`scripts/create_app_user.sh`, `fail2ban/fail2ban-ssh.local`, etc.) resolve correctly.
- User-provided answers (domain, email, trusted IPs, **vCPUs**, **RAM in GB**) persist to `/etc/vps-setup.conf` and are reloaded on re-run instead of re-asked. vCPUs/RAM default to auto-detected values (`nproc`, `/proc/meminfo`) that the user can accept with Enter or override.
- **Hardware-aware tuning**: `compute_pg_tuning()` derives PostgreSQL settings (`shared_buffers`, `effective_cache_size`, `work_mem`, `wal_buffers`, parallelism, autovacuum workers, etc.) from the reported vCPUs/RAM using PGTune-style formulas (mixed/OLTP profile, tuned for NVMe) rather than fixed values — read this function when changing tuning logic instead of editing the heredoc's numbers directly.
- All state-changing steps log to `/var/log/vps-setup.log` via `tee`.
- Redis is installed but the default `redis-server` service is disabled; each application gets its own instance through the `redis@<app>` systemd template unit (created by this script) and provisioned by `scripts/create_app_redis.sh`. That script also reads `CPUS`/`RAM_GB` from `/etc/vps-setup.conf` (`load_server_capacity()`) to size each instance's `maxmemory` (RAM/16, clamped 128mb–2048mb) and to enable `io-threads` when ≥4 vCPUs are available.
- TLS: a single Let's Encrypt cert (via standalone certbot) is distributed to both PostgreSQL (`server.crt`/`server.key` in the PG data dir) and Redis (`/etc/ssl/redis/`) by a certbot renewal deploy-hook generated in `step_renew_hook`, so renewals auto-propagate to both services.

`postgres_redis/scripts/` — per-app lifecycle management, run individually after `setup.sh`:

- `create_app_user.sh` / `delete_app_user.sh` / `list_app_users.sh` / `change_db_user_password.sh` — PostgreSQL role+database per app, one app name = one DB + one role of the same name.
- `create_app_redis.sh` — provisions an isolated `redis@<app>` instance (own port in the `6380:6479` range, own password, TLS via the shared certs in `/etc/ssl/redis/`, capacity-aware `maxmemory`/`io-threads` as described above).
- `setup_bd_firewall.sh` — UFW rules for a DB server: SSH/80/443 open to all, PostgreSQL (5432) and Redis (6380-6479) restricted to `--trusted-ip` args only.
- `setup_web_firewall.sh` — UFW rules for a separate Traefik-fronted web server (22/80/443 open, everything else denied). This is a different server role than the DB scripts above.
