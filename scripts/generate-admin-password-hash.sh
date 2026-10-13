#!/usr/bin/env bash
# Gera o GRAYLOG_ROOT_PASSWORD_SHA2 (SHA-256 da senha do usuário "admin").
#
# - A senha é pedida de forma interativa, sem eco, e confirmada.
# - Rejeita senhas vazias, curtas ou triviais (admin, password, changeme...).
# - Imprime SOMENTE o hash em stdout (prompts/mensagens vão para stderr).
# - Nada é gravado em disco nem passa por argumentos de linha de comando
#   (que apareceriam em `ps`).
set -euo pipefail

MIN_LENGTH=12

if [ ! -t 0 ]; then
  echo "ERRO: execute em um terminal interativo (a senha não deve vir de pipe/arquivo)." >&2
  exit 1
fi

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | awk '{print $NF}'
  else
    echo "ERRO: sha256sum, shasum ou openssl é necessário." >&2
    return 1
  fi
}

read -r -s -p "Senha do usuário admin do Graylog (mín. ${MIN_LENGTH} caracteres): " password
echo >&2
read -r -s -p "Confirme a senha: " confirm
echo >&2

if [ "$password" != "$confirm" ]; then
  echo "ERRO: as senhas não conferem." >&2
  exit 1
fi

if [ "${#password}" -lt "$MIN_LENGTH" ]; then
  echo "ERRO: use ao menos ${MIN_LENGTH} caracteres." >&2
  exit 1
fi

lower="$(printf '%s' "$password" | tr '[:upper:]' '[:lower:]')"
case "$lower" in
  admin* | password* | changeme* | change_me* | graylog* | 123456* | qwerty*)
    echo "ERRO: senha trivial/padrão não é aceita." >&2
    exit 1
    ;;
esac

# printf '%s' (sem newline): o Graylog compara o SHA-256 dos bytes da senha.
hash="$(printf '%s' "$password" | sha256)"
unset password confirm lower

printf '%s\n' "$hash"

cat >&2 <<'EOF'

Informe este hash em GRAYLOG_ROOT_PASSWORD_SHA2 (.env ou Environment Variables
do Coolify). O usuário é "admin" e a senha digitada é a que você usa no login
(após o preflight). Essa senha só pode ser alterada trocando o hash.
EOF
