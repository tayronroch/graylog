#!/usr/bin/env bash
# Gera um GRAYLOG_PASSWORD_SECRET criptograficamente seguro.
#
# - 96 caracteres alfanuméricos de /dev/urandom (a doc oficial exige >= 16 e
#   recomenda >= 64; 96 é o valor usado nos exemplos oficiais).
# - Imprime SOMENTE o segredo em stdout (mensagens vão para stderr), para uso
#   em:  GRAYLOG_PASSWORD_SECRET=$(./scripts/generate-password-secret.sh)
# - Não grava nada em disco. O mesmo valor deve ser usado por Graylog Server e
#   Data Node (o docker-compose.yml já injeta um único valor nos dois).
set -euo pipefail

LENGTH=96

# "|| true": o `head` fecha o pipe cedo e o `tr` recebe SIGPIPE (pipefail).
secret="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$LENGTH" || true)"

if [ "${#secret}" -ne "$LENGTH" ]; then
  echo "ERRO: não foi possível gerar ${LENGTH} caracteres a partir de /dev/urandom." >&2
  exit 1
fi

printf '%s\n' "$secret"

cat >&2 <<'EOF'

Guarde este valor em um cofre de senhas e informe-o em GRAYLOG_PASSWORD_SECRET
(.env ou Environment Variables do Coolify).
ATENÇÃO: trocar o segredo depois da instalação invalida sessões e valores
criptografados no MongoDB (incluindo a CA do Data Node).
EOF
