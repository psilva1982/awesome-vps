Most scripts (the newer ones) follow this pattern — match it when adding new scripts:

- `#!/usr/bin/env bash` + `set -Eeuo pipefail` + `shopt -s inherit_errexit`.
- `readonly SCRIPT_NAME`/`SCRIPT_VERSION`, a `usage()` heredoc, `-h/--help` and `-v/--version` flags. Bump `SCRIPT_VERSION` when changing a script's behavior/options.
- `log_info`/`log_warn`/`log_error` helpers printing to stderr with `[INFO]`/`[WARN]`/`[ERROR]` prefixes.
- User-facing prompts/comments/log messages are in **Portuguese** (pt-BR); code identifiers are in English.
- Root check: `[[ "$EUID" -ne 0 ]]` guard at the top of `main()`.
- App/service names validated with `^[a-z_][a-z0-9_]*$`.
- Passwords generated via `openssl rand -base64 64 | tr -dc '<charset>' | head -c <length>` with a `/dev/urandom` fallback if `openssl` is unavailable.
- Credential output: either printed to stdout in a `====` banner, or written to a file with `umask 177`/`umask 077` beforehand (never world/group readable).
- `apt-cache policy <pkg>` output is captured into a variable and grepped (not piped directly to `grep -q`), because pipefail + `grep -q` closing the pipe early triggers SIGPIPE; also force `LC_ALL=C` since apt output is localized.
- A `clamp VALUE MIN MAX` helper (in `setup.sh`) is the standard way to bound computed integers (memory sizes, worker counts, etc.) — reuse it rather than writing ad hoc `if` chains.

A couple of older scripts (`change_db_user_password.sh`, `setup_web_firewall.sh`) predate this convention and are simpler `#!/bin/bash` scripts without the strict-mode/logging scaffolding — don't assume every script follows the pattern above.
