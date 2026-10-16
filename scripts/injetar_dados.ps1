<#
.SYNOPSIS
    Gera de novo a massa de dados de demonstração (meses de histórico fake).

.DESCRIPTION
    Apaga a frota de demonstração e roda a simulação do seed outra vez com N
    dias de operação: 16 motoristas, 16 veículos com câmera, rotas, viagens,
    turnos, leituras, alertas, ações e acidentes da frota, coerentes entre si
    (ver "Dados de demonstração" no README), ancorados na data de hoje, com os
    turnos em andamento agora. A base da PRF (acidentes reais) fica como está.

    O banco é privado (sem acesso pela internet), então o script invoca a
    Lambda db_migrate, que roda dentro da VPC. Depois atualiza as views Gold e
    pede uma rodada nova de insights.

    Use no dia da apresentação, para os turnos "ao vivo" estarem atuais (o
    simulador mantém os dados chegando a cada minuto depois disso).

.EXAMPLE
    ./scripts/injetar_dados.ps1            # 120 dias
    ./scripts/injetar_dados.ps1 -Dias 180  # 6 meses
#>

[CmdletBinding()]
param(
    [ValidateRange(7, 400)][int]$Dias = 120,
    [string]$Regiao = "us-east-1",
    [string]$Prefixo = "driveguard-dev"
)

$ErrorActionPreference = "Stop"
$tmp = New-Item -ItemType Directory -Force -Path (Join-Path ([System.IO.Path]::GetTempPath()) "driveguard-injecao")
$evento = Join-Path $tmp "evento.json"
$saida = Join-Path $tmp "saida.json"

function Invocar([string]$Funcao, [string]$Json) {
    [System.IO.File]::WriteAllText($evento, $Json)
    aws lambda invoke --region $Regiao --function-name $Funcao --cli-binary-format raw-in-base64-out `
        --cli-read-timeout 900 --payload "fileb://$evento" $saida | Out-Null
    if ($LASTEXITCODE) { throw "Falha ao invocar $Funcao" }
    Get-Content $saida -Raw
}

Write-Host "==> Gerando $Dias dias de histórico (pode levar alguns minutos)..." -ForegroundColor Cyan
$r = Invocar "$Prefixo-db-migrate" "{`"seed`": true, `"resemear`": true, `"dias`": $Dias}"
if ($r -match '"erros": [1-9]' -or $r -match 'errorMessage') { throw "A migração falhou: $r" }
Write-Host "    ok: $($r.Substring(0, [Math]::Min(200, $r.Length)))"

Write-Host "==> Atualizando as views Gold" -ForegroundColor Cyan
Invocar "$Prefixo-etl-gold" "{}" | Out-Null

Write-Host "==> Pedindo uma rodada nova de insights" -ForegroundColor Cyan
try { Invocar "driveguard-backend-dev-insightsContexto" "{}" | Out-Null } catch { Write-Host "    (backend ainda não publicado: os insights saem na próxima hora)" -ForegroundColor Yellow }

Write-Host "==> Pronto. Abra o dashboard: $(terraform -chdir="$(Split-Path -Parent $PSScriptRoot)" output -raw dashboard_url 2>$null)" -ForegroundColor Green
