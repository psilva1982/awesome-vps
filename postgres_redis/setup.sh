#!/usr/bin/env bash
# ==============================================================================
# setup.sh - Bootstrap de VPS de banco de dados
#            PostgreSQL 17 + Redis 8 + Certbot/TLS + UFW + Fail2Ban
#
# Uso típico em um VPS Ubuntu 26.04 LTS recém-criado:
#   curl -fsSL https://raw.githubusercontent.com/psilva1982/awesome-vps/main/postgres_redis/setup.sh -o setup.sh
#   sudo bash setup.sh
#
# O script baixa o repositório completo para /opt/awesome-vps e se
# re-executa de lá. É idempotente: re-executar retoma de onde parou.
#
# POSIX Note: This script currently relies on bash-specific features (arrays, 
# [[ ]], process substitution). For strict POSIX compliance (posix-shell-pro), 
# consider migrating these constructs.
# ==============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.1.0"

readonly REPO_TARBALL_URL="https://github.com/psilva1982/awesome-vps/archive/refs/heads/main.tar.gz"
readonly INSTALL_DIR="/opt/awesome-vps"
readonly SETUP_CONF="/etc/vps-setup.conf"
readonly LOG_FILE="/var/log/vps-setup.log"

readonly PG_VERSION="17"
readonly PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"
readonly PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
readonly REDIS_TLS_DIR="/etc/ssl/redis"
readonly REDIS_KEYRING="/usr/share/keyrings/redis-archive-keyring.gpg"
# Fallback quando packages.redis.io ainda não publica o codename detectado
readonly REDIS_FALLBACK_CODENAME="noble"
readonly RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/vps-db-certs.sh"

readonly STEP_SEQUENCE=(preflight inputs postgres pg_tuning redis firewall fail2ban certbot renew_hook pg_tls redis_tls summary)

REPO_DIR=""
DOMAIN=""
EMAIL=""
TRUSTED_IPS=""
CPUS=""
RAM_GB=""
UBUNTU_CODENAME_DETECTED=""
CURRENT_STEP="(inicialização)"

usage() {
cat <<EOF
Uso: ${SCRIPT_NAME} [OPÇÕES]

Provisiona um VPS Ubuntu 26.04 LTS como servidor de banco de dados:
PostgreSQL ${PG_VERSION} (PGDG), Redis 8 (packages.redis.io), certificado
Let's Encrypt com TLS no PostgreSQL e no Redis, UFW e Fail2Ban.

Pergunta interativamente: domínio (certificado), e-mail (Let's Encrypt),
IPs confiáveis (firewall) e capacidade do servidor — vCPUs e RAM — usada
no tuning do PostgreSQL e do Redis. As respostas ficam em ${SETUP_CONF}
e são reaproveitadas em re-execuções.

OPÇÕES:
  -h, --help        Ajuda
  -v, --version     Versão
  --only ETAPA      Executa apenas uma etapa (após preflight e inputs).
                    Etapas: ${STEP_SEQUENCE[*]}

Exemplos:
  sudo bash ${SCRIPT_NAME}
  sudo bash ${SCRIPT_NAME} --only certbot
EOF
}

log_info()  { printf '[INFO] %s\n' "$*" >&2; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

on_error() {
    local line="$1"
    log_error "Falha na etapa '${CURRENT_STEP}' (linha ${line})."
    log_error "Corrija a causa e re-execute o script: etapas concluídas serão puladas."
    log_error "Log completo: ${LOG_FILE}"
}
trap 'on_error $LINENO' ERR

# ------------------------------------------------------------------------------
# Entrada interativa: funciona também via 'curl | bash' (lê de /dev/tty)
ask() {
    local msg="$1" reply=""
    if [[ -t 0 ]]; then
        read -rp "$msg" reply
    elif [[ -e /dev/tty ]]; then
        read -rp "$msg" reply < /dev/tty
    else
        log_error "Sem terminal para entrada interativa. Preencha ${SETUP_CONF} e re-execute."
        exit 1
    fi
    printf '%s' "$reply"
}

confirm() {
    local reply
    reply="$(ask "$1 [s/N] ")"
    [[ "$reply" =~ ^[sSyY] ]]
}

# ------------------------------------------------------------------------------
validate_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

validate_email() {
    [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] && return 0
    [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]] && return 0
    return 1
}

validate_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]]
}

