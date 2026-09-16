output "bronze_bucket_id" {
  description = "Nome do bucket Bronze."
  value       = awscc_s3_bucket.bronze.bucket_name
}

output "bronze_bucket_arn" {
  description = "ARN do bucket Bronze."
  value       = awscc_s3_bucket.bronze.arn
}

output "artifacts_bucket_id" {
  description = "Nome do bucket de artefatos."
  value       = awscc_s3_bucket.artifacts.bucket_name
}

output "artifacts_bucket_arn" {
  description = "ARN do bucket de artefatos."
  value       = awscc_s3_bucket.artifacts.arn
}

output "sql_object_keys" {
  description = "Chaves S3 dos scripts SQL publicados."
  value       = [for o in aws_s3_object.sql : o.key]
}
