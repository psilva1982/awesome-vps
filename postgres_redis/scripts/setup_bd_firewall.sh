#!/usr/bin/env bash
# ==============================================================================
# setup_bd_firewall.sh - UFW para servidor de banco (PostgreSQL + Redis)
# ==============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="2.0.0"

readonly DB_PORT="5432"
readonly REDIS_PORT_RANGE="6380:6479"

usage() {
cat <<EOF
Uso: ${SCRIPT_NAME} [OPÇÕES] {enable|disable|status}

Configura o UFW de um servidor de banco de dados:
  - SSH, 80/tcp e 443/tcp liberados para qualquer origem (Certbot)
  - PostgreSQL (${DB_PORT}) e instâncias Redis (${REDIS_PORT_RANGE})
    liberados apenas para os IPs confiáveis informados

OPÇÕES:
  -h, --help            Ajuda
  -v, --version         Versão
  -t, --trusted-ip IP   IP ou CIDR autorizado (repetível; obrigatório em enable/disable)

AÇÕES:
  enable   Aplica default deny, libera SSH/HTTP/HTTPS e os IPs confiáveis, ativa o UFW
  disable  Remove as regras criadas para os IPs informados
  status   Mostra o status detalhado do UFW

Exemplos:
  ${SCRIPT_NAME} -t 203.0.113.10 -t 2001:db8::/64 enable
  ${SCRIPT_NAME} -t 203.0.113.10 disable
EOF
}

log_info()  { printf '[INFO] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

# ------------------------------------------------------------------------------
validate_ip() {
    local ip="$1"
    # IPv4, com CIDR opcional
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] && return 0
    # IPv6, com CIDR opcional (validação permissiva)
    [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]] && return 0
    return 1
}

# ------------------------------------------------------------------------------
allow_trusted_rules() {
    local ip="$1"
    ufw allow from "$ip" to any port "$DB_PORT" proto tcp
    ufw allow from "$ip" to any port "$REDIS_PORT_RANGE" proto tcp
}

delete_trusted_rules() {
    local ip="$1"
    ufw delete allow from "$ip" to any port "$DB_PORT" proto tcp || true
    ufw delete allow from "$ip" to any port "$REDIS_PORT_RANGE" proto tcp || true
}

# ------------------------------------------------------------------------------
main() {
    local -a trusted_ips=()
    local action=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
            -t|--trusted-ip)
                [[ -z "${2:-}" ]] && {
                    log_error "Falta argumento para --trusted-ip"
                    exit 2
                }
                validate_ip "$2" || {
                    log_error "IP/CIDR inválido: $2"
                    exit 2
                }
                trusted_ips+=("$2"); shift 2 ;;
            -*) log_error "Opção desconhecida: $1"; exit 2 ;;
            *)
                [[ -n "$action" ]] && {
                    log_error "Ação duplicada: $1"
                    exit 2
                }
                action="$1"; shift ;;
        esac
    done

    action="${action:-enable}"

    if [[ "$EUID" -ne 0 ]]; then
        log_error "Execute como root (sudo)"
        exit 1
    fi

    case "$action" in
        enable)
            [[ ${#trusted_ips[@]} -eq 0 ]] && {
                log_error "Informe ao menos um IP confiável (--trusted-ip)"
                exit 2
            }

            log_info "Aplicando políticas padrão (deny incoming / allow outgoing)..."
            ufw default deny incoming
            ufw default allow outgoing

            log_info "Liberando SSH..."
            ufw allow ssh

            log_info "Liberando HTTP (80) e HTTPS (443) para o Certbot..."
            ufw allow 80/tcp
            ufw allow 443/tcp

            local ip
            for ip in "${trusted_ips[@]}"; do
                log_info "Liberando PostgreSQL (${DB_PORT}) e Redis (${REDIS_PORT_RANGE}) para ${ip}..."
                allow_trusted_rules "$ip"
            done

            log_info "Ativando UFW..."
            ufw --force enable
            ;;

        disable)
            [[ ${#trusted_ips[@]} -eq 0 ]] && {
                log_error "Informe os IPs cujas regras devem ser removidas (--trusted-ip)"
                exit 2
            }

            log_info "Removendo regras dos IPs informados..."
            local ip
            for ip in "${trusted_ips[@]}"; do
                delete_trusted_rules "$ip"
            done

            log_info "UFW continua ativo. Use 'ufw disable' para desativá-lo por completo."
            ;;

        status)
            ufw status verbose
            ;;

        *)
            log_error "Ação desconhecida: ${action}"
            usage
            exit 2
            ;;
    esac
}

main "$@"
