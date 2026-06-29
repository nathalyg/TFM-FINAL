output "instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.tfm[local.latest_instance_version].id
}

output "public_ip" {
  description = "IP publica de la instancia"
  value       = aws_instance.tfm[local.latest_instance_version].public_ip
}

output "latest_instance_version" {
  description = "Clave versionada de la instancia mas reciente"
  value       = local.latest_instance_version
}

output "instance_ids" {
  description = "IDs de todas las instancias versionadas"
  value       = { for version, instance in aws_instance.tfm : version => instance.id }
}

output "public_ips" {
  description = "IPs publicas de todas las instancias versionadas"
  value       = { for version, instance in aws_instance.tfm : version => instance.public_ip }
}

output "private_key_path" {
  description = "Ruta local de la llave privada generada"
  value       = local_file.private_key.filename
  sensitive   = true
}

output "ssh_connection_command" {
  description = "Comando SSH para conectarte a la instancia"
  value       = "ssh -i ${local_file.private_key.filename} -p ${var.ssh_port} ubuntu@${aws_instance.tfm[local.latest_instance_version].public_ip}"
}

output "http_url" {
  description = "URL HTTP de la instancia"
  value       = "http://${aws_instance.tfm[local.latest_instance_version].public_ip}"
}

output "nginx_nodeport_url" {
  description = "URL de Nginx via NodePort"
  value       = "http://${aws_instance.tfm[local.latest_instance_version].public_ip}:30080"
}

output "argocd_nodeport_url" {
  description = "URL de ArgoCD via NodePort"
  value       = "https://${aws_instance.tfm[local.latest_instance_version].public_ip}:30443"
}

output "prometheus_url" {
  description = "URL de Prometheus"
  value       = "http://${aws_instance.tfm[local.latest_instance_version].public_ip}:9090"
}
