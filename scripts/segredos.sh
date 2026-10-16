#!/usr/bin/env bash
#
# Abre ou fecha o cofre de segredos do grupo. Equivalente POSIX de
# scripts/segredos.ps1 (mesmo formato: openssl aes-256-cbc, PBKDF2-SHA256,
# 200 mil iterações) — ver o cabeçalho de lá.
#
# Uso: ./scripts/segredos.sh abrir|fechar   (senha em DG_SEGREDOS_SENHA ou perguntada)

set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLARO="$RAIZ/segredos.auto.tfvars"
COFRE="$RAIZ/segredos/segredos.tfvars.enc"
OPCOES=(-aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -a)

if [ -n "${DG_SEGREDOS_SENHA:-}" ]; then
  SENHA=(-pass env:DG_SEGREDOS_SENHA)
else
  SENHA=()
fi

case "${1:-abrir}" in
  abrir)
    [ -f "$COFRE" ] || { echo "Não achei $COFRE." >&2; exit 1; }
    openssl enc -d "${OPCOES[@]}" "${SENHA[@]}" -in "$COFRE" -out "$CLARO" \
      || { rm -f "$CLARO"; echo "Senha errada (ou cofre corrompido)." >&2; exit 1; }
    echo "Cofre aberto: segredos.auto.tfvars (o Terraform lê sozinho; não vai para o git)."
    ;;
  fechar)
    [ -f "$CLARO" ] || { echo "Não achei $CLARO para cifrar." >&2; exit 1; }
    mkdir -p "$(dirname "$COFRE")"
    openssl enc -salt "${OPCOES[@]}" "${SENHA[@]}" -in "$CLARO" -out "$COFRE"
    echo "Cofre atualizado: segredos/segredos.tfvars.enc. Faça o commit para o grupo receber."
    ;;
  *) echo "Uso: $0 abrir|fechar" >&2; exit 2 ;;
esac
