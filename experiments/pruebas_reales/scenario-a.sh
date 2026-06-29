#!/bin/bash
# scenario-a.sh
# ESCENARIO A — Detección y corrección de Configuration Drift
#
# Condición A1: selfHeal estándar (sin webhook, ArgoCD usa k8s watches).
#               Mide tiempo de detección + reversion del drift.
# Condición A2: Con refresh inmediato vía CLI (simula notificación webhook).
#               Mide tiempo de detección + reversion tras trigger manual.
#
# 30 repeticiones normales + 10 bajo estrés por condición.
# Métricas: spec_recovery_time_s, pods_ready_time_s
# CSV: results/scenario-a-<timestamp>.csv
#
# Target (basado en mecanismo real — ver README):
#   A1 normal:  P95 < 10 s   (k8s watch, sin trigger adicional)
#   A1 stress:  P95 < 30 s
#   A2 normal:  P95 < 5 s    (refresh inmediato tras inyección)
#   A2 stress:  P95 < 15 s

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
STRESS_SCRIPT="${SCRIPT_DIR}/stress-generator.sh"

NAMESPACE="tfm-app"
APP="nginx-demo"
ARGOCD_NS="argocd"
ORIGINAL_REPLICAS=2
DRIFT_REPLICAS=5         # valor inyectado en cada prueba
NORMAL_RUNS="${NORMAL_RUNS:-30}"
STRESS_RUNS="${STRESS_RUNS:-10}"
COOLDOWN=8               # segundos entre repeticiones
TIMEOUT_A1=60            # segundos máximo espera A1 (k8s watch es rápido)
TIMEOUT_A2=30            # segundos máximo espera A2
HTTP_URL="http://localhost:30080/"
HTTP_CONSECUTIVE_200=3

mkdir -p "${RESULTS_DIR}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CSV="${RESULTS_DIR}/scenario-a-${TIMESTAMP}.csv"

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

log() { echo "[$(date +%H:%M:%S)] $*"; }

ts_now() { date +%s; }  # epoch seconds

