#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

echo "→ Subindo todos os serviços (build incluso)…"
docker compose up -d --build

echo ""
echo "→ Aguardando os módulos responderem…"

aguardar_http() {
  local nome="$1" url="$2" tentativas="${3:-30}"
  for i in $(seq 1 "$tentativas"); do
    if curl -sf "$url" >/dev/null 2>&1; then
      echo "  ✓ $nome"
      return 0
    fi
    sleep 2
  done
  echo "  ✗ $nome não respondeu em $url (depois de $((tentativas * 2))s)"
  return 1
}

FALHOU=0
aguardar_http "m1-ingestao      (8001)" http://localhost:8001/denuncias || FALHOU=1
aguardar_http "m2-classificacao (8002)" http://localhost:8002/health    || FALHOU=1
aguardar_http "m3-priorizacao   (8003)" http://localhost:8003/health    || FALHOU=1
aguardar_http "m4-recorrencia   (8004)" http://localhost:8004/health    || FALHOU=1
aguardar_http "m5-roteamento    (8005)" http://localhost:8005/health    || FALHOU=1
aguardar_http "m6-notificacoes  (8006)" http://localhost:8006/health    || FALHOU=1
aguardar_http "m7-analytics     (8007)" http://localhost:8007/health    || FALHOU=1
aguardar_http "m9-secretarias   (8009)" http://localhost:8009/health    || FALHOU=1
aguardar_http "m8-frontend      (8080)" http://localhost:8080           || FALHOU=1

echo ""
echo "→ Checagem extra: o M7 realmente conectou na fila (RabbitMQ)?"
M7_SAUDE=$(curl -s http://localhost:8007/health 2>/dev/null || echo "")
echo "  $M7_SAUDE"
if echo "$M7_SAUDE" | grep -q '"broker_conectado":false'; then
  echo "  ⚠ M7 sem conexão com a fila — reiniciando só ele…"
  docker compose restart m7-analytics
  sleep 5
  curl -s http://localhost:8007/health
fi

echo ""
if [ "$FALHOU" -eq 0 ]; then
  echo "✅ Tudo no ar e saudável."
else
  echo "⚠ Algum módulo não respondeu — veja: docker compose logs <serviço> --tail=80"
fi

URL="http://localhost:8080/portal"
echo ""
echo "→ Tela de home (portal público): $URL"
( command -v xdg-open >/dev/null 2>&1 && xdg-open "$URL" >/dev/null 2>&1 ) \
  || ( command -v open >/dev/null 2>&1 && open "$URL" >/dev/null 2>&1 ) \
  || echo "  Abra manualmente no navegador."
