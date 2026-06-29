# TFM GitOps Setup

Repositorio de experimentacion reproducible para evaluar resiliencia GitOps con Kubernetes y ArgoCD sobre una instancia AWS EC2 creada con Terraform.

Stack del proyecto:
- Terraform para infraestructura AWS
- Kind para el cluster Kubernetes de nodo unico
- ArgoCD para GitOps
- Git y GitHub para versionado y reproducibilidad
- Bash para orquestar fases y escenarios
- Python para analisis, validacion Prometheus y graficas
- Nginx como aplicacion de referencia stateless

## 1. Proposito

Este proyecto documenta un experimento academico sobre resiliencia operacional en GitOps. Incluye la infraestructura, los manifiestos, los escenarios de falla y los scripts de analisis para que cualquier persona pueda reproducir la evaluacion desde su propia cuenta y su propia maquina o AWS.

## 2. Alcance y limitaciones

Este repositorio corresponde a un entorno de laboratorio.

- No es un entorno productivo.
- Kind corre como cluster de un solo nodo sobre una EC2 t3.medium.
- Los tiempos medidos dependen de la red, la carga del host, el rendimiento de la cuenta AWS y la version exacta de los componentes.
- El escenario C requiere permisos de escritura en el repositorio remoto porque hace commit y push de una rama temporal.

## 3. Requisitos previos

Antes de ejecutar el flujo, el usuario debe tener:

- Ubuntu 24.04 LTS en una EC2 propia o una maquina equivalente con sudo
- Acceso a una cuenta AWS propia
- Git instalado y configurado
- Python 3 disponible
- Conectividad a GitHub
- Espacio local suficiente para imagenes, cluster Kind y resultados del experimento

Recursos minimos recomendados para la maquina de laboratorio:

- 2 vCPU o mas
- 4 GB de RAM o mas
- 20 GB de disco para la EC2 y espacio adicional para cache, imagenes y resultados

## 4. Versiones del stack

Versiones validadas en este proyecto:

| Componente | Version |
|---|---|
| Docker | 29.4.1 |
| Kind | v0.23.0 |
| Kubernetes en Kind | v1.30.2 |
| ArgoCD | v2.11.3 |
| Helm | v3.14.2 |
| ArgoCD CLI | v2.11.3 |
| Python | 3.10.12 |
| Terraform | >= 1.0 |

Librerias Python usadas por los scripts de analisis y graficas:

- pandas
- numpy
- requests
- matplotlib
- scipy

Nota: el proyecto no fija un lock file de Python; si quieres una reproducibilidad total del analisis, genera tu propio `pip freeze` en el entorno que uses.

## 5. Estructura del repositorio

```text
tfm-gitops-setup/
├── README.md
├── QUICKSTART.sh
├── argocd/
│   └── application.yaml
├── manifests/
│   └── nginx-demo.yaml
├── scripts/
│   ├── cleanup.sh
│   ├── phase-0-dependencies.sh
│   ├── phase-1-cluster.sh
│   ├── phase-2-argocd.sh
│   ├── phase-3-prometheus.sh
│   ├── register-private-repo.sh
│   └── ...
├── tfm-terraform/
│   ├── main.tf
│   ├── outputs.tf
│   ├── variables.tf
│   ├── terraform.tfvars
│   └── README.md
└── experiments/
    └── pruebas_reales/
        ├── scenario-a.sh
        ├── scenario-b.sh
        ├── scenario-c.sh
        ├── run-scenario-c-local.sh
        ├── stress-generator.sh
        ├── genera_graficas_tfm_final.py
        ├── results/
        └── prometheus/
            ├── prometheus-config.yaml
            ├── prometheus_validation.py
            ├── prometheus_validation_e2e.py
            ├── analyze_prometheus_validations.py
            └── README.md
```

## 6. Configuracion de credenciales

### 6.1 AWS para Terraform

