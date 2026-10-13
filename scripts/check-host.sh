#!/usr/bin/env bash
# Verifica (somente leitura) se o host Linux atende aos requisitos do Graylog
# Data Node (OpenSearch). NÃO altera sysctl, firewall nem nada no host: apenas
# informa os comandos sugeridos.
#
# Uso: ./scripts/check-host.sh [diretório_dos_dados_docker]
#   diretório padrão: raiz de dados do Docker (docker info) ou /var/lib/docker
#
# Códigos de saída: 0 = ok (pode haver avisos), 1 = falhas encontradas.
set -uo pipefail

REQUIRED_MAX_MAP_COUNT=262144
MIN_DISK_GB=100
WARN_DISK_GB=200
MIN_MEM_GB=8
REC_MEM_GB=16

fails=0
warns=0
ok()   { printf '  [ OK ] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; fails=$((fails + 1)); }
hint() { printf '         -> %s\n' "$*"; }

echo "== Docker =="
if command -v docker >/dev/null 2>&1; then
  ok "docker: $(docker --version 2>/dev/null)"
  if docker info >/dev/null 2>&1; then
    ok "daemon do Docker acessível"
  else
    fail "daemon do Docker inacessível para este usuário"
    hint "inicie o serviço ou adicione o usuário ao grupo docker"
  fi
else
  fail "docker não encontrado"
  hint "instale o Docker Engine: https://docs.docker.com/engine/install/"
fi

if docker compose version >/dev/null 2>&1; then
  ok "docker compose: $(docker compose version --short 2>/dev/null)"
else
  fail "plugin 'docker compose' não encontrado"
  hint "instale o plugin: https://docs.docker.com/compose/install/"
fi

echo "== Kernel =="
if [ "$(uname -s)" = "Linux" ] && [ -r /proc/sys/vm/max_map_count ]; then
  current="$(cat /proc/sys/vm/max_map_count)"
  if [ "$current" -ge "$REQUIRED_MAX_MAP_COUNT" ]; then
    ok "vm.max_map_count = ${current} (mínimo ${REQUIRED_MAX_MAP_COUNT})"
  else
    fail "vm.max_map_count = ${current} (mínimo ${REQUIRED_MAX_MAP_COUNT}); o OpenSearch do Data Node não inicia"
    hint "aplicar agora:    sudo sysctl -w vm.max_map_count=${REQUIRED_MAX_MAP_COUNT}"
    hint "tornar permanente: echo 'vm.max_map_count=${REQUIRED_MAX_MAP_COUNT}' | sudo tee /etc/sysctl.d/99-graylog.conf && sudo sysctl --system"
  fi
  if [ -f /etc/sysctl.d/99-graylog.conf ]; then
    ok "/etc/sysctl.d/99-graylog.conf presente (persistente)"
  elif [ "$current" -ge "$REQUIRED_MAX_MAP_COUNT" ]; then
    warn "valor correto, mas /etc/sysctl.d/99-graylog.conf não existe: pode ser perdido no reboot"
    hint "echo 'vm.max_map_count=${REQUIRED_MAX_MAP_COUNT}' | sudo tee /etc/sysctl.d/99-graylog.conf"
  fi
else
  warn "não é Linux (ou /proc indisponível): confira vm.max_map_count no host/VM que roda o Docker"
fi

echo "== Disco =="
if [ -n "${1:-}" ]; then
  data_dir="$1"
else
  data_dir="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  [ -n "$data_dir" ] && [ -d "$data_dir" ] || data_dir="/var/lib/docker"
  [ -d "$data_dir" ] || data_dir="."
fi
avail_kb="$(df -Pk "$data_dir" 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "$avail_kb" ]; then
  avail_gb=$((avail_kb / 1024 / 1024))
  if [ "$avail_gb" -lt "$MIN_DISK_GB" ]; then
    fail "${avail_gb} GB livres em ${data_dir} (mínimo ${MIN_DISK_GB} GB; veja docs/STORAGE.md)"
  elif [ "$avail_gb" -lt "$WARN_DISK_GB" ]; then
    warn "${avail_gb} GB livres em ${data_dir} (recomendado >= ${WARN_DISK_GB} GB para retenção sem exclusão inicial)"
  else
    ok "${avail_gb} GB livres em ${data_dir}"
  fi
else
  warn "não foi possível medir o espaço livre em ${data_dir}"
fi

echo "== Memória =="
if [ -r /proc/meminfo ]; then
  total_gb=$(($(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 / 1024))
  avail_gb=$(($(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1024 / 1024))
  if [ "$total_gb" -lt "$MIN_MEM_GB" ]; then
    fail "RAM total ${total_gb} GB (mínimo ${MIN_MEM_GB} GB; recomendado ${REC_MEM_GB} GB)"
  elif [ "$total_gb" -lt "$REC_MEM_GB" ]; then
    warn "RAM total ${total_gb} GB (recomendado >= ${REC_MEM_GB} GB; reduza DATANODE_HEAP/GRAYLOG_SERVER_JAVA_OPTS)"
  else
    ok "RAM total ${total_gb} GB"
  fi
  echo "         disponível agora: ${avail_gb} GB"
else
  warn "/proc/meminfo indisponível: não foi possível medir a memória"
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "Resultado: ${fails} falha(s), ${warns} aviso(s). Corrija antes do deploy."
  exit 1
fi
echo "Resultado: sem falhas, ${warns} aviso(s)."
