# Primeiro Boot e Setup Inicial (Preflight)

Este guia descreve o procedimento passo a passo para o primeiro boot do Graylog Open 7.1 com Graylog Data Node.

> [!IMPORTANT]
> Nas versões modernas do Graylog com Data Node, o primeiro boot inicia em modo **Preflight / Setup Interface**. O servidor Graylog sobe uma interface simplificada na porta 9000 e gera uma **senha temporária de uso único nos logs**. O acesso normal com `admin` e a senha definida em `GRAYLOG_ROOT_PASSWORD_SHA2` só fica ativo **após** a conclusão do preflight.

---

## Fluxo Sequencial

```text
[1. Host Check] ──> [2. Config .env] ──> [3. Validação Mongo] ──> [4. Deploy Stack]
                                                                        │
                                                                        v
[8. Input Syslog] <── [7. Login Root] <── [6. Preflight Web] <── [5. Captura Senha Log]
        │
        v
[9. Teste & Indexação]
```

---

## Passo 1: Verificar Requisitos do Host

No servidor Docker ou VM do Coolify, execute:

```bash
./scripts/check-host.sh
```

O script valida:
- `vm.max_map_count >= 262144` (obrigatório para o OpenSearch do Data Node);
- Docker Engine e plugin Docker Compose;
- Espaço em disco livre (mínimo 100 GB recomendado);
- Memória RAM disponível.

Se `vm.max_map_count` estiver abaixo de 262144, aplique no host:

```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-graylog.conf
sudo sysctl --system
```

---

## Passo 2: Configurar o `.env` e Gerar Segredos

1. Crie o arquivo `.env` a partir do modelo:

```bash
cp .env.example .env
```

2. Gere o `GRAYLOG_PASSWORD_SECRET` (96 caracteres criptograficamente seguros):

```bash
./scripts/generate-password-secret.sh
```
Copie a saída e preencha em `GRAYLOG_PASSWORD_SECRET` no `.env`.

3. Gere o hash SHA-256 para o usuário administrador `admin`:

```bash
./scripts/generate-admin-password-hash.sh
```
Digite uma senha forte de produção (mínimo 12 caracteres). Copie o hash de 64 caracteres e preencha em `GRAYLOG_ROOT_PASSWORD_SHA2` no `.env`.

4. Configure a URL pública e Timezone:
- `GRAYLOG_HTTP_EXTERNAL_URI=https://graylog.seudominio.com/` (deve terminar com `/`)
- `TZ=America/Fortaleza`
- `GRAYLOG_ROOT_TIMEZONE=America/Fortaleza`

---

## Passo 3: Configurar e Validar a Conexão com o MongoDB

Certifique-se de que o MongoDB já foi criado no Coolify ou externamente conforme [MONGODB.md](MONGODB.md).

Preencha a variável no `.env`:

```env
MONGODB_URI=mongodb://graylog:<SENHA_URL_ENCODED>@<HOST_MONGO>:27017/graylog?authSource=graylog
```

Valide a sintaxe e conectividade:

```bash
./scripts/check-mongodb.sh
```

---

## Passo 4: Subir o Stack

Valide o arquivo compose:

```bash
docker compose config
```

Suba os serviços em segundo plano:

```bash
docker compose up -d
```

Verifique o status dos containers:

```bash
docker compose ps
```

---

## Passo 5: Capturar a Senha Temporária do Preflight nos Logs

Acompanhe os logs do container do Graylog:

```bash
docker compose logs -f graylog
```

No primeiro boot, você verá um banner no log semelhante a:

```text
========================================================================================================
It seems you are starting Graylog for the first time. To set up a fresh install, a setup interface has
been started. You must log in to it to perform the initial configuration and continue.

Initial configuration is accessible at 0.0.0.0:9000, with username 'admin' and password 'XXXXXXXXXX'.
Try clicking on http://admin:XXXXXXXXXX@0.0.0.0:9000
========================================================================================================
```