# clamp VALOR MIN MAX — limita um inteiro ao intervalo [MIN, MAX]
clamp() {
    local v="$1" min="$2" max="$3"
    if (( v < min )); then v="$min"; fi
    if (( v > max )); then v="$max"; fi
    printf '%s' "$v"
}

# ------------------------------------------------------------------------------
# Bootstrap: se não estamos dentro do repositório, baixa-o e re-executa de lá
bootstrap_if_needed() {
    local src="${BASH_SOURCE[0]:-}"
    local script_dir=""

    if [[ -n "$src" && "$src" != "bash" ]]; then
        script_dir="$(cd "$(dirname "$src")" && pwd)"
    fi

    if [[ -n "$script_dir" && -f "${script_dir}/scripts/create_app_user.sh" ]]; then
        REPO_DIR="$script_dir"
        return 0
    fi

    log_info "Executando fora do repositório: baixando para ${INSTALL_DIR}..."

    if ! command -v curl >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq curl ca-certificates
    fi

    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$REPO_TARBALL_URL" | tar -xz --strip-components=1 -C "$INSTALL_DIR"
    chmod +x "${INSTALL_DIR}/postgres_redis/"*.sh "${INSTALL_DIR}/postgres_redis/scripts/"*.sh

    log_info "Repositório extraído. Re-executando de ${INSTALL_DIR}..."
    exec bash "${INSTALL_DIR}/postgres_redis/setup.sh" "$@"
}

# ------------------------------------------------------------------------------
step_preflight() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "systemd não encontrado; este script exige Ubuntu com systemd."
        return 1
    fi

    if [[ ! -r /etc/os-release ]]; then
        log_error "/etc/os-release não encontrado."
        return 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    UBUNTU_CODENAME_DETECTED="${VERSION_CODENAME:-}"

    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "26.04" ]]; then
        log_warn "Sistema detectado: ${ID:-?} ${VERSION_ID:-?} (esperado: ubuntu 26.04)."
        confirm "Continuar mesmo assim?" || return 1
    fi

    if [[ -z "$UBUNTU_CODENAME_DETECTED" ]]; then
        log_error "Não foi possível detectar o codename do Ubuntu (VERSION_CODENAME)."
        return 1
    fi

    log_info "Sistema OK: ${PRETTY_NAME:-Ubuntu} (codename: ${UBUNTU_CODENAME_DETECTED})"
}

# ------------------------------------------------------------------------------
load_conf() {
    if [[ -r "$SETUP_CONF" ]]; then
        # shellcheck disable=SC1090
        . "$SETUP_CONF"
    fi
}

save_conf() {
    umask 077
    cat > "$SETUP_CONF" <<EOF
# Gerado por setup.sh — respostas do provisionamento (reutilizadas em re-execuções)
DOMAIN="${DOMAIN}"
EMAIL="${EMAIL}"
TRUSTED_IPS="${TRUSTED_IPS}"
CPUS="${CPUS}"
RAM_GB="${RAM_GB}"
EOF
    log_info "Respostas salvas em ${SETUP_CONF}"
}