Cada usuario debe usar sus propias credenciales de AWS. No publiques claves ni perfiles personales.

El flujo recomendado es editar `tfm-terraform/terraform.tfvars` con valores propios de la cuenta AWS del usuario que ejecuta Terraform.

Ejemplo de valores esperados:

```hcl
aws_region        = "us-east-1"
availability_zone = "us-east-1a"
instance_name     = "tfm"
instance_versions = ["YYYYMMDD-HHMMSS"]
instance_type     = "t3.medium"
root_volume_size  = 20
```

Archivos privados que no deben subirse:

- `.env`
- `terraform.tfstate`
- `terraform.tfstate.backup`
- cualquier `*.tfvars` real si contiene datos sensibles
- kubeconfig o secretos exportados localmente
- llaves privadas (`*.pem`, `*.key`, `*.crt`, `*.p12`)

### 6.2 GitHub para el escenario C

El escenario C hace `git commit` y `git push` sobre una rama temporal. Cada usuario debe crear su propio token y su propio acceso al repositorio.

Pasos:

```bash
cp .env.example .env
```

Contenido esperado de `.env`:

```bash
GITHUB_USER="TU_USUARIO"
GITHUB_TOKEN="TU_TOKEN_FINE_GRAINED"
REPO_URL="https://github.com/TU_USUARIO/TU_REPO.git"
```

Regla importante:

- No subas `.env` real.
- No subas tokens, PAT, passwords ni deploy keys.
- No subas `kubeconfig` ni carpetas `.kube/`.

## 7. Levantar la infraestructura con Terraform

La infraestructura se crea en la cuenta AWS de quien ejecuta el comando.

### 7.1 Inicializar

```bash
cd tfm-terraform
terraform init
```

### 7.2 Revisar el plan

```bash
terraform plan
```

### 7.3 Aplicar

```bash
terraform apply -auto-approve
```

### 7.4 Consultar salidas

```bash
terraform output
terraform output ssh_connection_command
```

Nota:

- Terraform crea una EC2 en la cuenta y region del usuario.
- El archivo `terraform.tfvars` es local y debe ajustarse a la cuenta de cada uno.
### Configuración de Permisos de la Clave Privada

Antes de conectarse por SSH, es obligatorio restringir los permisos del archivo de la clave privada (`tfm-private-key.pem`). De lo contrario, el cliente de SSH rechazará la conexión por seguridad.

