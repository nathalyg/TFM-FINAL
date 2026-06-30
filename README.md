# TFM GitOps Setup

Repositorio de experimentación reproducible para evaluar la resiliencia GitOps con Kubernetes y ArgoCD sobre una instancia AWS EC2 creada con Terraform.

**Stack del proyecto:**

- Terraform para la infraestructura AWS
- Kind para el clúster Kubernetes de nodo único
- ArgoCD para GitOps
- Git y GitHub para versionado y reproducibilidad
- Bash para orquestar fases y escenarios
- Python para análisis, validación con Prometheus y gráficas
- Nginx como aplicación de referencia *stateless*

---

## 1. Propósito

Este proyecto documenta un experimento académico sobre resiliencia operacional en GitOps. Incluye la infraestructura, los manifiestos, los escenarios de fallo y los scripts de análisis para que cualquier persona pueda reproducir la evaluación desde su propia cuenta AWS y su propia máquina.

---

## 2. Alcance y limitaciones

- Kind se ejecuta como clúster de un solo nodo sobre una EC2 `t3.medium`.
- No representa clústeres multinodo, multi-región ni cargas *stateful*.
- Los tiempos medidos dependen de la red, la carga del host, el rendimiento de la cuenta AWS y la versión exacta de cada componente.
- El Escenario C requiere permisos de escritura en el repositorio remoto, porque hace *commit* y *push* de una rama temporal.

> Los resultados son válidos para las condiciones específicas de este laboratorio y no deben extrapolarse a entornos de producción ni presentarse como representativos de cualquier organización.

---

## 3. Requisitos previos

Antes de ejecutar el flujo, el usuario debe tener:

- Ubuntu 22.04 LTS en una EC2 propia (AMI Jammy, según Terraform) o una máquina equivalente con `sudo`
- Acceso a una cuenta AWS propia
- Git instalado y configurado
- Python 3 disponible
- Conectividad a GitHub
- Espacio en disco suficiente para imágenes, clúster Kind y resultados

**Configuración real desplegada por Terraform (valores actuales de `tfm-terraform/terraform.tfvars`):**

- Tipo de instancia: `t3.medium` (2 vCPU, 4 GiB RAM)
- Volumen raíz EBS: `20 GB`
- Región: `us-east-1`
- Zona de disponibilidad: `us-east-1a`
- VPC/Subred: `10.20.0.0/16` y `10.20.1.0/24`

---

## 4. Versiones del stack

Versiones validadas en este proyecto:

| Componente | Versión |
|---|---|
| Docker | 29.4.1 |
| Kind | v0.23.0 |
| Kubernetes (en Kind) | v1.30.2 |
| ArgoCD | v2.11.3 |
| Helm | v3.14.2 |
| ArgoCD CLI | v2.11.3 |
| Python | 3.10.12 |
| Terraform | >= 1.0 |
| Imagen de la aplicación | `nginx:1.25-alpine` |

> **Imagen del contenedor:** se usa una etiqueta fija (`nginx:1.25-alpine`), nunca `latest`, para garantizar reproducibilidad. Verifica que coincida con la etiqueta declarada en `manifests/nginx-demo.yaml`.

**Librerías de Python** usadas por los scripts de análisis y gráficas:

- pandas
- numpy
- requests
- matplotlib
- scipy

> **Nota** Para reproducibilidad del análisis, crea un entorno virtual e instala las librerías listadas en esta sección (`pandas`, `numpy`, `requests`, `matplotlib`, `scipy`):
>
> ```bash
> python3 -m venv .venv
> source .venv/bin/activate
> pip install pandas numpy requests matplotlib scipy
> ```
>
> Después de instalar, guarda tu `pip freeze` para congelar versiones del entorno que uses. Versiones distintas de Python o de las librerías pueden cambiar detalles de las tablas o las gráficas.

---

## 5. Estructura del repositorio

```text
TFM-FINAL/
├── README.md
├── .gitignore
├── .env.example
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
│   ├── moved.tf
│   ├── outputs.tf
│   ├── variables.tf
│   ├── terraform.tfvars
│   ├── .terraform.lock.hcl
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
        ├── figures/
        │   ├── *.png
        │   └── tablas_tfm.md
        └── prometheus/
            ├── prometheus-config.yaml
            ├── prometheus_validation.py
            ├── prometheus_validation_e2e.py
            ├── analyze_prometheus_validations.py
            └── README.md
```

> Los archivos `.env` real y `terraform.tfstate` **no** forman parte del repositorio 

---

## 6. Configuración de credenciales

Cada usuario que reproduzca el experimento usa **sus propias credenciales**, en dos lugares distintos:

