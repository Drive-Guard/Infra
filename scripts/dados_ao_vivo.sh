#!/usr/bin/env bash
#
# Liga, desliga ou mostra o estado dos dados ao vivo (simulador de frota).
# Equivalente POSIX de scripts/dados_ao_vivo.ps1 — ver o cabeçalho de lá.
#
# Uso: ./scripts/dados_ao_vivo.sh [ligar|desligar|status]

set -euo pipefail

ACAO="${1:-status}"
REGIAO="${REGIAO:-us-east-1}"
PREFIXO="${PREFIXO:-driveguard-dev}"
REGRA="$PREFIXO-simulador"

case "$ACAO" in
  ligar)
    aws events enable-rule --region "$REGIAO" --name "$REGRA"
    # Preenche as lacunas até agora (assíncrono; ver o cabeçalho do .ps1).
    if aws lambda invoke --region "$REGIAO" --function-name "$REGRA" --invocation-type Event \
         --cli-binary-format raw-in-base64-out --payload '{"preencher": true}' /dev/null >/dev/null 2>&1; then
      echo "Preenchendo as lacunas até agora (alguns minutos; a dashboard atualiza sozinha)."
    else
      echo "Aviso: não consegui pedir o preenchimento agora; ele roda sozinho em até 15 min."
    fi
    ;;
  desligar) aws events disable-rule --region "$REGIAO" --name "$REGRA" ;;
  status) ;;
  *) echo "Uso: $0 [ligar|desligar|status]" >&2; exit 2 ;;
esac

ESTADO="$(aws events describe-rule --region "$REGIAO" --name "$REGRA" --query State --output text)"
if [ "$ESTADO" = "ENABLED" ]; then
  echo "Dados ao vivo: LIGADOS (simulador enviando leituras a cada minuto)"
else
  echo "Dados ao vivo: DESLIGADOS (o dashboard mostra só o histórico)"
fi