#### En Windows (PowerShell):
```powershell
icacls "tfm-private-key.pem" /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(R)" /remove:g "BUILTIN\Users" "NT AUTHORITY\Authenticated Users"

- El flujo completo puede ejecutarse con `QUICKSTART.sh` o fase por fase con cada script Bash individual.

## 8. Crear el cluster Kind

El cluster se crea sobre la EC2 y usa un nodo unico.

```bash
cd ..
bash scripts/phase-1-cluster.sh
```

Verificacion basica:

```bash
kubectl get nodes
kubectl get pods,svc -n tfm-app
kubectl cluster-info
```

Puertos expuestos por el script:

- `30080` para Nginx
- `30443` para ArgoCD

## 9. Instalar ArgoCD y configurar la Application

El despliegue de ArgoCD se hace con el script de fase 2, que aplica Helm y configura la Application.

```bash
bash scripts/phase-2-argocd.sh
```

La Application debe conservar estos principios:

- `selfHeal: true`
- `prune: true`
- `targetRevision: main`
- ruta `path: manifests`

Si vas a reproducir escenario C en un fork propio, el `repoURL` de `argocd/application.yaml` debe apuntar a tu fork.

## 10. Desplegar la aplicacion

La aplicacion de referencia es Nginx y se despliega desde `manifests/nginx-demo.yaml`.

```bash
kubectl apply -f manifests/nginx-demo.yaml
kubectl get pods,svc -n tfm-app
```

En la ruta normal del laboratorio, la fase 2 instala ArgoCD, crea la Application y deja el sistema listo para que el repositorio sea el origen de verdad.

## 11. Instruccion critica de reproduccion por terceros

### Para escenarios A y B

Los usuarios pueden clonar el repositorio y ejecutar los scripts en su propia cuenta.

```bash
git clone https://github.com/TU_USUARIO/TU_REPO.git
cd tfm-gitops-setup
```

### Para escenario C

El escenario C debe ejecutarse desde un fork propio.

Requisitos:

- Hacer fork del repositorio
- Cambiar `repoURL` en `argocd/application.yaml` para que apunte al fork propio
- Usar un PAT propio con permisos de escritura sobre ese fork

Si dejas `repoURL` apuntando al repositorio original de otra persona, el `git push` del escenario C fallara porque el usuario no tendra permiso de escritura en ese remoto.

## 12. Ejecutar cada escenario

### Escenario A

```bash
cd experiments/pruebas_reales
bash scenario-a.sh
```

Variables opcionales:

- `NORMAL_RUNS`
- `STRESS_RUNS`

Ejemplo corto:

```bash
NORMAL_RUNS=3 STRESS_RUNS=2 bash scenario-a.sh
```

### Escenario B

```bash
cd experiments/pruebas_reales
bash scenario-b.sh
```

Variables opcionales:

- `NORMAL_RUNS`
- `STRESS_RUNS`
- `CONTROL_RUNS`

Ejemplo corto:

```bash
NORMAL_RUNS=3 STRESS_RUNS=2 CONTROL_RUNS=3 bash scenario-b.sh
```

### Escenario C

```bash
cd experiments/pruebas_reales
bash scenario-c.sh
```

Variables opcionales:

- `NORMAL_RUNS`
- `STRESS_RUNS`

Ejemplo corto:

```bash
NORMAL_RUNS=3 STRESS_RUNS=3 bash scenario-c.sh
```

### Escenario C aislado en worktree temporal

```bash
cd experiments/pruebas_reales
NORMAL_RUNS=3 STRESS_RUNS=3 bash run-scenario-c-local.sh
```

La reproduccion se hace con los scripts individuales de A, B, C y con el wrapper local de C si quieres aislar la rama temporal.

## 13. Obtencion de los CSV

Los CSV se generan dentro de la instancia en:

```text
experiments/pruebas_reales/results/
```

Los resultados obtenidos para el TFM se adjuntan en esa carpeta. Los CSV presentes en el repositorio son:

- `scenario-a-20260522-005207.csv`
- `scenario-b-argocd-20260522-014828.csv`
- `scenario-b-control-20260522-014828.csv`
- `scenario-c-20260627-232855.csv`
- `prometheus_validation_t1.csv`
- `prometheus_validation_t3.csv`

Esquemas principales:

- Escenario A: `scenario-a-<timestamp>.csv`
- Escenario B con ArgoCD: `scenario-b-argocd-<timestamp>.csv`
- Escenario B de control: `scenario-b-control-<timestamp>.csv`
- Escenario C: `scenario-c-<timestamp>.csv`
- Prometheus validation: `prometheus_validation.csv`
- Prometheus validation e2e: `prometheus_validation_e2e.csv`

Campos tipicos:

- Escenario A: `run_id`, `condition`, `mode`, `spec_recovery_s`, `pods_ready_s`, `http_ok`
- Escenario B: `run_id`, `group`, `mode`, `spec_recreated_s`, `rto_s`, `http_ok`
- Escenario C: `run_id`, `mode`, `t1_degraded_s`, `t3_healthy_synced_s`, `tiempo_deteccion_s`, `tiempo_recuperacion_post_revert_s`, `http_ok`

## 14. Generar graficas y tablas

### 14.1 Graficas y tablas finales del TFM

```bash
python .\experiments\pruebas_reales\genera_graficas_tfm_final.py --results-dir .\experiments\pruebas_reales\results
```

### 14.2 Validacion de tiempos contra Prometheus

Comparacion script vs Prometheus:

```bash
python3 experiments/pruebas_reales/prometheus/prometheus_validation.py \
  --input-csv experiments/pruebas_reales/results/TU_CSV.csv \
  --prom-url http://localhost:9090 \
  --output-csv experiments/pruebas_reales/results/prometheus_validation.csv
