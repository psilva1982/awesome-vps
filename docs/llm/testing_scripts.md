There's no test harness. To validate a script:

```bash
bash -n path/to/script.sh     # syntax check
shellcheck path/to/script.sh  # if available
```

Real execution requires a target Ubuntu 26.04 LTS VPS and root — these scripts install system packages, write to `/etc`, and manage `systemctl`/`ufw`/`fail2ban`, so don't run them locally.

To validate arithmetic/formula changes (e.g. tuning calculations) without a VPS, extract the relevant function with `sed` into a throwaway script, source it, and call it directly with a matrix of inputs — see the pattern used for `compute_pg_tuning()`/`default_maxmemory()` during development.

`setup.sh` supports partial re-runs of a single step for iterative testing on a real VPS:

```bash
sudo bash setup.sh --only <step>
# steps: preflight inputs postgres pg_tuning redis firewall fail2ban certbot renew_hook pg_tls redis_tls summary
```
