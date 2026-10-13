#!/usr/bin/env bash
# Valida a MONGODB_URI (formato, encoding, conectividade) SEM imprimir
# credenciais. Somente leitura.
#
# Fonte da URI: variável de ambiente MONGODB_URI ou, se vazia, a linha
# MONGODB_URI= do arquivo .env na raiz do repositório (lida com grep; o .env
# nunca é executado/"sourced").
#
# Conectividade:
#   - se o container "graylog" estiver rodando, o teste TCP é feito DE DENTRO
#     dele (prova que a rede privada do Coolify está correta);
#   - caso contrário, do host onde o script roda.
#   - se houver `mongosh` local, também testa autenticação e mostra roles.
#
# Uso: ./scripts/check-mongodb.sh
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
warns=0
ok()   { printf '  [ OK ] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; fails=$((fails + 1)); }

mask() { sed -E 's#^(mongodb(\+srv)?://)[^/]*@#\1***:***@#'; }

uri="${MONGODB_URI:-}"
if [ -z "$uri" ] && [ -r "$ROOT_DIR/.env" ]; then
  uri="$(grep -E '^MONGODB_URI=' "$ROOT_DIR/.env" | tail -1 | cut -d= -f2- | sed -E "s/^[\"']//; s/[\"']\$//")"
fi
if [ -z "$uri" ]; then
  echo "ERRO: MONGODB_URI vazia (exporte a variável ou preencha o .env)." >&2
  exit 1
fi

echo "== Formato da URI =="
echo "  URI (mascarada): $(printf '%s' "$uri" | mask)"

case "$uri" in
  mongodb://* | mongodb+srv://*) ok "esquema válido" ;;
  *) fail "deve começar com mongodb:// ou mongodb+srv://"; exit 1 ;;
esac
srv=false
case "$uri" in mongodb+srv://*) srv=true ;; esac

rest="${uri#*://}"
base="${rest%%\?*}"
query=""
[ "$base" != "$rest" ] && query="${rest#*\?}"

# Depois da primeira "/" (início do database) nunca há "@" em uma URI válida:
# se houver, a senha tem "/" ou "@" sem URL-encode.
first_segment="${base%%/*}"
if [[ "$base" == */* ]] && [[ "${base#*/}" == *@* ]]; then
  fail "há '@' após '/': provável senha com '/' ou '@' sem URL-encode (veja docs/MONGODB.md)"
fi

if [[ "$first_segment" == *@* ]]; then
  userinfo="${first_segment%@*}"
  hosts="${first_segment##*@}"
  if [[ "$userinfo" == *@* ]]; then
    fail "usuário/senha com '@' sem URL-encode (use %40)"
  fi
  if [[ "$userinfo" != *:* ]]; then
    warn "credencial sem senha (esperado usuario:senha@)"
  else
    user="${userinfo%%:*}"
    pass="${userinfo#*:}"
    if [[ "$pass" == *:* ]]; then
      fail "senha com ':' sem URL-encode (use %3A)"
    fi
    if printf '%s%s' "$user" "$pass" | grep -qE '[]/?#[]'; then
      fail "usuário/senha com caractere reservado (/ ? # [ ]) sem URL-encode"
    fi
    if printf '%s%s' "$user" "$pass" | grep -qE '%($|[^0-9A-Fa-f]|[0-9A-Fa-f]($|[^0-9A-Fa-f]))'; then
      fail "'%' sem par hexadecimal: use %25 para um '%' literal"
    fi
    case "$user" in
      root | admin | administrator)
        warn "usuário '${user}' é administrativo: use um usuário dedicado ao Graylog" ;;
      *) ok "usuário dedicado: ${user}" ;;
    esac
  fi
else
  hosts="$first_segment"
  warn "URI sem credenciais: o MongoDB sem autenticação não é recomendado em produção"
fi

database=""
[[ "$base" == */* ]] && database="${base#*/}"
if [ -z "$database" ]; then
  fail "a URI não informa o database (ex.: .../graylog?authSource=...)"
else
  ok "database: ${database}"
fi

for param in authSource replicaSet directConnection tls ssl; do
  value="$(printf '%s' "$query" | tr '&' '\n' | grep -E "^${param}=" | head -1 | cut -d= -f2-)"
  [ -n "$value" ] && echo "         ${param}=${value}"
done
if ! printf '%s' "$query" | grep -qE '(^|&)authSource='; then
  warn "sem authSource: o MongoDB usará o database da URI (${database:-?}). Se o usuário foi criado em 'admin', informe authSource=admin"
fi

echo "== Conectividade =="
container="$(docker ps -q --filter 'label=com.docker.compose.service=graylog' 2>/dev/null | head -1)"
if [ -n "$container" ]; then
  echo "  testando de dentro do container graylog (${container})"
  tcp_test() { docker exec "$container" bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1; }
else
  echo "  container graylog não está rodando: testando a partir deste host"
  if command -v timeout >/dev/null 2>&1; then
    tcp_test() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1; }
  else
    tcp_test() { bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1; }
  fi
fi

if [ "$srv" = true ]; then
  warn "mongodb+srv:// usa DNS SRV: teste TCP por host não aplicável"
else
  IFS=',' read -r -a host_list <<<"$hosts"
  for entry in "${host_list[@]}"; do
    host="${entry%:*}"
    port="${entry##*:}"
    [ "$host" = "$entry" ] && port=27017
    if tcp_test "$host" "$port"; then
      ok "TCP ${host}:${port} acessível"
    else
      fail "TCP ${host}:${port} inacessível (rede privada do Coolify? 'Connect to predefined network' habilitado? ver docs/COOLIFY.md)"
    fi
  done
fi

echo "== Autenticação (opcional) =="
if command -v mongosh >/dev/null 2>&1; then
  if mongosh --quiet "$uri" \
    --eval 'const s=db.runCommand({connectionStatus:1}).authInfo; print("  usuários: "+JSON.stringify(s.authenticatedUsers.map(u=>u.user+"@"+u.db))); print("  roles:    "+JSON.stringify(s.authenticatedUserRoles.map(r=>r.role+"@"+r.db)))' 2>/dev/null; then
    ok "autenticação OK"
  else
    fail "mongosh não conseguiu autenticar/conectar"
  fi
else
  echo "  mongosh não instalado localmente; teste manual (a partir da rede do MongoDB):"
  echo "    docker run --rm -it --network <rede> mongo:7.0 mongosh '<URI>' --eval 'db.runCommand({ping:1})'"
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "Resultado: ${fails} falha(s), ${warns} aviso(s)."
  exit 1
fi
echo "Resultado: sem falhas, ${warns} aviso(s)."
