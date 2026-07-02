#!/usr/bin/env bash
# ==============================================================================
# setup.sh - Bootstrap do stack n8n (docker-compose.yml)
#            Gera o .env a partir de Postgres/Redis externos (stack
#            postgres_redis) e sobe o compose atrás de um Traefik externo.
#
# Uso típico em um VPS de aplicação, com o Traefik externo já em produção
# (rede docker "traefik_public") e o Postgres/Redis já provisionados em
# outro VPS via postgres_redis/setup.sh + create_app_user.sh/create_app_redis.sh:
#
#   curl -fsSL https://raw.githubusercontent.com/psilva1982/awesome-vps/main/compose_n8n/setup.sh -o setup.sh
#   bash setup.sh
#
# O script baixa apenas o conteúdo de compose_n8n/ para /opt/awesome-vps-n8n
# (root) ou ~/.local/share/awesome-vps-n8n (usuário sem sudo, desde que
# tenha permissão para usar o Docker — grupo 'docker') e se re-executa de
# lá. É idempotente: re-executar reaproveita as respostas salvas e não
# sobrescreve o .env sem confirmação.
#
# POSIX Note: This script currently relies on bash-specific features (arrays,
# [[ ]], process substitution). For strict POSIX compliance (posix-shell-pro),
# consider migrating these constructs.
# ==============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.2.0"

readonly REPO_TARBALL_URL="https://github.com/psilva1982/awesome-vps/archive/refs/heads/main.tar.gz"
# Diretório de instalação: em /opt (todo o sistema) quando executado como
# root; sob o HOME do usuário quando executado sem sudo — assim o script
# funciona (e o bootstrap consegue escrever) com ou sem root, e não deixa um
# ${INSTALL_DIR} de propriedade de root bloqueando execuções futuras como
# usuário normal.
if [[ "$EUID" -eq 0 ]]; then
    readonly INSTALL_DIR="/opt/awesome-vps-n8n"
else
    readonly INSTALL_DIR="${HOME}/.local/share/awesome-vps-n8n"
fi
# Nome do projeto compose (ver 'name:' em docker-compose.yml) — usado no purge
# como fallback quando o docker-compose.yml não está disponível localmente.
readonly COMPOSE_PROJECT_NAME="workflow"

REPO_DIR=""
COMPOSE_DIR=""
SETUP_CONF=""
ENV_FILE=""
CURRENT_STEP="(inicialização)"
PURGE_FORCE=false

readonly STEP_SEQUENCE=(preflight inputs generate_env up summary)
readonly PURGE_SEQUENCE=(confirm down env state)

DOMAIN=""
DB_POSTGRESDB_HOST=""
DB_POSTGRESDB_PORT=""
POSTGRES_DB=""
POSTGRES_USER=""
POSTGRES_PASSWORD=""
QUEUE_BULL_REDIS_HOST=""
QUEUE_BULL_REDIS_PORT=""
QUEUE_BULL_REDIS_PASSWORD=""
N8N_ENCRYPTION_KEY=""

usage() {
cat <<EOF
Uso: ${SCRIPT_NAME} [OPÇÕES]

Gera o .env do stack n8n (compose_n8n/docker-compose.yml) a partir de
credenciais de um Postgres e um Redis externos (stack postgres_redis,
já provisionados em outro VPS) e sobe o compose com 'docker compose up -d'.

Pergunta interativamente: domínio do n8n (roteado pelo Traefik externo),
host/porta/banco/usuário/senha do PostgreSQL e host/porta/senha do Redis.
As respostas ficam em ${COMPOSE_DIR:-<repo>/compose_n8n}/.setup.conf e são
reaproveitadas em re-execuções.

Pré-requisitos: Docker + plugin 'docker compose', e uma rede docker externa
chamada 'traefik_public' apontando para um Traefik já em produção. Não exige
root: funciona com um usuário comum que esteja no grupo 'docker' (o
diretório de instalação e os arquivos de estado seguem esse usuário).

OPÇÕES:
  -h, --help        Ajuda
  -v, --version     Versão
  --purge           DESTRUTIVO: desfaz a instalação do stack n8n — para e
                    remove os containers, a rede interna e o volume n8n_data
                    (TODOS os workflows, credenciais e execuções salvos no
                    n8n), além de .env e .setup.conf.
                    NÃO afeta o Postgres/Redis externos (stack postgres_redis)
                    nem a rede 'traefik_public'. Pede confirmação (domínio ou
                    'DESINSTALAR'), a menos que -f/--force seja usado.
  -f, --force       Com --purge: pula a confirmação (útil para automação)

Exemplos:
  bash ${SCRIPT_NAME}
  bash ${SCRIPT_NAME} --purge
  bash ${SCRIPT_NAME} --purge --force
EOF
}

