# Estratégia e Procedimentos de Backup

Este documento estabelece a política de backup e recuperação de desastres (Disaster Recovery) para o ambiente Graylog.

---

## 1. Classificação dos Componentes

| Componente | Conteúdo | Criticidade | Tamanho Típico | Estratégia de Backup |
|---|---|---|---|---|
| **MongoDB** | Usuários, senhas, streams, regras, dashboards, inputs, CA do Data Node | **CRÍTICA** (Se perder, reconfigura o sistema do zero) | 10 MB a 500 MB | Backup lógico diário (`mongodump`) ou snapshot do Coolify |
| **Data Node (OpenSearch)** | Histórico de mensagens e índices de busca | **MÉDIA / ALTA** (Depende de exigência regulatória) | 50 GB a 1 TB+ | Snapshot do OpenSearch (S3/NFS) ou snapshot de volume |
| **Journal do Graylog** | Fila transitória de mensagens em trânsito | **NENHUMA** (Transitório) | 10 MB a 10 GB | **NÃO FAZER BACKUP** |
| **Configuração (.env / Secrets)** | `GRAYLOG_PASSWORD_SECRET`, `MONGODB_URI`, etc. | **CRÍTICA** | Poucos bytes | Cofre de senhas corporativo (Vault/Bitwarden) |

> [!WARNING]
> **NUNCA faça backup de banco copiando arquivos brutos (`cp -r`) com o MongoDB ou o OpenSearch em execução!** Isso gera arquivos corrompidos e inconsistentes que falharão na restauração.

---

## 2. Backup do MongoDB (Obrigatório e Crítico)

Como o MongoDB armazena toda a configuração e a chave privada da autoridade certificadora que valida os Data Nodes, o backup dele é o mais importante e tem menor custo de armazenamento.

### Método 1: Backups Automáticos do Coolify
Se você criou o MongoDB pelo Coolify:
1. Acesse o recurso do MongoDB no Coolify.
2. Vá na aba **Backups**.
3. Ative **Scheduled backups** (ex: diário às 02:00 UTC).
4. Configure retenção (ex: 14 dias) e, opcionalmente, envio para bucket S3.

### Método 2: Backup Manual / Cron via `mongodump`
Execute a partir de uma máquina com acesso à rede do MongoDB (ou container auxiliar):

```bash
# Executa dump consistente e compactado diretamente para um arquivo único
docker run --rm --network <rede_do_mongodb> mongo:7.0 \
  mongodump --uri="$MONGODB_URI" --gzip --archive=/tmp/backup.gz > graylog_mongo_$(date +%Y%m%d_%H%M%S).gz
```

### Procedimento de Restauração do MongoDB:
```bash
# Restaura o banco de dados graylog a partir do arquivo compactado
docker run --rm -i --network <rede_do_mongodb> mongo:7.0 \
  mongorestore --uri="$MONGODB_URI" --drop --gzip --archive < graylog_mongo_20261013.gz
```

---

## 3. Backup dos Índices do Data Node (OpenSearch)

Para salvar o histórico completo das mensagens indexadas, a estratégia recomendada é utilizar a API nativa de **Snapshots** do OpenSearch ou snapshot de volume de armazenamento.

### Opção A: Snapshots do OpenSearch para Bucket S3 / MinIO
1. Cadastre um repositório de snapshot apontando para um bucket S3 compatível.
2. Crie uma política de snapshot periódica (Index State Management - ISM) para salvar índices antigos em armazenamento frio.

### Opção B: Snapshot de Volume em Bloco (AWS EBS / DigitalOcean Volume / ZFS / Ceph)
Caso sua infraestrutura conte com volumes gerenciados:
1. Congele temporariamente as escritas ou execute o snapshot de disco consistente do volume `graylog-datanode`.

### Cenário de Recuperação Rápida Sem Backup de Mensagens (RTO Mínimo):
Em caso de perda total de storage:
1. Restaure apenas o **MongoDB** e o arquivo `.env`.
2. Suba o `docker compose up -d`.
3. O Graylog e o Data Node inicializarão automaticamente, recriarão os índices zerados a partir das definições do MongoDB e retomarão a recepção de Syslog imediatamente.
4. **Resultado:** Todos os inputs, usuários, alertas e dashboards continuam intactos; apenas o histórico passado foi perdido.

---

## 4. O que NUNCA Deve Ser Feito

1. **Não fazer backup do diretório `journal/`:** O journal é uma fila de spool volátil que muda continuamente enquanto mensagens chegam. Tentar sincronizar arquivos de journal gera arquivos com locks e corrompidos.
2. **Não trocar o `GRAYLOG_PASSWORD_SECRET` após restauração:** O MongoDB armazena dados cifrados (incluindo a CA do Data Node). Se você restaurar o banco mas subir um container com outro segredo, o Graylog não conseguirá decifrar as chaves e falhará no boot.

---

## 5. Script Informativo

Para visualizar o status atual de volumes e caminhos sem executar ações destrutivas:

```bash
./scripts/backup-info.sh
```
