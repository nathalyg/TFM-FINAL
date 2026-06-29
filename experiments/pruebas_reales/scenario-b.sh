#!/bin/bash
# scenario-b.sh
# ESCENARIO B — RTO Puro: eliminación completa del Deployment
#
# Grupo experimental (con ArgoCD activo):
#   30 repeticiones normales + 10 bajo estrés.
#   Mide tiempo desde kubectl delete deployment hasta pods Ready.
#   Target: RTO P90 < 60 s (carga normal), P90 < 120 s (estrés).
#
# Grupo de control (sin ArgoCD):
#   30 repeticiones. Se desactiva automated sync + selfHeal.
#   Se elimina el deployment y se confirma que NO se recupera solo.
#   Documenta la necesidad de intervención manual (hallazgo clave).
#   Tiempo de observación: 120 s por prueba (ventana fija).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
STRESS_SCRIPT="${SCRIPT_DIR}/stress-generator.sh"

NAMESPACE="tfm-app"
APP="nginx-demo"
ARGOCD_NS="argocd"
ORIGINAL_REPLICAS=2
NORMAL_RUNS="${NORMAL_RUNS:-30}"
STRESS_RUNS="${STRESS_RUNS:-10}"
CONTROL_RUNS="${CONTROL_RUNS:-30}"
COOLDOWN=15               # segundos entre repeticiones (B necesita más que A)
TIMEOUT_RTO=120           # segundos máximo espera grupo experimental
CONTROL_OBSERVATION=120   # segundos ventana observación grupo control
HTTP_URL="http://localhost:30080/"
HTTP_CONSECUTIVE_200=3

mkdir -p "${RESULTS_DIR}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CSV_ARGOCD="${RESULTS_DIR}/scenario-b-argocd-${TIMESTAMP}.csv"
CSV_CONTROL="${RESULTS_DIR}/scenario-b-control-${TIMESTAMP}.csv"

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

log() { echo "[$(date +%H:%M:%S)] $*"; }
ts_now() { date +%s; }

