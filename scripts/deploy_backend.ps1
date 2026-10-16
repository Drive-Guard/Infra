<#
.SYNOPSIS
    Faz o deploy do repositório Backend (osls) na API criada pelo Terraform.

.DESCRIPTION
    Chamado pelo próprio `terraform apply` (null_resource em app.tf), mas pode
    rodar à mão. O serverless.ts lê tudo do SSM (/driveguard-<stage>/backend/),
    então basta o Terraform já ter rodado.

.EXAMPLE
    ./scripts/deploy_backend.ps1 -BackendDir ..\Backend
#>

[CmdletBinding()]
param(
    [string]$BackendDir = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "Backend"),
    [string]$Stage = "dev"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path (Join-Path $BackendDir "serverless.ts"))) {
    throw "Repositório Backend não encontrado em $BackendDir (clone Drive-Guard/Backend ao lado do Infra)."
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "Node.js 22+ não encontrado no PATH." }

Push-Location $BackendDir
try {
    if (-not (Test-Path node_modules)) {
        Write-Host "==> npm ci (Backend)" -ForegroundColor Cyan
        npm ci --no-audit --no-fund
        if ($LASTEXITCODE) { throw "npm ci falhou" }
    }
    Write-Host "==> Build e deploy do Backend (stage $Stage)" -ForegroundColor Cyan
    npm run build
    if ($LASTEXITCODE) { throw "build do Backend falhou" }
    npx osls deploy --stage $Stage
    if ($LASTEXITCODE) {
        # Erros transitórios do CloudFormation acontecem; uma segunda tentativa resolve a maioria.
        Write-Host "Deploy falhou; tentando de novo em 20 s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 20
        npx osls deploy --stage $Stage
        if ($LASTEXITCODE) { throw "osls deploy falhou" }
    }
} finally {
    Pop-Location
}