step_inputs() {
    load_conf

    while [[ -z "$DOMAIN" ]]; do
        DOMAIN="$(ask "Domínio do servidor (ex.: db.seudominio.com): ")"
        validate_domain "$DOMAIN" || {
            log_warn "Domínio inválido: '${DOMAIN}'"
            DOMAIN=""
        }
    done

    while [[ -z "$EMAIL" ]]; do
        EMAIL="$(ask "E-mail para o Let's Encrypt (avisos de expiração): ")"
        validate_email "$EMAIL" || {
            log_warn "E-mail inválido: '${EMAIL}'"
            EMAIL=""
        }
    done

    while [[ -z "$TRUSTED_IPS" ]]; do
        TRUSTED_IPS="$(ask "IPs/CIDRs autorizados a acessar PostgreSQL/Redis (separados por espaço): ")"
        local ip ok=1
        for ip in $TRUSTED_IPS; do
            validate_ip "$ip" || {
                log_warn "IP/CIDR inválido: '${ip}'"
                ok=0
            }
        done
        [[ $ok -eq 1 ]] || TRUSTED_IPS=""
    done

    # Capacidade do servidor: usada no tuning do PostgreSQL e do Redis.
    # Detecta valores como sugestão; Enter aceita o detectado.
    local detected_cpus detected_ram_gb
    detected_cpus="$(nproc 2>/dev/null || echo 1)"
    detected_ram_gb="$(awk '/^MemTotal:/ {printf "%d", ($2 + 524288) / 1048576}' /proc/meminfo 2>/dev/null || echo 1)"
    if [[ -z "$detected_ram_gb" || "$detected_ram_gb" -lt 1 ]]; then
        detected_ram_gb=1
    fi

    while ! validate_positive_int "$CPUS"; do
        CPUS="$(ask "vCPUs do servidor [${detected_cpus}]: ")"
        if [[ -z "$CPUS" ]]; then
            CPUS="$detected_cpus"
        fi
        validate_positive_int "$CPUS" || {
            log_warn "Valor inválido: '${CPUS}' (inteiro >= 1)"
            CPUS=""
        }
    done

    while ! validate_positive_int "$RAM_GB"; do
        RAM_GB="$(ask "RAM do servidor em GB [${detected_ram_gb}]: ")"
        if [[ -z "$RAM_GB" ]]; then
            RAM_GB="$detected_ram_gb"
        fi
        validate_positive_int "$RAM_GB" || {
            log_warn "Valor inválido: '${RAM_GB}' (inteiro >= 1)"
            RAM_GB=""
        }
    done

    log_info "Capacidade informada: ${CPUS} vCPU / ${RAM_GB} GB RAM"

    # DNS: o domínio precisa apontar para este VPS antes do Certbot (standalone)
    local resolved public_ip
    resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
    public_ip="$(curl -fsS4 --max-time 10 https://ifconfig.me 2>/dev/null || true)"

    if [[ -z "$resolved" ]]; then
        log_warn "O domínio '${DOMAIN}' não resolve no DNS. A emissão do certificado vai falhar."
        confirm "Continuar mesmo assim?" || return 1
    elif [[ -n "$public_ip" && "$resolved" != "$public_ip" ]]; then
        log_warn "'${DOMAIN}' resolve para ${resolved}, mas o IP público deste VPS parece ser ${public_ip}."
        confirm "Continuar mesmo assim?" || return 1
    fi

    save_conf
}

# ------------------------------------------------------------------------------
step_postgres() {
    if dpkg -s "postgresql-${PG_VERSION}" >/dev/null 2>&1; then
        log_info "postgresql-${PG_VERSION} já instalado; pulando."
        return 0
    fi

    apt-get update -qq
    apt-get install -y postgresql-common ca-certificates

    # Adiciona o repositório PGDG (usa o codename de /etc/os-release)
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

    # Captura a saída e faz grep na variável: 'apt-cache | grep -q' sofre
    # SIGPIPE sob pipefail (grep -q fecha o pipe no primeiro match).
    # LC_ALL=C: a saída do apt é localizada (ex.: 'Candidato:' em pt_BR)
    local policy
    policy="$(LC_ALL=C apt-cache policy "postgresql-${PG_VERSION}")"
    if ! grep -q 'Candidate: [0-9]' <<< "$policy"; then
        log_error "O repositório PGDG ainda não publica postgresql-${PG_VERSION} para '${UBUNTU_CODENAME_DETECTED}'."
        log_error "Verifique https://wiki.postgresql.org/wiki/Apt e re-execute quando disponível."
        return 1
    fi

    apt-get install -y "postgresql-${PG_VERSION}"
    systemctl enable --now postgresql
    log_info "PostgreSQL ${PG_VERSION} instalado."
}

