<#
.SYNOPSIS
    Desliga o DriveGuard por completo: destrói tudo e confere que nada ficou.

.DESCRIPTION
    O liga/desliga deste projeto é o próprio Terraform:

        ligar     terraform apply      (~15 min, banco nasce com o seed)
        desligar  este script          (~15 min)

    Não existe "pausar". Parar EC2 e RDS não zera o custo: o RDS religa
    sozinho após 7 dias parado, o Start Lab religa a EC2, e VPC Endpoint,
    Elastic IP e discos cobram mesmo com tudo parado. Uma tentativa anterior
    de "stop" deixou o ambiente ligado e consumiu US$30 do lab.

    Os dados NÃO são preservados. Banco e buckets são apagados.

    Antes do destroy, apaga o stack CloudFormation do backend (rotas e
    Lambdas que o repositório Backend publica na API criada aqui). Sem isso o
    Terraform apagaria a API e deixaria as Lambdas do backend órfãs.

    Depois do destroy, o script consulta a conta e lista qualquer recurso do
    projeto que ainda exista. Sai com código 1 se encontrar algo.

.EXAMPLE
    ./scripts/desligar.ps1
#>

[CmdletBinding()]
param(
    [string]$Regiao = "us-east-1",
    [string]$Prefixo = "driveguard"
)

$ErrorActionPreference = "Continue"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot

Write-Host "==> DriveGuard: destruindo toda a infraestrutura" -ForegroundColor Cyan
Write-Host "    Banco e buckets serao APAGADOS." -ForegroundColor DarkYellow

# 1. Stack do backend (osls). Ele so pendura rotas e Lambdas na API do
#    Terraform, entao sai primeiro.
$stacks = aws cloudformation list-stacks --region $Regiao `
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE CREATE_FAILED UPDATE_FAILED DELETE_FAILED UPDATE_ROLLBACK_FAILED `
    --query "StackSummaries[?starts_with(StackName,'$Prefixo-backend')].StackName" --output text 2>$null
foreach ($stack in ("$stacks" -split "\s+" | Where-Object { $_ -and $_ -ne "None" })) {
    Write-Host "--> Apagando o stack do backend: $stack"
    aws cloudformation delete-stack --region $Regiao --stack-name $stack
    aws cloudformation wait stack-delete-complete --region $Regiao --stack-name $stack
}

# 2. Todo o resto.
terraform destroy -input=false -auto-approve -no-color
$codigoDestroy = $LASTEXITCODE

