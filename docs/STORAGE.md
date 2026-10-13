# Armazenamento, Retenção e Compressão

Este documento apresenta o dimensionamento de armazenamento, política de retenção, análise técnica de codecs e detalhes de operação do Journal do Graylog para o cenário de telecomunicações.

---

## 1. Estimativa de Dimensionamento (200 a 500 Equipamentos)

### Características do Tráfego:
- **Fontes:** Switches IP/MPLS, roteadores, BGP, OSPF, interfaces, traps de hardware, autenticação.
- **NÃO incluso:** NetFlow, CGNAT (sessões massivas de NAT), DNS query logging, conexões de firewall de borda.

### Projeção Numérica:

| Métrica | Regime Normal | Janela de Pico (Flap / Ruptura de Enlace) |
|---|---|---|
| **EPS por equipamento** | 0.1 a 0.5 msg/s | 10 a 50 msg/s |
| **EPS Total do Cluster (300 eq.)** | 30 a 100 EPS | 1.000 a 3.000 EPS |
| **Volume Diário (Mensagens)** | ~2,5 a 8,5 milhões de msgs/dia | Rajadas transitórias |
| **Tamanho Médio (indexado)** | ~600 a 800 bytes / msg | ~600 a 800 bytes / msg |
| **Armazenamento Diário (bruto)** | **~2 a 6 GB / dia** | +2 a 5 GB adicionais por evento |
| **Projeção para 90 dias** | **~180 GB a 540 GB** | - |

> [!NOTE]
> A recomendação inicial é **não descartar mensagens**. Comece de forma conservadora, observe a taxa real de crescimento e defina filtros de descarte apenas para mensagens sabidamente inúteis após 30 dias de telemetria.

---

## 2. Estratégia de Retenção (Index Sets)

No Graylog, a retenção é configurada em **System** → **Indices** no *Default index set*.

### Configuração Inicial Recomendada:
- **Index Rotation Strategy:** *Index Time* (Rotação por tempo)
  - **Rotation Period:** `P1D` (1 dia)
  - *Vantagem:* Facilita expurgo e auditoria forense por data exata.
- **Index Retention Strategy:** *Delete Index* (ou *Close Index* se houver espaço)
  - **Max number of indices:** `90` (mantém 90 dias de retenção).
  - *Estimativa de disco:* ~250 GB a 500 GB no volume `graylog-datanode`.

---

## 3. Investigação Técnica de Compressão e Codecs

O Graylog Data Node utiliza internamente o **OpenSearch 2.19**. Os codecs de compressão de índices suportados pela engine são:

### Opções de Codec no OpenSearch:
1. **`default` (LZ4):**
   - **Comportamento:** Codec padrão do Lucene / OpenSearch.
   - **Vantagens:** Altíssimo throughput de escrita e busca; uso mínimo de CPU; compatibilidade universal em qualquer upgrade.
   - **Recomendação:** **Padrão de produção.**

2. **`best_compression` (DEFLATE / Zlib):**
   - **Comportamento:** Aplica algoritmo DEFLATE com taxa de compressão mais agressiva.
   - **Vantagens:** Reduz o tamanho em disco dos índices em **15% a 30%** adicionais em relação ao LZ4.
   - **Desvantagens:** Leve aumento no consumo de CPU durante tarefas de *segment merging* (fusão em background de shards).

3. **`zstd` (Zstandard):**
   - **Status Técnico:** O algoritmo Zstandard oferece excelente razão compressão/velocidade. Porém, na distribuição padrão empacotada do OpenSearch 2.19 no container oficial do Graylog Data Node 7.1, os módulos nativos de Zstandard para codec de índice Lucene não vêm ativados por padrão como codec primário de core.
   - **Diretriz de Produção:** Seguindo a diretriz de **estabilidade > compatibilidade > desempenho > compressão máxima**, **NÃO** instale bibliotecas nativas customizadas dentro do container efêmero nem force codecs não declarados oficialmente no core.

### Como Ativar `best_compression` com Segurança (Pós-Boot)
Se após o primeiro mês for desejado reduzir o espaço em disco sem afetar a estabilidade:

No OpenSearch (Data Node), os codecs são propriedades estáticas definidas na criação do índice via **Index Template**. Para que novos índices criados pelo Graylog herdem `best_compression`:

Execute via API de dentro do container `graylog`:
```bash
# Cria um template composable de prioridade para novos índices de eventos
docker exec -i $(docker ps -q -f name=graylog) curl -s -X PUT "http://datanode:9200/_index_template/telecom_best_compression" \
  -H "Content-Type: application/json" \
  -d '{
    "index_patterns": ["graylog_*", "gl-events_*"],
    "template": {
      "settings": {
        "index.codec": "best_compression"
      }
    },
    "priority": 500
  }'
```

Os índices já existentes continuam legíveis normalmente em LZ4. Os novos índices rotacionados passarão a usar `best_compression`.

---

## 4. O Graylog Message Journal

O Journal é uma fila circular persistente em disco (implementada com base em logs de commit similares ao Apache Kafka).

### Função Vital em Telecom:
Em cenários de crise na rede (ex: rompimento de fibra com flap de anel IP/MPLS de dezenas de enlaces simultâneos):
1. Milhares de mensagens chegam em poucos segundos nas portas 5140.
2. O Graylog grava os pacotes brutos imediatamente no **journal em disco** (`/usr/share/graylog/data/journal`).
3. Mesmo que o OpenSearch / Data Node esteja sob carga pesada e a taxa de indexação fique mais lenta que a recepção, **nenhuma mensagem é perdida**.
4. Se o Data Node for reiniciado para manutenção, o Graylog continua recebendo e acumulando logs no journal por até `GRAYLOG_MESSAGE_JOURNAL_MAX_AGE` (padrão: 24h) ou até atingir `GRAYLOG_MESSAGE_JOURNAL_MAX_SIZE` (padrão: 10 GB).

### Configurações no `.env`:
```env
GRAYLOG_MESSAGE_JOURNAL_DIR=/usr/share/graylog/data/journal
GRAYLOG_MESSAGE_JOURNAL_MAX_SIZE=10gb
GRAYLOG_MESSAGE_JOURNAL_MAX_AGE=24h
```

### Garantia de Persistência:
No `docker-compose.yml`, o diretório pai `/usr/share/graylog/data` está mapeado para o volume persistente nomeado `graylog-data`. **O journal NUNCA fica no filesystem efêmero do container.**

---

## 5. Como Monitorar a Utilização de Armazenamento

Execute o script de status a qualquer momento:

```bash
./scripts/status.sh
```

Saída monitorada:
- **Tamanho do Journal em disco:** Indica se há mensagens pendentes de processamento.
- **Espaço em disco dos volumes:** Uso percentual e GB restantes.
- **Status do Data Node:** Conectividade e saúde do cluster.
- **Entradas pendentes no Journal (via API):** Se `uncommitted_journal_entries` estiver subindo continuamente, indica gargalo na escrita do Data Node (disco lento ou falta de heap).