# ------------------------------------------------------------------------------
# Calcula o tuning do PostgreSQL a partir da capacidade informada (CPUS/RAM_GB).
# Fórmulas estilo PGTune (perfil misto/OLTP) para storage NVMe.
compute_pg_tuning() {
    local ram_mb=$((RAM_GB * 1024))

    PG_SHARED_BUFFERS_MB=$((ram_mb / 4))
    PG_EFFECTIVE_CACHE_MB=$((ram_mb * 3 / 4))
    PG_MAINTENANCE_MB="$(clamp $((ram_mb / 16)) 64 2048)"
    PG_MAX_CONNECTIONS=200

    # pior caso: max_connections × 2 workers × work_mem ≈ 80% da RAM
    PG_WORK_MEM_MB="$(clamp $((ram_mb * 8 / 10 / (PG_MAX_CONNECTIONS * 2))) 4 1048576)"

    PG_WAL_BUFFERS_MB="$(clamp $((PG_SHARED_BUFFERS_MB / 32)) 16 64)"
    if (( RAM_GB >= 16 )); then
        PG_MIN_WAL="2GB"
        PG_MAX_WAL="8GB"
    else
        PG_MIN_WAL="1GB"
        PG_MAX_WAL="4GB"
    fi

    PG_MAX_WORKER_PROCESSES="$CPUS"
    PG_MAX_PARALLEL_WORKERS="$CPUS"
    if (( CPUS == 1 )); then
        # 1 vCPU: paralelismo em queries só atrapalha
        PG_PARALLEL_PER_GATHER=0
    else
        PG_PARALLEL_PER_GATHER="$(clamp $((CPUS / 2)) 1 4)"
    fi
    PG_PARALLEL_MAINTENANCE="$(clamp $((CPUS / 2)) 1 4)"

    PG_AUTOVACUUM_WORKERS=3
    if (( CPUS >= 8 )); then
        PG_AUTOVACUUM_WORKERS=4
    fi
}

# ------------------------------------------------------------------------------
step_pg_tuning() {
    local custom_conf="${PG_CONF_DIR}/conf.d/custom.conf"

    compute_pg_tuning

    install -d -o postgres -g postgres "${PG_CONF_DIR}/conf.d"

    cat > "$custom_conf" <<EOF
# =============================================================
# Gerado por setup.sh para ${CPUS} vCPU / ${RAM_GB} GB RAM / NVMe
# (fórmulas estilo PGTune, perfil misto/OLTP)
# =============================================================

# =============================================================
# MEMORY
# =============================================================
shared_buffers = ${PG_SHARED_BUFFERS_MB}MB      # 25% da RAM — cache principal do PG
effective_cache_size = ${PG_EFFECTIVE_CACHE_MB}MB    # 75% da RAM — estimativa para o planner
work_mem = ${PG_WORK_MEM_MB}MB          # pior caso: ${PG_MAX_CONNECTIONS} conn × 2 workers × ${PG_WORK_MEM_MB}MB ≈ 80% da RAM
maintenance_work_mem = ${PG_MAINTENANCE_MB}MB  # VACUUM, CREATE INDEX, ALTER TABLE (RAM/16, máx 2GB)
max_connections = ${PG_MAX_CONNECTIONS}          # use pgBouncer para workloads com muitas conexões curtas

# =============================================================
# STORAGE — NVMe SSD
# =============================================================
random_page_cost = 1.1         # NVMe: custo de acesso aleatório ≈ sequencial
effective_io_concurrency = 200 # NVMe suporta alta concorrência de I/O
default_statistics_target = 500

# =============================================================
# WAL
# =============================================================
wal_buffers = ${PG_WAL_BUFFERS_MB}MB       # shared_buffers/32, entre 16MB e 64MB
min_wal_size = ${PG_MIN_WAL}
max_wal_size = ${PG_MAX_WAL}
checkpoint_completion_target = 0.9
wal_compression = on

# =============================================================
# PARALELISMO — ${CPUS} vCPUs
# =============================================================
max_worker_processes = ${PG_MAX_WORKER_PROCESSES}             # total de workers em background (= vCPUs)
max_parallel_workers = ${PG_MAX_PARALLEL_WORKERS}             # workers disponíveis para queries paralelas
max_parallel_workers_per_gather = ${PG_PARALLEL_PER_GATHER}   # workers por query (vCPUs ÷ 2 para OLTP misto, máx 4)
max_parallel_maintenance_workers = ${PG_PARALLEL_MAINTENANCE} # workers para VACUUM/CREATE INDEX

# =============================================================
# LOGGING
# =============================================================
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_line_prefix = '%t [%p] %q%u@%d '
log_timezone = 'America/Sao_Paulo'
log_min_duration_statement = 1000    # logar queries > 1 segundo
log_temp_files = 0                   # logar qualquer arquivo temporário (spill de work_mem)

# =============================================================
# MONITORAMENTO
# =============================================================
shared_preload_libraries = 'pg_stat_statements'
track_activities = on
track_counts = on
track_io_timing = on
track_wal_io_timing = on
track_functions = pl

# =============================================================
# AUTOVACUUM
# =============================================================
autovacuum_max_workers = ${PG_AUTOVACUUM_WORKERS}            # 3 = padrão PG; 4 a partir de 8 vCPUs
autovacuum_naptime = 30s
autovacuum_vacuum_threshold = 50
autovacuum_analyze_threshold = 50
autovacuum_vacuum_cost_delay = 2ms   # NVMe: reduzir throttle do autovacuum (padrão 2ms no PG17)
EOF
    chown postgres:postgres "$custom_conf"
    systemctl restart postgresql
    log_info "PostgreSQL tuning configurado em ${custom_conf} (${CPUS} vCPU / ${RAM_GB} GB RAM / NVMe)."
}