```

Modo end-to-end:

```bash
python3 experiments/pruebas_reales/prometheus/prometheus_validation_e2e.py \
  --input-csv experiments/pruebas_reales/results/TU_CSV.csv \
  --prom-url http://localhost:9090 \
  --output-csv experiments/pruebas_reales/results/prometheus_validation_e2e.csv
```

Resumen consolidado de pares escenario + validacion Prometheus:

```bash
python3 experiments/pruebas_reales/prometheus/analyze_prometheus_validations.py \
  --pair experiments/pruebas_reales/results/scenario-a-TIMESTAMP.csv experiments/pruebas_reales/results/prometheus-validation-a-TIMESTAMP.csv \
  --pair experiments/pruebas_reales/results/scenario-b-argocd-TIMESTAMP.csv experiments/pruebas_reales/results/prometheus-validation-b-argocd-TIMESTAMP.csv \
  --pair experiments/pruebas_reales/results/scenario-c-TIMESTAMP.csv experiments/pruebas_reales/results/prometheus-validation-c-TIMESTAMP.csv \
  --output-csv experiments/pruebas_reales/results/prometheus-analysis-summary.csv
```

## 15. Figuras y tabla adjuntas del TFM

Las figuras generadas para el TFM estan adjuntas en:

```text
experiments/pruebas_reales/figures/
```

Archivos incluidos:

- `figA1_histograma_A1.png`
- `figA2_histograma_A2.png`
- `figA3_boxplot_A.png`
- `figA4_scatter_A1_vs_A2.png`
- `figB1_rto_normal.png`
- `figB2_bstress_spec_recreated.png`
- `figB3_comparativa_argocd_control.png`
- `figB4_intervalos_confianza.png`
- `figC1_histograma_deteccion.png`
- `figC2_histograma_recuperacion.png`
- `figC3_boxplot_recuperacion_normal_vs_stress.png`

La tabla resumida del TFM esta en:

```text
experiments/pruebas_reales/figures/tablas_tfm.md
```

## 16. Commit o release de referencia

Se adjunta punto de referencia inmutable para la version publica del experimento.

Ejemplo:

```text
COMMIT_BASE_FIJO = <HASH_DE_LA_VERSION_PUBLICA>
```

Recomendacion:

- etiqueta ese punto con un tag de Git
- no cambies el README base despues de publicar la version citada
- documenta ese mismo hash en la memoria del TFM

## 17. Limitaciones de reproducibilidad conocidas

- Los tiempos varian segun la carga de la instancia AWS y la latencia de red.
- Kind es un cluster de un solo nodo, asi que no representa un entorno de produccion.
- El escenario C necesita permisos de escritura en el fork propio y un token personal valido.
- Prometheus depende de que los targets esten realmente scrapeando en la misma ventana temporal.
- Los CSV historicos de resultados no deben usarse como datos fijos; la analitica debe regenerarse desde los CSV que se produzcan en cada corrida.
- Si el usuario ejecuta los scripts con otra version de Python o librerias diferentes, pueden cambiar los detalles de salida de las tablas o los graficos.

## 18. Limpieza

Para destruir lo creado en la cuenta AWS y limpiar el laboratorio, revisa los scripts de limpieza del repositorio y elimina tambien el cluster Kind cuando ya no lo necesites.

```bash
bash scripts/cleanup.sh
```

---

Este README resume la instalacion, la reproduccion y la validacion del experimento. Cada usuario debe ejecutar el flujo con su propia cuenta AWS, su propio fork si aplica al escenario C y sus propias credenciales locales.