log_info()  { printf '[INFO] %s\n' "$*" >&2; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

on_error() {
    local line="$1"
    log_error "Falha na etapa '${CURRENT_STEP}' (linha ${line})."
    log_error "Corrija a causa e re-execute o script: as respostas salvas serão reaproveitadas."
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

# ask_secret MSG — como ask(), mas sem eco no terminal (senhas)
ask_secret() {
    local msg="$1" reply=""
    if [[ -t 0 ]]; then
        read -rsp "$msg" reply; echo >&2
    elif [[ -e /dev/tty ]]; then
        read -rsp "$msg" reply < /dev/tty; echo >&2
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

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

validate_not_empty() {
    [[ -n "$1" ]]
}

# ------------------------------------------------------------------------------
# Bootstrap: se não estamos dentro do repositório, baixa-o e re-executa de lá
bootstrap_if_needed() {
    local src="${BASH_SOURCE[0]:-}"
    local script_dir=""

    if [[ -n "$src" && "$src" != "bash" ]]; then
        script_dir="$(cd "$(dirname "$src")" && pwd)"
    fi

    if [[ -n "$script_dir" && -f "${script_dir}/docker-compose.yml" ]]; then
        REPO_DIR="$script_dir"
        COMPOSE_DIR="$script_dir"
        return 0
    fi

    log_info "Executando fora do repositório: baixando compose_n8n/ para ${INSTALL_DIR}..."

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl não encontrado. Instale curl e re-execute."
        exit 1
    fi

    # ${INSTALL_DIR} pode ter sido criado por outro usuário (ex.: root, via
    # sudo, em execução anterior); escrever nele como usuário diferente
    # falha com permissão negada. Detecta e orienta em vez de deixar o tar
    # falhar com um erro críptico.
    if [[ -e "$INSTALL_DIR" && ! -w "$INSTALL_DIR" ]]; then
        log_error "${INSTALL_DIR} existe mas não pode ser escrito pelo usuário atual ($(whoami))."
        log_error "Provavelmente foi criado por outro usuário (ex.: root, via sudo) em execução anterior."
        log_error "Ajuste a posse com: sudo chown -R \"\$(id -u):\$(id -g)\" \"${INSTALL_DIR}\""
        log_error "ou remova o diretório (sudo rm -rf \"${INSTALL_DIR}\") e re-execute."
        exit 1
    fi

    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$REPO_TARBALL_URL" | tar -xz --wildcards --strip-components=2 -C "$INSTALL_DIR" '*/compose_n8n/*'
    chmod +x "${INSTALL_DIR}/"*.sh

    REPO_DIR="$INSTALL_DIR"
    log_info "compose_n8n/ extraído. Re-executando de ${INSTALL_DIR}..."
    exec bash "${INSTALL_DIR}/setup.sh" "$@"
}

# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# .setup.conf/.env podem ter sido criados por outro usuário (ex.: root, via
# sudo) em execução anterior; escrever neles como usuário diferente falha
# com permissão negada. Detecta e orienta em vez de deixar 'set -e' matar o
# script com um erro críptico no meio de uma etapa.
check_state_files_writable() {
    local f
    for f in "$SETUP_CONF" "$ENV_FILE"; do
        if [[ -e "$f" && ! -w "$f" ]]; then
            log_error "'${f}' existe mas não pode ser escrito pelo usuário atual ($(whoami))."
            log_error "Provavelmente foi criado por outro usuário (ex.: root, via sudo) em execução anterior."
            log_error "Ajuste a posse com: sudo chown \"\$(id -u):\$(id -g)\" \"${f}\""
            exit 1
        fi
    done
}

# ------------------------------------------------------------------------------
step_preflight() {
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker não encontrado. Instale o Docker Engine e re-execute."
        return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        log_error "Plugin 'docker compose' não encontrado. Instale docker-compose-plugin e re-execute."
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        log_error "Não foi possível falar com o daemon do Docker (permissão? serviço parado?)."
        log_error "Adicione seu usuário ao grupo 'docker' ou execute com sudo."
        return 1
    fi

    log_info "Docker OK: $(docker --version)"
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
DB_POSTGRESDB_HOST="${DB_POSTGRESDB_HOST}"
DB_POSTGRESDB_PORT="${DB_POSTGRESDB_PORT}"
POSTGRES_DB="${POSTGRES_DB}"
POSTGRES_USER="${POSTGRES_USER}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
QUEUE_BULL_REDIS_HOST="${QUEUE_BULL_REDIS_HOST}"
QUEUE_BULL_REDIS_PORT="${QUEUE_BULL_REDIS_PORT}"
QUEUE_BULL_REDIS_PASSWORD="${QUEUE_BULL_REDIS_PASSWORD}"
N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY}"
EOF
    log_info "Respostas salvas em ${SETUP_CONF}"
}

step_inputs() {
    load_conf

    while [[ -z "$DOMAIN" ]]; do
        DOMAIN="$(ask "Domínio do n8n (ex.: n8n.seudominio.com): ")"
        validate_domain "$DOMAIN" || {
            log_warn "Domínio inválido: '${DOMAIN}'"
            DOMAIN=""
        }
    done

    log_info "--- PostgreSQL externo (stack postgres_redis) ---"

    while [[ -z "$DB_POSTGRESDB_HOST" ]]; do
        DB_POSTGRESDB_HOST="$(ask "Host do PostgreSQL (domínio do VPS de banco): ")"
        validate_not_empty "$DB_POSTGRESDB_HOST" || DB_POSTGRESDB_HOST=""
    done

    while ! validate_port "$DB_POSTGRESDB_PORT"; do
        DB_POSTGRESDB_PORT="$(ask "Porta do PostgreSQL [5432]: ")"
        [[ -z "$DB_POSTGRESDB_PORT" ]] && DB_POSTGRESDB_PORT="5432"
        validate_port "$DB_POSTGRESDB_PORT" || {
            log_warn "Porta inválida: '${DB_POSTGRESDB_PORT}'"
            DB_POSTGRESDB_PORT=""
        }
    done

    while [[ -z "$POSTGRES_DB" ]]; do
        POSTGRES_DB="$(ask "Nome do banco (DB_NAME de create_app_user.sh): ")"
        validate_not_empty "$POSTGRES_DB" || POSTGRES_DB=""
    done

    while [[ -z "$POSTGRES_USER" ]]; do
        POSTGRES_USER="$(ask "Usuário do PostgreSQL (DB_USER de create_app_user.sh): ")"
        validate_not_empty "$POSTGRES_USER" || POSTGRES_USER=""
    done

    while [[ -z "$POSTGRES_PASSWORD" ]]; do
        POSTGRES_PASSWORD="$(ask_secret "Senha do PostgreSQL (DB_PASSWORD): ")"
        validate_not_empty "$POSTGRES_PASSWORD" || POSTGRES_PASSWORD=""
    done

    log_info "--- Redis externo (stack postgres_redis, instância per-app com TLS) ---"

    while [[ -z "$QUEUE_BULL_REDIS_HOST" ]]; do
        QUEUE_BULL_REDIS_HOST="$(ask "Host do Redis [${DB_POSTGRESDB_HOST}]: ")"
        [[ -z "$QUEUE_BULL_REDIS_HOST" ]] && QUEUE_BULL_REDIS_HOST="$DB_POSTGRESDB_HOST"
    done

    while ! validate_port "$QUEUE_BULL_REDIS_PORT"; do
        QUEUE_BULL_REDIS_PORT="$(ask "Porta do Redis (REDIS_PORT de create_app_redis.sh) [6380]: ")"
        [[ -z "$QUEUE_BULL_REDIS_PORT" ]] && QUEUE_BULL_REDIS_PORT="6380"
        validate_port "$QUEUE_BULL_REDIS_PORT" || {
            log_warn "Porta inválida: '${QUEUE_BULL_REDIS_PORT}'"
            QUEUE_BULL_REDIS_PORT=""
        }
    done

    while [[ -z "$QUEUE_BULL_REDIS_PASSWORD" ]]; do
        QUEUE_BULL_REDIS_PASSWORD="$(ask_secret "Senha do Redis (REDIS_PASSWORD de create_app_redis.sh): ")"
        validate_not_empty "$QUEUE_BULL_REDIS_PASSWORD" || QUEUE_BULL_REDIS_PASSWORD=""
    done

    save_conf
}

# ------------------------------------------------------------------------------
# Reaproveita N8N_ENCRYPTION_KEY já persistida em .setup.conf (carregada por
# load_conf() em step_inputs); cai para um .env pré-existente como
# compatibilidade com instalações anteriores a esta versão, que só
# guardavam a chave no .env. Só gera uma chave nova se nenhuma das duas
# fontes tiver uma: a chave NUNCA pode mudar depois que o volume n8n_data é
# inicializado com ela — trocá-la depois causa 'Mismatching encryption keys'.
existing_encryption_key() {
    if [[ -n "$N8N_ENCRYPTION_KEY" ]]; then
        printf '%s' "$N8N_ENCRYPTION_KEY"
        return 0
    fi
    [[ -r "$ENV_FILE" ]] || return 0
    grep -oP '^N8N_ENCRYPTION_KEY=\K.*' "$ENV_FILE" || true
}

step_generate_env() {
    N8N_ENCRYPTION_KEY="$(existing_encryption_key)"
    if [[ -z "$N8N_ENCRYPTION_KEY" ]]; then
        # Nenhuma chave conhecida (nem em .setup.conf, nem em .env) mas o
        # volume de dados do n8n já existe: gerar uma chave nova agora vai
        # deixá-la incompatível com a que está gravada dentro do volume.
        if docker volume inspect "${COMPOSE_PROJECT_NAME}_n8n_data" >/dev/null 2>&1; then
            log_warn "O volume '${COMPOSE_PROJECT_NAME}_n8n_data' já existe, mas nenhuma"
            log_warn "N8N_ENCRYPTION_KEY foi encontrada em ${SETUP_CONF} nem em ${ENV_FILE}."
            log_warn "Gerar uma chave nova agora vai causar 'Mismatching encryption keys' ao subir o n8n."
            confirm "Gerar mesmo assim uma NOVA chave (dados existentes no volume podem ficar inacessíveis)?" || {
                log_error "Informe a chave correta em N8N_ENCRYPTION_KEY dentro de ${SETUP_CONF} e re-execute."
                exit 1
            }
        fi
        N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)"
        log_info "N8N_ENCRYPTION_KEY gerada (primeira execução)."
    else
        log_info "N8N_ENCRYPTION_KEY reaproveitada de execução anterior."
    fi

    # Persiste a chave já aqui, antes do 'confirm' abaixo: mesmo que o
    # usuário opte por não sobrescrever o .env, ou que uma etapa seguinte
    # falhe, a chave gerada/reaproveitada fica salva em .setup.conf e nunca
    # será gerada de novo nas próximas execuções.
    save_conf

    if [[ -f "$ENV_FILE" ]]; then
        confirm "Já existe um .env em ${ENV_FILE}. Sobrescrever com os valores informados?" || {
            log_info "Mantendo .env existente."
            return 0
        }
    fi

    umask 077
    cat > "$ENV_FILE" <<EOF
# Gerado por setup.sh — não editar manualmente, re-execute o script para atualizar
DOMAIN=${DOMAIN}

DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=${DB_POSTGRESDB_HOST}
DB_POSTGRESDB_PORT=${DB_POSTGRESDB_PORT}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}
DB_POSTGRESDB_SSL_ENABLED=true
DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=true
DB_POSTGRESDB_SSL_CA_FILE=

N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

EXECUTIONS_MODE=queue
QUEUE_BULL_REDIS_HOST=${QUEUE_BULL_REDIS_HOST}
QUEUE_BULL_REDIS_PORT=${QUEUE_BULL_REDIS_PORT}
QUEUE_BULL_REDIS_PASSWORD=${QUEUE_BULL_REDIS_PASSWORD}
QUEUE_BULL_REDIS_TLS=true

GENERIC_TIMEZONE=America/Sao_Paulo
N8N_PROTOCOL=https
N8N_PORT=5678
N8N_PROXY_HOPS=1
N8N_RUNNERS_ENABLED=true
EOF
    log_info ".env gerado em ${ENV_FILE}"
}

