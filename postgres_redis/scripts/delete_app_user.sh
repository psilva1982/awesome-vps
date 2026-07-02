#!/usr/bin/env bash
# ==============================================================================
# delete_app_user.sh - Exclui usuário e banco PostgreSQL do app
# ==============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"

usage() {
cat <<EOF
Uso: ${SCRIPT_NAME} [OPÇÕES] <nome_do_app>

OPÇÕES:
  -h, --help        Ajuda
  -v, --version     Versão
  -f, --force       Não pedir confirmação (útil para automação)

Exemplo:
  ${SCRIPT_NAME} meuapp
EOF
}

log_info()  { printf '[INFO] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

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
terminate_connections() {
    local dbname="$1"
    # Tenta encerrar as conexões ativas com o banco para permitir o DROP
    psql_exec -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${dbname}' AND pid <> pg_backend_pid();" > /dev/null || true
}

# ------------------------------------------------------------------------------
drop_postgres_database() {
    local dbname="$1"
    terminate_connections "$dbname"
    psql_exec -c "DROP DATABASE IF EXISTS ${dbname};"
}

# ------------------------------------------------------------------------------
drop_postgres_user() {
    local username="$1"
    # A exclusão do banco de dados já remove os objetos que o usuário possuía nele.
    # Caso o usuário possua privilégios em outros bancos, a exclusão falhará,
    # exigindo ação manual ou um DROP OWNED BY.
    psql_exec -c "DROP USER IF EXISTS ${username};"
}

# ------------------------------------------------------------------------------
main() {
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
            -f|--force) force=true; shift ;;
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
        log_error "Nome inválido. Deve conter apenas letras minúsculas, números e sublinhados."
        exit 2
    }

    if ! check_db_exists "$db_name" && ! check_user_exists "$username"; then
        log_error "Banco de dados e usuário '${app_name}' não existem."
        exit 3
    fi

    if [[ "$force" == "false" ]]; then
        read -r -p "Tem certeza que deseja EXCLUIR o banco e o usuário '${app_name}'? Isso apagará TODOS os dados! [s/N] " confirm
        if [[ ! "$confirm" =~ ^[sS]$ ]]; then
            log_info "Operação cancelada."
            exit 0
        fi
    fi

    if check_db_exists "$db_name"; then
        log_info "Excluindo banco de dados '${db_name}'..."
        drop_postgres_database "$db_name"
    else
        log_info "Banco de dados '${db_name}' não encontrado, pulando..."
    fi

    if check_user_exists "$username"; then
        log_info "Excluindo usuário '${username}'..."
        drop_postgres_user "$username"
    else
        log_info "Usuário '${username}' não encontrado, pulando..."
    fi

    log_info "Concluído!"
}

main "$@"
