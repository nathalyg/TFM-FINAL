variable "aws_region" {
  description = "Region AWS"
  type        = string
}

variable "availability_zone" {
  description = "Zona de disponibilidad para la subnet/instancia (opcional). Si se deja vacia, usa la primera zona disponible de la region"
  type        = string
  default     = ""
}

variable "instance_name" {
  description = "Nombre de la instancia EC2"
  type        = string
}

variable "instance_versions" {
  description = "Claves versionadas de despliegue para conservar instancias anteriores. Usa timestamps en formato YYYYMMDD-HHMMSS."
  type        = set(string)

  validation {
    condition     = length(var.instance_versions) > 0 && alltrue([for version in var.instance_versions : can(regex("^\\d{8}-\\d{6}$", version))])
    error_message = "instance_versions debe tener al menos una clave con formato YYYYMMDD-HHMMSS."
  }
}

variable "instance_type" {
  description = "Tipo de instancia EC2"
  type        = string
}

variable "root_volume_size" {
  description = "Tamano del volumen raiz en GB"
  type        = number
}

variable "vpc_cidr" {
  description = "CIDR para la VPC"
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR para la subnet"
  type        = string
}

variable "allowed_http_cidr" {
  description = "CIDR permitido para HTTP"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR permitido para SSH"
  type        = string
}

variable "allowed_app_cidr" {
  description = "CIDR permitido para puertos de aplicaciones (Nginx/ArgoCD)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_port" {
  description = "Puerto SSH expuesto en la instancia"
  type        = number
}

variable "canonical_owner" {
  description = "Owner ID de Canonical para Ubuntu"
  type        = string
}

variable "common_tags" {
  description = "Tags comunes"
  type        = map(string)
}

variable "enable_windows_key_acl_fix" {
  description = "Si es true, aplica icacls al PEM para OpenSSH en Windows"
  type        = bool
  default     = true
}
