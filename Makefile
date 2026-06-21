# Projeto Prisma — atalhos. Use "make ajuda" para ver os comandos.
# (Windows sem make? Use os comandos docker compose direto — ver README.)

.DEFAULT_GOAL := ajuda

.PHONY: ajuda setup up scale down reset logs ps rabbit

ajuda:
	@echo "Comandos disponiveis:"
	@echo "  make setup   - clona/atualiza todos os modulos (./setup.sh)"
	@echo "  make up      - sobe todo o sistema (build incluso)"
	@echo "  make scale   - sobe escalando o M2 (classificacao) para 3 replicas"
	@echo "  make down    - derruba os containers (MANTEM os bancos)"
	@echo "  make reset   - derruba e APAGA todos os bancos (volumes)"
	@echo "  make logs    - acompanha os logs de todos os servicos"
	@echo "  make ps      - status dos containers"
	@echo "  make rabbit  - URL do painel do RabbitMQ"

setup:
	./setup.sh

up:
	docker compose up --build

scale:
	docker compose up --build --scale m2-classificacao=3

down:
	docker compose down

reset:
	docker compose down -v

logs:
	docker compose logs -f

ps:
	docker compose ps

rabbit:
	@echo "Painel RabbitMQ: http://localhost:15672"
