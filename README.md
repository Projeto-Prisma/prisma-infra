# Prisma — Infraestrutura e Orquestração

Repositório **maestro** do Projeto Prisma (*Tratamento Inteligente de Denúncias — Conecta Recife*, Sistemas Distribuídos / UFRPE).

Este repo **não tem lógica de negócio**. Ele orquestra todo o sistema: sobe o **RabbitMQ** (broker) e os **9 módulos**, cada um com seu **banco próprio** (*database-per-service*), em um único `docker compose up`.

A lógica de cada módulo vive no seu próprio repositório (`prisma-m1-ingestao` … `prisma-m9-secretarias`). Aqui apenas os **conectamos**.

---

## 1. Pré-requisitos

- **Docker** + **Docker Compose v2** (`docker compose`, sem hífen). Verifique com `docker compose version`.
- **Git**.

---

## 2. Como rodar (3 passos)

```bash
# 1) Clonar este repositório de infra
git clone git@github.com:Projeto-Prisma/prisma-infra.git
cd prisma-infra

# 2) Trazer o código dos 9 módulos para dentro desta pasta
./setup.sh                 # via SSH (clona o m9 privado sem token)
#   ./setup.sh https       # alternativa via HTTPS (exige login/token p/ o m9)

# 3) Configurar o ambiente e subir tudo
cp .env.example .env
docker compose up --build
```

Pronto. O `setup.sh` clona cada módulo com o **nome de diretório** que o `docker-compose.yml` espera (`m1-ingestao`, `m2-classificacao`, …). Cada módulo precisa ter um **`Dockerfile` na raiz** — esse é o único contrato de build entre a infra e os módulos.

> **Atalhos (opcional):** se tiver `make`, use `make setup`, `make up`, `make scale`, `make down`, `make reset`. Rode `make ajuda` para a lista. Sem `make` (ex.: Windows), use os comandos `docker compose` direto.

---

## 3. O que acessar depois de subir

| Serviço | URL | Para quê |
|---|---|---|
| **Painel RabbitMQ** | http://localhost:15672 | Ver filas enchendo/esvaziando, conexões, taxa de mensagens. Login: usuário/senha do `.env` (`prisma`/`prisma_secret`). |
| **M1 — Ingestão (API)** | http://localhost:8001 | Ponto de entrada: enviar denúncias para o sistema. |
| **M7 — Analytics (API)** | http://localhost:8007 | View consolidada (CQRS) consumida pelo painel. |
| **M8 — Painel Web** | http://localhost:8080 | Interface da gestão municipal. |
| **M9 — Secretarias (API)** | http://localhost:8009 | CRUD de secretarias (destinos do roteamento). |

Os módulos **M3, M4, M5 e M6** não publicam porta no host de propósito — são consumidores puros; o efeito deles aparece no painel do RabbitMQ, nos logs e no M7. O **M2** também não publica porta, porque é escalável (veja a seção 6).

**Bancos** (inspeção opcional via DBeaver/psql/Compass): Postgres em `localhost:5433`–`5439`, MongoDB em `27017`, Redis em `6379`. Útil para **provar a separação** dos bancos na apresentação. As linhas de `ports:` dos bancos podem ser comentadas se preferir não expô-los.

---

## 4. Estrutura do repositório

```
prisma-infra/
├── docker-compose.yml      # sobe rabbit + 9 módulos + 9 bancos
├── .env.example            # credenciais/portas compartilhadas (copie p/ .env)
├── .gitignore              # ignora .env e os módulos clonados
├── setup.sh                # clona/atualiza os 9 módulos
├── Makefile                # atalhos (opcional)
└── README.md               # este arquivo

# criados pelo setup.sh (não versionados aqui):
├── m1-ingestao/  m2-classificacao/  m3-priorizacao/  m4-recorrencia/
├── m5-roteamento/  m6-notificacoes/  m7-analytics/  m8-frontend/
└── m9-secretarias/
```

---

## 5. Contrato de mensageria (LEIA — é o acordo entre os 4 repos)

Como os módulos estão em repositórios separados, eles só conseguem conversar se **todos seguirem a mesma convenção** de exchange, routing keys e filas. Esta é a parte mais importante da integração.

**Exchange único:** `denuncias` — tipo **`topic`**, **durável**.
**Mensagens persistentes:** publique com `delivery_mode=2` e declare as filas como **duráveis**, para que nada se perca se o broker reiniciar.

### Routing keys (nomes dos eventos)

