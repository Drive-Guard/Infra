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

terraform destroy -input=false -auto-approve -no-color
CODIGO_DESTROY=$?

# A Lambda Gold pode disparar pelo EventBridge durante o destroy e recriar o
# proprio log group depois que o Terraform o apagou. Limpamos o rastro.
for lg in $(aws logs describe-log-groups --region "$REGIAO" --log-group-name-prefix "/aws/lambda/$PREFIXO"     --query "logGroups[].logGroupName" --output text 2>/dev/null); do
  [ "$lg" = "None" ] && continue
  aws logs delete-log-group --region "$REGIAO" --log-group-name "$lg" 2>/dev/null
  echo "    log group orfao removido: $lg"
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
