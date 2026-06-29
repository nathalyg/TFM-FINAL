#!/usr/bin/env bash
# phase-3-prometheus.sh — Desplegar Prometheus para metricas de ArgoCD
# Uso: bash scripts/phase-3-prometheus.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROM_NS="argocd"
APP_NAME="nginx-demo"
PROM_MANIFEST="${REPO_ROOT}/experiments/pruebas_reales/prometheus/prometheus-config.yaml"
KSM_NS="kube-system"
KSM_DEPLOY="kube-state-metrics"


echo "================================"
echo "  FASE 3: Prometheus Metrics"
echo "================================"
echo ""

# 1) Validaciones base

echo "[1/5] Validando prerrequisitos de ArgoCD..."
if ! kubectl get namespace "${PROM_NS}" &>/dev/null; then
  echo "ERROR: namespace ${PROM_NS} no existe. Ejecuta fase 2 primero."
  exit 1
fi

SYNC_STATUS=$(kubectl get application "${APP_NAME}" -n "${PROM_NS}" \
  -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
HEALTH_STATUS=$(kubectl get application "${APP_NAME}" -n "${PROM_NS}" \
  -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

if [ "${SYNC_STATUS}" != "Synced" ] || [ "${HEALTH_STATUS}" != "Healthy" ]; then
  echo "ERROR: ArgoCD app ${APP_NAME} debe estar Synced/Healthy antes de instalar Prometheus."
  echo "Estado actual: sync=${SYNC_STATUS}, health=${HEALTH_STATUS}"
  exit 1
fi

if ! kubectl get svc argocd-metrics -n "${PROM_NS}" &>/dev/null; then
  echo "ERROR: servicio argocd-metrics no encontrado en ${PROM_NS}."
  exit 1
fi

echo "OK: ArgoCD listo y endpoint argocd-metrics disponible"
echo ""

# 2) Instalar kube-state-metrics (si no existe)

echo "[2/5] Verificando kube-state-metrics..."
if kubectl get deployment "${KSM_DEPLOY}" -n "${KSM_NS}" &>/dev/null; then
  echo "kube-state-metrics ya existe en ${KSM_NS}"
else
  echo "Instalando kube-state-metrics con Helm (metodo estable)..."
  if ! command -v helm &>/dev/null; then
    echo "ERROR: helm no esta instalado y kube-state-metrics no existe."
    echo "Instala helm o despliega kube-state-metrics manualmente, luego reintenta fase 3."
    exit 1
  fi

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
    --namespace "${KSM_NS}" \
    --create-namespace \
    >/dev/null
fi

echo "Esperando deployment/${KSM_DEPLOY}..."
kubectl wait --for=condition=Available deployment/"${KSM_DEPLOY}" \
  -n "${KSM_NS}" --timeout=180s

if ! kubectl get svc "${KSM_DEPLOY}" -n "${KSM_NS}" &>/dev/null; then
  echo "ERROR: servicio ${KSM_DEPLOY} no encontrado en ${KSM_NS}."
  exit 1
fi

echo "OK: kube-state-metrics disponible"
echo ""

# 3) Aplicar manifiesto

echo "[3/5] Aplicando manifiesto de Prometheus..."
if [ ! -f "${PROM_MANIFEST}" ]; then
  echo "ERROR: no existe ${PROM_MANIFEST}"
  exit 1
fi

kubectl apply -f "${PROM_MANIFEST}"
echo "Reiniciando deployment/prometheus para recargar scrape_configs..."
kubectl rollout restart deployment/prometheus -n "${PROM_NS}"
echo "Manifiesto aplicado"
echo ""

# 4) Esperar readiness

echo "[4/5] Esperando deployment/prometheus..."
kubectl wait --for=condition=Available deployment/prometheus \
  -n "${PROM_NS}" --timeout=180s

echo "Prometheus desplegado y disponible"
echo ""

# 5) Info operativa

echo "[5/5] Estado y comandos útiles"
kubectl get pods -n "${PROM_NS}" -l app=prometheus
kubectl get svc prometheus -n "${PROM_NS}"
kubectl get pods -n "${KSM_NS}" -l app.kubernetes.io/name=kube-state-metrics

echo ""
echo "FASE 3 COMPLETADA"
echo ""
echo "Comandos sugeridos:"
echo "  Port-forward UI:"
echo "    kubectl -n ${PROM_NS} port-forward svc/prometheus 9090:9090"
echo ""
echo "  Verificar target ArgoCD UP:"
echo "    curl -s http://localhost:9090/api/v1/targets | grep -E \"argocd-metrics|\\\"health\\\":\\\"up\\\"\""
echo ""
echo "  Verificar metricas kube_deployment_* disponibles:"
echo "    curl -g -s \"http://localhost:9090/api/v1/query?query=count(kube_deployment_spec_replicas)\""
echo ""
echo "  Continuar con experimentos:"
echo "    cd experiments/pruebas_reales && bash scenario-a.sh"
echo "    cd experiments/pruebas_reales && bash scenario-b.sh"
echo "    cd experiments/pruebas_reales && bash scenario-c.sh"
