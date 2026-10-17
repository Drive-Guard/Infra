#!/usr/bin/env bash
#
# Deploy do repositório Backend (osls) na API criada pelo Terraform.
# Equivalente POSIX de scripts/deploy_backend.ps1.
#
# Uso: ./scripts/deploy_backend.sh [diretorio-do-backend] [stage]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="${1:-$REPO_ROOT/../Backend}"
STAGE="${2:-dev}"

[ -f "$BACKEND_DIR/serverless.ts" ] || { echo "Repositório Backend não encontrado em $BACKEND_DIR" >&2; exit 1; }
command -v node >/dev/null || { echo "Node.js 22+ não encontrado no PATH" >&2; exit 1; }

cd "$BACKEND_DIR"
[ -d node_modules ] || npm ci --no-audit --no-fund
npm run build
npx osls deploy --stage "$STAGE" || { echo "Deploy falhou; tentando de novo em 20 s..."; sleep 20; npx osls deploy --stage "$STAGE"; }
