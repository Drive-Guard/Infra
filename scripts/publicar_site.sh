#!/usr/bin/env bash
#
# Builda o dashboard (repositório Site) e publica no bucket de artefatos.
# Equivalente POSIX de scripts/publicar_site.ps1 — ver o cabeçalho de lá.
#
# Uso: ./scripts/publicar_site.sh [diretorio-do-site] [--sem-build]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_DIR="${1:-$REPO_ROOT/../Site/driveguard-codigo}"
SEM_BUILD="${2:-}"

BUCKET="$(terraform -chdir="$REPO_ROOT" output -raw artifacts_bucket)"
[ -n "$BUCKET" ] || { echo "Sem bucket de artefatos: rode terraform apply antes." >&2; exit 1; }

if [ "$SEM_BUILD" != "--sem-build" ]; then
  echo "==> Buildando o dashboard em $SITE_DIR"
  (cd "$SITE_DIR" && { [ -d node_modules ] || npm ci --no-audit --no-fund; } && npm run build)
fi

[ -f "$SITE_DIR/dist/index.html" ] || { echo "dist/index.html não encontrado em $SITE_DIR" >&2; exit 1; }

echo "==> Publicando em s3://$BUCKET/site/"
aws s3 sync "$SITE_DIR/dist" "s3://$BUCKET/site/" --delete --exclude config.json --only-show-errors

echo "==> Publicado. A EC2 pega a versão nova em até 1 minuto: $(terraform -chdir="$REPO_ROOT" output -raw dashboard_url)"
