#!/usr/bin/env bash
#
# Apaga TODAS as versões e marcadores de exclusão de um bucket S3.
# Equivalente POSIX de scripts/esvaziar_bucket.ps1 — ver o cabeçalho de lá.
#
# Uso: ./scripts/esvaziar_bucket.sh <bucket> [regiao]

set -uo pipefail

BUCKET="$1"
REGIAO="${2:-us-east-1}"
TOTAL=0

while :; do
  LOTE="$(aws s3api list-object-versions --bucket "$BUCKET" --region "$REGIAO" \
    --max-items 1000 --output json \
    --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][] , Quiet: `true`}' \
    2>/dev/null)"

  QTD="$(printf '%s' "$LOTE" | grep -c '"VersionId"' || true)"
  [ "${QTD:-0}" -eq 0 ] && break

  aws s3api delete-objects --bucket "$BUCKET" --region "$REGIAO" --delete "$LOTE" >/dev/null
  TOTAL=$((TOTAL + QTD))
done

echo "$BUCKET : $TOTAL versoes/marcadores removidos"
