# Diagnóstico e Resolução de Problemas (Troubleshooting)

Este guia reúne diagnósticos e soluções para os incidentes mais comuns na operação do Graylog e do Data Node.

---

## 1. Problemas no Host e Inicialização do Data Node

### Sintoma: O Data Node não inicia e fecha imediatamente
- **Causa provável:** O kernel do Linux está com `vm.max_map_count` inferior a `262144`, impedindo a inicialização do processo OpenSearch interno.
- **Log típico:**
  ```text
  max virtual memory areas vm.max_map_count [65530] is too low, increase to at least [262144]
  ```
- **Solução:**
  1. Aplique no host do Docker:
     ```bash
     sudo sysctl -w vm.max_map_count=262144
     echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-graylog.conf
     sudo sysctl --system
     ```
  2. Valide com `./scripts/check-host.sh`.
  3. Reinicie o container: `docker compose restart datanode`.

---

## 2. Falhas de Conexão com o MongoDB

### Sintoma A: `MongoSocketOpenException` / `Connection refused`
- **Causa provável:** O Graylog não consegue resolver o hostname do container do MongoDB na rede do Coolify.
- **Verificação:**
  Execute o script de teste de conectividade:
  ```bash
  ./scripts/check-mongodb.sh
  ```
- **Solução:**
  1. No Coolify, abra o recurso do Graylog → **Advanced** → **Docker compose** → **Predefined network**.
  2. Certifique-se de que a opção **Connect to predefined network** está ativada.
  3. Verifique se o hostname na `MONGODB_URI` corresponde exatamente ao nome interno do container do MongoDB no Coolify.

### Sintoma B: `Command failed with error 18 (AuthenticationFailed)`
- **Causa provável:** 
  1. A senha contém caracteres especiais (como `@`, `/`, `:`, `+`, `#`, `%`) que **não** foram convertidos para URL-encoding.
  2. O parâmetro `authSource` está incorreto.
- **Solução:**
  - Se o usuário `graylog` foi criado dentro do database `admin`, a URI **deve** conter `?authSource=admin`.
  - Se foi criado dentro do database `graylog`, utilize `?authSource=graylog`.
  - Consulte [MONGODB.md](MONGODB.md#url-encoding-da-senha) para a tabela de codificação.

---

## 3. Problemas no Preflight e Data Node Setup

### Sintoma: Perdi a senha temporária do preflight exibida no primeiro boot
- **Solução:**
  Recupere a senha inspecionando os logs do container do Graylog:
  ```bash
  docker compose logs graylog | grep -iE "password '"
  ```
  A senha é uma sequência alfanumérica de 10 caracteres informada no banner inicial.

### Sintoma: No preflight, o Data Node fica travado em `UNCONFIGURED`
- **Causa:** O Graylog Server ainda não disparou a assinatura do certificado ou o Data Node não conseguiu alcançar a API do Graylog Server.
- **Solução:**
  1. Na interface web de Preflight, clique em **Configure** ao lado do nó do Data Node.
  2. Se a CA não foi criada, clique em **Create CA** informando um nome de organização.
  3. Verifique os logs do Data Node:
     ```bash
     docker compose logs datanode
     ```

---

## 4. Healthcheck Falhando ou Status Unhealthy

### Sintoma: Container Graylog marcado como `unhealthy` durante o primeiro boot
- **Causa:** Durante o preflight, o endpoint `/api/system/lbstatus` retorna HTTP 404 (pois o sistema ainda não está totalmente provisionado).
- **Solução:**
  - Certifique-se de que a variável `HEALTHCHECK_ALLOW_PREFLIGHT=true` está configurada no `.env`. Ela permite que o healthcheck aceite o HTTP 404 temporário para que o proxy do Coolify direcione o tráfego para a tela de setup.
  - Após concluir o setup inicial, mude para `HEALTHCHECK_ALLOW_PREFLIGHT=false` se desejar checagem estrita de produção.

### Sintoma: Endpoint `/api/system/lbstatus` retorna 503 DEAD
- **Causa:** O cluster do Graylog pausou o processamento porque o Data Node ou o OpenSearch ficaram inacessíveis ou com shards vermelhos (*Red Status*).
- **Solução:**
  Verifique os logs com:
  ```bash
  ./scripts/status.sh
  ```

---

## 5. Mensagens de Syslog Não Estão Sendo Recebidas

### Sintoma: Os equipamentos enviam syslog mas nada aparece no Graylog
- **Passo 1: Verificar se a porta está ouvindo no host:**
  ```bash
  sudo ss -tulpn | grep 5140
  ```
  Deverá exibir bindings para `0.0.0.0:5140` e `:::5140` em TCP e UDP.

- **Passo 2: Testar envio manual com Netcat:**
  ```bash
  # Teste UDP
  echo "<189>$(date) teste-manual host-test Mensagem de teste" | nc -u -w1 127.0.0.1 5140
  ```
  Se aparecer na busca da Web UI do Graylog, a stack do Docker está funcionando perfeitamente.

- **Passo 3: Verificar Firewall do Host:**
  Se o teste local funciona mas os equipamentos externos não chegam, o firewall do provedor (Security Group / AWS / Hetzner) ou o `iptables/ufw` do servidor está bloqueando a porta `5140/UDP`. Siga a configuração em [SECURITY.md](SECURITY.md#mitigação-obrigatória-firewall--iptables--security-groups).

- **Passo 4: Verificar se o Input está ativo:**
  Na interface web do Graylog, em **System** → **Inputs**, certifique-se de que o input está com status **RUNNING** e que o contador de mensagens por segundo não está travado.

---

## 6. Journal Crescendo Continuamente (`uncommitted_journal_entries`)

### Sintoma: O script `./scripts/status.sh` reporta o tamanho do journal subindo
- **Causa:** A taxa de recepção nas portas 5140 está maior que a capacidade de indexação do Data Node no disco, ou o OpenSearch está sofrendo com GC (Garbage Collection) prolongado por falta de memória heap.
- **Solução:**
  1. Verifique o consumo de CPU e RAM dos containers com `docker stats`.
  2. Ajuste `DATANODE_HEAP` no `.env` (ex: aumente de `2g` para `4g` ou `8g` se a máquina tiver RAM disponível).
  3. Verifique a velocidade de I/O do disco (evite discos de rede lentos para os volumes do Graylog).