iso_from_epoch() { date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"; }

ensure_baseline() {
  # Garantiza que el deployment tiene el estado original antes de cada prueba
  local current
  current=$(kubectl get deployment "${APP}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [ "${current}" != "${ORIGINAL_REPLICAS}" ]; then
    kubectl scale deployment "${APP}" -n "${NAMESPACE}" --replicas="${ORIGINAL_REPLICAS}" &>/dev/null
    local wait=0
    while [ "$(kubectl get deployment "${APP}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null)" != "${ORIGINAL_REPLICAS}" ]; do
      sleep 1; wait=$((wait+1))
      [ ${wait} -ge 30 ] && { log "ERROR: no se pudo restaurar baseline"; exit 1; }
    done
    # Además esperar pods Ready
    kubectl rollout status deployment/"${APP}" -n "${NAMESPACE}" --timeout=60s &>/dev/null || true
  fi
}

wait_spec_replicas() {
  local target=$1 timeout=$2
  local elapsed=0
  while [ "$(kubectl get deployment "${APP}" -n "${NAMESPACE}" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null)" != "${target}" ]; do
    sleep 1; elapsed=$((elapsed+1))
    [ ${elapsed} -ge ${timeout} ] && echo "TIMEOUT" && return 0
  done
  echo "${elapsed}"
}

wait_pods_ready() {
  local target=$1 timeout=$2
  local elapsed=0
  while true; do
    local ready
    ready=$(kubectl get deployment "${APP}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [ "${ready:-0}" = "${target}" ] && echo "${elapsed}" && return 0
    sleep 1; elapsed=$((elapsed+1))
    [ ${elapsed} -ge ${timeout} ] && echo "TIMEOUT" && return 0
  done
}

wait_http_200_streak() {
  local timeout=$1
  local target_streak=${HTTP_CONSECUTIVE_200}
  local elapsed=0
  local streak=0
  local first_ok_epoch=""
  local last_code="NA"

  while [ ${elapsed} -lt ${timeout} ]; do
    last_code=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" "${HTTP_URL}" || echo "000")
    if [ "${last_code}" = "200" ]; then
      if [ ${streak} -eq 0 ]; then
        first_ok_epoch=$(ts_now)
      fi
      streak=$((streak + 1))
      if [ ${streak} -ge ${target_streak} ]; then
        printf '%s|%s' "${first_ok_epoch}" "${last_code}"
        return 0
      fi
    else
      streak=0
      first_ok_epoch=""
    fi
    sleep 1; elapsed=$((elapsed+1))
  done

  printf '|%s' "${last_code}"
  return 1
}

argocd_refresh() {
  # Simula notificación webhook: fuerza reconciliación inmediata
  if command -v argocd &>/dev/null; then
    argocd app refresh "${APP}" --hard-refresh &>/dev/null || true
  else
    # Alternativa: anotar la app para forzar reconciliación
    kubectl annotate application "${APP}" -n "${ARGOCD_NS}" \
      "argocd.argoproj.io/refresh=hard" --overwrite &>/dev/null || true
  fi
}

# ─────────────────────────────────────────────
# CSV header
# ─────────────────────────────────────────────

echo "run_id,condition,mode,injection_epoch,t_inicio_iso,spec_recovery_s,pods_ready_s,t5_http_first200_s,http_status_final,t_fin_iso,spec_ok,pods_ok,http_ok" \
  > "${CSV}"

log "CSV de resultados: ${CSV}"

# ─────────────────────────────────────────────
# Función de prueba individual
# ─────────────────────────────────────────────

run_test_a() {
  local run_id=$1 condition=$2 mode=$3
  local timeout_spec timeout_pods

  if [ "${condition}" = "A1" ]; then
    timeout_spec=${TIMEOUT_A1}; timeout_pods=${TIMEOUT_A1}
  else
    timeout_spec=${TIMEOUT_A2}; timeout_pods=${TIMEOUT_A2}
  fi

  # Baseline
  ensure_baseline
  sleep 2

  log "[${condition} | ${mode} | run ${run_id}] Inyectando drift: replicas=${DRIFT_REPLICAS}..."
  local t0; t0=$(ts_now)
  local t_inicio_iso
  t_inicio_iso=$(iso_from_epoch "${t0}")

  kubectl scale deployment "${APP}" -n "${NAMESPACE}" --replicas="${DRIFT_REPLICAS}" &>/dev/null

  # A2: trigger inmediato de reconciliación (simula webhook)
  if [ "${condition}" = "A2" ]; then
    argocd_refresh
  fi

  local spec_s
  spec_s=$(wait_spec_replicas "${ORIGINAL_REPLICAS}" "${timeout_spec}")

  local pods_s
  pods_s=$(wait_pods_ready "${ORIGINAL_REPLICAS}" "${timeout_pods}")

  local t5_http_first200_s=""
  local http_status_final="NA"
  local http_ok="false"
  local http_window=""
  if http_window=$(wait_http_200_streak "${timeout_pods}"); then
    t5_http_first200_s="${http_window%|*}"
    http_status_final="${http_window#*|}"
    http_ok="true"
  fi

  # Evaluar resultado
  local spec_ok="true" pods_ok="true"
  [ "${spec_s}" = "TIMEOUT" ] && spec_ok="false"
  [ "${pods_s}" = "TIMEOUT" ] && pods_ok="false"

  local t_fin_iso=""
  if [ "${spec_s}" != "TIMEOUT" ]; then
    t_fin_iso=$(iso_from_epoch "$((t0 + spec_s))")
  fi

  local spec_display="${spec_s}s"
  local pods_display="${pods_s}s"
  local http_display="${t5_http_first200_s}s"
  [ "${spec_s}" = "TIMEOUT" ] && spec_display="TIMEOUT(>${timeout_spec}s)"
  [ "${pods_s}" = "TIMEOUT" ] && pods_display="TIMEOUT(>${timeout_pods}s)"
  [ "${http_ok}" = "false" ] && http_display="TIMEOUT(>${timeout_pods}s)"

  log "  → spec_recovery=${spec_display} | pods_ready=${pods_display} | http_first200=${http_display} | spec_ok=${spec_ok} | pods_ok=${pods_ok} | http_ok=${http_ok}"

  echo "${run_id},${condition},${mode},${t0},${t_inicio_iso},${spec_s},${pods_s},${t5_http_first200_s},${http_status_final},${t_fin_iso},${spec_ok},${pods_ok},${http_ok}" >> "${CSV}"
}

# ─────────────────────────────────────────────
# CONDICIÓN A1 — sin trigger adicional
# ─────────────────────────────────────────────

echo ""
echo "================================================================"
log "CONDICIÓN A1: selfHeal estándar (k8s watch, sin webhook)"
echo "================================================================"

# Documentar resync period actual
RESYNC_PERIOD=$(kubectl get configmap argocd-cm -n "${ARGOCD_NS}" \
  -o jsonpath='{.data.timeout\.reconciliation}' 2>/dev/null || echo "180s (default)")
log "  ArgoCD resync period configurado: ${RESYNC_PERIOD}"
echo "  (Para drift in-cluster, ArgoCD usa k8s watches — independiente del resync period)"

echo ""
log "A1 — Bloque normal (${NORMAL_RUNS} repeticiones)..."
for i in $(seq 1 ${NORMAL_RUNS}); do
  run_test_a "${i}" "A1" "normal"
  [ "${i}" -lt "${NORMAL_RUNS}" ] && sleep "${COOLDOWN}"
done

echo ""
log "A1 — Bloque estrés (${STRESS_RUNS} repeticiones con carga de CPU)..."
bash "${STRESS_SCRIPT}" start
for i in $(seq 1 ${STRESS_RUNS}); do
  run_test_a "$((NORMAL_RUNS + i))" "A1" "stress"
  [ "${i}" -lt "${STRESS_RUNS}" ] && sleep "${COOLDOWN}"
done
bash "${STRESS_SCRIPT}" stop

# ─────────────────────────────────────────────
# CONDICIÓN A2 — refresh inmediato (simula webhook)
# ─────────────────────────────────────────────

echo ""
echo "================================================================"
log "CONDICIÓN A2: refresh inmediato vía CLI (simula notificación webhook)"
echo "================================================================"

echo ""
log "A2 — Bloque normal (${NORMAL_RUNS} repeticiones)..."
for i in $(seq 1 ${NORMAL_RUNS}); do
  run_test_a "${i}" "A2" "normal"
  [ "${i}" -lt "${NORMAL_RUNS}" ] && sleep "${COOLDOWN}"
done

echo ""
log "A2 — Bloque estrés (${STRESS_RUNS} repeticiones con carga de CPU)..."
bash "${STRESS_SCRIPT}" start
for i in $(seq 1 ${STRESS_RUNS}); do
  run_test_a "$((NORMAL_RUNS + i))" "A2" "stress"
  [ "${i}" -lt "${STRESS_RUNS}" ] && sleep "${COOLDOWN}"
done
bash "${STRESS_SCRIPT}" stop

echo ""
echo "================================================================"
log "ESCENARIO A completado. CSV: ${CSV}"
echo "================================================================"