- **AWS** → para que Terraform levante la infraestructura en *su* cuenta.
- **GitHub (PAT)** → solo para el Escenario C, que hace *push* a *su* fork.

Estos dos no se mezclan y ninguno da acceso a las cuentas del autor original.

### 6.1 AWS para Terraform

Edita `tfm-terraform/terraform.tfvars` con los valores de tu propia cuenta:

```bash
cd tfm-terraform
vi terraform.tfvars
```

Valores esperados:

```hcl
aws_region        = "us-east-1"
availability_zone = "us-east-1a"
instance_name     = "tfm"
instance_versions = ["YYYYMMDD-HHMMSS"]
instance_type     = "t3.medium"
root_volume_size  = 20
```

> Las credenciales de AWS **no** se escriben en estos archivos. Terraform las toma del entorno del usuario (`~/.aws/credentials`, un perfil o las variables `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`). Así, quien reproduce crea la infraestructura en su propia cuenta sin tocar la del autor.

### 6.2 GitHub para el Escenario C

El Escenario C hace `git commit` y `git push` sobre una rama temporal, por lo que **siempre** requiere un token de escritura propio sobre el fork del usuario.

Copia la plantilla en la raíz del repositorio:

```bash
cp .env.example .env
```

Contenido esperado de `.env`:

```bash
GITHUB_USER="TU_USUARIO"
GITHUB_TOKEN="TU_TOKEN_FINE_GRAINED"
REPO_URL="https://github.com/TU_USUARIO/TU_FORK.git"
```

El `.env` se utiliza en:

- `experiments/pruebas_reales/scenario-c.sh` — para autenticar el `git push`.
- `experiments/pruebas_reales/run-scenario-c-local.sh` — para copiar credenciales al *worktree* temporal.
- `scripts/register-private-repo.sh` — **solo** si mantienes tu fork en privado (ver nota de abajo).

> **Repositorio público vs. privado:**
> Este repositorio es público. Para **leer** un repo público, ArgoCD **no necesita ningún token**: basta con que el `repoURL` del `application.yaml` apunte a la URL correcta. El script `register-private-repo.sh` y un token de **lectura** solo son necesarios si decides mantener tu fork en **privado**. El token de **escritura** del `.env` (para el Escenario C) es obligatorio en ambos casos.

**Reglas de seguridad (obligatorias):**

- No subas `.env` real, tokens, PAT, passwords ni *deploy keys*.
- No subas `terraform.tfvars` real, `terraform.tfstate` ni `terraform.tfstate.backup`.
- No subas `kubeconfig` ni carpetas `.kube/`.
- No subas llaves privadas (`*.pem`, `*.key`, `*.crt`, `*.p12`).
- Verifica que estos patrones estén en el `.gitignore` **antes** del primer `git add`.

---

## 7. Levantar la infraestructura con Terraform

La infraestructura se crea en la cuenta AWS de quien ejecuta el comando.

Clona el repositorio en el entorno desde el que ejecutarás Terraform:

```bash
git clone https://github.com/nathalyg/TFM-FINAL.git
cd TFM-FINAL/tfm-terraform
```

### 7.1 Inicializar

