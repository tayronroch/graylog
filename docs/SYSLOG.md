# Configuração de SYSLOG para Rede de Telecom

Este documento orienta a recepção e o processamento de logs de uma infraestrutura de telecomunicações com mais de 200 a 500 equipamentos de rede (switches IP/MPLS, roteadores de borda, agregação e distribuição).

---

## 1. Princípios de Arquitetura

1. **Entrada Direta via Host:** As portas `5140/UDP` e `5140/TCP` são publicadas diretamente no host do container Docker, sem passar pelo proxy reverso HTTP (Traefik/Caddy do Coolify).
2. **Buffer de Recepção e Journal:** Toda mensagem que entra no Graylog é gravada imediatamente no disco do volume persistente (`graylog-data/journal`) antes de ser processada e gravada no Data Node. Em rajadas de rede (ex.: queda de anel MPLS ou flap de sessão BGP), o journal absorve o pico.
3. **Criação Oficial de Inputs:** **NUNCA** insira documentos diretamente nas coleções do MongoDB para criar inputs. Os inputs do Graylog devem ser criados via **Web UI** ou via **REST API oficial**.

---

## 2. Parâmetros Recomendados para os Inputs

### Parâmetros Críticos de Performance:
- **`force_rdns: false` (CRÍTICO):** Se ativado, o Graylog tenta resolver o PTR de DNS para o IP de origem de **cada** pacote syslog. Em uma rajada de 2.000 EPS, isso causa fila imediata e esgotamento de buffers de rede.
- **`store_full_message: false`:** Evita armazenar o campo `full_message` duplicado além do campo `message`, economizando ~40% de espaço em disco nos índices.
- **`recv_buffer_size: 1048576` (1 MB) ou `2097152` (2 MB):** Garante que o buffer do socket do kernel do Linux não descarte pacotes UDP durante rajadas curtas.
- **`timezone: America/Fortaleza`:** Protocolos legados de Syslog (RFC 3164) enviam timestamps sem informação de fuso horário (ex: `Oct 13 14:32:00`). Esse parâmetro força o Graylog a interpretar o horário no timezone correto da operação.
- **`allow_override_date: true`:** Se o relógio do roteador estiver ligeiramente dessincronizado, permite o ajuste adequado.

---

## 3. Criação dos Inputs via Web Interface

Acesse a interface web: **System** → **Inputs**.

### Input 1: Syslog UDP
1. No menu drop-down *Select input*, escolha **Syslog UDP** e clique em **Launch new input**.
2. Preencha:
   - **Title:** `Syslog UDP (5140)`
   - **Global:** Marque a caixa (habilita em todos os nós caso haja expansão futura)
   - **Bind address:** `0.0.0.0`
   - **Port:** `5140`
   - **Receive Buffer Size:** `1048576` (1048576 bytes = 1MB)
   - **Default Timezone:** `America/Fortaleza`
   - **Force rDNS:** Desmarcado (`false`)
   - **Store full message:** Desmarcado (`false`)
   - **Allow overriding date:** Marcado (`true`)
3. Clique em **Save**.

### Input 2: Syslog TCP
1. No menu drop-down *Select input*, escolha **Syslog TCP** e clique em **Launch new input**.
2. Preencha:
   - **Title:** `Syslog TCP (5140)`
   - **Global:** Marque a caixa
   - **Bind address:** `0.0.0.0`
   - **Port:** `5140`
   - **Receive Buffer Size:** `1048576`
   - **Max message size:** `2097152` (2 MB)
   - **TCP keepalive:** Marcado (`true`)
   - **Default Timezone:** `America/Fortaleza`
   - **Force rDNS:** Desmarcado (`false`)
   - **Store full message:** Desmarcado (`false`)
   - **Allow overriding date:** Marcado (`true`)
3. Clique em **Save**.

---

## 4. Automação Idempotente via REST API (Opcional)

Se preferir provisionar via script automatizado, utilize o endpoint oficial autenticado:

