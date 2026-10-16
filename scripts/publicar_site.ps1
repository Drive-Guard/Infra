<#
.SYNOPSIS
    Builda o dashboard (repositório Site) e publica no bucket de artefatos.

.DESCRIPTION
    A EC2 do dashboard sincroniza s3://<artefatos>/site/ a cada minuto e serve
    com nginx. O config.json (URL da API e Cognito) é gerado pelo Terraform em
    site-config/ e não é sobrescrito por este script.

.EXAMPLE
    ./scripts/publicar_site.ps1
    ./scripts/publicar_site.ps1 -SiteDir ..\Site\driveguard-codigo -SemBuild
#>

[CmdletBinding()]
param(
    [string]$SiteDir = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "Site\driveguard-codigo"),
    [switch]$SemBuild
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

$bucket = (terraform -chdir="$RepoRoot" output -raw artifacts_bucket).Trim()
if (-not $bucket) { throw "Sem bucket de artefatos: rode terraform apply antes." }

if (-not $SemBuild) {
    Write-Host "==> Buildando o dashboard em $SiteDir" -ForegroundColor Cyan
    Push-Location $SiteDir
    try {
        if (-not (Test-Path node_modules)) { npm ci --no-audit --no-fund; if ($LASTEXITCODE) { throw "npm ci falhou" } }
        npm run build; if ($LASTEXITCODE) { throw "build falhou" }
    } finally { Pop-Location }
}

$dist = Join-Path $SiteDir "dist"
if (-not (Test-Path (Join-Path $dist "index.html"))) { throw "dist/index.html não encontrado em $SiteDir" }

Write-Host "==> Publicando em s3://$bucket/site/" -ForegroundColor Cyan
aws s3 sync $dist "s3://$bucket/site/" --delete --exclude config.json --only-show-errors
if ($LASTEXITCODE) { throw "aws s3 sync falhou" }

$url = (terraform -chdir="$RepoRoot" output -raw dashboard_url).Trim()
Write-Host "==> Publicado. A EC2 pega a versão nova em até 1 minuto: $url" -ForegroundColor Green
