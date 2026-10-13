# Arquitetura

## Visão geral

```text
Equipamentos de rede (Huawei, Datacom, Cisco, MikroTik, Linux)
      |
      | SYSLOG TCP/UDP 5140  (publicado direto no host; NÃO passa pelo proxy HTTP)
      v
+------------------------------+          Usuários / API
|  graylog (Graylog Server)    |<---- HTTPS 443 --> Proxy do Coolify --> :9000
|  inputs, pipelines, streams, |
|  journal, Web/API            |
+---------------+--------------+
                | rede Docker "graylog" (bridge)
+---------------v--------------+
|  datanode (Graylog Data Node)|
|  OpenSearch embutido         |
|  8999 API | 9200 | 9300      |   (somente internas)
+---------------+--------------+
                |
                +---- rede privada do Coolify ----> MongoDB (recurso separado)
```

Ambos os containers (`graylog` e `datanode`) acessam o MongoDB pela mesma `MONGODB_URI`.

## Componentes

| Serviço | Imagem | Função |
|---|---|---|
| `graylog` | `graylog/graylog:${GRAYLOG_VERSION}` | Recebe syslog, processa, grava no Data Node, expõe Web/API |
| `datanode` | `graylog/graylog-datanode:${DATANODE_VERSION}` | Roda e gerencia o OpenSearch onde os índices ficam |
| MongoDB (externo) | recurso do Coolify | Metadados: usuários, streams, dashboards, inputs, config do cluster, **CA/certificados do Data Node** |

O MongoDB **não** é armazenamento de mensagens; as mensagens ficam nos índices do Data Node.

## Fluxo de uma mensagem

1. O equipamento envia o syslog a `host:5140` (UDP ou TCP).
2. O input Syslog do Graylog decodifica e coloca a mensagem no **journal** (disco, volume `graylog-data`).
3. Os *process buffers* aplicam extratores/pipelines/streams.
4. Os *output buffers* gravam no índice ativo do Data Node (OpenSearch).
5. Se o Data Node estiver indisponível, as mensagens **acumulam no journal** até `GRAYLOG_MESSAGE_JOURNAL_MAX_SIZE`/`MAX_AGE` (ver [STORAGE.md](STORAGE.md#journal)).

## Rede

- Rede `graylog` (bridge, definida no compose): comunicação `graylog` ↔ `datanode` pelos nomes de serviço. O Data Node registra o hostname `datanode` no MongoDB e o Graylog Server o resolve por essa rede. **Não altere `hostname:`** após o primeiro boot.
- Acesso ao MongoDB: o compose **não** define rede para ele. No Coolify, habilite *Connect to predefined network* para os containers entrarem na rede privada onde o MongoDB vive ([COOLIFY.md](COOLIFY.md)). Fora do Coolify, o MongoDB precisa ser alcançável pela `MONGODB_URI` a partir dos containers.

## Portas

| Porta | Quem | Publicação |
|---|---|---|
| 5140/tcp, 5140/udp | `graylog` | `ports:` (host = container). Restringir por firewall às redes dos equipamentos |
| 9000/tcp | `graylog` | `expose:` apenas; servida pelo proxy HTTPS do Coolify |
| 8999, 9200, 9300 | `datanode` | `expose:` apenas (internas) |

A porta 9000 não é publicada no host de propósito: publicá-la daria acesso HTTP sem TLS contornando o proxy.

## Persistência

| Volume | Montagem | Importância |
|---|---|---|
| `graylog-data` | `/usr/share/graylog/data` | `config/node-id` e `journal/` (mensagens ainda não indexadas) |
| `graylog-datanode` | `/var/lib/graylog-datanode` | `node-id`, keystores/certificados e `opensearch/data` (índices) |

O `node-id` do Graylog (`GRAYLOG_NODE_ID_FILE`) e do Data Node (`GRAYLOG_DATANODE_NODE_ID_FILE`) ficam nos volumes para que a identidade do nó sobreviva a redeploys. Perder o `node-id` faz o nó aparecer como um novo nó no cluster.

## Segredo único

`GRAYLOG_PASSWORD_SECRET` é injetado uma única vez no compose e mapeado para `GRAYLOG_PASSWORD_SECRET` (Server) e `GRAYLOG_DATANODE_PASSWORD_SECRET` (Data Node). Os dois **precisam** ser idênticos: o Data Node o usa para autenticar a comunicação com o Server e proteger o material criptográfico guardado no MongoDB.

## Decisões

| Decisão | Motivo |
|---|---|
| Série 7.1 (7.1.10) em vez de 7.2.0 | 7.2.0 foi publicada em 2026-10-12; para produção prefere-se um patch maduro. A matriz oficial aceita MongoDB 7.x–8.2.x nas duas |
| Sem `depends_on` | MongoDB é externo; o Graylog/Data Node aguardam o MongoDB sozinhos (validado: ambos retomam quando o Mongo sobe depois) |
| `restart: unless-stopped` | Recupera de crash/reboot do Docker sem religar contêineres parados à mão |
| Healthcheck não derruba container | Docker só marca `unhealthy`; evita *restart loop* no preflight |
| Sem `network_mode: host`, sem `privileged` | Mínimo privilégio; as portas necessárias são publicadas pelo Docker |
| `ulimits` (`memlock`, `nofile`) no Data Node | Recomendação oficial para o OpenSearch (confirmada na versão 7.1) |
