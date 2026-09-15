output "notebook_name" {
  description = "Nome do notebook SageMaker."
  value       = aws_sagemaker_notebook_instance.this.name
}

output "notebook_arn" {
  description = "ARN do notebook SageMaker."
  value       = aws_sagemaker_notebook_instance.this.arn
}

output "notebook_url" {
  description = "URL do Jupyter do notebook."
  value       = aws_sagemaker_notebook_instance.this.url
}
