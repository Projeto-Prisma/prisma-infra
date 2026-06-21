#!/usr/bin/env bash
# ============================================================================
#  Projeto Prisma — setup.sh
#  Clona (ou atualiza) todos os 9 módulos nesta pasta, com os nomes de
#  diretório que o docker-compose.yml espera (m1-ingestao ... m9-secretarias).
#
#  Uso:
#    ./setup.sh          # padrão: SSH (recomendado — clona o m9 privado sem token)
#    ./setup.sh https    # via HTTPS (exige login/token p/ o repositório privado m9)
#
#  Depois:  cp .env.example .env  &&  docker compose up --build
# ============================================================================
set -euo pipefail

ORG="Projeto-Prisma"
PROTO="${1:-ssh}"

if [ "$PROTO" = "ssh" ]; then
  BASE="git@github.com:${ORG}"
else
  BASE="https://github.com/${ORG}"
fi

echo "→ Organização: ${ORG}   |   Protocolo: ${PROTO}"
echo

# "repo_no_github:diretorio_local"
MODULOS=(
  "prisma-m1-ingestao:m1-ingestao"
  "prisma-m2-classificacao:m2-classificacao"
  "prisma-m3-priorizacao:m3-priorizacao"
  "prisma-m4-recorrencia:m4-recorrencia"
  "prisma-m5-roteamento:m5-roteamento"
  "prisma-m6-notificacoes:m6-notificacoes"
  "prisma-m7-analytics:m7-analytics"
  "prisma-m8-frontend:m8-frontend"
  "prisma-m9-secretarias:m9-secretarias"
)

for entry in "${MODULOS[@]}"; do
  repo="${entry%%:*}"
  dir="${entry##*:}"
  if [ -d "$dir/.git" ]; then
    echo "↻  Atualizando $dir ..."
    git -C "$dir" pull --ff-only
  else
    echo "⬇  Clonando $repo  →  $dir ..."
    git clone "${BASE}/${repo}.git" "$dir"
  fi
done

echo
echo "✅ Todos os módulos prontos."
echo "   Próximo passo:  cp .env.example .env  &&  docker compose up --build"
