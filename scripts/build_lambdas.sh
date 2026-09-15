#!/usr/bin/env bash
#
# Empacota as Lambdas do DriveGuard em build/.
# Equivalente POSIX de scripts/build_lambdas.ps1 — ver o cabeçalho de lá para
# a descrição completa das etapas.
#
# Uso: ./scripts/build_lambdas.sh

set -euo pipefail

PYTHON="${PYTHON:-python3}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAMBDAS_DIR="$REPO_ROOT/lambdas"
BUILD_DIR="$REPO_ROOT/build"
COMMON_DIR="$LAMBDAS_DIR/common"
CA_BUNDLE_URL="https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
CA_CACHE="$BUILD_DIR/_cache"
CA_FILE="$CA_CACHE/rds-ca-bundle.pem"

# Funções que abrem conexão com o RDS.
FUNCOES_COM_BANCO="etl_silver etl_gold db_migrate"

echo "==> Empacotando Lambdas do DriveGuard"

command -v "$PYTHON" >/dev/null 2>&1 || {
  echo "ERRO: $PYTHON nao encontrado no PATH." >&2
  exit 1
}

mkdir -p "$CA_CACHE" "$BUILD_DIR/_zips"

if [ ! -s "$CA_FILE" ]; then
  echo "--> Baixando bundle de CAs do RDS"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$CA_BUNDLE_URL" -o "$CA_FILE"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$CA_BUNDLE_URL" -O "$CA_FILE"
  else
    echo "ERRO: nem curl nem wget disponiveis para baixar o CA bundle." >&2
    exit 1
  fi
fi

if [ "$(wc -c < "$CA_FILE")" -lt 1000 ]; then
  echo "ERRO: rds-ca-bundle.pem veio vazio ou truncado. Apague build/_cache e rode de novo." >&2
  exit 1
fi

for dir in "$LAMBDAS_DIR"/*/; do
  nome="$(basename "$dir")"
  [ "$nome" = "common" ] && continue
  [ "$nome" = "__pycache__" ] && continue

  destino="$BUILD_DIR/$nome"
  echo "--> $nome"

  rm -rf "$destino"
  mkdir -p "$destino"
  cp "$dir"*.py "$destino"/

  case " $FUNCOES_COM_BANCO " in
    *" $nome "*)
      cp "$COMMON_DIR"/*.py "$destino"/
      cp "$CA_FILE" "$destino/rds-ca-bundle.pem"
      ;;
  esac

  if [ -f "$dir/requirements.txt" ] && grep -qEv '^\s*(#|$)' "$dir/requirements.txt"; then
    "$PYTHON" -m pip install --quiet --upgrade --target "$destino" -r "$dir/requirements.txt"
  fi

  find "$destino" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
  find "$destino" -type d \( -name "*.dist-info" -o -name "*.egg-info" \) -exec rm -rf {} + 2>/dev/null || true

  echo "    ok - $(du -sk "$destino" | cut -f1) KB em build/$nome"
done

echo "==> Build concluido. Rode 'terraform apply'."
