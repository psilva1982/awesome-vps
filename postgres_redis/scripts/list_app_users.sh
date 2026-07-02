#!/usr/bin/env bash
# ==============================================================================
# list_app_users.sh - Lista os bancos de dados (apps) e seus respectivos donos
# ==============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"

usage() {
cat <<EOF
Uso: ${SCRIPT_NAME} [OPÇÕES]

Lista todos os bancos de dados de aplicações e seus usuários donos no PostgreSQL.

OPÇÕES:
  -h, --help        Ajuda
  -v, --version     Versão

Exemplo:
  ${SCRIPT_NAME}
EOF
}

log_error() { printf '[ERROR] %s\n' "$*" >&2; }

# ------------------------------------------------------------------------------
psql_exec() {
    sudo -u postgres psql -v ON_ERROR_STOP=1 --quiet "$@"
}

# ------------------------------------------------------------------------------
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
            -*) log_error "Opção desconhecida: $1"; exit 2 ;;
            *) break ;;
        esac
    done

    local sql="
    SELECT 
        datname AS \"App (Banco de Dados)\", 
        rolname AS \"Usuário Dono\"
    FROM pg_database 
    JOIN pg_roles ON pg_database.datdba = pg_roles.oid 
    WHERE datistemplate = false 
      AND datname NOT IN ('postgres') 
    ORDER BY datname;
    "

    echo "Consultando Apps e Usuários no PostgreSQL..."
    echo
    psql_exec -c "$sql"
    echo
}

main "$@"
