# n8n Stack (Docker Compose)

## Resumo

Este diretório sobe o **n8n** em modo `queue` (main + worker) via Docker Compose, roteado por um **Traefik externo** já em produção. O PostgreSQL e o Redis usados pelo n8n **não** rodam neste compose: são instâncias externas, per-app, provisionadas pelo stack [`postgres_redis`](../postgres_redis/README.md) em outro VPS.

O `setup.sh` deste diretório pergunta as credenciais desse Postgres/Redis externos, gera o `.env` e sobe o compose — sem provisionar Traefik, Postgres ou Redis (isso é feito por outros stacks/scripts).

---

## Pré-requisitos

- **Docker Engine** + plugin **`docker compose`** instalados no VPS de aplicação.
- Uma rede Docker externa chamada **`traefik_public`**, criada pelo Traefik que já roteia o tráfego HTTPS deste VPS (fora do escopo deste diretório).
- Um **PostgreSQL** e um **Redis** já provisionados no VPS de banco via `postgres_redis/setup.sh`, com usuário/DB e instância criados por:
  ```bash
  sudo /opt/awesome-vps/postgres_redis/scripts/create_app_user.sh n8n -o /root/n8n-pg.env
  sudo /opt/awesome-vps/postgres_redis/scripts/create_app_redis.sh n8n -o /root/n8n-redis.env
  ```
  Esses dois arquivos de saída (`DB_NAME`/`DB_USER`/`DB_PASSWORD` e `REDIS_HOST`/`REDIS_PORT`/`REDIS_PASSWORD`) são exatamente o que o `setup.sh` abaixo vai pedir.
- O domínio do n8n (ex.: `n8n.seudominio.com`) já apontando via DNS para este VPS, com o Traefik cuidando do certificado TLS.

---

## Uso

```bash
curl -fsSL https://raw.githubusercontent.com/psilva1982/awesome-vps/main/compose_n8n/setup.sh -o setup.sh
bash setup.sh
```

O script:

1. **preflight** — confere `docker` e o plugin `docker compose`.
2. **inputs** — pergunta domínio do n8n, host/porta/banco/usuário/senha do PostgreSQL e host/porta/senha do Redis. As respostas ficam em `.setup.conf` (reaproveitadas em re-execuções).
3. **generate_env** — escreve `.env` a partir das respostas. Gera `N8N_ENCRYPTION_KEY` automaticamente na primeira execução e a **preserva** em execuções seguintes (essa chave nunca pode mudar depois de criada). Se já existir um `.env`, pede confirmação antes de sobrescrever.
4. **up** — confere se a rede `traefik_public` existe e roda `docker compose up -d`.
5. **summary** — mostra a URL, o status dos containers e onde ver os logs.

É idempotente: re-executar reaproveita `.setup.conf` e não perde a `N8N_ENCRYPTION_KEY`.

---

## Arquitetura do compose

| Serviço | Papel |
|---|---|
| `n8n` | Instância principal (UI, API, webhooks). Exposta ao Traefik via labels (`traefik.http.routers.n8n...`), na rede externa `traefik_public`. |
| `n8n-worker` | Processa as execuções da fila (`command: worker`), 2 réplicas. Não é exposto ao Traefik — fica só na rede `internal`. |

Ambos os serviços conversam com o Postgres e o Redis externos (TLS obrigatório em ambos) via variáveis de ambiente carregadas do `.env`; nenhum banco de dados roda neste compose.

O volume `./certs` (montado em `/certs` nos containers) existe para o caso do Postgres externo usar uma CA própria — aponte `DB_POSTGRESDB_SSL_CA_FILE` para o arquivo dentro dele. Com Let's Encrypt (padrão do `postgres_redis`), não é necessário.

---

## Variáveis de ambiente

Veja `.env.example` para a lista completa e comentada. As principais:

- `DOMAIN` — domínio do n8n, usado no roteamento do Traefik e no `WEBHOOK_URL`.
- `DB_POSTGRESDB_HOST`, `DB_POSTGRESDB_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` — conexão com o Postgres externo (TLS obrigatório).
- `QUEUE_BULL_REDIS_HOST`, `QUEUE_BULL_REDIS_PORT`, `QUEUE_BULL_REDIS_PASSWORD` — conexão com a instância Redis externa (TLS obrigatório, `QUEUE_BULL_REDIS_TLS=true`).
- `N8N_ENCRYPTION_KEY` — gerada pelo `setup.sh`; se for preencher manualmente, gere com `openssl rand -hex 32` e **nunca** altere depois.

---

## Operação

```bash
# Ver logs
docker compose logs -f n8n
docker compose logs -f n8n-worker

# Reiniciar após alterar o .env
bash setup.sh   # reaplica .env e sobe de novo
# ou, manualmente:
docker compose up -d

# Escalar workers
docker compose up -d --scale n8n-worker=4
```

## Troubleshooting

- **`docker network inspect traefik_public` falha**: o Traefik externo ainda não está rodando neste VPS, ou a rede tem outro nome. Suba o Traefik primeiro.
- **n8n não conecta no Postgres/Redis**: confirme que o IP deste VPS está em `TRUSTED_IPS` no `postgres_redis/setup.sh` do VPS de banco (veja a seção de troubleshooting em [`postgres_redis/README.md`](../postgres_redis/README.md#troubleshooting-connectivity)).
- **Erro de certificado/TLS no Redis ou Postgres**: use o mesmo `DOMAIN` do VPS de banco (não o IP) — o certificado Let's Encrypt só é válido para esse hostname.