# ------------------------------------------------------------------------------
step_redis() {
    if command -v redis-server >/dev/null 2>&1 && redis-server --version | grep 'v=8\.' >/dev/null; then
        log_info "Redis 8 já instalado; pulando instalação."
    else
        apt-get install -y gnupg ca-certificates

        # Usa o codename detectado se publicado; senão cai para o LTS anterior
        # (binários do LTS anterior são compatíveis)
        local redis_dist="$UBUNTU_CODENAME_DETECTED"
        if ! curl -fsIL "https://packages.redis.io/deb/dists/${redis_dist}/Release" >/dev/null 2>&1; then
            log_warn "packages.redis.io não publica para '${redis_dist}'; usando fallback '${REDIS_FALLBACK_CODENAME}'."
            redis_dist="$REDIS_FALLBACK_CODENAME"
        fi

        curl -fsSL https://packages.redis.io/gpg | gpg --dearmor --yes -o "$REDIS_KEYRING"
        chmod 644 "$REDIS_KEYRING"
        echo "deb [signed-by=${REDIS_KEYRING}] https://packages.redis.io/deb ${redis_dist} main" \
            > /etc/apt/sources.list.d/redis.list

        # Sem '|| true': falha aqui é a causa real de erros adiante
        apt-get update

        # Captura a saída e faz grep na variável: 'apt-cache | grep -q' sofre
        # SIGPIPE sob pipefail (grep -q fecha o pipe no primeiro match).
        # LC_ALL=C: a saída do apt é localizada (ex.: 'Candidato:' em pt_BR)
        local policy
        policy="$(LC_ALL=C apt-cache policy redis-server)"
        if ! grep -q 'Candidate: [0-9]' <<< "$policy"; then
            log_error "redis-server sem candidato de instalação para '${redis_dist}'. Saída do apt:"
            printf '%s\n' "$policy" >&2
            return 1
        fi

        apt-get install -y redis
    fi

    # O serviço padrão fica desabilitado: cada app recebe sua própria
    # instância via create_app_redis.sh (unidades redis@<app>)
    systemctl disable --now redis-server 2>/dev/null || true

    # Template systemd usado pelas instâncias per-app (redis@<app>)
    local template="/etc/systemd/system/redis@.service"
    if [[ ! -f "$template" ]]; then
        cat > "$template" <<EOF
[Unit]
Description=Instância Redis por app (%i)
After=network.target

[Service]
Type=notify
User=redis
Group=redis
ExecStart=/usr/bin/redis-server /etc/redis/redis-%i.conf --supervised systemd
Restart=always
RestartSec=3
RuntimeDirectory=redis
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        log_info "Template systemd redis@.service criado."
    fi

    install -d -o redis -g redis /var/log/redis
    log_info "Redis pronto (instâncias per-app via scripts/create_app_redis.sh)."
}

# ------------------------------------------------------------------------------
step_firewall() {
    local -a args=()
    local -a ips=()
    read -ra ips <<< "$TRUSTED_IPS"

    local ip
    for ip in "${ips[@]}"; do
        args+=(-t "$ip")
    done

    bash "${REPO_DIR}/scripts/setup_bd_firewall.sh" "${args[@]}" enable
}