```bash
# Obtenha o token de autenticação ou use credencial admin
GRAYLOG_URL="http://127.0.0.1:9000"
AUTH="admin:SUA_SENHA_ADMIN"

# Criar Syslog UDP
curl -s -u "$AUTH" -H "X-Requested-By: cli" -H "Content-Type: application/json" \
  -X POST "$GRAYLOG_URL/api/system/inputs" \
  -d '{
    "title": "Syslog UDP (5140)",
    "type": "org.graylog2.inputs.syslog.udp.SyslogUDPInput",
    "global": true,
    "configuration": {
      "bind_address": "0.0.0.0",
      "port": 5140,
      "recv_buffer_size": 1048576,
      "timezone": "America/Fortaleza",
      "force_rdns": false,
      "allow_override_date": true,
      "store_full_message": false,
      "expand_structured_data": false
    }
  }'

# Criar Syslog TCP
curl -s -u "$AUTH" -H "X-Requested-By: cli" -H "Content-Type: application/json" \
  -X POST "$GRAYLOG_URL/api/system/inputs" \
  -d '{
    "title": "Syslog TCP (5140)",
    "type": "org.graylog2.inputs.syslog.tcp.SyslogTCPInput",
    "global": true,
    "configuration": {
      "bind_address": "0.0.0.0",
      "port": 5140,
      "recv_buffer_size": 1048576,
      "timezone": "America/Fortaleza",
      "force_rdns": false,
      "allow_override_date": true,
      "store_full_message": false,
      "use_null_delimiter": false,
      "max_message_size": 2097152,
      "tcp_keepalive": true,
      "tls_enable": false
    }
  }'
```

---

## 5. Exemplos de Configuração nos Equipamentos

Substitua `10.200.0.50` pelo IP da interface de gerência do seu servidor Graylog.

### Huawei (VRP)
```text
system-view
info-center enable
info-center loghost source-ip 10.200.0.10
info-center loghost 10.200.0.50 port 5140 facility local0
commit
```

### Datacom (DmOS)
```text
config
logging host 10.200.0.50
 logging host 10.200.0.50 transport udp port 5140
 logging host 10.200.0.50 facility local0
 logging host 10.200.0.50 severity informational
commit
```

### Cisco (IOS / IOS-XE)
```text
configure terminal
service timestamps log datetime msec localtime show-timezone
logging host 10.200.0.50 transport udp port 5140
logging trap informational
logging facility local0
logging source-interface Loopback0
end
write memory
```

### MikroTik (RouterOS v7)
```text
/system logging action
add name=graylog target=remote remote=10.200.0.50 remote-port=5140 src-address=10.200.0.20 bsd-syslog=yes syslog-facility=local0

/system logging
add action=graylog topics=info
add action=graylog topics=warning
add action=graylog topics=error
add action=graylog topics=critical
add action=graylog topics=ospf
add action=graylog topics=bgp
add action=graylog topics=mpls
```

### Servidores Linux (rsyslog)
Adicione em `/etc/rsyslog.d/50-graylog.conf`:
```text
*.* @10.200.0.50:5140;RSYSLOG_SyslogProtocol23Format
```
*(Para envio TCP, use `@@10.200.0.50:5140`)*.
Reinicie o serviço:
```bash
sudo systemctl restart rsyslog
```

---

## 6. Categorização e Pipelines Recomendados (Próximos Passos)

Em uma rede com switches/roteadores IP/MPLS, os logs mais frequentes são:
- **Interfaces & LACP:** `IFNET`, `LINK`, `LINEPROTO`, `ETH_TRUNK`, `LACP`
- **Roteamento:** `OSPF`, `BGP`, `ISIS`
- **MPLS & L2VPN:** `LDP`, `RSVP`, `MPLS_L2VPN`, `VPLS`, `EVPN`
- **Segurança & AAA:** `LOGIN`, `SSH`, `TACACS`, `RADIUS`, `CMD_RECORD`
- **Hardware & Ambiente:** `FAN`, `POWER`, `TEMPERATURE`, `OPTICAL`

Recomenda-se criar **Streams** dedicados no Graylog por categoria ou fabricante, com regras de alerta para eventos críticos (ex: *BGP Neighbor Down*, *OSPF Adjacency Down*, *Port Down em Uplink*).