Copie a senha alfanumérica de 10 caracteres exibida entre aspas simples (`password 'XXXXXXXXXX'`).

---

## Passo 6: Acessar a Interface de Preflight

1. Acesse no navegador o domínio configurado (ou `http://IP_DO_HOST:9000` se estiver testando diretamente):
   ```text
   https://graylog.seudominio.com
   ```
2. O navegador solicitará autenticação HTTP Basic (ou formulário de login de setup).
3. Utilize:
   - **Usuário:** `admin`
   - **Senha:** A senha temporária capturada no **Passo 5**.

---

## Passo 7: Provisionar CA e Conectar o Data Node

Na interface de Preflight:

1. **Certificate Authority (CA):**
   - O Graylog criará a autoridade certificadora interna para cifrar a comunicação TLS entre Graylog Server e Graylog Data Node.
   - Clique em **Create CA** (ou defina um nome de organização, ex: `MinhaRede Telecom CA`).
2. **Data Nodes Discovery:**
   - O Graylog detectará o container `datanode` via MongoDB (status inicial: `UNCONFIGURED`).
   - Clique em **Configure** / **Generate Certificates**.
   - O Graylog assinará os certificados para o nó `datanode` e enviará as chaves para ele.
   - O status do Data Node mudará para `STARTING` e em poucos segundos para `CONNECTED`.
3. **Concluir Setup:**
   - Clique em **Finish Configuration** (ou **Complete Setup**).
   - O Graylog encerrará a API de preflight e iniciará o servidor principal com o subsistema OpenSearch ativo.
   - A página recarregará automaticamente para a tela de login definitiva.

---

## Passo 8: Login no Graylog Principal

1. Na tela de login padrão do Graylog:
   - **Username:** `admin`
   - **Password:** A senha definida interativamente no **Passo 2** (cuja hash foi colocada em `GRAYLOG_ROOT_PASSWORD_SHA2`).
2. O painel principal do Graylog será exibido.

---

## Passo 9: Criar os Inputs de SYSLOG

Siga as instruções detalhadas em [SYSLOG.md](SYSLOG.md):

1. Vá em **System** → **Inputs**.
2. Selecione **Syslog UDP** → **Launch new input**:
   - Title: `Syslog UDP Telecom`
   - Bind address: `0.0.0.0`
   - Port: `5140`
   - Global: marque a caixa (ou deixe selecionado o nó)
   - Save.
3. Selecione **Syslog TCP** → **Launch new input**:
   - Title: `Syslog TCP Telecom`
   - Bind address: `0.0.0.0`
   - Port: `5140`
   - Global: marque a caixa
   - Save.

---

## Passo 10: Enviar Mensagem de Teste e Validar

No próprio servidor (ou de um host autorizado da rede), teste o envio:

### Teste UDP:
```bash
echo "<189>$(date '+%b %d %H:%M:%S') switch-core-01 IFNET: Interface GigabitEthernet0/0/1 state changed to UP" | nc -u -w1 127.0.0.1 5140
```

### Teste TCP:
```bash
echo "<189>$(date '+%b %d %H:%M:%S') router-border-01 OSPF: Neighbor 10.255.0.1 on Eth0/1 moved to FULL" | nc -w1 127.0.0.1 5140
```

### Validação na Interface:
1. Acesse **Search** no menu superior do Graylog.
2. Defina o intervalo para `Search in all messages` ou `Last 5 minutes`.
3. Você deverá ver as duas mensagens indexadas com campos decodificados (`facility`, `level`, `source`, `message`).

---

## Passo 11: Endurecer Healthcheck (Produção)

Após o preflight estar concluído, você pode alterar no `.env` (ou no Coolify):

```env
HEALTHCHECK_ALLOW_PREFLIGHT=false
```

E recarregar a stack:

```bash
docker compose up -d
```

Isso garante que o healthcheck exija estritamente HTTP `200 ALIVE` de `/api/system/lbstatus`.
