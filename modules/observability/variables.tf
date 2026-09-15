variable "name_prefix" {
  description = "Prefixo dos nomes de recurso."
  type        = string
}

variable "region" {
  description = "Região AWS (usada nos widgets do dashboard)."
  type        = string
}

variable "alarm_email" {
  description = "E-mail inscrito no tópico SNS. Vazio = sem inscrição."
  type        = string
  default     = ""
}

variable "ingest_function_name" {
  description = "Nome da Lambda de ingestão."
  type        = string
}

variable "etl_silver_function_name" {
  description = "Nome da Lambda ETL Silver."
  type        = string
}

variable "etl_gold_function_name" {
  description = "Nome da Lambda ETL Gold."
  type        = string
}

variable "dlq_name" {
  description = "Nome da fila DLQ do ETL."
  type        = string
}

variable "db_instance_id" {
  description = "Identificador da instância RDS."
  type        = string
}

variable "db_max_connections_alarm" {
  description = "Conexões simultâneas que disparam o alarme do RDS."
  type        = number
  default     = 60
}

variable "dashboard_instance_id" {
  description = "ID da EC2 do dashboard. Vazio desabilita o alarme de status check."
  type        = string
  default     = ""
}

variable "api_name" {
  description = "Nome da REST API no CloudWatch."
  type        = string
}

variable "api_stage" {
  description = "Nome do stage da API."
  type        = string
}

variable "bronze_bucket" {
  description = "Nome do bucket Bronze."
  type        = string
}

variable "metric_namespace" {
  description = "Namespace das métricas customizadas do ETL."
  type        = string
  default     = "DriveGuard/ETL"
}

variable "gold_views" {
  description = "Nomes das MATERIALIZED VIEWs monitoradas no widget de refresh."
  type        = list(string)
  default = [
    "mv_kpis_diarios",
    "mv_incidentes_por_faixa_horaria",
    "mv_incidentes_por_causa_mes",
    "mv_fadiga_por_tempo_direcao",
    "mv_hotspots_cidades",
    "mv_curva_fadiga_turno",
    "mv_ranking_motoristas",
  ]
}

variable "enable_dashboard" {
  description = "Cria o dashboard do CloudWatch."
  type        = bool
  default     = true
}