| Evento (routing key) | Produtor | Consumidores |
|---|---|---|
| `denuncia.recebida` | M1 | M2 |
| `denuncia.classificada` | M2 | M3, M4, M7 |
| `padrao.recorrencia` | M4 | M3, M7 |
| `denuncia.priorizada` | M3 | M5, M6, M7 |
| `denuncia.encaminhada` | M5 | M6, M7 |

### Filas e bindings (já refletidos no `docker-compose.yml`)

Cada consumidor declara **uma fila durável própria** e a vincula (`bind`) às routing keys que lhe interessam. Os nomes abaixo chegam a cada módulo via variáveis `QUEUE` e `BINDING_KEYS`.

| Módulo | Fila (`QUEUE`) | Vinculada a (`BINDING_KEYS`) |
|---|---|---|
| M2 | `m2.classificacao` | `denuncia.recebida` |
| M3 | `m3.priorizacao` | `denuncia.classificada`, `padrao.recorrencia` |
| M4 | `m4.recorrencia` | `denuncia.classificada` |
| M5 | `m5.roteamento` | `denuncia.priorizada` |
| M6 | `m6.notificacoes` | `denuncia.encaminhada`, `denuncia.priorizada` |
| M7 | `m7.analytics` | `#` (todos os eventos — padrão CQRS) |

> **Por que filas nomeadas e duráveis?** Porque é isso que garante a **resiliência**: se um consumidor cai, as mensagens ficam acumuladas na fila dele e são processadas quando ele volta. E é o que permite o padrão **competing consumers** do M2 (seção 6): várias réplicas consomem da **mesma** fila `m2.classificacao`.

---

## 6. Escalonamento — *competing consumers* (M2)

O **M2 (classificação/NLP)** é o módulo pesado. Em picos de denúncias, suba várias réplicas:

```bash
docker compose up --build --scale m2-classificacao=3
```

As 3 réplicas consomem da **mesma fila** `m2.classificacao`, e o RabbitMQ distribui as mensagens entre elas (round-robin). Por isso o serviço `m2-classificacao` **não tem `container_name` nem `ports`** no compose — fixar qualquer um dos dois impediria subir a 2ª réplica (conflito de nome/porta).

Para o efeito ficar visível na demo, recomenda-se que o M2 use **prefetch baixo** (`basic_qos(prefetch_count=1)`) e dê **ack só ao terminar** de processar cada mensagem — assim a carga se espalha de fato entre as réplicas, em vez de uma só abocanhar tudo.

---

## 7. Contrato de ambiente (o que cada módulo recebe)

A infra injeta estas variáveis nos módulos. Cada repo deve **ler a configuração do ambiente** (nunca hardcodar host/porta), para funcionar igual aqui e isolado.

**Todos os módulos de mensageria** recebem:
- `RABBITMQ_URL` — ex.: `amqp://prisma:prisma_secret@rabbitmq:5672/`
- `EXCHANGE` — sempre `denuncias`
- `QUEUE` e `BINDING_KEYS` — conforme a tabela da seção 5 (M1 não tem, é só produtor)

**Banco de dados** (cada um aponta para o SEU container):
- M1, M2, M3, M5, M6, M9 → `DATABASE_URL` (PostgreSQL)
- M4 → `DATABASE_URL` (PostGIS) — o M4 deve rodar, na subida, `CREATE EXTENSION IF NOT EXISTS postgis;`
- M7 → `MONGODB_URL` (`mongodb://db-m7:27017/analytics`)
- M8 → `REDIS_URL` (`redis://db-m8:6379/0`)

**Integração REST** (módulos que consultam o M9):
- M5 e M6 → `SECRETARIAS_API_URL` = `http://m9-secretarias:8000` (hostname interno do Docker)

**Frontend (M8) — atenção à rede:** o JavaScript do painel roda no **navegador**, não dentro do container. Logo, as URLs de API que o front chama devem ser as **portas publicadas no host** (`http://localhost:8001`, `:8007`, `:8009`) — e **não** os hostnames internos (`m7-analytics:8000` não resolve no navegador). Se o M8 for Vite/CRA, essas variáveis costumam ser de **build** (`VITE_…` / `REACT_APP_…`); nesse caso, passe-as como **build args** no Dockerfile do M8.

> Convenção de porta interna: os serviços de aplicação escutam na **porta 8000** dentro do container (Python/FastAPI ou Node). O M8 escuta na **80** (nginx servindo o build). Se o Dockerfile de algum módulo usar outra porta, ajuste o lado direito do mapeamento `ports:` daquele serviço no compose.

---

## 8. Roteiro de demonstração (para o vídeo)

