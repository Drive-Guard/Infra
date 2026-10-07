# =============================================================================
# DriveGuard — atalhos de operação da infraestrutura
#
# No Windows, use `make` do Git Bash / WSL, ou chame os comandos equivalentes
# descritos no README.
# =============================================================================

SHELL := /bin/bash
TF     ?= terraform
PYTHON ?= python3

.DEFAULT_GOAL := help

.PHONY: help build init fmt validate lint plan apply apply-auto destroy \
        up down custos output creds migrate seed refresh-gold logs-silver \
        logs-gold test-api db-shell clean

help: ## Lista os alvos disponíveis
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# -----------------------------------------------------------------------------
# Ciclo de vida
# -----------------------------------------------------------------------------

build: ## Empacota as Lambdas em build/
	PYTHON=$(PYTHON) ./scripts/build_lambdas.sh

init: ## Inicializa o Terraform
	$(TF) init

fmt: ## Formata os arquivos .tf
	$(TF) fmt -recursive

validate: ## Valida a configuração
	$(TF) validate

lint: fmt validate ## fmt + validate

plan: build ## Mostra o plano de execução
	$(TF) plan -out=tfplan

apply: build ## Aplica a infraestrutura (pede confirmação)
	$(TF) apply

apply-auto: build ## Aplica sem confirmação
	$(TF) apply -auto-approve

destroy: ## Destrói tudo (pede confirmação)
	$(TF) destroy

# -----------------------------------------------------------------------------
# Liga / desliga
#
# Nao existe "pausar". Parar EC2 e RDS nao zera o custo: o RDS religa sozinho
# apos 7 dias, o Start Lab religa a EC2, e VPC Endpoint, Elastic IP e discos
# cobram mesmo parados. O liga/desliga e o proprio Terraform.
# -----------------------------------------------------------------------------

up: build ## LIGA tudo (terraform apply, ~15 min, banco nasce com o seed)
	$(TF) apply -auto-approve

down: ## DESLIGA tudo e confere que nada ficou cobrando (APAGA os dados)
	./scripts/desligar.sh

custos: ## Lista o que do DriveGuard ainda existe na conta
	@echo "== EC2 =="
	@aws ec2 describe-instances --filters "Name=tag:Project,Values=DriveGuard" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name]" --output table
	@echo "== RDS =="
	@aws rds describe-db-instances --query "DBInstances[].[DBInstanceIdentifier,DBInstanceClass,DBInstanceStatus]" --output table
	@echo "== VPC Endpoints de interface =="
	@aws ec2 describe-vpc-endpoints --filters "Name=vpc-endpoint-type,Values=Interface" --query "VpcEndpoints[].[VpcEndpointId,ServiceName,State]" --output table
	@echo "== Elastic IPs =="
	@aws ec2 describe-addresses --query "Addresses[].[PublicIp,InstanceId]" --output table
	@echo "== NAT Gateways =="
	@aws ec2 describe-nat-gateways --filter "Name=state,Values=available" --query "NatGateways[].[NatGatewayId,State]" --output table
	@echo "== SageMaker =="
	@aws sagemaker list-notebook-instances --query "NotebookInstances[].[NotebookInstanceName,NotebookInstanceStatus]" --output table
	@echo "== Buckets =="
	@aws s3api list-buckets --query "Buckets[?starts_with(Name,'driveguard')].Name" --output table

# -----------------------------------------------------------------------------
# Operação
# -----------------------------------------------------------------------------

output: ## Mostra o resumo da infraestrutura
	@$(TF) output resumo

creds: ## Mostra os segredos (API Key e senha do banco)
	@echo "API Key : $$($(TF) output -raw api_key_value)"
	@echo "DB user : $$($(TF) output -raw db_username)"
	@echo "DB senha: $$($(TF) output -raw db_password)"
	@echo "DB URI  : $$($(TF) output -raw db_connection_uri)"

migrate: ## Reaplica o DDL (sem seed)
	aws lambda invoke \
		--function-name $$($(TF) output -json lambdas | jq -r .db_migrate) \
		--payload '{"seed":false}' --cli-binary-format raw-in-base64-out \
		/dev/stdout

seed: ## Reaplica o DDL e o seed de demonstração
	aws lambda invoke \
		--function-name $$($(TF) output -json lambdas | jq -r .db_migrate) \
		--payload '{"seed":true}' --cli-binary-format raw-in-base64-out \
		/dev/stdout

refresh-gold: ## Força o refresh das MATERIALIZED VIEWs agora
	aws lambda invoke \
		--function-name $$($(TF) output -json lambdas | jq -r .etl_gold) \
		--payload '{}' --cli-binary-format raw-in-base64-out \
		/dev/stdout

logs-silver: ## Acompanha os logs do ETL Silver
	aws logs tail /aws/lambda/$$($(TF) output -json lambdas | jq -r .etl_silver) --follow

logs-gold: ## Acompanha os logs do ETL Gold
	aws logs tail /aws/lambda/$$($(TF) output -json lambdas | jq -r .etl_gold) --follow

test-api: ## Envia um evento de teste para a API de ingestão
	@curl -sS -X POST "$$($(TF) output -raw api_eventos_endpoint)" \
		-H "x-api-key: $$($(TF) output -raw api_key_value)" \
		-H "Content-Type: application/json" \
		-d @examples/evento.json | jq .

db-shell: ## Abre o psql no banco (precisa de db_publicly_accessible = true)
	psql "$$($(TF) output -raw db_connection_uri)"

clean: ## Remove os artefatos de build
	rm -rf build tfplan
