#!/usr/bin/env bash
#
# Desliga o DriveGuard por completo: destrói tudo e confere que nada ficou.
# Equivalente POSIX de scripts/desligar.ps1 — ver o cabeçalho de lá.
#
# Liga:     terraform apply
# Desliga:  ./scripts/desligar.sh
#
# Os dados NÃO são preservados. Sai com código 1 se sobrar algum recurso.

set -uo pipefail

REGIAO="${REGIAO:-us-east-1}"
PREFIXO="${PREFIXO:-driveguard}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> DriveGuard: destruindo toda a infraestrutura"
echo "    Banco e buckets serao APAGADOS."

# 1. Stack do backend (osls). Ele so pendura rotas e Lambdas na API do
#    Terraform, entao sai primeiro.
for stack in $(aws cloudformation list-stacks --region "$REGIAO" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE CREATE_FAILED UPDATE_FAILED DELETE_FAILED UPDATE_ROLLBACK_FAILED \
    --query "StackSummaries[?starts_with(StackName,'$PREFIXO-backend')].StackName" --output text 2>/dev/null); do
  [ "$stack" = "None" ] && continue
  echo "--> Apagando o stack do backend: $stack"
  aws cloudformation delete-stack --region "$REGIAO" --stack-name "$stack"
  aws cloudformation wait stack-delete-complete --region "$REGIAO" --stack-name "$stack"
done

# 2. Todo o resto.
terraform destroy -input=false -auto-approve -no-color
CODIGO_DESTROY=$?

# A Lambda Gold pode disparar pelo EventBridge durante o destroy e recriar o
# proprio log group depois que o Terraform o apagou. Limpamos o rastro.
for prefixo_log in "/aws/lambda/$PREFIXO" "/aws/apigateway/$PREFIXO"; do
  for lg in $(aws logs describe-log-groups --region "$REGIAO" --log-group-name-prefix "$prefixo_log" \
      --query "logGroups[].logGroupName" --output text 2>/dev/null); do
    [ "$lg" = "None" ] && continue
    aws logs delete-log-group --region "$REGIAO" --log-group-name "$lg" 2>/dev/null
    echo "    log group orfao removido: $lg"
  done
done

echo
echo "==> Conferindo se sobrou algo na conta ($REGIAO)"

SOBRAS=0
checar() {
  local rotulo="$1"; shift
  local saida
  saida="$("$@" 2>/dev/null | grep -v '^\s*$' | grep -v '^None$' || true)"
  if [ -n "$saida" ]; then
    echo "  [SOBROU] $rotulo"
    echo "$saida" | sed 's/^/           /'
    SOBRAS=$((SOBRAS + 1))
  else
    echo "  [ok]     $rotulo"
  fi
}

checar "EC2 (rodando ou parada)" aws ec2 describe-instances --region "$REGIAO" \
  --filters "Name=tag:Project,Values=DriveGuard" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].[InstanceId,State.Name]" --output text
checar "RDS" aws rds describe-db-instances --region "$REGIAO" \
  --query "DBInstances[?starts_with(DBInstanceIdentifier,'$PREFIXO')].[DBInstanceIdentifier,DBInstanceStatus]" --output text
checar "VPC Endpoints de interface" aws ec2 describe-vpc-endpoints --region "$REGIAO" \
  --filters "Name=vpc-endpoint-type,Values=Interface" "Name=tag:Project,Values=DriveGuard" \
  --query "VpcEndpoints[].[VpcEndpointId,State]" --output text
checar "Elastic IPs" aws ec2 describe-addresses --region "$REGIAO" \
  --filters "Name=tag:Project,Values=DriveGuard" --query "Addresses[].PublicIp" --output text
checar "NAT Gateways" aws ec2 describe-nat-gateways --region "$REGIAO" \
  --filter "Name=state,Values=pending,available" "Name=tag:Project,Values=DriveGuard" \
  --query "NatGateways[].NatGatewayId" --output text
checar "Notebooks SageMaker" aws sagemaker list-notebook-instances --region "$REGIAO" --name-contains "$PREFIXO" \
  --query "NotebookInstances[?NotebookInstanceStatus!='Deleting'].NotebookInstanceName" --output text
checar "Buckets S3" aws s3api list-buckets \
  --query "Buckets[?starts_with(Name,'$PREFIXO')].Name" --output text
checar "VPC" aws ec2 describe-vpcs --region "$REGIAO" --filters "Name=tag:Project,Values=DriveGuard" \
  --query "Vpcs[].VpcId" --output text
checar "Lambdas" aws lambda list-functions --region "$REGIAO" \
  --query "Functions[?starts_with(FunctionName,'$PREFIXO')].FunctionName" --output text
checar "APIs HTTP (backend)" aws apigatewayv2 get-apis --region "$REGIAO" \
  --query "Items[?starts_with(Name,'$PREFIXO')].[ApiId,Name]" --output text
checar "Stacks CloudFormation do backend" aws cloudformation list-stacks --region "$REGIAO" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE CREATE_FAILED UPDATE_FAILED DELETE_FAILED DELETE_IN_PROGRESS \
  --query "StackSummaries[?starts_with(StackName,'$PREFIXO')].[StackName,StackStatus]" --output text
checar "User pools do Cognito" aws cognito-idp list-user-pools --region "$REGIAO" --max-results 60 \
  --query "UserPools[?starts_with(Name,'$PREFIXO')].[Id,Name]" --output text
checar "Regras do EventBridge" aws events list-rules --region "$REGIAO" --name-prefix "$PREFIXO" \
  --query "Rules[].Name" --output text

echo
if [ "$CODIGO_DESTROY" -eq 0 ] && [ "$SOBRAS" -eq 0 ]; then
  echo "==> Tudo destruido. Nada do DriveGuard cobrando na conta."
  echo "    Para ligar de novo: terraform apply"
  exit 0
fi

echo "==> ATENCAO: ainda ha recursos na conta."
[ "$CODIGO_DESTROY" -ne 0 ] && echo "    O terraform destroy terminou com erro (codigo $CODIGO_DESTROY)."
echo "    Rode este script de novo. Se persistir, apague pelo console da AWS."
exit 1
