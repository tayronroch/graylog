# Deploy no Coolify

Guia para publicar este repositório como recurso **Docker Compose** no Coolify, com o MongoDB como recurso **separado**.

> Os nomes de menus do Coolify mudam entre versões; os conceitos abaixo (Environment Variables, Domains, Advanced → Predefined network, Persistent Storage) são estáveis. Referência: [Coolify – Docker Compose](https://coolify.io/docs/knowledge-base/docker/compose) e [Coolify – MongoDB](https://coolify.io/docs/databases/mongodb).

## Pré-requisitos no servidor

```bash
./scripts/check-host.sh          # vm.max_map_count, Docker, disco, RAM
```

`vm.max_map_count` precisa ser >= 262144 **no servidor Coolify** (o script apenas sugere os comandos; veja [SECURITY.md](SECURITY.md) e [TROUBLESHOOTING.md](TROUBLESHOOTING.md)).

## 1. Criar o MongoDB como recurso separado

1. No projeto/ambiente: **+ New → Database → MongoDB**.
2. Selecione o **mesmo servidor e a mesma Network (destination)** onde o Graylog será implantado.
3. Imagem: mantenha `mongo:7` (padrão do Coolify) ou use uma 7.x/8.0–8.2.x. O Graylog 7.1 suporta MongoDB **7.x até 8.2.x**.
4. **Não** habilite *Public access / Make it publicly available*: a conexão é pela rede privada.
5. Inicie e aguarde *healthy*. Anote o **nome do container** do banco (aparece na *Mongo URL (internal)*): `mongodb://root:…@<container-do-mongo>:27017/?directConnection=true`. Esse `<container-do-mongo>` é o hostname que irá na `MONGODB_URI`.

## 2. Criar database e usuário dedicado `graylog`

Não use o `root` do Coolify no Graylog. Abra o **Terminal** do recurso MongoDB (ou `docker exec -it <container> mongosh -u root --authenticationDatabase admin`) e siga [MONGODB.md](MONGODB.md#criar-o-usuário):

```javascript
use graylog
db.createUser({
  user: "graylog",
  pwd:  passwordPrompt(),
  roles: [
    { role: "readWrite", db: "graylog" },
    { role: "dbAdmin",   db: "graylog" }
  ]
})
```

O database `graylog` é criado na primeira escrita.

## 3. Montar a `MONGODB_URI`

Como o usuário foi criado no database `graylog`:

```text
mongodb://graylog:<SENHA_URL_ENCODED>@<container-do-mongo>:27017/graylog?authSource=graylog
```

A senha precisa estar **URL-encoded** (`@`→`%40`, `/`→`%2F`, `:`→`%3A`, `+`→`%2B`, `#`→`%23`, `?`→`%3F`, `%`→`%25`). Mais simples: gere uma senha só com letras e números. Detalhes em [MONGODB.md](MONGODB.md).

## 4. Criar o recurso Docker Compose

1. **+ New → Application** a partir deste repositório Git (público ou deploy key).
2. **Build Pack: Docker Compose**; *Base Directory* `/`; *Docker Compose Location* `/docker-compose.yml`.
3. Salve e **Reload Compose File** para o Coolify detectar as variáveis.

## 5. Variáveis de ambiente

Em **Environment Variables** preencha (modelo completo em [.env.example](../.env.example)):

| Variável | Valor |
|---|---|
| `GRAYLOG_VERSION` / `DATANODE_VERSION` | `7.1.10` (iguais) |
| `MONGODB_URI` | URI do passo 3 |
| `GRAYLOG_PASSWORD_SECRET` | `./scripts/generate-password-secret.sh` |
| `GRAYLOG_ROOT_PASSWORD_SHA2` | `./scripts/generate-admin-password-hash.sh` |
| `GRAYLOG_HTTP_EXTERNAL_URI` | `https://graylog.seudominio.com/` (com `/` final) |
| `TZ`, `GRAYLOG_ROOT_TIMEZONE` | `America/Fortaleza` |
| `SYSLOG_PORT` | `5140` |
| `GRAYLOG_SERVER_JAVA_OPTS`, `DATANODE_HEAP` | conforme RAM (ver `.env.example`) |

Dicas:
- Marque como *runtime only* (não *build variable*). Variáveis com `${…}` sem valor padrão são obrigatórias: o deploy falha se faltarem.
- Se algum valor contiver `$`, marque *Literal* para o Coolify não interpolar.
- **Nunca** cadastre `MONGODB_URI` em arquivo versionado.

## 6. Rede privada até o MongoDB

Em **Advanced → Docker compose → Predefined network**, habilite **Connect to predefined network**. Sem isso os containers só enxergam a rede do próprio compose e **não alcançam o MongoDB**. Como o Coolify pode prefixar nomes, confirme o hostname real (o nome do container do MongoDB do passo 1) e valide depois do deploy:

```bash
./scripts/check-mongodb.sh        # testa TCP de dentro do container graylog
```

## 7. Domínio da Web/API (porta 9000)

Em **Domains** (serviço `graylog`) informe, **com a porta interna**:

```text
https://graylog.seudominio.com:9000
```

O `:9000` diz ao proxy (Traefik/Caddy) qual porta do container receber; o acesso público continua em 443. O Coolify emite o certificado TLS. A `GRAYLOG_HTTP_EXTERNAL_URI` deve ser exatamente essa URL (`https://…/`). **Não** configure domínio para o serviço `datanode`.

## 8. SYSLOG 5140 TCP/UDP

O compose já publica `5140/tcp` e `5140/udp` diretamente no host (`ports:`), **sem passar pelo proxy HTTP**. O Coolify mantém essas `ports:` do compose. Verifique que:

- nenhuma outra aplicação do servidor usa 5140 (conflito faz o deploy falhar);
- o firewall/security group permite 5140 **somente das redes dos equipamentos** ([SECURITY.md](SECURITY.md));
- o input criado no Graylog escuta a mesma porta (`SYSLOG_PORT`).

Não publique `8999`, `9200`, `9300` nem 9000.

## 9. Volumes persistentes

Os volumes nomeados `graylog-data` e `graylog-datanode` do compose aparecem em **Persistent Storage** (somente leitura, definidos no compose) e o Coolify os prefixa com o ID do recurso. **Não os apague** e não use *Delete volumes* ao remover o recurso. Eles contêm journal, node-id, certificados e índices. O backup de volumes de compose **não** é coberto pelos backups agendados de banco do Coolify: veja [BACKUP.md](BACKUP.md).

## 10. Deploy e acompanhamento

1. Clique em **Deploy**.
2. Acompanhe **Deployment Logs** e depois **Logs** de cada serviço (`graylog`, `datanode`).
3. Esperado: ambos `healthy`. No primeiro boot o Graylog mostra no log:

```text
It seems you are starting Graylog for the first time. To set up a fresh install, a setup interface has been started...
Initial configuration is accessible at 0.0.0.0:9000, with username 'admin' and password '<senha-temporária>'.
```

Copie a senha temporária (ela só aparece no log do primeiro boot).

## 11. Preflight, Data Node e primeiro input

Acesse `https://graylog.seudominio.com`, entre no **preflight** com `admin` + senha temporária, provisione a CA/Data Node, aguarde *Connected* e retome a inicialização. Passo a passo em [FIRST-BOOT.md](FIRST-BOOT.md). Depois crie os inputs Syslog UDP/TCP 5140 ([SYSLOG.md](SYSLOG.md)).

## 12. Ações manuais que sobram no Coolify

- [ ] Criar o MongoDB (recurso separado) e o usuário `graylog`.
- [ ] Verificar que o scheduled backup do MongoDB inclui o database `graylog` ([BACKUP.md](BACKUP.md)).
- [ ] Cadastrar as variáveis de ambiente.
- [ ] Habilitar *Connect to predefined network*.
- [ ] Configurar o domínio `https://…:9000` no serviço `graylog`.
- [ ] Liberar 5140 TCP/UDP no firewall apenas para as redes autorizadas.
- [ ] Concluir o preflight e depois trocar `HEALTHCHECK_ALLOW_PREFLIGHT=false` (redeploy).
- [ ] Criar inputs Syslog; configurar retenção ([STORAGE.md](STORAGE.md)).
- [ ] (Opcional) limites de CPU/RAM do recurso conforme o `DATANODE_HEAP`.

## Observação sobre o healthcheck no Coolify

O healthcheck do `graylog` usa `$$` (escape do Compose para `$`). Se o Coolify exibir erro de interpolação, defina o healthcheck simplificado na sua cópia do compose: `curl -fsS http://127.0.0.1:9000/api/system/lbstatus` e mantenha `HEALTHCHECK_ALLOW_PREFLIGHT` fora do fluxo (nesse caso a UI de preflight só é acessível por túnel; veja [TROUBLESHOOTING.md](TROUBLESHOOTING.md)).
