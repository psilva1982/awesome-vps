#!/usr/bin/env bash
# ==============================================================================
# create_app_user.sh - Cria usuário e banco PostgreSQL com senha aleatória
# ==============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.2.0"

usage() {
cat <<EOF
Uso: ${SCRIPT_NAME} [OPÇÕES] <nome_do_app>

OPÇÕES:
  -h, --help        Ajuda
  -v, --version     Versão
  -s, --superuser   Superusuário
  -l, --length N    Tamanho da senha (>=16, padrão: 48)
  -o, --output FILE Salvar credenciais

Exemplo:
  ${SCRIPT_NAME} meuapp
EOF
}

log_info()  { printf '[INFO] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

# ------------------------------------------------------------------------------
# Geração de senha (openssl → fallback urandom)
# ------------------------------------------------------------------------------
generate_password() {
    local -r length="${1:-48}"
    local password=""

    if command -v openssl >/dev/null 2>&1; then
        password=$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9!@#$%^&*_+=-' | head -c "$length")
    else
        password=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*_+=-' </dev/urandom | head -c "$length")
    fi

    if [[ -z "$password" ]]; then
        log_error "Falha ao gerar senha"
        exit 1
    fi

    printf '%s' "$password"
}

# ------------------------------------------------------------------------------
validate_app_name() {
    local name="$1"
    [[ "$name" =~ ^[a-z_][a-z0-9_]*$ ]]
}

# ------------------------------------------------------------------------------
psql_exec() {
    sudo -u postgres psql -v ON_ERROR_STOP=1 --quiet "$@"
}

# ------------------------------------------------------------------------------
check_user_exists() {
    local username="$1"
    psql_exec -tAc "SELECT 1 FROM pg_roles WHERE rolname='${username}'" | grep -q 1
}

check_db_exists() {
    local dbname="$1"
    psql_exec -tAc "SELECT 1 FROM pg_database WHERE datname='${dbname}'" | grep -q 1
}

# ------------------------------------------------------------------------------
create_postgres_user() {
    local username="$1"
    local password="$2"
    local is_superuser="$3"

    # Escapar aspas simples
    local escaped_password
    escaped_password=$(printf "%s" "$password" | sed "s/'/''/g")

    local sql="CREATE USER ${username} WITH PASSWORD '${escaped_password}'"
    [[ "$is_superuser" == "true" ]] && sql+=" SUPERUSER"
    sql+=";"

    psql_exec -c "$sql"
}

# ------------------------------------------------------------------------------
create_postgres_database() {
    local dbname="$1"
    local owner="$2"

    psql_exec -c "CREATE DATABASE ${dbname} OWNER ${owner};"
}

# ------------------------------------------------------------------------------
main() {
    local superuser=false
    local password_length=48
    local output_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
            -s|--superuser) superuser=true; shift ;;
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
    local username="$app_name"
    local db_name="$app_name"

    validate_app_name "$app_name" || {
        log_error "Nome inválido"
        exit 2
    }

    if check_user_exists "$username"; then
        log_error "Usuário já existe"
        exit 3
    fi

    if check_db_exists "$db_name"; then
        log_error "Banco já existe"
        exit 3
    fi

    local password
    password=$(generate_password "$password_length")

    log_info "Criando usuário..."
    create_postgres_user "$username" "$password" "$superuser"

    log_info "Criando banco..."
    create_postgres_database "$db_name" "$username"

    local connection_string="postgresql://${username}:${password}@localhost:5432/${db_name}?sslmode=require"

    if [[ -n "$output_file" ]]; then
        umask 177
        cat > "$output_file" <<EOF
# PostgreSQL credentials
DB_NAME=${db_name}
DB_USER=${username}
DB_PASSWORD=${password}
DATABASE_URL=${connection_string}
EOF
        log_info "Credenciais salvas em: ${output_file}"
    else
        echo "========================================"
        echo " PostgreSQL - ${app_name}"
        echo "========================================"
        echo "USER: $username"
        echo "DB:   $db_name"
        echo "PASS: $password"
        echo "URL:  $connection_string"
        echo "========================================"
    fi

    log_info "Concluído!"
}

main "$@"
