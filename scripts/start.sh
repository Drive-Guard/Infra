#!/usr/bin/env bash
#
# Traz o ambiente de volta ao ar depois de um ./scripts/stop.sh.
# Equivalente POSIX de scripts/start.ps1.
#
# A ordem importa: o RDS leva alguns minutos para voltar a "available" e a
# EC2 tenta ler o banco no boot. Por isso:
#   1. religa o RDS e ESPERA;  2. recria os VPC Endpoints;
#   3. liga a EC2;             4. reabilita o agendamento.
#
# Se a sessão do Learner Lab expirou desde o stop, atualize
# ~/.aws/credentials antes de rodar.
#
# Uso: ./scripts/start.sh

set -uo pipefail

TIMEOUT_MINUTOS="${TIMEOUT_MINUTOS:-15}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

tf_out() { terraform output -raw "$1" 2>/dev/null || true; }

echo "==> DriveGuard: religando o ambiente"

[ -f terraform.tfstate ] || {
  echo "ERRO: terraform.tfstate nao encontrado. Rode a partir do repositorio Infra." >&2
  exit 1
}

REGIAO="$(tf_out aws_region_efetiva)"
[ -z "$REGIAO" ] && REGIAO="us-east-1"

# --------------------------------------------------------------------- RDS
BANCO="$(tf_out db_instance_id)"
if [ -n "$BANCO" ]; then
  ESTADO="$(aws rds describe-db-instances --db-instance-identifier "$BANCO" \
    --region "$REGIAO" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo desconhecido)"

  if [ "$ESTADO" = "available" ]; then
    echo "--> RDS ja esta disponivel"
  else
    echo "--> Religando o RDS ($BANCO, estado atual: $ESTADO)"
    aws rds start-db-instance --db-instance-identifier "$BANCO" --region "$REGIAO" >/dev/null 2>&1

    echo "    aguardando ficar disponivel (pode levar ~5 min)..."
    LIMITE=$(( $(date +%s) + TIMEOUT_MINUTOS * 60 ))
    while [ "$ESTADO" != "available" ] && [ "$(date +%s)" -lt "$LIMITE" ]; do
      sleep 20
      ESTADO="$(aws rds describe-db-instances --db-instance-identifier "$BANCO" \
        --region "$REGIAO" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo desconhecido)"
      echo "    estado: $ESTADO"
    done

    if [ "$ESTADO" = "available" ]; then
      echo "    ok"
    else
      echo "    ATENCAO: timeout esperando o RDS. Siga manualmente."
    fi
  fi
fi

# ----------------------------------------------------------- VPC Endpoints
echo "--> Recriando VPC Endpoints de interface"
terraform apply -input=false -auto-approve -no-color 2>&1 \
  | grep -E "Apply complete|Error" | sed 's/^/    /'

# --------------------------------------------------------------------- EC2
INSTANCIA="$(tf_out dashboard_instance_id)"
if [ -n "$INSTANCIA" ]; then
  echo "--> Ligando a EC2 do dashboard ($INSTANCIA)"
  aws ec2 start-instances --instance-ids "$INSTANCIA" --region "$REGIAO" >/dev/null 2>&1 \
    && echo "    ok" || echo "    falhou"
fi

# ------------------------------------------------------------- EventBridge
REGRA="$(tf_out gold_schedule_rule_name)"
if [ -n "$REGRA" ]; then
  echo "--> Reabilitando o agendamento do ETL Gold ($REGRA)"
  aws events enable-rule --name "$REGRA" --region "$REGIAO" >/dev/null 2>&1 \
    && echo "    ok" || echo "    falhou"
fi

echo
echo "==> Ambiente no ar."
URL="$(tf_out dashboard_url)"
[ -n "$URL" ] && echo "    Dashboard: $URL  (o nginx leva ~1 min para responder)"
echo "    Resumo:    terraform output resumo"
