#!/usr/bin/env bash
#
# Derruba tudo que cobra por hora, preservando os dados.
# Equivalente POSIX de scripts/stop.ps1 — ver o cabeçalho de lá para o
# raciocínio completo de custo.
#
# Resumo: para EC2 e RDS, desabilita o agendamento do ETL Gold e DELETA os
# VPC Endpoints de interface. O Learner Lab já para EC2 e RDS sozinho ao
# encerrar a sessão, mas os endpoints não têm estado "parado" — cada ENI
# cobra ~US$0,01/h enquanto existir (~US$15/mês drenando à toa).
#
# NÃO zera o consumo: EBS, storage do RDS e o Elastic IP continuam cobrando
# (~US$7,60/mês). Para zerar de verdade, use `terraform destroy`.
#
# ATENÇÃO: o stop do RDS dura no máximo 7 dias; depois a AWS religa sozinha.
#
# Uso: ./scripts/stop.sh [--manter-endpoints]

set -uo pipefail

MANTER_ENDPOINTS=0
[ "${1:-}" = "--manter-endpoints" ] && MANTER_ENDPOINTS=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

tf_out() { terraform output -raw "$1" 2>/dev/null || true; }

echo "==> DriveGuard: derrubando recursos que cobram por hora"

[ -f terraform.tfstate ] || {
  echo "ERRO: terraform.tfstate nao encontrado. Rode a partir do repositorio Infra." >&2
  exit 1
}

REGIAO="$(tf_out aws_region_efetiva)"
[ -z "$REGIAO" ] && REGIAO="us-east-1"

# ------------------------------------------------------------- EventBridge
REGRA="$(tf_out gold_schedule_rule_name)"
if [ -n "$REGRA" ]; then
  echo "--> Desabilitando agendamento do ETL Gold ($REGRA)"
  aws events disable-rule --name "$REGRA" --region "$REGIAO" >/dev/null 2>&1 \
    && echo "    ok" || echo "    falhou (siga)"
fi

# --------------------------------------------------------------------- EC2
INSTANCIA="$(tf_out dashboard_instance_id)"
if [ -n "$INSTANCIA" ]; then
  echo "--> Parando a EC2 do dashboard ($INSTANCIA)"
  aws ec2 stop-instances --instance-ids "$INSTANCIA" --region "$REGIAO" >/dev/null 2>&1 \
    && echo "    ok" || echo "    falhou (siga)"
fi

# --------------------------------------------------------------------- RDS
BANCO="$(tf_out db_instance_id)"
if [ -n "$BANCO" ]; then
  echo "--> Parando o RDS ($BANCO)"
  echo "    lembrete: a AWS religa sozinha em 7 dias"
  aws rds stop-db-instance --db-instance-identifier "$BANCO" --region "$REGIAO" >/dev/null 2>&1 \
    && echo "    ok" || echo "    falhou ou ja estava parado"
fi

# ----------------------------------------------------------- VPC Endpoints
if [ "$MANTER_ENDPOINTS" = "1" ]; then
  echo "--> VPC Endpoints mantidos por --manter-endpoints (~US\$15/mes)"
else
  echo "--> Removendo VPC Endpoints de interface (~US\$15/mes)"
  terraform apply -input=false -auto-approve -no-color \
    -var="enable_vpc_interface_endpoints=false" 2>&1 \
    | grep -E "Apply complete|Error" | sed 's/^/    /'
fi

echo
echo "==> Pronto."
echo "    Residuo estimado: ~US\$7,60/mes (EBS + storage RDS + Elastic IP)."
echo "    Voltar ao ar:  ./scripts/start.sh   (ou: make start)"
echo "    Zerar de vez:  terraform destroy    (ou: make nuke)"