# A Lambda Gold pode disparar pelo EventBridge durante o destroy e recriar o
# proprio log group depois que o Terraform o apagou. Custo desprezivel, mas
# limpamos para nao deixar rastro.
foreach ($prefixoLog in @("/aws/lambda/$Prefixo", "/aws/apigateway/$Prefixo")) {
    $orfaos = aws logs describe-log-groups --region $Regiao --log-group-name-prefix $prefixoLog `
        --query "logGroups[].logGroupName" --output text 2>$null
    foreach ($lg in ("$orfaos" -split "\s+" | Where-Object { $_ -and $_ -ne "None" })) {
        aws logs delete-log-group --region $Regiao --log-group-name $lg 2>$null
        Write-Host "    log group orfao removido: $lg"
    }
}

Write-Host ""
Write-Host "==> Conferindo se sobrou algo na conta ($Regiao)" -ForegroundColor Cyan

$sobras = @()

function Checar([string]$rotulo, [scriptblock]$consulta) {
    $resultado = & $consulta 2>$null
    $linhas = @($resultado | Where-Object { $_ -and $_.Trim() -and $_.Trim() -ne "None" })
    if ($linhas.Count -gt 0) {
        Write-Host ("  [SOBROU] {0}" -f $rotulo) -ForegroundColor Red
        $linhas | ForEach-Object { Write-Host "           $_" }
        $script:sobras += $rotulo
    } else {
        Write-Host ("  [ok]     {0}" -f $rotulo) -ForegroundColor Green
    }
}

Checar "EC2 (rodando ou parada)" {
    aws ec2 describe-instances --region $Regiao `
        --filters "Name=tag:Project,Values=DriveGuard" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
        --query "Reservations[].Instances[].[InstanceId,State.Name]" --output text
}
Checar "RDS" {
    aws rds describe-db-instances --region $Regiao `
        --query "DBInstances[?starts_with(DBInstanceIdentifier,'$Prefixo')].[DBInstanceIdentifier,DBInstanceStatus]" --output text
}
Checar "VPC Endpoints de interface" {
    aws ec2 describe-vpc-endpoints --region $Regiao `
        --filters "Name=vpc-endpoint-type,Values=Interface" "Name=tag:Project,Values=DriveGuard" `
        --query "VpcEndpoints[].[VpcEndpointId,State]" --output text
}
Checar "Elastic IPs" {
    aws ec2 describe-addresses --region $Regiao `
        --filters "Name=tag:Project,Values=DriveGuard" --query "Addresses[].PublicIp" --output text
}
Checar "NAT Gateways" {
    aws ec2 describe-nat-gateways --region $Regiao `
        --filter "Name=state,Values=pending,available" "Name=tag:Project,Values=DriveGuard" `
        --query "NatGateways[].NatGatewayId" --output text
}
Checar "Notebooks SageMaker" {
    aws sagemaker list-notebook-instances --region $Regiao --name-contains $Prefixo `
        --query "NotebookInstances[?NotebookInstanceStatus!='Deleting'].NotebookInstanceName" --output text
}
# O bucket do state (driveguard-tfstate-<conta>) fica de propósito: guarda o
# state vazio para o próximo subir e custa centavos.
Checar "Buckets S3 (fora o do state)" {
    aws s3api list-buckets --query "Buckets[?starts_with(Name,'$Prefixo') && !starts_with(Name,'$Prefixo-tfstate')].Name" --output text
}
Checar "VPC" {
    aws ec2 describe-vpcs --region $Regiao --filters "Name=tag:Project,Values=DriveGuard" `
        --query "Vpcs[].VpcId" --output text
}
Checar "Lambdas" {
    aws lambda list-functions --region $Regiao `
        --query "Functions[?starts_with(FunctionName,'$Prefixo')].FunctionName" --output text
}
Checar "APIs HTTP (backend)" {
    aws apigatewayv2 get-apis --region $Regiao `
        --query "Items[?starts_with(Name,'$Prefixo')].[ApiId,Name]" --output text
}
Checar "Stacks CloudFormation do backend" {
    aws cloudformation list-stacks --region $Regiao `
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE CREATE_FAILED UPDATE_FAILED DELETE_FAILED DELETE_IN_PROGRESS `
        --query "StackSummaries[?starts_with(StackName,'$Prefixo')].[StackName,StackStatus]" --output text
}
Checar "User pools do Cognito" {
    aws cognito-idp list-user-pools --region $Regiao --max-results 60 `
        --query "UserPools[?starts_with(Name,'$Prefixo')].[Id,Name]" --output text
}
Checar "Regras do EventBridge" {
    aws events list-rules --region $Regiao --name-prefix $Prefixo --query "Rules[].Name" --output text
}

Write-Host ""
if ($codigoDestroy -eq 0 -and $sobras.Count -eq 0) {
    Write-Host "==> Tudo destruido. Nada do DriveGuard cobrando na conta." -ForegroundColor Green
    Write-Host "    Para ligar de novo: subir.cmd (ou terraform apply)"
    Pop-Location
    exit 0
}

Write-Host "==> ATENCAO: ainda ha recursos na conta." -ForegroundColor Red
if ($codigoDestroy -ne 0) { Write-Host "    O terraform destroy terminou com erro (codigo $codigoDestroy)." }
Write-Host "    Rode este script de novo. Se persistir, apague pelo console da AWS."
Pop-Location
exit 1