# ------------------------------------------------------------------------------
step_up() {
    if ! docker network inspect traefik_public >/dev/null 2>&1; then
        log_error "Rede docker 'traefik_public' não encontrada."
        log_error "Suba o Traefik externo (que cria essa rede) antes de continuar."
        return 1
    fi

    (cd "$COMPOSE_DIR" && docker compose up -d)
    log_info "Stack n8n iniciado."
}

# ------------------------------------------------------------------------------
step_summary() {
    echo
    echo "=============================================================="
    echo " n8n provisionado"
    echo "=============================================================="
    echo " URL:        https://${DOMAIN}"
    echo " .env:       ${ENV_FILE}"
    echo " Respostas:  ${SETUP_CONF}"
    echo
    (cd "$COMPOSE_DIR" && docker compose ps)
    echo
    echo " Logs:"
    echo "   cd ${COMPOSE_DIR} && docker compose logs -f n8n"
    echo "=============================================================="
}

# ==============================================================================
# PURGE — desfaz a instalação do stack n8n, inclusive dados (--purge)
# ==============================================================================

# Mesma detecção de COMPOSE_DIR do bootstrap_if_needed(), sem baixar o
# tarball: se o docker-compose.yml não for encontrado nem localmente nem em
# INSTALL_DIR, purge_down() cai para comandos docker diretos (fallback).
resolve_compose_dir_for_purge() {
    local src="${BASH_SOURCE[0]:-}"
    local script_dir=""

    if [[ -n "$src" && "$src" != "bash" ]]; then
        script_dir="$(cd "$(dirname "$src")" && pwd)"
    fi

    if [[ -n "$script_dir" && -f "${script_dir}/docker-compose.yml" ]]; then
        COMPOSE_DIR="$script_dir"
    elif [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
        COMPOSE_DIR="$INSTALL_DIR"
    fi
}

# ------------------------------------------------------------------------------
purge_confirm() {
    load_conf

    if [[ "$PURGE_FORCE" == true ]]; then
        log_warn "Modo --force: pulando confirmação de purge."
        return 0
    fi

    log_warn "=============================================================="
    log_warn " ATENÇÃO: isto vai REMOVER o stack n8n deste VPS:"
    log_warn "  - Containers do compose (n8n, n8n-worker) e a rede interna"
    log_warn "  - O volume n8n_data — TODOS os workflows, credenciais e"
    log_warn "    execuções salvos no n8n serão PERDIDOS"
    log_warn "  - Os arquivos .env e .setup.conf"
    log_warn ""
    log_warn " NÃO afeta: o Postgres/Redis externos (stack postgres_redis)"
    log_warn " nem a rede 'traefik_public' (compartilhada com o Traefik e"
    log_warn " possivelmente outras stacks)."
    log_warn "=============================================================="

    local expected="${DOMAIN:-}"
    local prompt
    if [[ -n "$expected" ]]; then
        prompt="Digite o domínio configurado (${expected}) ou 'DESINSTALAR' para confirmar: "
    else
        prompt="Domínio não encontrado em ${SETUP_CONF}. Digite 'DESINSTALAR' para confirmar: "
    fi

    local reply
    reply="$(ask "$prompt")"

    if [[ "$reply" == "DESINSTALAR" ]] || { [[ -n "$expected" ]] && [[ "$reply" == "$expected" ]]; }; then
        return 0
    fi

    log_error "Confirmação não corresponde. Purge cancelado."
    exit 1
}

# ------------------------------------------------------------------------------
purge_down() {
    if [[ -n "$COMPOSE_DIR" && -f "${COMPOSE_DIR}/docker-compose.yml" ]]; then
        (cd "$COMPOSE_DIR" && docker compose down --volumes --remove-orphans)
        log_info "Containers, rede interna e volume n8n_data removidos via docker compose."
        return 0
    fi

    log_warn "docker-compose.yml não encontrado; removendo pelo nome do projeto '${COMPOSE_PROJECT_NAME}'."

    local containers
    containers="$(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}")"
    if [[ -n "$containers" ]]; then
        # shellcheck disable=SC2086
        docker rm -f $containers >/dev/null
    fi

    docker volume rm -f "${COMPOSE_PROJECT_NAME}_n8n_data" >/dev/null 2>&1 || true
    docker network rm "${COMPOSE_PROJECT_NAME}_internal" >/dev/null 2>&1 || true
    log_info "Containers, rede interna e volume n8n_data removidos (fallback via docker)."
}

