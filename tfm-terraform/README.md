# tfm-terraform

Modulo Terraform del proyecto. El flujo completo de instalacion y reproducibilidad esta documentado en el README raiz del repositorio.

Este directorio contiene la infraestructura AWS que crea la instancia EC2 del laboratorio y su red asociada.

## Que hace

- Crea una instancia EC2 para el laboratorio
- Asigna red, seguridad y salida publica
- Genera un PEM local para conectar por SSH
- Expone outputs utiles para continuar con Kind y ArgoCD
- Configura Ubuntu 22.04 (Jammy) y cambia SSH al puerto definido en `ssh_port`

## Requisitos

- Terraform >= 1.0
- Credenciales AWS de la cuenta que ejecutara el despliegue

## Uso basico

Desde este directorio:

```bash
terraform init
terraform plan
terraform apply -auto-approve
```

## Configuracion

La configuracion del despliegue se define en `terraform.tfvars`.

Valores tipicos:

```hcl
aws_region        = "us-east-1"
availability_zone = "us-east-1a"
instance_name     = "tfm"
instance_versions = ["YYYYMMDD-HHMMSS"]
instance_type     = "t3.medium"
root_volume_size  = 20
ssh_port          = 2222
```

Tambien suelen definirse: `vpc_cidr`, `subnet_cidr`, `allowed_http_cidr`, `allowed_ssh_cidr`, `allowed_app_cidr`, `canonical_owner` y `common_tags`.

Cada usuario debe adaptar ese archivo a su propia cuenta AWS. Si necesitas reproducibilidad publica, usa `terraform.tfvars` local y conserva una version ejemplo si la añades aparte.

## Instancias versionadas

El modulo usa `instance_versions` como historial de despliegues. Para crear una instancia nueva sin borrar la anterior, agrega un timestamp mayor y vuelve a ejecutar `terraform apply`.

Comportamiento esperado:

- `latest_instance_version` apunta a la entrada mas reciente
- `instance_ids` y `public_ips` conservan el historial de instancias creadas

## Outputs utiles

```bash
terraform output
terraform output instance_id
terraform output public_ip
terraform output ssh_connection_command
terraform output latest_instance_version
terraform output instance_ids
terraform output public_ips
terraform output nginx_nodeport_url
terraform output argocd_nodeport_url
terraform output prometheus_url
```

## Acceso SSH

Si cambias el puerto SSH en `terraform.tfvars`, actualiza tambien el comando de conexion que te devuelve el output `ssh_connection_command`.

Nota: el modulo devuelve el comando SSH listo para usar con la llave generada en `private_key_path`.

## Nota sobre la llave privada en Windows

El modulo aplica un ajuste de permisos sobre el PEM generado para evitar el error de Windows:

`WARNING: UNPROTECTED PRIVATE KEY FILE!`

Si trabajas en Linux o macOS, puedes desactivar ese ajuste en la configuracion correspondiente del modulo.

## Relacion con el README raiz

Usa el README raiz para seguir el orden completo de ejecucion:

1. Terraform
2. Kind
3. ArgoCD
4. Escenarios A, B y C
5. Prometheus y graficas
