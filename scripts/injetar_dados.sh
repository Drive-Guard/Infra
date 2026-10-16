#!/usr/bin/env bash
#
# Gera de novo a massa de dados de demonstração (meses de histórico fake).
# Equivalente POSIX de scripts/injetar_dados.ps1 — ver o cabeçalho de lá.
#
# Uso: ./scripts/injetar_dados.sh [dias]   (padrão 120)

set -euo pipefail

DIAS="${1:-120}"
REGIAO="${REGIAO:-us-east-1}"
PREFIXO="${PREFIXO:-driveguard-dev}"
TMP="$(mktemp -d)"

invocar() {
  printf '%s' "$2" > "$TMP/evento.json"
  # A etl-gold tem concorrência 1 e roda sozinha a cada 5 minutos: se estiver
  # ocupada, espera e tenta de novo.
  for _ in 1 2 3 4 5 6; do
    if aws lambda invoke --region "$REGIAO" --function-name "$1" --cli-binary-format raw-in-base64-out \
      --cli-read-timeout 900 --payload "fileb://$TMP/evento.json" "$TMP/saida.json" >/dev/null 2>&1; then
      cat "$TMP/saida.json"; return 0
    fi
    sleep 20
  done
  echo "Falha ao invocar $1" >&2; return 1
}

echo "==> Gerando $DIAS dias de histórico (pode levar alguns minutos)..."
r="$(invocar "$PREFIXO-db-migrate" "{\"seed\": true, \"resemear\": true, \"dias\": $DIAS}")"
if echo "$r" | grep -Eq '"erros": [1-9]|errorMessage'; then echo "A migração falhou: $r" >&2; exit 1; fi
echo "    ok: ${r:0:200}"

echo "==> Atualizando as views Gold"
invocar "$PREFIXO-etl-gold" "{}" >/dev/null

echo "==> Pedindo uma rodada nova de insights"
invocar "driveguard-backend-dev-insightsContexto" "{}" >/dev/null || echo "    (backend ainda não publicado: os insights saem na próxima hora)"

echo "==> Pronto. Dashboard: $(terraform -chdir="$(dirname "$0")/.." output -raw dashboard_url 2>/dev/null || true)"