1. **Subir e mostrar a topologia.** `docker compose up --build` e abra http://localhost:15672 → aba *Queues* para ver as filas declaradas.
2. **Fluxo ponta a ponta.** Envie uma denúncia pelo M1 (`localhost:8001`) e acompanhe nos logs (`docker compose logs -f`) o evento passar por M2 → M4/M3 → M5 → M6, e o M7 atualizar a view. Veja o resultado no painel (`localhost:8080`).
3. **Database-per-service.** Conecte em dois bancos diferentes (ex.: `localhost:5433` do M1 e `localhost:5435` do M3) e mostre que cada um guarda só os seus dados — não há JOIN entre eles.
4. **Resiliência (o destaque).** Derrube um consumidor e mostre as mensagens se acumulando:
   ```bash
   docker compose stop m2-classificacao        # "cai" a classificação
   # envie várias denúncias pelo M1 → veja a fila m2.classificacao crescer no painel
   docker compose start m2-classificacao        # volta → processa o acúmulo
   ```
   Isso prova na prática o *"nada se perde em picos"*.
5. **Escalabilidade.** `docker compose up --scale m2-classificacao=3` e mostre, no painel, as 3 conexões consumindo a mesma fila.

---

## 9. Comandos úteis

```bash
docker compose up --build                              # sobe tudo
docker compose up --build --scale m2-classificacao=3   # escala o M2
docker compose ps                                      # status
docker compose logs -f                                 # logs de tudo
docker compose logs -f m5-roteamento                   # logs de um módulo
docker compose stop m2-classificacao                   # derruba um serviço
docker compose start m2-classificacao                  # religa um serviço
docker compose down                                    # derruba (MANTÉM os dados)
docker compose down -v                                 # derruba e APAGA os bancos
docker compose build m7-analytics                      # rebuild de um módulo só
```

---

## 10. Alternativa: Git submodules (em vez do `setup.sh`)

O `setup.sh` puxa sempre o **último** commit de cada módulo (simples, mas mais frágil às vésperas da demo). **Submódulos** fixam o **commit exato** de cada módulo neste repo — mais reprodutível para a entrega. Para adotar:

```bash
# rode UMA vez, dentro do prisma-infra:
for m in m1-ingestao m2-classificacao m3-priorizacao m4-recorrencia \
         m5-roteamento m6-notificacoes m7-analytics m8-frontend m9-secretarias; do
  git submodule add git@github.com:Projeto-Prisma/prisma-$m.git $m
done
git commit -am "infra: módulos como submódulos"
```

Depois, **remova** as linhas dos diretórios de módulo do `.gitignore` (com submódulos eles devem ser rastreados). Quem for rodar clona com:

```bash
git clone --recurse-submodules git@github.com:Projeto-Prisma/prisma-infra.git
```

E para atualizar os módulos depois: `git submodule update --remote --merge`.

---

## 11. Troubleshooting

**Os módulos não conectam no RabbitMQ / erro de credencial.** Por padrão, o usuário `guest` do RabbitMQ **só conecta via localhost** — e os módulos conectam de outros containers. Por isso usamos um usuário dedicado (`prisma`) no `.env`, e **não** `guest`. Se algum módulo hardcodou `guest/guest`, troque para ler `RABBITMQ_URL` do ambiente.

**Um módulo sobe antes do banco/broker e morre (*crash loop*).** O compose já usa `depends_on` com `condition: service_healthy`, mas "container saudável" não garante que a fila já exista. Coloque **retry com backoff** na conexão AMQP dentro de cada módulo. O `restart: unless-stopped` faz o container tentar de novo enquanto isso.

**M4 reclama que a extensão `postgis` não existe.** A imagem é `postgis/postgis`, mas a extensão precisa ser ativada **no banco**: o M4 deve rodar `CREATE EXTENSION IF NOT EXISTS postgis;` na inicialização (migração ou script de start).

**Conflito de porta no host (`port is already allocated`).** Algo na sua máquina já usa aquela porta (ex.: um Postgres local na 5432 — por isso os bancos aqui usam 5433+). Ajuste o lado esquerdo do `ports:` no compose ou pare o serviço conflitante.

**Erro ao escalar o M2.** Confirme que `m2-classificacao` continua **sem** `container_name` e **sem** `ports`. Qualquer um dos dois quebra o `--scale`.

**O painel do M8 não puxa dados.** Veja a seção 7: as URLs de API do front têm de ser as portas publicadas no host (`localhost:800x`), e em Vite/CRA precisam ser **build args** — não basta `environment:` em runtime.

**`make` não funciona no Windows.** Use os comandos `docker compose` da seção 9 diretamente.
