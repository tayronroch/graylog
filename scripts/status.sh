#!/usr/bin/env bash
# Painel de status do Graylog em Docker. Somente leitura; nunca imprime
# secrets nem a MONGODB_URI (credenciais são mascaradas nos logs).
#
# Mostra: containers/saúde, uso dos volumes, lbstatus, últimos logs relevantes
# e, se GRAYLOG_API_TOKEN estiver exportado, journal, Data Nodes e falhas de
# indexação via API oficial.
#
# Uso:
#   ./scripts/status.sh                      # tudo que não exige token
#   GRAYLOG_API_TOKEN=xxxx ./scripts/status.sh   # + API (token de usuário)
#   COMPOSE_PROJECT=nome ./scripts/status.sh # restringe a um projeto compose
#   LOG_LINES=100 ./scripts/status.sh        # linhas de log por serviço
#
# O token é criado em: UI > <usuário> > Edit tokens. É enviado por stdin do
# curl (não aparece em `ps`).
set -uo pipefail

LOG_LINES="${LOG_LINES:-60}"
project_filter=()
[ -n "${COMPOSE_PROJECT:-}" ] && project_filter=(--filter "label=com.docker.compose.project=${COMPOSE_PROJECT}")

if ! command -v docker >/dev/null 2>&1; then
  echo "ERRO: docker não encontrado." >&2
  exit 1
fi

find_container() {
  docker ps -a -q --filter "label=com.docker.compose.service=$1" "${project_filter[@]}" 2>/dev/null | head -1
}

# Remove credenciais de URIs e segredos que eventualmente apareçam nos logs.
sanitize() {
  sed -E \
    -e 's#(mongodb(\+srv)?://)[^/@[:space:]]*@#\1***:***@#g' \
    -e 's#((password_secret|root_password_sha2|PASSWORD_SECRET|PASSWORD_SHA2|authorization|token)[=: "'\'']+)[A-Za-z0-9+/=_.-]{8,}#\1***#Ig'
}

graylog_ctr="$(find_container graylog)"
datanode_ctr="$(find_container datanode)"

echo "== Containers =="
docker ps -a --filter 'label=com.docker.compose.service' "${project_filter[@]}" \
  --format 'table {{.Label "com.docker.compose.service"}}\t{{.Names}}\t{{.Status}}' |
  grep -E 'SERVICE|^(graylog|datanode)\b' || echo "  nenhum container graylog/datanode encontrado"

echo
echo "== Saúde (healthcheck) / restarts =="
for ctr in "$graylog_ctr" "$datanode_ctr"; do
  [ -n "$ctr" ] || continue
  docker inspect --format '  {{.Name}}: estado={{.State.Status}} saúde={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}} restarts={{.RestartCount}} oom={{.State.OOMKilled}}' "$ctr"
done

echo
echo "== CPU / RAM =="
# shellcheck disable=SC2046
docker stats --no-stream --format '  {{.Name}}: cpu={{.CPUPerc}} mem={{.MemUsage}} ({{.MemPerc}})' $(printf '%s\n' "$graylog_ctr" "$datanode_ctr" | grep .) 2>/dev/null

echo
echo "== Uso dos volumes (dentro dos containers) =="
if [ -n "$graylog_ctr" ] && [ "$(docker inspect -f '{{.State.Running}}' "$graylog_ctr")" = true ]; then
  echo "  graylog  /usr/share/graylog/data:"
  docker exec "$graylog_ctr" sh -c 'du -sh /usr/share/graylog/data/journal 2>/dev/null | sed "s/^/    journal: /"; df -h /usr/share/graylog/data | tail -1 | awk "{print \"    disco: usado \"\$3\" de \"\$2\" (\"\$5\")\"}"'
fi
if [ -n "$datanode_ctr" ] && [ "$(docker inspect -f '{{.State.Running}}' "$datanode_ctr")" = true ]; then
  echo "  datanode /var/lib/graylog-datanode:"
  docker exec "$datanode_ctr" sh -c 'du -sh /var/lib/graylog-datanode/opensearch/data 2>/dev/null | sed "s/^/    índices: /"; df -h /var/lib/graylog-datanode | tail -1 | awk "{print \"    disco: usado \"\$3\" de \"\$2\" (\"\$5\")\"}"'
fi

echo
echo "== lbstatus (/api/system/lbstatus) =="
if [ -n "$graylog_ctr" ]; then
  docker exec "$graylog_ctr" sh -c 'curl -s -m 3 -w " (HTTP %{http_code})\n" "http://127.0.0.1:${GRAYLOG_HTTP_BIND_ADDRESS##*:}/api/system/lbstatus"' 2>/dev/null |
    sed 's/^/  /'
  echo "  (200 ALIVE = ok; 404 = ainda em preflight/setup; 503 DEAD; 429 THROTTLED)"
fi

api() { # api <path> : GET autenticado por token, dentro do container graylog
  printf 'user = "%s:token"\n' "$GRAYLOG_API_TOKEN" |
    docker exec -i "$graylog_ctr" sh -c \
      'curl -s -m 10 -K - -H "Accept: application/json" "http://127.0.0.1:${GRAYLOG_HTTP_BIND_ADDRESS##*:}$1"' _ "$1"
}

if [ -n "${GRAYLOG_API_TOKEN:-}" ] && [ -n "$graylog_ctr" ]; then
  echo
  echo "== API: journal =="
  api /api/system/journal | python3 -c '
import sys, json
try:
    j = json.load(sys.stdin)
    size, limit = j["journal_size"], j["journal_size_limit"]
    print("  entradas pendentes : %s" % j["uncommitted_journal_entries"])
    print("  tamanho            : %.1f MB de %.1f MB (%.1f%%)" % (size/1e6, limit/1e6, 100.0*size/limit if limit else 0))
    print("  entrada/s | saída/s: %s | %s" % (j["append_events_per_second"], j["read_events_per_second"]))
except Exception as e:
    print("  indisponível (%s): confira o token/permissões" % e.__class__.__name__)
'
  echo
  echo "== API: Data Nodes =="
  api '/api/system/cluster/datanodes?per_page=50' | python3 -c '
import sys, json
try:
    for n in json.load(sys.stdin).get("elements", []):
        print("  %-20s status=%s" % (n.get("hostname"), n.get("data_node_status") or n.get("status")))
except Exception as e:
    print("  indisponível (%s)" % e.__class__.__name__)
'
  echo
  echo "== API: falhas de indexação (últimas 24h) =="
  since="$(date -u -v-24H +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%S.000Z)"
  api "/api/system/indexer/failures/count?since=${since}" | sed 's/^/  /'
  echo
elif [ -z "${GRAYLOG_API_TOKEN:-}" ]; then
  echo
  echo "(Dica: exporte GRAYLOG_API_TOKEN para ver journal, Data Nodes e falhas de indexação.)"
fi

echo
echo "== Últimos logs relevantes (WARN/ERROR; MongoDB URI mascarada) =="
for ctr in "$graylog_ctr" "$datanode_ctr"; do
  [ -n "$ctr" ] || continue
  name="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$ctr")"
  echo "-- ${name} (últimas ${LOG_LINES} linhas, filtradas) --"
  docker logs --tail "$LOG_LINES" "$ctr" 2>&1 |
    grep -E 'WARN|ERROR|FATAL|Exception|first time|[Uu]nable|[Uu]navailable|[Ff]ailed|preflight' |
    sanitize | cut -c1-240 | tail -n 15
done
