# Prometheus para ArgoCD Metrics (Escenarios TFM)

Este directorio contiene lo necesario para:

1. Desplegar Prometheus en el namespace `argocd`
2. Scrappear métricas nativas de ArgoCD en `argocd-metrics:8082`
3. Scrappear métricas de estado de Kubernetes via `kube-state-metrics`
4. Validar tiempos del script vs métricas en Prometheus

## Archivos

- `prometheus-config.yaml`: ConfigMap + Deployment + Service (ClusterIP)
- `prometheus_validation.py`: compara tiempos del CSV contra Prometheus
- `prometheus_validation_e2e.py`: compara tiempo de reloj end-to-end vs Prometheus

## 1) Desplegar Prometheus

Desde la raiz del repo:

```bash
kubectl apply -f experiments/pruebas_reales/prometheus/prometheus-config.yaml
```

Verificar estado:

```bash
kubectl -n argocd get pods -l app=prometheus
kubectl -n argocd get svc prometheus
```

## 2) Acceder a la UI de Prometheus

```bash
kubectl -n argocd port-forward svc/prometheus 9090:9090
```

Abrir en navegador:

- http://localhost:9090

## 3) Verificar target de ArgoCD como UP

Comando simple:

```bash
curl -s http://localhost:9090/api/v1/targets | grep -E "argocd-metrics|\"health\":\"up\""
```

Si tienes `jq`:

```bash
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="argocd-metrics") | {job:.labels.job, health:.health, scrapeUrl:.scrapeUrl}'
```

Debe mostrarse `health: up` para el job `argocd-metrics`.

## 4) Validar tiempos de scripts vs Prometheus

### Requisitos del CSV de entrada

Columnas minimas requeridas:

- `run_id`
- `t_inicio_iso`
- `t_fin_iso`
- una columna de duracion del script. El validador la infiere automaticamente entre:
  - `spec_recovery_s`
  - `rto_s`
  - `c2_rollback_s`
  - `c1_degraded_s`
  - `rto_segundos`
  - `rto_script_s`
  - `duracion_script_s`

Ejemplo de ISO valido:

- `2026-05-20T03:43:00Z`

### Ejecutar validacion

```bash
python3 experiments/pruebas_reales/prometheus/prometheus_validation.py \
  --input-csv experiments/pruebas_reales/results/scenario-a-20260522-005207.csv \
  --prom-url http://localhost:9090 \
  --query "sum(argocd_app_reconcile_sum)" \
  --step 1s \
  --output-csv experiments/pruebas_reales/results/prometheus_validation.csv
```

Si quieres forzar una columna concreta:

```bash
python experiments/pruebas_reales/prometheus/prometheus_validation.py \
  --input-csv experiments/pruebas_reales/results/tu_archivo.csv \
  --value-column rto_s \
  --prom-url http://localhost:9090 \
  --output-csv experiments/pruebas_reales/results/prometheus_validation.csv
```

Salida generada:

- `prometheus_validation.csv` con columnas:
  - `run_id`
  - `t_script_s`
  - `t_prometheus_s`
  - `delta_s`
  - `dentro_margen_15s`

El script imprime resumen final:

- filas dentro del margen de 15 segundos
- delta promedio (`script - prometheus`)

## 5) Validacion end-to-end (tiempo de reloj)

Este validador usa metricas de estado del deployment para medir recuperacion visible:

- `ready`: `kube_deployment_status_replicas_available`
- `expected`: `kube_deployment_spec_replicas`

Primero verifica que existen en Prometheus:

```bash
curl -g -s "http://localhost:9090/api/v1/query?query=sum(kube_deployment_status_replicas_available{deployment=\"nginx-demo\",namespace=\"tfm-app\"})"
curl -g -s "http://localhost:9090/api/v1/query?query=sum(kube_deployment_spec_replicas{deployment=\"nginx-demo\",namespace=\"tfm-app\"})"
```

Luego ejecuta la comparacion end-to-end:

```bash
python3 experiments/pruebas_reales/prometheus/prometheus_validation_e2e.py \
  --input-csv experiments/pruebas_reales/results/scenario-a-20260522-005207.csv \
  --prom-url http://localhost:9090 \
  --step 1s \
  --lookahead 30 \
  --output-csv experiments/pruebas_reales/results/prometheus_validation_e2e.csv
```

Salida generada:

- `prometheus_validation_e2e.csv` con columnas:
  - `run_id`
  - `t_script_s`
  - `t_prometheus_e2e_s`
  - `delta_s`
  - `dentro_margen_15s`

Nota:

- Si no tienes `kube_*` metricas, necesitas exponer/scrapear `kube-state-metrics`.

## 6) Notas importantes

- La consulta usada por defecto en este repositorio es:

```text
sum(argocd_app_reconcile_sum)
```

- Si deseas cambiar PromQL (por ejemplo filtrando namespace):

```bash
python experiments/pruebas_reales/prometheus/prometheus_validation.py \
  --input-csv ... \
  --prom-url http://localhost:9090 \
  --query 'sum(argocd_app_reconcile_sum{namespace="argocd"})'
```

- Si quieres resumir resultados con `awk`, y el CSV viene con formato CRLF, limpia `\r` antes de comparar:

```bash
awk -F, 'NR==1{next} {tot++; v=$5; gsub(/\r/,"",v); if(v=="True") ok++} END{printf("dentro_margen=%d/%d\n",ok,tot)}' experiments/pruebas_reales/results/prometheus_validation.csv
```

- `query_range` requiere que `t_inicio_iso` y `t_fin_iso` esten en formato parseable por pandas.
- Si no hay datos en el rango, la fila quedara sin `t_prometheus_s` y sin `delta_s`.
- El script compara el valor del CSV contra la metrica de Prometheus dentro de la misma ventana temporal.

## 7) Limpieza (opcional)

```bash
kubectl delete -f experiments/pruebas_reales/prometheus/prometheus-config.yaml
```