```bash
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

> Terraform crea una EC2 en la cuenta y la región del usuario. El archivo `terraform.tfvars` es local y debe ajustarse a cada cuenta.

### 7.5 Permisos de la clave privada SSH

Antes de conectarte por SSH, restringe los permisos del archivo de la clave privada (`tfm-private-key.pem`); de lo contrario, el cliente SSH rechazará la conexión.

**En Windows (PowerShell):**

```powershell
icacls "tfm-private-key.pem" /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(R)" /remove:g "BUILTIN\Users" "NT AUTHORITY\Authenticated Users"
```

**En Linux / macOS:**

```bash
chmod 600 tfm-private-key.pem
```

> Para interactuar con la infraestructura desde fuera de la EC2, usa la IP pública que devuelve `terraform output`.

---

## 8. Crear el clúster Kind

> Las fases de Kubernetes (§8 a §15) se ejecutan **dentro de la EC2**. Conéctate por SSH y clona también el repositorio dentro de la instancia.

El clúster se crea sobre la EC2 con un nodo único:

```bash
cd ~/TFM-FINAL
bash scripts/phase-1-cluster.sh
```

Verificación básica:

```bash
kubectl get nodes
kubectl get pods,svc -n tfm-app
kubectl cluster-info
```

Puertos expuestos por el script:

- `30080` → Nginx
- `30443` → ArgoCD

> **Atajo:** puedes ejecutar todo el flujo de fases con `sudo bash QUICKSTART.sh`, o fase por fase con cada script individual.

---

## 9. Instalar ArgoCD y configurar la Application

El despliegue de ArgoCD se realiza con el script de la fase 2, que instala vía Helm y crea la `Application`:

```bash
bash scripts/phase-2-argocd.sh
```

La `Application` debe conservar estos parámetros:

- `selfHeal: true`
- `prune: true`
- `targetRevision: main`
- `path: manifests`

El script de fase 2 garantiza de forma idempotente que `syncPolicy.automated` quede activo (`selfHeal: true` y `prune: true`) para `nginx-demo`.

> **Para reproducir el Escenario C en un fork propio**, el `repoURL` de `argocd/application.yaml` debe apuntar a **tu** fork (ver §11).

Una vez ejecutada la fase, la salida muestra las credenciales de acceso a ArgoCD. Comandos útiles:

```bash
kubectl get applications -n argocd
kubectl describe app nginx-demo -n argocd
argocd app sync nginx-demo
kubectl logs -f -n argocd -l app.kubernetes.io/name=argocd-server
kubectl port-forward -n argocd svc/argocd-server 8443:443
```

---

## 10. Desplegar la aplicación

La aplicación de referencia es Nginx, desplegada desde `manifests/nginx-demo.yaml`:

```bash
kubectl apply -f manifests/nginx-demo.yaml
kubectl get pods,svc -n tfm-app
```

En la ruta normal del laboratorio, la fase 2 instala ArgoCD, crea la `Application` y deja el repositorio como origen de verdad.

### Fase 3 — Prometheus

```bash
bash scripts/phase-3-prometheus.sh
```

Para poder comparar tiempos con Prometheus, mantenlo accesible durante los experimentos y la validación. En otra terminal:

```bash
kubectl -n argocd port-forward svc/prometheus 9090:9090
```

> **Nota:** si al usar `QUICKSTART.sh` la fase 3 falla, vuelve a ejecutar **solo** la fase 3. Esto ocurre cuando el stack aún no estaba completamente listo en el primer intento.

---

## 11. Instrucción crítica de reproducción por terceros

La forma de ejecutar depende del escenario.

### Escenarios A y B — basta con clonar

Solo leen el repositorio, así que pueden ejecutarse clonando este repo directamente:

```bash
git clone https://github.com/nathalyg/TFM-FINAL.git
cd TFM-FINAL
```

### Escenario C — requiere fork propio

El Escenario C escribe en el repositorio (hace *push* de una rama temporal), por lo que **no** funciona en modo solo lectura contra el repo original. Pasos:

1. Haz **fork** de este repositorio a tu cuenta de GitHub.
2. Clona **tu fork** en la máquina de trabajo.
3. Cambia el `repoURL` de `argocd/application.yaml` para que apunte a **tu fork**, no al repositorio original.
4. Configura tu `.env` con un **PAT propio** con permisos de escritura sobre tu fork (ver §6.2).

> Si dejas el `repoURL` apuntando al repositorio original, el `git push` del Escenario C **fallará**, porque no tienes permiso de escritura sobre ese remoto. Cambiar el `repoURL` a tu fork es lo que hace que el escenario sea reproducible.

---

## 12. Ejecutar cada escenario

### Escenario A

```bash
cd experiments/pruebas_reales
bash scenario-a.sh
```

Variables opcionales: `NORMAL_RUNS`, `STRESS_RUNS`

```bash
NORMAL_RUNS=3 STRESS_RUNS=2 bash scenario-a.sh
```

### Escenario B

```bash
cd experiments/pruebas_reales
bash scenario-b.sh
```

Variables opcionales: `NORMAL_RUNS`, `STRESS_RUNS`, `CONTROL_RUNS`

```bash
NORMAL_RUNS=3 STRESS_RUNS=2 CONTROL_RUNS=3 bash scenario-b.sh
```

### Escenario C

```bash
cd experiments/pruebas_reales
NORMAL_RUNS=3 STRESS_RUNS=3 bash run-scenario-c-local.sh
```

Variables opcionales: `NORMAL_RUNS`, `STRESS_RUNS`

> `scenario-c.sh` ya no debe ejecutarse directo. El wrapper `run-scenario-c-local.sh` exporta la orquestación, crea worktree/branch temporal y realiza la limpieza de cierre.


### Escenario C aislado en *worktree* temporal

```bash
cd experiments/pruebas_reales
NORMAL_RUNS=3 STRESS_RUNS=3 bash run-scenario-c-local.sh
```

> El *wrapper* `run-scenario-c-local.sh` crea una rama temporal y un `git worktree` aislado para que la inyección del fallo no interfiera con tu rama `main` de trabajo. Al terminar, restaura `targetRevision` a `main` y elimina la rama y el *worktree* temporales.

---

## 13. Obtención de los CSV

Los CSV se generan dentro de la instancia en:

```text
experiments/pruebas_reales/results/
```

Los resultados obtenidos para el TFM se adjuntan en esa carpeta. Los CSV presentes en el repositorio son:

- `scenario-a-20260522-005207.csv`
- `scenario-b-argocd-20260522-014828.csv`
- `scenario-b-control-20260522-014828.csv`
- `scenario-c-20260627-232855.csv`
- `prometheus_validation-scenario-a-20260522-005207.csv`
- `prometheus-analysis-summary-a-20260522-005207.csv`
- `prometheus_validation_t1.csv`
- `prometheus_validation_t3.csv`

Esquemas principales:

- Escenario A: `scenario-a-<timestamp>.csv`
- Escenario B con ArgoCD: `scenario-b-argocd-<timestamp>.csv`
- Escenario B de control: `scenario-b-control-<timestamp>.csv`
- Escenario C: `scenario-c-<timestamp>.csv`
- Prometheus validation: `prometheus_validation.csv`
- Prometheus validation e2e: `prometheus_validation_e2e.csv`

Campos típicos:

- Escenario A: `run_id`, `condition`, `mode`, `injection_epoch`, `t_inicio_iso`, `spec_recovery_s`, `pods_ready_s`, `t_fin_iso`, `spec_ok`, `pods_ok`
- Escenario B: `run_id`, `group`, `mode`, `deletion_epoch`, `t_inicio_iso`, `spec_recreated_s`, `rto_s`, `t_fin_iso`, `spec_ok`, `rto_ok`
- Escenario C: `run_id`, `mode`, `t1_degraded_s`, `t3_healthy_synced_s`, `tiempo_deteccion_s`, `tiempo_recuperacion_post_revert_s`, `http_ok`

---

## 14. Generar gráficas y tablas

> Los comandos se muestran para Linux (ejecución dentro de la EC2). En Windows/PowerShell, sustituye `python3` por `python` y las rutas `/` por `\`.

### 14.1 Gráficas y tablas finales del TFM

```bash
python3 experiments/pruebas_reales/genera_graficas_tfm_final.py \
  --results-dir experiments/pruebas_reales/results
