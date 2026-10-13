# Diretrizes e Boas Práticas de Segurança

Este documento detalha o modelo de segurança e as proteções implementadas no ambiente Graylog.

---

## 1. Tratamento de Segredos e Credenciais

- **Sem Segredos no Versionamento:** O arquivo `.env` está explicitamente no `.gitignore` e **nunca** deve ser versionado no Git.
- **`.env.example` Sanitizado:** O arquivo de exemplo contém apenas placeholders e variáveis vazias documentadas, sem senhas padrão ou de teste.
- **Geração Segura:**
  - `GRAYLOG_PASSWORD_SECRET`: gerado com 96 caracteres pseudoaleatórios de `/dev/urandom` através do script `./scripts/generate-password-secret.sh`.
  - `GRAYLOG_ROOT_PASSWORD_SHA2`: calculado a partir de entrada interativa oculta via `./scripts/generate-admin-password-hash.sh`, sem persistência de senha plana em disco ou histórico de shell.

---

## 2. Superfície de Rede e Exposição de Portas

```text
[ Internet / Público ]
         │
         │  (HTTPS 443 com certificado TLS do Coolify)
         v
+─────────────────────────────────────────+
│ Proxy Reverso Coolify (Traefik/Caddy)   │
+─────────────────────────────────────────+
         │
         │  (Rede interna Docker, porta 9000)
         v
+─────────────────────────────────────────+
│ Container: Graylog Server (porta 9000)  │
+─────────────────────────────────────────+
         │
         │  (Rede bridge interna isolada)
         v
+─────────────────────────────────────────+
│ Container: Graylog Data Node            │
│ Portas 8999, 9200, 9300: NÃO PUBLICADAS │
+─────────────────────────────────────────+
```

### Regras de Portas e Bindings:
1. **Porta 9000 (Web UI / API):**
   - Configurada via `expose: ["9000"]` no `docker-compose.yml`.
   - **Não** possui mapeamento direto com o host (`ports:`). O tráfego obrigatoriamente passa pelo proxy do Coolify, forçando HTTPS e TLS.
2. **Portas 8999, 9200 e 9300 (Data Node / OpenSearch):**
   - **Estritamente internas** à rede Docker `graylog`.
   - Nenhuma dessas portas é exposta ao host ou à internet, impedindo qualquer acesso externo não autorizado à engine do OpenSearch.
3. **Porta 27017 (MongoDB):**
   - O MongoDB opera como recurso isolado dentro da rede privada do Coolify.
   - **Não** ative *Public access* no MongoDB.

---

## 3. Proteção do SYSLOG (Porta 5140 TCP/UDP)

A porta 5140 é a **única** porta publicada no host pelo Docker (`ports: ["5140:5140/tcp", "5140:5140/udp"]`).

### Riscos Reais da Porta 5140 Aberta na Internet:
- **UDP Spoofing:** Pacotes UDP podem ter o IP de origem forjado por atacantes, injetando logs falsos no seu SIEM.
- **Amplificação e Negação de Serviço (DoS):** Flood de pacotes de log esgotando o Journal e o disco do Graylog.
- **Vazamento de Topologia:** Mensagens de log de roteadores contêm IPs internos, rotas, nomes de interfaces e alertas de falha.

### Mitigação Obrigatória (Firewall / IPTables / Security Groups):
A porta 5140 deve ser bloqueada para a Internet pública e liberada **exclusivamente** para os prefixos IP de gerência dos seus equipamentos.

#### Exemplo com `iptables` / `ufw` no Host Linux:
> [!WARNING]
> Por padrão, o Docker manipula as regras de iptables contornando o UFW básico. Para proteger portas Docker publicadas, utilize a chain `DOCKER-USER`:

```bash
# Permite Syslog apenas da sub-rede de gerência dos roteadores (ex: 10.200.0.0/16)
sudo iptables -I DOCKER-USER -p udp -m multiport --dports 5140 -s 10.200.0.0/16 -j ACCEPT
sudo iptables -I DOCKER-USER -p tcp -m multiport --dports 5140 -s 10.200.0.0/16 -j ACCEPT

# Bloqueia todo o restante
sudo iptables -A DOCKER-USER -p udp -m multiport --dports 5140 -j DROP
sudo iptables -A DOCKER-USER -p tcp -m multiport --dports 5140 -j DROP
```

---

## 4. Evolução Futura: SYSLOG TCP com TLS

Para equipamentos que suportam Syslog com criptografia TLS (RFC 5425), como servidores Linux, firewalls de nova geração e roteadores compatíveis:
1. Em **System** → **Inputs**, crie um input **Syslog TCP** com `tls_enable: true`.
2. Configure o certificado de servidor e a chave privada no input (ou utilize a CA corporativa).
3. Isso garante sigilo e autenticidade ponta a ponta na transmissão dos logs.

---

## 5. Mínimo Privilégio no MongoDB

- O Graylog **não** deve utilizar o usuário administrativo `root` do MongoDB.
- O usuário dedicado `graylog` deve possuir apenas os privilégios estritamente necessários no seu próprio database:
  - `readWrite` (leitura e escrita nas coleções do Graylog)
  - `dbAdmin` (criação de índices e estatísticas da base)

---

## 6. Versionamento Fixo e Imutabilidade

- Todas as imagens de containers no `docker-compose.yml` utilizam tags de versão semântica explícitas (ex: `graylog:7.1.10`, `graylog-datanode:7.1.10`).
- A tag `latest` é estritamente proibida para evitar quebras silenciosas em redeploys não planejados.

---

## 7. Processo Seguro de Upgrade

Antes de atualizar uma versão do Graylog:
1. Execute backup completo do MongoDB conforme [BACKUP.md](BACKUP.md).
2. Consulte a matriz oficial de compatibilidade do Graylog para validar se a versão pretendida suporta a sua versão do MongoDB.
3. Atualize a versão no `.env`:
   - Altere `GRAYLOG_VERSION` e `DATANODE_VERSION` simultaneamente (Graylog e Data Node devem permanecer na mesma versão).
4. Aplique via Coolify ou com `docker compose up -d`.
5. Monitore os logs com `./scripts/status.sh` e acompanhe as migrações automáticas de schema do banco.
