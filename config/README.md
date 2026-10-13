# Diretório de Configurações (`config/`)

Este diretório é reservado para artefatos opcionais e arquivos de configuração adicionais que você queira versionar ou acoplar ao Graylog no futuro.

---

## Como as Configurações São Gerenciadas Neste Projeto

Nesta arquitetura moderna do Graylog Open com Data Node:

1. **Configurações de Produção:**
   - São declaradas centralmente via **variáveis de ambiente** no arquivo `.env` e mapeadas no `docker-compose.yml` (ex: limites de memória JVM, timezones, URIs e portas).
2. **Configurações Internas e Estados Dinâmicos:**
   - O `node-id`, certificados gerados pela CA do preflight, tokens e metadados são gravados de forma segura e transparente no banco de dados MongoDB externo e nos volumes Docker persistentes (`graylog-data` e `graylog-datanode`).
3. **Inputs, Streams e Pipelines:**
   - São gerenciados e mantidos diretamente pela interface Web ou REST API oficial do Graylog.

---

## Casos de Uso Futuros para Esta Pasta

Você pode utilizar este diretório para guardar:
- **Content Packs (`.json`):** Exportações de dashboards, regras de parsing de telecom (Grok patterns para Huawei/Cisco/Datacom/MikroTik) e pipelines de enriquecimento.
- **Plugins customizados (`.jar`):** Caso sua infraestrutura desenvolva ou utilize plugins adicionais do Graylog, eles podem ser organizados aqui e montados no volume de plugins do Graylog.
- **Certificados TLS corporativos:** Arquivos de certificados CA para cenários onde a autoridade certificadora é corporativa externa em vez da gerada pelo preflight.