```

### 14.2 Validación de tiempos contra Prometheus

Comparación script vs. Prometheus:

> **Importante:** antes de ejecutar estos comandos, verifica que Prometheus sigue corriendo y accesible en `http://localhost:9090` (por ejemplo, con el `port-forward` en otra terminal).

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

Resumen consolidado de pares escenario + validación Prometheus:

```bash
python3 experiments/pruebas_reales/prometheus/analyze_prometheus_validations.py \
  --pair experiments/pruebas_reales/results/scenario-a-TIMESTAMP.csv experiments/pruebas_reales/results/prometheus-validation-a-TIMESTAMP.csv \
  --pair experiments/pruebas_reales/results/scenario-b-argocd-TIMESTAMP.csv experiments/pruebas_reales/results/prometheus-validation-b-argocd-TIMESTAMP.csv \
  --pair experiments/pruebas_reales/results/scenario-c-TIMESTAMP.csv experiments/pruebas_reales/results/prometheus-validation-c-TIMESTAMP.csv \
  --output-csv experiments/pruebas_reales/results/prometheus-analysis-summary.csv
```

---

## 15. Figuras y tabla adjuntas del TFM

Las figuras generadas para el TFM están adjuntas en:

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

La tabla resumida del TFM está en:

```text
experiments/pruebas_reales/figures/tablas_tfm.md
```

---

## 17. Limitaciones de reproducibilidad conocidas

- Los tiempos varían según la carga de la instancia AWS y la latencia de red.
- Kind es un clúster de un solo nodo; no representa un entorno de producción.
- El Escenario C necesita permisos de escritura sobre un fork propio y un token personal válido.
- Prometheus depende de que los *targets* estén realmente *scrapeando* en la misma ventana temporal.
- Los CSV históricos no deben usarse como datos fijos: la analítica debe regenerarse desde los CSV producidos en cada corrida.
- Ejecutar los scripts con otra versión de Python o de las librerías puede cambiar detalles de las tablas o las gráficas.

---

## 18. Limpieza

Para eliminar el clúster Kind y destruir la infraestructura creada en AWS:

```bash
bash scripts/cleanup.sh
```

Y, desde `tfm-terraform/`, para destruir la EC2:

```bash
cd tfm-terraform
terraform destroy -auto-approve
```

---

Este README resume la instalación, la reproducción y la validación del experimento. Cada usuario debe ejecutar el flujo con su propia cuenta AWS, su propio fork (si aplica al Escenario C) y sus propias credenciales locales.