# ------------------------------------------------------------------------------
purge_env() {
    if [[ -n "$ENV_FILE" ]]; then
        rm -f "$ENV_FILE"
        log_info ".env removido (${ENV_FILE})."
    fi
}

# ------------------------------------------------------------------------------
purge_state() {
    if [[ -n "$SETUP_CONF" ]]; then
        rm -f "$SETUP_CONF"
        log_info "Respostas salvas removidas (${SETUP_CONF})."
    fi
    if [[ -d "$INSTALL_DIR" ]]; then
        log_warn "Cópia do repositório em ${INSTALL_DIR} não foi removida (pode estar em uso). Remova manualmente se desejar."
    fi
}

# ------------------------------------------------------------------------------
run_purge_step() {
    local step="$1"
    CURRENT_STEP="purge:${step}"
    log_info "==> Purge: ${step}"
    "purge_${step}"
}

do_purge() {
    resolve_compose_dir_for_purge
    if [[ -n "$COMPOSE_DIR" ]]; then
        SETUP_CONF="${COMPOSE_DIR}/.setup.conf"
        ENV_FILE="${COMPOSE_DIR}/.env"
    fi

    local step
    for step in "${PURGE_SEQUENCE[@]}"; do
        run_purge_step "$step"
    done

    log_info "Purge concluído."
}

# ------------------------------------------------------------------------------
run_step() {
    local step="$1"
    CURRENT_STEP="$step"
    log_info "==> Etapa: ${step}"
    "step_${step}"
}

main() {
    local purge=false
    local -a orig_args=("$@")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
            --purge) purge=true; shift ;;
            -f|--force) PURGE_FORCE=true; shift ;;
            *) log_error "Opção desconhecida: $1"; usage; exit 2 ;;
        esac
    done

    if [[ "$purge" == true ]]; then
        log_info "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} — purge — $(date -Is) ==="
        do_purge
        return 0
    fi

    bootstrap_if_needed "${orig_args[@]}"

    SETUP_CONF="${COMPOSE_DIR}/.setup.conf"
    ENV_FILE="${COMPOSE_DIR}/.env"
    check_state_files_writable

    log_info "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} — $(date -Is) ==="
    log_info "Repositório: ${REPO_DIR}"

    local step
    for step in "${STEP_SEQUENCE[@]}"; do
        run_step "$step"
    done
}

main "$@"
