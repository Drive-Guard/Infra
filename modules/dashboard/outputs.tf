output "instance_id" {
  description = "ID da instancia EC2 do dashboard."
  value       = aws_instance.dashboard.id
}

output "instance_arn" {
  description = "ARN da instancia EC2."
  value       = aws_instance.dashboard.arn
}

output "public_ip" {
  description = "Elastic IP do dashboard."
  value       = aws_eip.dashboard.public_ip
}

output "public_dns" {
  description = "DNS publico da instancia."
  value       = aws_instance.dashboard.public_dns
}

output "url" {
  description = "URL de acesso ao dashboard."
  value       = "http://${aws_eip.dashboard.public_ip}"
}

output "ami_id" {
  description = "AMI Amazon Linux 2023 utilizada."
  value       = data.aws_ami.al2023.id
}
