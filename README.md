# Graylog Docker

Servidor central de **SYSLOG** (rede de telecom: switches/roteadores IP/MPLS, Huawei, Datacom, MikroTik, Cisco, Linux) com **Graylog Open + Graylog Data Node** e **MongoDB externo**, pronto para **Docker Compose** e **Coolify**.

| Componente | Versão (fixa) |
|---|---|
| Graylog Open (`graylog/graylog`) | **7.1.10** |
| Graylog Data Node (`graylog/graylog-datanode`) | **7.1.10** (sempre igual ao Graylog Server) |
| MongoDB (recurso externo) | 7.x a 8.2.x (matriz oficial do Graylog 7.1) |

## Arquitetura

```text
Equipamentos de rede
      | SYSLOG TCP/UDP 5140 (direto no host, fora do proxy HTTP)
      v
+---------------------+        HTTPS 443 (proxy do Coolify) --> :9000
|   Graylog Server    |<------ Web/API
+----------+----------+
           | rede interna "graylog"
+----------v----------+
|  Graylog Data Node  |  OpenSearch embutido (8999/9200/9300 só internos)
+----------+----------+
           |
           +---- rede privada do Coolify ----> MongoDB (recurso separado)
```

Detalhes em [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Requisitos

- Host Linux com Docker Engine + plugin Compose, **>= 16 GB RAM** (mín. 8 GB), disco conforme [docs/STORAGE.md](docs/STORAGE.md).
- `vm.max_map_count >= 262144` no host (`./scripts/check-host.sh` verifica e sugere os comandos).
- MongoDB 7.x–8.2.x como recurso separado, com usuário dedicado ([docs/MONGODB.md](docs/MONGODB.md)).

## Quick Start (Docker Compose direto no servidor)

```bash
cp .env.example .env
./scripts/generate-password-secret.sh          # -> GRAYLOG_PASSWORD_SECRET
./scripts/generate-admin-password-hash.sh      # -> GRAYLOG_ROOT_PASSWORD_SHA2
$EDITOR .env                                    # MONGODB_URI, segredos, GRAYLOG_HTTP_EXTERNAL_URI
./scripts/check-host.sh
./scripts/check-mongodb.sh
docker compose config -q
docker compose up -d
docker compose ps
```

Na primeira subida o Graylog mostra uma **UI de preflight** (configuração do Data Node); siga [docs/FIRST-BOOT.md](docs/FIRST-BOOT.md).
A porta 9000 **não** é publicada no host: a Web/API é servida por um proxy HTTPS (Coolify) apontando para o container na porta 9000.

## Variáveis obrigatórias

| Variável | Descrição |
|---|---|
| `GRAYLOG_VERSION`, `DATANODE_VERSION` | Tags fixas das imagens (iguais entre si) |
| `MONGODB_URI` | Connection string completa do MongoDB externo (usuário/senha URL-encoded) |
| `GRAYLOG_PASSWORD_SECRET` | Segredo único (96 chars) compartilhado por Server e Data Node |
| `GRAYLOG_ROOT_PASSWORD_SHA2` | SHA-256 da senha do usuário `admin` |
| `GRAYLOG_HTTP_EXTERNAL_URI` | URL pública HTTPS terminada em `/` |

Opcionais (com padrão): `GRAYLOG_HTTP_BIND_ADDRESS`, `TZ`, `GRAYLOG_ROOT_TIMEZONE`, `SYSLOG_PORT`, `GRAYLOG_MESSAGE_JOURNAL_MAX_SIZE`, `GRAYLOG_MESSAGE_JOURNAL_MAX_AGE`, `GRAYLOG_SERVER_JAVA_OPTS`, `DATANODE_HEAP`, `HEALTHCHECK_ALLOW_PREFLIGHT`. Tudo comentado em [.env.example](.env.example).

## Deployment no Coolify

Resumo: criar o MongoDB como recurso separado → criar usuário/database `graylog` → novo recurso *Docker Compose* a partir deste repositório → variáveis de ambiente → habilitar *Connect to predefined network* → domínio `https://graylog.seudominio.com:9000` → portas 5140 TCP/UDP publicadas pelo compose → deploy.
Guia completo: [docs/COOLIFY.md](docs/COOLIFY.md).

## Portas

| Porta | Proto | Exposição | Uso |
|---|---|---|---|
| 5140 (`SYSLOG_PORT`) | TCP e UDP | **Publicada no host** (restrinja por firewall) | Inputs Syslog |
| 9000 | TCP | Somente `expose` (proxy do Coolify → HTTPS) | Web/API Graylog |
| 8999, 9200, 9300 | TCP | **Somente internas** (Data Node/OpenSearch) | API do Data Node, OpenSearch HTTP, transporte |
| 27017 | TCP | Externo ao compose (rede privada) | MongoDB |

## Volumes

| Volume | Caminho no container | Conteúdo |
|---|---|---|
| `graylog-data` | `/usr/share/graylog/data` | `config/node-id`, **`journal/`**, content packs, plugins |
| `graylog-datanode` | `/var/lib/graylog-datanode` | `node-id`, certificados, **dados/índices do OpenSearch** |

## Healthcheck

- **Graylog**: `GET /api/system/lbstatus` → `200 ALIVE`. Durante o preflight o endpoint não existe (404); com `HEALTHCHECK_ALLOW_PREFLIGHT=true` isso é tolerado para o proxy alcançar a UI de setup. Depois do setup, use `false`.
- **Data Node**: connect TCP na API do Data Node (`8999`), que já responde durante o preflight.
- Falha de healthcheck não reinicia containers; a política é `restart: unless-stopped`.

## Documentação

[ARCHITECTURE](docs/ARCHITECTURE.md) · [COOLIFY](docs/COOLIFY.md) · [FIRST-BOOT](docs/FIRST-BOOT.md) · [MONGODB](docs/MONGODB.md) · [SYSLOG](docs/SYSLOG.md) · [STORAGE](docs/STORAGE.md) · [BACKUP](docs/BACKUP.md) · [SECURITY](docs/SECURITY.md) · [OPERATIONS](docs/OPERATIONS.md) · [TROUBLESHOOTING](docs/TROUBLESHOOTING.md)

Scripts em [`scripts/`](scripts/): `generate-password-secret.sh`, `generate-admin-password-hash.sh`, `check-host.sh`, `check-mongodb.sh`, `status.sh`, `backup-info.sh`.

## Licença

Veja [LICENSE](LICENSE). Graylog e Data Node são licenciados sob SSPL-1.0 pela Graylog, Inc.