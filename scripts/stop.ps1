<#
.SYNOPSIS
    Derruba tudo que cobra por hora, preservando os dados.

.DESCRIPTION
    Pensado para o fim de cada sessão do AWS Academy Learner Lab.

    O que faz, em ordem:
      1. desabilita a regra do EventBridge (senão a Lambda Gold segue
         acordando de 5 em 5 min e falhando contra um banco parado);
      2. para a EC2 do dashboard;
      3. para a instância RDS;
      4. DELETA os VPC Endpoints de interface.

    O passo 4 é o que justifica este script. O Learner Lab já para EC2 e RDS
    ao encerrar a sessão, mas os VPC Endpoints não têm estado "parado": cada
    ENI cobra ~US$0,01/h enquanto existir, o que dá ~US$15/mês drenando sem
    ninguém usar o ambiente. É o vazamento silencioso desta arquitetura.

    NÃO zera o consumo. Continuam cobrando:
      - EBS da EC2 (20 GB gp3)         ~US$1,60/mês
      - storage do RDS (20 GB gp3)     ~US$2,30/mês
      - Elastic IP                     ~US$3,60/mês (IPv4 publico cobra
                                        mesmo com a instancia parada)
      Total ~US$7,60/mês.

    Para zerar de verdade, use `terraform destroy` (make nuke).

.NOTES
    ATENÇÃO: `stop-db-instance` do RDS dura no máximo 7 dias. Passado esse
    prazo a AWS religa a instância automaticamente. Se for ficar mais de uma
    semana sem usar, destrua em vez de parar.

.EXAMPLE
    ./scripts/stop.ps1
#>

[CmdletBinding()]
param(
    [switch]$ManterEndpoints
)

$ErrorActionPreference = "Continue"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot

function Get-TfOutput([string]$nome) {
    $valor = terraform output -raw $nome 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($valor)) { return $null }
    return $valor.Trim()
}

Write-Host "==> DriveGuard: derrubando recursos que cobram por hora" -ForegroundColor Cyan

if (-not (Test-Path "terraform.tfstate")) {
    throw "terraform.tfstate nao encontrado. Rode este script a partir do repositorio Infra."
}

$regiao = Get-TfOutput "aws_region_efetiva"
if (-not $regiao) { $regiao = "us-east-1" }

# ----------------------------------------------------------- 1. EventBridge
$regra = Get-TfOutput "gold_schedule_rule_name"
if ($regra) {
    Write-Host "--> Desabilitando agendamento do ETL Gold ($regra)" -ForegroundColor Yellow
    aws events disable-rule --name $regra --region $regiao 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "    ok" } else { Write-Host "    falhou (siga)" -ForegroundColor DarkYellow }
}

# ------------------------------------------------------------------ 2. EC2
$instancia = Get-TfOutput "dashboard_instance_id"
if ($instancia) {
    Write-Host "--> Parando a EC2 do dashboard ($instancia)" -ForegroundColor Yellow
    aws ec2 stop-instances --instance-ids $instancia --region $regiao 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "    ok" } else { Write-Host "    falhou (siga)" -ForegroundColor DarkYellow }
}

# ------------------------------------------------------------------ 3. RDS
$banco = Get-TfOutput "db_instance_id"
if ($banco) {
    Write-Host "--> Parando o RDS ($banco)" -ForegroundColor Yellow
    Write-Host "    lembrete: a AWS religa sozinha em 7 dias" -ForegroundColor DarkGray
    aws rds stop-db-instance --db-instance-identifier $banco --region $regiao 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "    ok" } else { Write-Host "    falhou ou ja estava parado" -ForegroundColor DarkYellow }
}

# -------------------------------------------------------- 4. VPC Endpoints
if ($ManterEndpoints) {
    Write-Host "--> VPC Endpoints mantidos por -ManterEndpoints (~US`$15/mes)" -ForegroundColor DarkYellow
} else {
    Write-Host "--> Removendo VPC Endpoints de interface (~US`$15/mes)" -ForegroundColor Yellow
    terraform apply -input=false -auto-approve -no-color `
        -var="enable_vpc_interface_endpoints=false" 2>&1 |
        Select-String -Pattern "Apply complete|Error" | ForEach-Object { "    $_" }
}

Write-Host ""
Write-Host "==> Pronto." -ForegroundColor Green
Write-Host "    Residuo estimado: ~US`$7,60/mes (EBS + storage RDS + Elastic IP)."
Write-Host "    Voltar ao ar:  ./scripts/start.ps1   (ou: make start)"
Write-Host "    Zerar de vez:  terraform destroy     (ou: make nuke)"

Pop-Location
