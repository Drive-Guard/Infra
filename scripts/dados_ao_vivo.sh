#!/usr/bin/env bash
#
# Liga, desliga ou mostra o estado dos dados ao vivo (simulador de frota).
# Equivalente POSIX de scripts/dados_ao_vivo.ps1 — ver o cabeçalho de lá.
#
# Uso: ./scripts/dados_ao_vivo.sh [ligar|desligar|status]
#      ./scripts/dados_ao_vivo.sh regenerar AAAA-MM-DD [AAAA-MM-DD]
#      ./scripts/dados_ao_vivo.sh cenario [minutos] | cenario-desligar

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
  cenario|cenario-desligar)
    ACAO_CENARIO=ligar; [ "$ACAO" = "cenario-desligar" ] && ACAO_CENARIO=desligar
    SAIDA="$(mktemp)"
    aws lambda invoke --region "$REGIAO" --function-name "$REGRA" --cli-read-timeout 300 \
      --cli-binary-format raw-in-base64-out --payload "{\"cenario\": {\"acao\": \"$ACAO_CENARIO\", \"minutos\": ${2:-120}}}" "$SAIDA" >/dev/null
    if grep -q errorMessage "$SAIDA"; then cat "$SAIDA" >&2; exit 1; fi
    echo "Cenário da apresentação: $ACAO_CENARIO. $(cat "$SAIDA")"
    rm -f "$SAIDA"
    ;;
  regenerar)
    DE="${2:?informe a data (AAAA-MM-DD)}"
    ATE="${3:-$DE}"
    echo "Apagando $DE a $ATE e gerando de novo (pode levar alguns minutos)..."
    SAIDA="$(mktemp)"
    aws lambda invoke --region "$REGIAO" --function-name "$REGRA" --cli-read-timeout 900 \
      --cli-binary-format raw-in-base64-out --payload "{\"regenerar\": {\"de\": \"$DE\", \"ate\": \"$ATE\"}}" "$SAIDA" >/dev/null
    if grep -q errorMessage "$SAIDA"; then cat "$SAIDA" >&2; exit 1; fi
    echo "Pronto: $(cat "$SAIDA")"
    rm -f "$SAIDA"
    ;;
  status) ;;
  *) echo "Uso: $0 [ligar|desligar|status] | regenerar AAAA-MM-DD [AAAA-MM-DD] | cenario [minutos] | cenario-desligar" >&2; exit 2 ;;
esac

ESTADO="$(aws events describe-rule --region "$REGIAO" --name "$REGRA" --query State --output text)"
if [ "$ESTADO" = "ENABLED" ]; then
  echo "Dados ao vivo: LIGADOS (simulador enviando leituras a cada minuto)"
else
  echo "Dados ao vivo: DESLIGADOS (o dashboard mostra só o histórico)"
fi
