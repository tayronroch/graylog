# MongoDB externo

O MongoDB **não** faz parte do `docker-compose.yml`. Ele é um recurso separado (no Coolify, um recurso *Database → MongoDB*) e chega ao Graylog **somente** pela variável `MONGODB_URI`, que o compose mapeia para:

```text
MONGODB_URI ──┬──> GRAYLOG_MONGODB_URI            (Graylog Server)
              └──> GRAYLOG_DATANODE_MONGODB_URI   (Data Node)
```

Hostname, usuário, senha, porta, database, replica set e `authSource` vêm integralmente da URI; o projeto não assume nenhum hostname.

## Versões suportadas

Matriz oficial do Graylog (verificada em 2026-10-13): Graylog **7.1.x e 7.2.x → MongoDB 7.x a 8.2.x**. O padrão do Coolify (`mongo:7`) atende. Não use MongoDB 6.x ou inferior com o Graylog 7.

## O que o Graylog guarda no MongoDB

Usuários, roles, streams, dashboards, definições de inputs, configuração do cluster, registro dos nós e a **CA/certificados do Data Node** (protegidos pelo `GRAYLOG_PASSWORD_SECRET`). As mensagens de log **não** ficam no MongoDB. Por isso o MongoDB precisa de backup ([BACKUP.md](BACKUP.md)).

## Criar o usuário

Use um usuário **dedicado** (não o `root`). Conecte como administrador (no Coolify: Terminal do recurso MongoDB ou `docker exec -it <container> mongosh -u root --authenticationDatabase admin`).

### Opção A (recomendada): usuário criado no próprio database `graylog`

```javascript
use graylog
db.createUser({
  user: "graylog",
  pwd:  passwordPrompt(),      // digita sem eco; use letras e números para evitar URL-encoding
  roles: [
    { role: "readWrite", db: "graylog" },
    { role: "dbAdmin",   db: "graylog" }
  ]
})
```

URI (note `authSource=graylog`):

```text
mongodb://graylog:PASSWORD@HOST:27017/graylog?authSource=graylog
```

### Opção B: usuário criado no database `admin`

```javascript
use admin
db.createUser({
  user: "graylog",
  pwd:  passwordPrompt(),
  roles: [
    { role: "readWrite", db: "graylog" },
    { role: "dbAdmin",   db: "graylog" }
  ]
})
```

URI (note `authSource=admin`):

```text
mongodb://graylog:PASSWORD@HOST:27017/graylog?authSource=admin
```

### Qual a diferença?

`authSource` é o **database onde o usuário foi criado** (onde o MongoDB procura a credencial), não o database que o Graylog usa. O database de trabalho é o do caminho da URI (`/graylog`).

| | Opção A | Opção B |
|---|---|---|
| Usuário criado em | `graylog` | `admin` |
| `authSource` | `graylog` | `admin` |
| Escopo | Isolado ao database | Mesmo local de contas administrativas |

Se `authSource` não for informado, o driver autentica no database do caminho da URI (`graylog`); se o usuário foi criado em `admin`, a autenticação falha. Erro típico: `Authentication failed`.

> Validado: com a Opção A (`readWrite` + `dbAdmin` em `graylog`, sem `clusterMonitor`), o preflight, a criação do Data Node, a indexação e a operação normal do Graylog 7.1.10 funcionaram com MongoDB 7.0. `dbAdmin` é necessário porque o Graylog cria coleções e índices. Roles administrativos adicionais (`clusterMonitor` etc.) **não** foram necessários para o fluxo testado; páginas de diagnóstico do MongoDB na UI podem exibir informações limitadas sem eles.

## Replica Set (opcional)

Este projeto **não** ativa Replica Set. Se o seu MongoDB externo for um Replica Set, apenas forneça a URI correspondente:

```text
mongodb://user:password@mongo1:27017,mongo2:27017,mongo3:27017/graylog?replicaSet=rs0&authSource=admin
```

O recurso MongoDB padrão do Coolify é *standalone*; a URI interna dele usa `?directConnection=true`. Para o Graylog use a URI no formato dos exemplos acima (`/graylog?authSource=...`); `directConnection=true` também é aceito em instância standalone.

## URL encoding da senha

Usuário e senha **precisam estar URL-encoded** na URI. Caracteres reservados:

| Caractere | Codificado |
|---|---|
| `@` | `%40` |
| `:` | `%3A` |
| `/` | `%2F` |
| `?` | `%3F` |
| `#` | `%23` |
| `[` `]` | `%5B` `%5D` |
| `%` | `%25` |
| `+` | `%2B` |
| espaço | `%20` |

Exemplo: senha `Zx9/Q@t:+8#%k` → `Zx9%2FQ%40t%3A%2B8%23%25k` (testado: Graylog e Data Node conectaram normalmente com essa senha). Recomendação prática: gere uma senha **apenas alfanumérica** longa (ex.: `openssl rand -hex 24`) e evite o assunto.

Ao digitar a URI no Coolify, se ela contiver `$`, marque a variável como *Literal*.

## Rede

O MongoDB deve ficar **privado** (sem *Public access*). Os containers `graylog` e `datanode` precisam estar na mesma rede Docker do MongoDB: no Coolify habilite *Connect to predefined network* ([COOLIFY.md](COOLIFY.md#6-rede-privada-até-o-mongodb)) e use na URI o nome do container do MongoDB mostrado na *Mongo URL (internal)*.

## Validar

```bash
./scripts/check-mongodb.sh
```

O script valida o formato (URL-encoding, `authSource`, usuário administrativo), testa a conexão TCP de dentro do container `graylog` e **nunca imprime credenciais**.

Se o MongoDB estiver indisponível no início, o Graylog e o Data Node ficam tentando reconectar (nos logs: `Waiting for server to become available`) e prosseguem quando ele volta; não há `depends_on` de propósito.
