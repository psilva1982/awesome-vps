#!/usr/bin/env bash
# ==============================================================================
# create_app_redis.sh - Cria instância Redis isolada por app
# ==============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.1.0"

readonly REDIS_BASE_PORT=6380
readonly REDIS_CONFIG_DIR="/etc/redis"
readonly REDIS_SERVICE_DIR="/etc/systemd/system"
readonly REDIS_TLS_DIR="/etc/ssl/redis"
readonly VPS_SETUP_CONF="/etc/vps-setup.conf"

usage() {
cat <<EOF
Uso: ${SCRIPT_NAME} [OPÇÕES] <nome_do_app>

Cria instância Redis isolada com senha aleatória forte.

OPÇÕES:
  -h, --help        Ajuda
  -v, --version     Versão
  -l, --length N   Tamanho da senha (>=16, padrão: 32)
  -o, --output FILE Salvar credenciais
  -p, --port PORTA Porta TCP (padrão: automático)

Exemplo:
  ${SCRIPT_NAME} meuapp
  ${SCRIPT_NAME} --port 6380 meuapp

TLS: se existirem certificados em ${REDIS_TLS_DIR} (server.crt/server.key,
provisionados pelo setup.sh via Let's Encrypt), a instância é criada com TLS
habilitado (tls-port, plaintext desabilitado) e exposta para acesso remoto —
o firewall restringe as origens. Sem certificados, comportamento original:
plaintext apenas em localhost.
EOF
}

log_info()  { printf '[INFO] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

# ------------------------------------------------------------------------------
generate_password() {
    local -r length="${1:-32}"

    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#$%^&*_+=-' | head -c "$length"
    else
        LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*_+=-' </dev/urandom | head -c "$length"
    fi
}

# ------------------------------------------------------------------------------
tls_available() {
    [[ -f "${REDIS_TLS_DIR}/server.crt" && -f "${REDIS_TLS_DIR}/server.key" ]]
}

# ------------------------------------------------------------------------------
validate_app_name() {
    local name="$1"
    [[ "$name" =~ ^[a-z_][a-z0-9_]*$ ]]
}

# ------------------------------------------------------------------------------
get_next_port() {
    local app_name="$1"
    local port=$((REDIS_BASE_PORT))

    while ss -tlnp 2>/dev/null | grep ":${port} " >/dev/null; do
        port=$((port + 1))
    done

    printf '%s' "$port"
}

# ------------------------------------------------------------------------------
check_service_exists() {
    local app_name="$1"
    systemctl list-unit-files "redis@${app_name}.service" 2>/dev/null | grep "redis@${app_name}" >/dev/null
}

# ------------------------------------------------------------------------------
check_port_in_use() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep ":${port} " >/dev/null
}

# ------------------------------------------------------------------------------
create_redis_config() {
    local app_name="$1"
    local port="$2"
    local password="$3"

    local config_file="${REDIS_CONFIG_DIR}/redis-${app_name}.conf"
    local maxmemory="${4:-256mb}"

    local network_block
    if tls_available; then
        # TLS: porta cifrada exposta (o firewall restringe as origens);
        # plaintext desabilitado (port 0)
        network_block="tls-port ${port}
port 0
bind 0.0.0.0 ::
tls-cert-file ${REDIS_TLS_DIR}/server.crt
tls-key-file ${REDIS_TLS_DIR}/server.key
tls-auth-clients no"
        log_info "TLS habilitado (certificados em ${REDIS_TLS_DIR})"
    else
        network_block="port ${port}
bind 127.0.0.1 ::1"
        log_info "Sem certificados em ${REDIS_TLS_DIR}: instância plaintext em localhost"
    fi

    tee "$config_file" > /dev/null << EOF
# =============================================================================
# Redis config - ${app_name}
# =============================================================================

${network_block}
protected-mode yes
daemonize no
supervised systemd
pidfile /var/run/redis/redis-${app_name}.pid
loglevel notice
logfile /var/log/redis/redis-${app_name}.log

# Security
requirepass ${password}
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command KEYS ""
rename-command DEBUG ""

# Memory
maxmemory ${maxmemory}
maxmemory-policy allkeys-lru
maxmemory-samples 5

# Persistence
save ""
appendonly yes
appendfilename "appendonly-${app_name}.aof"
appendfsync everysec
EOF

    chown redis:redis "$config_file"
    chmod 640 "$config_file"

    log_info "Config criado: ${config_file}"
}

# ------------------------------------------------------------------------------
create_systemd_override() {
    local app_name="$1"
    local config_file="${REDIS_CONFIG_DIR}/redis-${app_name}.conf"

    local override_dir="${REDIS_SERVICE_DIR}/redis@${app_name}.service.d"
    mkdir -p "$override_dir"

    tee "${override_dir}/override.conf" > /dev/null << EOF
[Service]
ExecStart=
ExecStart=/usr/bin/redis-server ${config_file} --supervised systemd
Restart=always
RestartSec=3
EOF

    log_info "Systemd override criado"
}

# ------------------------------------------------------------------------------
enable_and_start() {
    local app_name="$1"

    systemctl daemon-reload
    systemctl enable "redis@${app_name}" 2>/dev/null || \
        systemctl enable redis-server 2>/dev/null

    if systemctl start "redis@${app_name}" 2>/dev/null; then
        log_info "Serviço iniciado: redis@${app_name}"
    elif systemctl start redis-server 2>/dev/null; then
        log_info "Serviço redis-server iniciado"
    else
        log_error "Falha ao iniciar Redis"
        return 1
    fi

    sleep 1
    return 0
}

# ------------------------------------------------------------------------------
test_connection() {
    local port="$1"
    local password="$2"

    local -a tls_opts=()
    if tls_available; then
        # O cert é válido para o domínio; o teste local usa 127.0.0.1,
        # então a verificação de hostname é dispensada
        tls_opts=(--tls --insecure)
    fi

    if timeout 5 redis-cli "${tls_opts[@]}" -p "$port" -a "$password" PING 2>/dev/null | grep "PONG" >/dev/null; then
        log_info "Conexão testada OK"
        return 0
    fi

    log_error "Falha no teste de conexão"
    return 1
}

# ------------------------------------------------------------------------------
main() {
    local password_length=32
    local output_file=""
    local port=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
            -l|--length)
                [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ || "$2" -lt 16 ]] && {
                    log_error "Tamanho inválido (>=16)"
                    exit 2
                }
                password_length="$2"; shift 2 ;;
            -o|--output)
                [[ -z "${2:-}" ]] && {
                    log_error "Falta argumento para --output"
                    exit 2
                }
                output_file="$2"; shift 2 ;;
            -p|--port)
                [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]] && {
                    log_error "Porta inválida"
                    exit 2
                }
                port="$2"; shift 2 ;;
            -*) log_error "Opção desconhecida: $1"; exit 2 ;;
            *) break ;;
        esac
    done

    [[ $# -lt 1 ]] && {
        log_error "Nome do app é obrigatório"
        usage
        exit 2
    }

    local app_name="$1"

    validate_app_name "$app_name" || {
        log_error "Nome inválido"
        exit 2
    }

    if check_service_exists "$app_name"; then
        log_error "Instância já existe: ${app_name}"
        exit 3
    fi

    if [[ -z "$port" ]]; then
        port=$(get_next_port "$app_name")
        log_info "Porta selecionada: ${port}"
    else
        if check_port_in_use "$port"; then
            log_error "Porta ${port} já em uso"
            exit 2
        fi
    fi

    local password
    password=$(generate_password "$password_length")

    if [[ -z "$password" ]]; then
        log_error "Falha ao gerar senha"
        exit 1
    fi

    log_info "Criando instância Redis para: ${app_name}"

    create_redis_config "$app_name" "$port" "$password"
    create_systemd_override "$app_name"
    enable_and_start "$app_name" || exit 1
    test_connection "$port" "$password" || exit 1

    local host="localhost"
    local scheme="redis"
    if tls_available; then
        scheme="rediss"
        # Clientes TLS validam o hostname: usa o domínio do cert quando conhecido
        if [[ -r "$VPS_SETUP_CONF" ]]; then
            local conf_domain
            conf_domain=$(grep -oP '^DOMAIN="\K[^"]+' "$VPS_SETUP_CONF" || true)
            [[ -n "$conf_domain" ]] && host="$conf_domain"
        fi
    fi

    local redis_url="${scheme}://:${password}@${host}:${port}"

    if [[ -n "$output_file" ]]; then
        umask 177
        cat > "$output_file" <<EOF
# Redis credentials
REDIS_HOST=${host}
REDIS_PORT=${port}
REDIS_PASSWORD=${password}
REDIS_URL=${redis_url}
EOF
        log_info "Credenciais salvas em: ${output_file}"
    else
        echo "========================================"
        echo " Redis - ${app_name}"
        echo "========================================"
        echo "HOST: $host"
        echo "PORT: $port"
        echo "PASS: $password"
        echo "URL:  $redis_url"
        echo "========================================"
    fi

    log_info "Concluído!"
}

main "$@"
