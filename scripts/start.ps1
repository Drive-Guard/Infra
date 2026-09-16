<#
.SYNOPSIS
    Traz o ambiente de volta ao ar depois de um ./scripts/stop.ps1.

.DESCRIPTION
    Ordem importa: o RDS leva alguns minutos para voltar a "available", e a
    EC2 do dashboard tenta ler o banco no boot. Por isso a sequência é

      1. religar o RDS e ESPERAR ficar disponível;
      2. recriar os VPC Endpoints (terraform apply sem o -var de stop);
      3. ligar a EC2;
      4. reabilitar o agendamento do EventBridge.

    Tempo total típico: 4 a 7 minutos, quase tudo esperando o RDS.

    Se a sessão do Learner Lab expirou desde o stop, atualize as credenciais
    em ~/.aws/credentials antes de rodar.

.EXAMPLE
    ./scripts/start.ps1
#>

[CmdletBinding()]
param(
    [int]$TimeoutMinutos = 15
)

$ErrorActionPreference = "Continue"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot

function Get-TfOutput([string]$nome) {
    $valor = terraform output -raw $nome 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($valor)) { return $null }
    return $valor.Trim()
}

Write-Host "==> DriveGuard: religando o ambiente" -ForegroundColor Cyan

if (-not (Test-Path "terraform.tfstate")) {
    throw "terraform.tfstate nao encontrado. Rode este script a partir do repositorio Infra."
}

$regiao = Get-TfOutput "aws_region_efetiva"
if (-not $regiao) { $regiao = "us-east-1" }

# ------------------------------------------------------------------ 1. RDS
$banco = Get-TfOutput "db_instance_id"
if ($banco) {
    $estado = aws rds describe-db-instances --db-instance-identifier $banco `
        --region $regiao --query 'DBInstances[0].DBInstanceStatus' --output text 2>$null

    if ($estado -eq "available") {
        Write-Host "--> RDS ja esta disponivel" -ForegroundColor Yellow
    } else {
        Write-Host "--> Religando o RDS ($banco, estado atual: $estado)" -ForegroundColor Yellow
        aws rds start-db-instance --db-instance-identifier $banco --region $regiao 2>&1 | Out-Null

        Write-Host "    aguardando ficar disponivel (pode levar ~5 min)..." -ForegroundColor DarkGray
        $limite = (Get-Date).AddMinutes($TimeoutMinutos)
        do {
            Start-Sleep -Seconds 20
            $estado = aws rds describe-db-instances --db-instance-identifier $banco `
                --region $regiao --query 'DBInstances[0].DBInstanceStatus' --output text 2>$null
            Write-Host "    estado: $estado" -ForegroundColor DarkGray
        } while ($estado -ne "available" -and (Get-Date) -lt $limite)

        if ($estado -eq "available") {
            Write-Host "    ok" -ForegroundColor Green
        } else {
            Write-Host "    ATENCAO: timeout esperando o RDS. Siga manualmente." -ForegroundColor Red
        }
    }
}

# -------------------------------------------------------- 2. VPC Endpoints
Write-Host "--> Recriando VPC Endpoints de interface" -ForegroundColor Yellow
terraform apply -input=false -auto-approve -no-color 2>&1 |
    Select-String -Pattern "Apply complete|Error" | ForEach-Object { "    $_" }

# ------------------------------------------------------------------ 3. EC2
$instancia = Get-TfOutput "dashboard_instance_id"
if ($instancia) {
    Write-Host "--> Ligando a EC2 do dashboard ($instancia)" -ForegroundColor Yellow
    aws ec2 start-instances --instance-ids $instancia --region $regiao 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "    ok" } else { Write-Host "    falhou" -ForegroundColor DarkYellow }
}

# ----------------------------------------------------------- 4. EventBridge
$regra = Get-TfOutput "gold_schedule_rule_name"
if ($regra) {
    Write-Host "--> Reabilitando o agendamento do ETL Gold ($regra)" -ForegroundColor Yellow
    aws events enable-rule --name $regra --region $regiao 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "    ok" } else { Write-Host "    falhou" -ForegroundColor DarkYellow }
}

Write-Host ""
Write-Host "==> Ambiente no ar." -ForegroundColor Green
$url = Get-TfOutput "dashboard_url"
if ($url) { Write-Host "    Dashboard: $url  (o nginx leva ~1 min para responder)" }
Write-Host "    Resumo:    terraform output resumo"

Pop-Location
