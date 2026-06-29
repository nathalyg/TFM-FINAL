# Diseño Experimental — TFM GitOps / ArgoCD (`pruebas_reales`)

Este directorio contiene los scripts de ejecucion de los escenarios del TFM, la generacion de resultados y la produccion de graficas finales.

La informacion cuantitativa del experimento no se documenta aqui. Los valores obtenidos, CSV y graficas se generan y se adjuntan en `results/` y en la salida de los scripts de analisis.

## Estructura

```text
pruebas_reales/
├── scenario-a.sh
├── scenario-b.sh
├── scenario-c.sh
├── run-scenario-c-local.sh
├── stress-generator.sh
├── genera_graficas_tfm_final.py
├── prometheus/
│   ├── prometheus-config.yaml
│   ├── prometheus_validation.py
│   ├── prometheus_validation_e2e.py
│   └── analyze_prometheus_validations.py
└── results/
```

## Prerrequisitos

Antes de ejecutar los escenarios, verifica que ya existen y funcionan:

```bash
kubectl cluster-info
kubectl get app nginx-demo -n argocd
kubectl get pods,svc -n tfm-app
python3 --version
```

Si vas a regenerar figuras PNG, instala tambien `matplotlib` en tu entorno Python.

## Como ejecutar

Desde este directorio:

```bash
cd experiments/pruebas_reales
```

Escenarios individuales:

```bash
bash scenario-a.sh
bash scenario-b.sh
bash scenario-c.sh
```

Escenario C aislado en worktree temporal:

```bash
bash run-scenario-c-local.sh
```

Para reducir la duracion de una corrida preliminar, puedes pasar variables de entorno antes de lanzar cada script. Los valores por defecto ya vienen definidos en cada script.

## Diseño experimental

### Escenario A

Evalua la correccion de configuration drift en la aplicacion de referencia. El script mide la respuesta de ArgoCD, el regreso al estado deseado y la validacion HTTP del servicio.

### Escenario B

Evalua la recuperacion tras la eliminacion del Deployment. Incluye el caso con ArgoCD activo y el grupo de control sin recuperacion automatica.

### Escenario C

Evalua el rollback ante un despliegue fallido por commit y push a Git. El flujo usa una rama temporal y un worktree para aislar la ejecucion cuando se requiere.

## Resultados

Los resultados obtenidos para el TFM se adjuntan en `results/`.

Archivos presentes en el repositorio:

- `scenario-a-20260522-005207.csv`
- `scenario-b-argocd-20260522-014828.csv`
- `scenario-b-control-20260522-014828.csv`
- `scenario-c-20260627-232855.csv`
- `prometheus_validation_t1.csv`
- `prometheus_validation_t3.csv`

Los CSV nuevos que generes durante tus corridas tambien se guardan en `results/`.

## Graficas y validacion Prometheus

Generacion de graficas y tablas finales:

```bash
python3 genera_graficas_tfm_final.py --results-dir results
```

Validacion contra Prometheus:

```bash
python3 prometheus/prometheus_validation.py \
  --input-csv results/TU_CSV.csv \
  --prom-url http://localhost:9090 \
  --output-csv results/prometheus_validation.csv
```

Validacion end-to-end:

```bash
python3 prometheus/prometheus_validation_e2e.py \
  --input-csv results/TU_CSV.csv \
  --prom-url http://localhost:9090 \
  --output-csv results/prometheus_validation_e2e.csv
```

Resumen consolidado de pares escenario + validacion Prometheus:

```bash
python3 prometheus/analyze_prometheus_validations.py \
  --pair results/TU_ESCENARIO.csv results/TU_VALIDACION_PROMETHEUS.csv \
  --output-csv results/prometheus-analysis-summary.csv
```

## Reproducibilidad

- Los scripts toman como entrada los CSV que se carguen en cada corrida.
- Este README no fija datos experimentales ni resultados numericos.
- Si ejecutas el laboratorio en otra maquina o con otra version de Python, vuelve a generar los CSV y las figuras.
- Para el escenario C, usa tu propio fork y tus propias credenciales si vas a hacer `push`.
