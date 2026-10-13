# Operação e Manutenção em Produção

Este documento consolida os procedimentos operacionais para sustentação do ambiente Graylog no dia a dia.

---

## 1. Comandos de Operação Básica

### Iniciar / Parar Serviços
```bash
# Iniciar a stack em background
docker compose up -d

# Parar os serviços de forma graciosa (aguarda o Data Node fechar shards)
docker compose stop

# Reiniciar um serviço específico
docker compose restart graylog
docker compose restart datanode

# Visualizar status de containers
docker compose ps
```

### Visualização de Logs
```bash
# Acompanhar logs em tempo real
docker compose logs -f graylog
docker compose logs -f datanode

# Filtrar apenas erros
docker compose logs --tail=100 graylog | grep -E "ERROR|WARN"
```

---

## 2. Monitoramento e Saúde do Ambiente

Execute periodicamente o script de status integrado:

```bash
./scripts/status.sh
```

### Métricas com Token de API (Recomendado):
Para que o script exiba estatísticas completas de journal e Data Node via API oficial:
1. Na interface do Graylog, clique no seu usuário no canto superior direito → **Edit tokens**.
2. Crie um token com o nome `monitor-ops`.
3. Execute o script com a variável informada:
   ```bash
   GRAYLOG_API_TOKEN="seu_token_aqui" ./scripts/status.sh
   ```

---

## 3. Gestão e Dimensionamento de Memória (JVM Heap)

### Regras de Ouro para Alocação de Memória:
1. **Graylog Server (`GRAYLOG_SERVER_JAVA_OPTS`):**
   - Para 200 a 500 equipamentos sem pipelines complexas de regex: **2 GB a 4 GB** de Heap são suficientes.
   - Padrão: `-Xms2g -Xmx2g`.
2. **Data Node (`DATANODE_HEAP`):**
   - O Heap do OpenSearch **nunca deve ultrapassar 50% da RAM física** do host.
   - O restante da RAM livre é utilizado pelo kernel do Linux para *Filesystem Cache*, fundamental para a performance de leitura dos índices Lucene.
   - **Nunca configure o Heap do Data Node acima de 31 GB** (limite em que o Java deixa de utilizar Compressed OOPs, piorando o uso de memória).
   - Recomendações por tamanho de servidor:
     - Servidor de 16 GB RAM: Graylog `2g`, Data Node `4g` (sobram 10 GB para cache do SO e outros serviços).
     - Servidor de 32 GB RAM: Graylog `4g`, Data Node `8g` ou `12g`.

---

## 4. Procedimento de Upgrade de Versão

### Etapa 1: Validação Prévia
1. Consulte as notas de lançamento e a matriz de compatibilidade do Graylog.
2. Certifique-se de que a versão do seu MongoDB atende à versão de destino do Graylog.
3. Execute um backup do MongoDB:
   ```bash
   ./scripts/backup-info.sh
   ```

### Etapa 2: Atualização do `.env`
No `.env` (ou na aba *Environment Variables* do Coolify), altere ambas as variáveis simultaneamente para a nova versão desejada:

```env
GRAYLOG_VERSION=7.1.11
DATANODE_VERSION=7.1.11
```

> [!IMPORTANT]
> **O Graylog Server e o Graylog Data Node DEVEM utilizar exatamente a mesma versão.** Nunca atualize um nó sem atualizar o outro.

### Etapa 3: Aplicar a Atualização
```bash
docker compose pull
docker compose up -d
```

Acompanhe os logs de inicialização. O Graylog executará automaticamente as migrações necessárias no MongoDB e OpenSearch:
```bash
docker compose logs -f graylog
```

---

## 5. Rotação de Logs do Docker

No `docker-compose.yml`, ambos os serviços já estão configurados com rotação de log do driver `json-file`:

```yaml
logging:
  driver: "json-file"
  options:
    max-size: "50m"
    max-file: "5"
```

Isso garante que os logs de stdout dos containers ocupem no máximo 250 MB por container no disco do host, prevenindo exaustão de armazenamento.

---

## 6. Manutenção e Gerenciamento de Índices

A gestão regular de expurgo é feita automaticamente pelas políticas de retenção configuradas em **System** → **Indices**.

Caso necessite forçar a rotação de um índice imediatamente (por exemplo, antes de uma janela de manutenção programada):
1. Acesse **System** → **Indices**.
2. No *Default index set*, clique em **Maintenance** → **Rotate active write index**.
3. O Graylog fechará o índice atual e iniciará um novo índice limpo para escrita.