# ------------------------------------------------------------------------------
step_fail2ban() {
    dpkg -s fail2ban >/dev/null 2>&1 || apt-get install -y fail2ban

    local src="${REPO_DIR}/fail2ban/fail2ban-ssh.local"
    local dst="/etc/fail2ban/jail.local"
    if ! cmp -s "$src" "$dst" 2>/dev/null; then
        cp "$src" "$dst"
        log_info "Config do Fail2Ban aplicada em ${dst}"
    fi

    # Ubuntu recente sem rsyslog não tem /var/log/auth.log: usa o journal
    if [[ ! -e /var/log/auth.log ]]; then
        cat > /etc/fail2ban/jail.d/sshd-systemd.local <<EOF
[sshd]
backend = systemd
EOF
        log_info "Sem /var/log/auth.log: jail sshd configurada com backend systemd."
    fi

    systemctl enable --now fail2ban
    systemctl restart fail2ban
}

# ------------------------------------------------------------------------------
step_certbot() {
    dpkg -s certbot >/dev/null 2>&1 || apt-get install -y certbot

    if [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
        log_info "Certificado para ${DOMAIN} já emitido; pulando."
        return 0
    fi

    if ss -tln | grep -E '[:.]80[[:space:]]' >/dev/null; then
        log_error "Porta 80 em uso: o modo standalone do Certbot precisa dela livre."
        log_error "Pare o serviço que ocupa a porta 80 e re-execute."
        return 1
    fi

    certbot certonly --standalone -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive
    log_info "Certificado emitido para ${DOMAIN}."
}

# ------------------------------------------------------------------------------
step_renew_hook() {
    install -d -m 0755 "$(dirname "$RENEW_HOOK")"

    cat > "$RENEW_HOOK" <<EOF
#!/usr/bin/env bash
# Gerado por setup.sh: distribui o certificado Let's Encrypt para o
# PostgreSQL e para as instâncias Redis a cada emissão/renovação.
set -Eeuo pipefail

DOMAIN="${DOMAIN}"
PG_DATA="${PG_DATA}"
REDIS_TLS_DIR="${REDIS_TLS_DIR}"
LIVE_DIR="/etc/letsencrypt/live/\${DOMAIN}"

case " \${RENEWED_DOMAINS:-\$DOMAIN} " in
    *" \${DOMAIN} "*) ;;
    *) exit 0 ;;
esac

# PostgreSQL (chave precisa ser 0600 e pertencer ao postgres)
install -o postgres -g postgres -m 0600 "\${LIVE_DIR}/fullchain.pem" "\${PG_DATA}/server.crt"
install -o postgres -g postgres -m 0600 "\${LIVE_DIR}/privkey.pem" "\${PG_DATA}/server.key"
systemctl reload postgresql 2>/dev/null || systemctl restart postgresql

# Redis: certs compartilhados por todas as instâncias per-app
install -d -o redis -g redis -m 0750 "\${REDIS_TLS_DIR}"
install -o redis -g redis -m 0640 "\${LIVE_DIR}/fullchain.pem" "\${REDIS_TLS_DIR}/server.crt"
install -o redis -g redis -m 0640 "\${LIVE_DIR}/privkey.pem" "\${REDIS_TLS_DIR}/server.key"

shopt -s nullglob
for conf in /etc/redis/redis-*.conf; do
    app="\$(basename "\$conf" .conf)"
    app="\${app#redis-}"
    systemctl try-restart "redis@\${app}" 2>/dev/null || true
done
EOF
    chmod +x "$RENEW_HOOK"
    log_info "Deploy-hook de renovação criado: ${RENEW_HOOK}"

    # Primeira distribuição dos certs (o hook só roda sozinho nas renovações)
    RENEWED_DOMAINS="$DOMAIN" "$RENEW_HOOK"
    log_info "Certificados distribuídos para PostgreSQL e Redis."
}

# ------------------------------------------------------------------------------
step_pg_tls() {
    local ssl_conf="${PG_CONF_DIR}/conf.d/10-ssl.conf"
    local changed=0

    local desired
    desired="$(cat <<EOF
# Gerado por setup.sh — TLS e acesso remoto
listen_addresses = '*'
ssl = on
ssl_cert_file = '${PG_DATA}/server.crt'
ssl_key_file = '${PG_DATA}/server.key'
EOF
)"

    install -d -o postgres -g postgres "${PG_CONF_DIR}/conf.d"
    if [[ ! -f "$ssl_conf" ]] || [[ "$(cat "$ssl_conf")" != "$desired" ]]; then
        printf '%s\n' "$desired" > "$ssl_conf"
        chown postgres:postgres "$ssl_conf"
        changed=1
    fi

    local pg_hba="${PG_CONF_DIR}/pg_hba.conf"
    if ! grep -q '^hostssl' "$pg_hba"; then
        cat >> "$pg_hba" <<EOF

