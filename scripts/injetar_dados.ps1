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
    ./scripts/injetar_dados.ps1            # 365 dias (um ano)
    ./scripts/injetar_dados.ps1 -Dias 180  # 6 meses (mais rápido)
#>

[CmdletBinding()]
param(
    [ValidateRange(7, 400)][int]$Dias = 365,
    [string]$Regiao = "us-east-1",
    [string]$Prefixo = "driveguard-dev"
)

$ErrorActionPreference = "Stop"
$tmp = New-Item -ItemType Directory -Force -Path (Join-Path ([System.IO.Path]::GetTempPath()) "driveguard-injecao")
$evento = Join-Path $tmp "evento.json"
$saida = Join-Path $tmp "saida.json"

function Invocar([string]$Funcao, [string]$Json) {
    [System.IO.File]::WriteAllText($evento, $Json)
    # A etl-gold tem concorrência 1 e roda sozinha a cada 5 minutos: se estiver
    # ocupada, espera e tenta de novo.
    # No PowerShell 5.1, stderr de comando nativo com ErrorActionPreference=Stop
    # vira erro fatal: durante as tentativas o erro é só lido no código de saída.
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        for ($tentativa = 1; $tentativa -le 6; $tentativa++) {
            aws lambda invoke --region $Regiao --function-name $Funcao --cli-binary-format raw-in-base64-out `
                --cli-read-timeout 900 --payload "fileb://$evento" $saida *> $null
            if (-not $LASTEXITCODE) { return Get-Content $saida -Raw }
            Write-Host "    $Funcao ocupada ou indisponível; nova tentativa em 20 s ($tentativa/6)" -ForegroundColor Yellow
            Start-Sleep -Seconds 20
        }
    } finally {
        $ErrorActionPreference = $anterior
    }
    throw "Falha ao invocar $Funcao"
}

# Pausa os dados ao vivo durante a injeção: leituras chegando no meio do seed
# disputariam as mesmas tabelas. No fim, volta ao estado anterior.
$regra = "$Prefixo-simulador"
$ErrorActionPreference = "Continue"
$estadoSimulador = aws events describe-rule --region $Regiao --name $regra --query State --output text 2>$null
$ErrorActionPreference = "Stop"
if ($estadoSimulador -eq "ENABLED") {
    aws events disable-rule --region $Regiao --name $regra | Out-Null
    Write-Host "==> Dados ao vivo pausados durante a injeção" -ForegroundColor Cyan
}

try {
    Write-Host "==> Gerando $Dias dias de histórico (pode levar alguns minutos)..." -ForegroundColor Cyan
    # A migração espera uma carga da PRF em andamento terminar (mesma trava).
    $r = Invocar "$Prefixo-db-migrate" "{`"seed`": true, `"resemear`": true, `"dias`": $Dias}"
    if ($r -match '"erros": [1-9]' -or $r -match 'errorMessage') { throw "A migração falhou: $r" }
    Write-Host "    ok: $($r.Substring(0, [Math]::Min(200, $r.Length)))"
} finally {
    if ($estadoSimulador -eq "ENABLED") {
        aws events enable-rule --region $Regiao --name $regra | Out-Null
        Write-Host "==> Dados ao vivo religados" -ForegroundColor Cyan
    }
}

Write-Host "==> Atualizando as views Gold" -ForegroundColor Cyan
Invocar "$Prefixo-etl-gold" "{}" | Out-Null

Write-Host "==> Pedindo uma rodada nova de insights" -ForegroundColor Cyan
try { Invocar "driveguard-backend-dev-insightsContexto" "{}" | Out-Null } catch { Write-Host "    (backend ainda não publicado: os insights saem na próxima hora)" -ForegroundColor Yellow }

Write-Host "==> Pronto. Abra o dashboard: $(terraform -chdir="$(Split-Path -Parent $PSScriptRoot)" output -raw dashboard_url 2>$null)" -ForegroundColor Green