iso_from_epoch() { date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"; }

ensure_deployment_exists() {
  local wait=0
  while ! kubectl get deployment "${APP}" -n "${NAMESPACE}" &>/dev/null; do
    sleep 2; wait=$((wait+2))
    [ ${wait} -ge 60 ] && { log "ERROR: deployment no existe y no fue recreado"; exit 1; }
  done
  kubectl rollout status deployment/"${APP}" -n "${NAMESPACE}" --timeout=90s &>/dev/null || true
}

wait_deployment_ready() {
  # Espera hasta que spec.replicas y status.readyReplicas coincidan con target
  local target=$1 timeout=$2
  local elapsed=0
  # Primero esperar a que el Deployment exista
  while ! kubectl get deployment "${APP}" -n "${NAMESPACE}" &>/dev/null; do
    sleep 1; elapsed=$((elapsed+1))
    [ ${elapsed} -ge ${timeout} ] && echo "TIMEOUT" && return 0
  done
  # Luego esperar spec.replicas correcto
  while [ "$(kubectl get deployment "${APP}" -n "${NAMESPACE}" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null)" != "${target}" ]; do
    sleep 1; elapsed=$((elapsed+1))
    [ ${elapsed} -ge ${timeout} ] && echo "TIMEOUT" && return 0
  done
  # Finalmente esperar pods Ready
  while true; do
    local ready
    ready=$(kubectl get deployment "${APP}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [ "${ready:-0}" = "${target}" ] && echo "${elapsed}" && return 0
    sleep 1; elapsed=$((elapsed+1))
    [ ${elapsed} -ge ${timeout} ] && echo "TIMEOUT" && return 0
  done
}

wait_spec_recreated() {
  # Tiempo hasta que el Deployment reaparece con spec.replicas = target
  local target=$1 timeout=$2
  local elapsed=0
  # Primero esperar desaparición (puede tardar un momento)
  sleep 1
  # Esperar reaparición
  while ! kubectl get deployment "${APP}" -n "${NAMESPACE}" &>/dev/null; do
    sleep 1; elapsed=$((elapsed+1))
    [ ${elapsed} -ge ${timeout} ] && echo "TIMEOUT" && return 0
  done
  while [ "$(kubectl get deployment "${APP}" -n "${NAMESPACE}" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null)" != "${target}" ]; do
    sleep 1; elapsed=$((elapsed+1))
    [ ${elapsed} -ge ${timeout} ] && echo "TIMEOUT" && return 0
  done
  echo "${elapsed}"
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

disable_argocd_sync() {
  log "  Desactivando automated sync + selfHeal en ArgoCD..."
  kubectl patch application "${APP}" -n "${ARGOCD_NS}" --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}' &>/dev/null
  # Pequeña pausa para que el controlador procese el cambio
  sleep 3
}

enable_argocd_sync() {
  log "  Reactivando automated sync + selfHeal en ArgoCD..."
  kubectl patch application "${APP}" -n "${ARGOCD_NS}" --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' &>/dev/null
  # Forzar sync inmediato para restaurar el estado
  if command -v argocd &>/dev/null; then
    argocd app sync "${APP}" --force &>/dev/null || true
  else
    kubectl annotate application "${APP}" -n "${ARGOCD_NS}" \
      "argocd.argoproj.io/refresh=hard" --overwrite &>/dev/null || true
  fi
  # Esperar recuperación completa antes de la próxima prueba
  local wait=0
  while ! kubectl get deployment "${APP}" -n "${NAMESPACE}" &>/dev/null; do
    sleep 2; wait=$((wait+2))
    [ ${wait} -ge 60 ] && { log "ADVERTENCIA: ArgoCD tardó más de 60s en recrear el deployment"; break; }
  done
  kubectl rollout status deployment/"${APP}" -n "${NAMESPACE}" --timeout=90s &>/dev/null || true
  log "  ArgoCD sync reactivado y deployment restaurado."
}

# ─────────────────────────────────────────────
# CSV headers
# ─────────────────────────────────────────────

echo "run_id,group,mode,deletion_epoch,t_inicio_iso,spec_recreated_s,rto_s,t5_http_first200_s,http_status_final,t_fin_iso,spec_ok,rto_ok,http_ok" \
  > "${CSV_ARGOCD}"

echo "run_id,group,deletion_epoch,t_inicio_iso,observation_window_s,t5_http_first200_s,http_status_final,t_fin_iso,deployment_recreated,recovery_type,notes,http_ok" \
  > "${CSV_CONTROL}"

log "CSV ArgoCD:  ${CSV_ARGOCD}"
log "CSV Control: ${CSV_CONTROL}"

# ─────────────────────────────────────────────
# GRUPO EXPERIMENTAL — con ArgoCD
# ─────────────────────────────────────────────

echo ""
echo "================================================================"
log "GRUPO EXPERIMENTAL: con ArgoCD activo (selfHeal=true)"
echo "================================================================"

run_test_b_argocd() {
  local run_id=$1 mode=$2

  ensure_deployment_exists

  log "[B ArgoCD | ${mode} | run ${run_id}] Eliminando deployment..."
  local t0; t0=$(ts_now)
  local t_inicio_iso
  t_inicio_iso=$(iso_from_epoch "${t0}")

  kubectl delete deployment "${APP}" -n "${NAMESPACE}" --ignore-not-found &>/dev/null

  local spec_s
  spec_s=$(wait_spec_recreated "${ORIGINAL_REPLICAS}" "${TIMEOUT_RTO}")

  local rto_s
  rto_s=$(wait_deployment_ready "${ORIGINAL_REPLICAS}" "${TIMEOUT_RTO}")

  local t5_http_first200_s=""
  local http_status_final="NA"
  local http_ok="false"
  local http_window=""
  if http_window=$(wait_http_200_streak "${TIMEOUT_RTO}"); then
    t5_http_first200_s="${http_window%|*}"
    http_status_final="${http_window#*|}"
    http_ok="true"
  fi

  local spec_ok="true" rto_ok="true"
  [ "${spec_s}" = "TIMEOUT" ] && spec_ok="false"
  [ "${rto_s}" = "TIMEOUT" ] && rto_ok="false"

  local t_fin_iso=""
  if [ "${rto_s}" != "TIMEOUT" ]; then
    t_fin_iso=$(iso_from_epoch "$((t0 + rto_s))")
  fi

  # Evaluar contra target: RTO < 60s (normal) / < 120s (stress)
  local rto_target=60
  [ "${mode}" = "stress" ] && rto_target=120
  if [ "${rto_ok}" = "true" ] && [ "${rto_s}" -gt "${rto_target}" ]; then
    rto_ok="false (>${rto_target}s)"
  fi

  local spec_d="${spec_s}s"; [ "${spec_s}" = "TIMEOUT" ] && spec_d="TIMEOUT"
  local rto_d="${rto_s}s";  [ "${rto_s}"  = "TIMEOUT" ] && rto_d="TIMEOUT"

  log "  → spec_recreated=${spec_d} | rto=${rto_d} | http_first200=${t5_http_first200_s:-TIMEOUT} | spec_ok=${spec_ok} | rto_ok=${rto_ok} | http_ok=${http_ok}"

  echo "${run_id},argocd,${mode},${t0},${t_inicio_iso},${spec_s},${rto_s},${t5_http_first200_s},${http_status_final},${t_fin_iso},${spec_ok},${rto_ok},${http_ok}" >> "${CSV_ARGOCD}"
}

log "B ArgoCD — Bloque normal (${NORMAL_RUNS} repeticiones)..."
for i in $(seq 1 ${NORMAL_RUNS}); do
  run_test_b_argocd "${i}" "normal"
  [ "${i}" -lt "${NORMAL_RUNS}" ] && sleep "${COOLDOWN}"
done

echo ""
log "B ArgoCD — Bloque estrés (${STRESS_RUNS} repeticiones con carga de CPU)..."
bash "${STRESS_SCRIPT}" start
for i in $(seq 1 ${STRESS_RUNS}); do
  run_test_b_argocd "$((NORMAL_RUNS + i))" "stress"
  [ "${i}" -lt "${STRESS_RUNS}" ] && sleep "${COOLDOWN}"
done
bash "${STRESS_SCRIPT}" stop

# ─────────────────────────────────────────────
# GRUPO DE CONTROL — sin ArgoCD
# ─────────────────────────────────────────────

echo ""
echo "================================================================"
log "GRUPO DE CONTROL: sin ArgoCD (automated sync desactivado)"
log "Esperado: el deployment NO se recupera en la ventana de ${CONTROL_OBSERVATION}s"
echo "================================================================"

run_test_b_control() {
  local run_id=$1

  ensure_deployment_exists
  disable_argocd_sync
  sleep 2

  log "[B Control | run ${run_id}] Eliminando deployment (sin ArgoCD)..."
  local t0; t0=$(ts_now)
  local t_inicio_iso
  t_inicio_iso=$(iso_from_epoch "${t0}")

  kubectl delete deployment "${APP}" -n "${NAMESPACE}" --ignore-not-found &>/dev/null

  local t5_http_first200_s=""
  local http_status_final="NA"
  local http_ok="false"
  local http_window=""

  # Observar durante la ventana fija: ¿se recrea el deployment?
  local elapsed=0 recreated="false"
  while [ ${elapsed} -lt ${CONTROL_OBSERVATION} ]; do
    if kubectl get deployment "${APP}" -n "${NAMESPACE}" &>/dev/null; then
      recreated="true"
      break
    fi
    if [ "${http_ok}" = "false" ] && http_window=$(wait_http_200_streak 1); then
      t5_http_first200_s="${http_window%|*}"
      http_status_final="${http_window#*|}"
      http_ok="true"
    fi
    sleep 2; elapsed=$((elapsed+2))
  done

  local recovery_type="none (manual_required)"
  local notes="Deployment absent for >${CONTROL_OBSERVATION}s — GitOps not active"
  if [ "${recreated}" = "true" ]; then
    recovery_type="unexpected_auto_recovery"
    notes="Deployment recreated at t=${elapsed}s — check if ArgoCD was actually disabled"
  fi

  local t_fin_iso
  t_fin_iso=$(iso_from_epoch "$((t0 + CONTROL_OBSERVATION))")

  log "  → recreated=${recreated} | recovery_type=${recovery_type}"

  # Restaurar ArgoCD antes de la siguiente prueba
  enable_argocd_sync
  sleep 5

  echo "${run_id},control,${t0},${t_inicio_iso},${CONTROL_OBSERVATION},${t5_http_first200_s},${http_status_final},${t_fin_iso},${recreated},${recovery_type},\"${notes}\",${http_ok}" \
    >> "${CSV_CONTROL}"
}

log "B Control — ${CONTROL_RUNS} repeticiones..."
for i in $(seq 1 ${CONTROL_RUNS}); do
  run_test_b_control "${i}"
  [ "${i}" -lt "${CONTROL_RUNS}" ] && sleep 5
done

echo ""
echo "================================================================"
log "ESCENARIO B completado."
log "CSV ArgoCD:  ${CSV_ARGOCD}"
log "CSV Control: ${CSV_CONTROL}"
echo "================================================================"