# Conexões remotas somente com TLS (setup.sh); firewall restringe as origens
hostssl all             all             0.0.0.0/0               scram-sha-256
hostssl all             all             ::/0                    scram-sha-256
EOF
        changed=1
    fi

    if [[ $changed -eq 1 ]]; then
        systemctl restart postgresql
        log_info "PostgreSQL configurado com TLS (hostssl + scram-sha-256)."
    else
        log_info "TLS do PostgreSQL já configurado; pulando."
    fi
}

# ------------------------------------------------------------------------------
step_redis_tls() {
    if [[ ! -f "${REDIS_TLS_DIR}/server.crt" || ! -f "${REDIS_TLS_DIR}/server.key" ]]; then
        log_error "Certificados não encontrados em ${REDIS_TLS_DIR} (a etapa renew_hook rodou?)."
        return 1
    fi

    log_info "Certificados TLS do Redis prontos em ${REDIS_TLS_DIR}."
    log_info "Novas instâncias criadas com scripts/create_app_redis.sh já nascem com TLS."
}

# ------------------------------------------------------------------------------
step_summary() {
    echo
    echo "=============================================================="
    echo " Provisionamento concluído"
    echo "=============================================================="
    echo " Domínio:      ${DOMAIN}"
    echo " Capacidade:   ${CPUS} vCPU / ${RAM_GB} GB RAM"
    echo " PostgreSQL:   $(psql --version 2>/dev/null || echo 'não encontrado')"
    echo " Redis:        $(redis-server --version 2>/dev/null || echo 'não encontrado')"
    echo " Certificado:  /etc/letsencrypt/live/${DOMAIN}/"
    echo " Respostas:    ${SETUP_CONF}"
    echo " Log:          ${LOG_FILE}"
    echo
    echo " Firewall:"
    ufw status verbose | sed 's/^/   /'
    echo
    echo " Próximos passos (por aplicação):"
    echo "   sudo ${REPO_DIR}/scripts/create_app_user.sh <app>    # DB + role PostgreSQL"
    echo "   sudo ${REPO_DIR}/scripts/create_app_redis.sh <app>   # instância Redis com TLS"
    echo
    echo " Verificação manual:"
    echo "   psql \"sslmode=require host=${DOMAIN} user=postgres dbname=postgres\""
    echo "   redis-cli --tls -h ${DOMAIN} -p <porta> -a <senha> PING"
    echo "=============================================================="
}

# ------------------------------------------------------------------------------
run_step() {
    local step="$1"
    CURRENT_STEP="$step"
    log_info "==> Etapa: ${step}"
    "step_${step}"
}

main() {
    local only=""
    local -a orig_args=("$@")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
            --only)
                [[ -z "${2:-}" ]] && {
                    log_error "Falta argumento para --only"
                    exit 2
                }
                only="$2"; shift 2 ;;
            *) log_error "Opção desconhecida: $1"; usage; exit 2 ;;
        esac
    done

    if [[ "$EUID" -ne 0 ]]; then
        log_error "Execute como root (sudo)"
        exit 1
    fi

    if [[ -n "$only" ]]; then
        local valid=0 step
        for step in "${STEP_SEQUENCE[@]}"; do
            [[ "$step" == "$only" ]] && valid=1
        done
        [[ $valid -eq 1 ]] || {
            log_error "Etapa desconhecida: '${only}'. Etapas: ${STEP_SEQUENCE[*]}"
            exit 2
        }
    fi

    bootstrap_if_needed "${orig_args[@]}"

    # Log completo da execução (stdout+stderr) em ${LOG_FILE}
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_info "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} — $(date -Is) ==="
    log_info "Repositório: ${REPO_DIR}"

    if [[ -n "$only" ]]; then
        run_step preflight
        run_step inputs
        if [[ "$only" != "preflight" && "$only" != "inputs" ]]; then
            run_step "$only"
        fi
    else
        local step
        for step in "${STEP_SEQUENCE[@]}"; do
            run_step "$step"
        done
    fi
}

main "$@"
