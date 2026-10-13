#!/usr/bin/env bash
# Informa O QUE salvar e ONDE está (somente leitura). NÃO copia nem exporta
# arquivos de banco/índices: copiar arquivos de um MongoDB/OpenSearch em
# execução gera backup inconsistente. Use os mecanismos descritos em
# docs/BACKUP.md (mongodump/snapshot do MongoDB, snapshot do OpenSearch ou
# snapshot de volume com o Data Node parado).
#
# Uso: ./scripts/backup-info.sh
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mask() { sed -E 's#^(mongodb(\+srv)?://)[^/]*@#\1***:***@#'; }

echo "== 1. MongoDB (CRÍTICO: usuários, dashboards, streams, inputs, CA do Data Node) =="
uri="${MONGODB_URI:-}"
if [ -z "$uri" ] && [ -r "$ROOT_DIR/.env" ]; then
  uri="$(grep -E '^MONGODB_URI=' "$ROOT_DIR/.env" | tail -1 | cut -d= -f2-)"
fi
if [ -n "$uri" ]; then
  echo "  URI (mascarada): $(printf '%s' "$uri" | mask)"
else
  echo "  MONGODB_URI não encontrada neste ambiente."
fi
echo "  Backup: mongodump (consistente) ou snapshot do recurso MongoDB no Coolify."
echo "  Exemplo (execute a partir da rede do MongoDB, com a URI em variável):"
echo "    mongodump --uri=\"\$MONGODB_URI\" --gzip --archive=graylog-\$(date +%F).archive.gz"
echo

echo "== 2. Volumes Docker deste deploy =="
if command -v docker >/dev/null 2>&1; then
  for svc in graylog datanode; do
    ctr="$(docker ps -a -q --filter "label=com.docker.compose.service=${svc}" | head -1)"
    [ -n "$ctr" ] || { echo "  ${svc}: container não encontrado"; continue; }
    echo "  ${svc}:"
    docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}    volume={{.Name}} -> {{.Destination}}{{"\n"}}{{end}}{{end}}' "$ctr"
  done
  echo
  echo "  graylog-data      (/usr/share/graylog/data): node-id + JOURNAL (transitório; ver docs/BACKUP.md)"
  echo "  graylog-datanode  (/var/lib/graylog-datanode): node-id, certificados e ÍNDICES (reconstruível só se houver snapshot)"
else
  echo "  docker não encontrado."
fi
echo

echo "== 3. Configuração do repositório =="
echo "  Versionado no Git: docker-compose.yml, .env.example, docs/, scripts/."
if [ -r "$ROOT_DIR/.env" ]; then
  echo "  .env presente (NÃO está no Git). Variáveis definidas (apenas nomes):"
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ROOT_DIR/.env" | cut -d= -f1 | sed 's/^/    /'
else
  echo "  .env ausente aqui (no Coolify, as variáveis ficam na aba Environment Variables)."
fi
echo "  Guarde em COFRE: GRAYLOG_PASSWORD_SECRET, GRAYLOG_ROOT_PASSWORD_SHA2 (ou a senha admin) e MONGODB_URI."
echo "  Sem o GRAYLOG_PASSWORD_SECRET original, o restore do MongoDB não decifra a CA nem tokens."
echo
echo "Detalhes e procedimentos de restore: docs/BACKUP.md"
