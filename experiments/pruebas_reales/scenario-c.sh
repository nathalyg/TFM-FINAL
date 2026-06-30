#!/bin/bash
# scenario-c.sh
# ESCENARIO C — Gestión de Rollback ante Despliegue Fallido
#
# El fallo se inyecta por Git push sobre el mismo repositorio que observa
# ArgoCD. El rollback se ejecuta con git revert + git push. Las marcas T1 y
# T3 se capturan mediante watch sobre la API de Kubernetes/ArgoCD,
# eliminando el error de redondeo del sondeo periódico; la latencia interna
# de cómputo de ArgoCD antes de escribir el cambio de estado no es observable
# desde el cliente. No se afirma precisión de milisegundos.
#
# 30 repeticiones normales + 10 bajo estrés.
# Métricas: t0_push_s, t1_degraded_s, t2_revert_push_s, t3_healthy_synced_s,
#           t4_pods_ready_s, t5_http_first200_s

set -euo pipefail

if [ "${SCENARIO_C_ORCHESTRATED:-0}" != "1" ]; then
  echo "ERROR: scenario-c.sh no debe ejecutarse directamente."
  echo "       Usa: bash experiments/pruebas_reales/run-scenario-c-local.sh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
STRESS_SCRIPT="${SCRIPT_DIR}/stress-generator.sh"
MANIFEST_FILE="${REPO_ROOT}/manifests/nginx-demo.yaml"

NAMESPACE="tfm-app"
APP="nginx-demo"
ARGOCD_NS="argocd"
REPO_BRANCH="${REPO_BRANCH:-main}"
ORIGINAL_REPLICAS=2
ORIGINAL_IMAGE="nginx:1.25-alpine"
NORMAL_RUNS="${NORMAL_RUNS:-30}"
STRESS_RUNS="${STRESS_RUNS:-10}"
GIT_PUSH_TARGET="origin"
COOLDOWN=15
TIMEOUT_DEGRADED=60
TIMEOUT_RECOVERY=120
TIMEOUT_PODS=120
TIMEOUT_HTTP=120
HTTP_URL="http://localhost:30080/"
HTTP_CONSECUTIVE_200=3

case "${NORMAL_RUNS}" in
  ''|*[!0-9]*) echo "ERROR: NORMAL_RUNS debe ser un entero no negativo"; exit 1 ;;
esac

case "${STRESS_RUNS}" in
  ''|*[!0-9]*) echo "ERROR: STRESS_RUNS debe ser un entero no negativo"; exit 1 ;;
esac

mkdir -p "${RESULTS_DIR}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CSV="${RESULTS_DIR}/scenario-c-${TIMESTAMP}.csv"

log() { echo "[$(date +%H:%M:%S)] $*"; }
ts_now() { date +%s; }
iso_from_epoch() { date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"; }

ensure_git_identity() {
  git -C "${REPO_ROOT}" config user.name >/dev/null 2>&1 || git -C "${REPO_ROOT}" config user.name "tfm-gitops-bot"
  git -C "${REPO_ROOT}" config user.email >/dev/null 2>&1 || git -C "${REPO_ROOT}" config user.email "tfm-gitops-bot@example.com"
}

load_git_push_auth() {
  local env_file="${REPO_ROOT}/.env"
  if [ ! -f "${env_file}" ]; then
    return 0
  fi

  set +u
  # shellcheck disable=SC1090
  source "${env_file}"
  set -u

  if [ -n "${GITHUB_USER:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    local origin_url
    origin_url=$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)
    if printf '%s' "${origin_url}" | grep -q '^https://'; then
      GIT_PUSH_TARGET="https://${GITHUB_USER}:${GITHUB_TOKEN}@${origin_url#https://}"
      log "[git] credenciales GitHub cargadas desde .env para el push"
    fi
  fi
}

ensure_clean_repo() {
  if [ -n "$(git -C "${REPO_ROOT}" status --porcelain)" ]; then
    log "ERROR: el repositorio tiene cambios locales no gestionados"
    exit 1
  fi
}

git_no_prompt() {
  GIT_TERMINAL_PROMPT=0 git -C "${REPO_ROOT}" "$@"
}

git_push_with_timeout() {
  local refspec=$1
  local push_target="${GIT_PUSH_TARGET:-origin}"
  if ! env GIT_TERMINAL_PROMPT=0 timeout 180s git -C "${REPO_ROOT}" push "${push_target}" "${refspec}"; then
    log "ERROR: git push falló o excedió el timeout para ${refspec}"
    log "       Si ves 'could not read Username', crea ${REPO_ROOT}/.env con GITHUB_USER, GITHUB_TOKEN y REPO_URL."
    exit 1
  fi
}

read_app_status_fields() {
  local status_line
  if ! status_line=$(timeout 15s kubectl get application "${APP}" -n "${ARGOCD_NS}" -o jsonpath='{.status.health.status}{"\t"}{.status.sync.status}' 2>/dev/null); then
    echo $'Unknown\tUnknown'
    return 0
  fi

  if [ -z "${status_line}" ]; then
    echo $'Unknown\tUnknown'
  else
    printf '%s\n' "${status_line}"
  fi
}

force_argocd_sync() {
  kubectl patch application "${APP}" -n "${ARGOCD_NS}" --type merge \
    -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' &>/dev/null || true
}

validate_automated_policy_enabled() {
  local prune self_heal
  prune="$(kubectl get application "${APP}" -n "${ARGOCD_NS}" -o jsonpath='{.spec.syncPolicy.automated.prune}' 2>/dev/null || true)"
  self_heal="$(kubectl get application "${APP}" -n "${ARGOCD_NS}" -o jsonpath='{.spec.syncPolicy.automated.selfHeal}' 2>/dev/null || true)"

  if [ "${prune}" != "true" ] || [ "${self_heal}" != "true" ]; then
    log "ERROR: ArgoCD ${APP} requiere syncPolicy.automated activo (selfHeal=true, prune=true)."
    log "       Reejecuta la fase 2 para garantizar esa configuracion."
    log "       Estado detectado: automated.prune=${prune:-<vacio>} automated.selfHeal=${self_heal:-<vacio>}"
    exit 1
  fi
}

wait_app_healthy_synced_poll() {
  local timeout_s=$1
  local max_steps=$((timeout_s * 2))
  local step=0
  while [ ${step} -lt ${max_steps} ]; do
    local health sync
    IFS=$'\t' read -r health sync < <(read_app_status_fields)
    if [ "${health}" = "Healthy" ] && [ "${sync}" = "Synced" ]; then
      return 0
    fi
    sleep 0.5
    step=$((step + 1))
  done
  return 1
}

watch_app_status_tsv() {
  local timeout_s=$1
  timeout "${timeout_s}s" bash -lc "kubectl get application '${APP}' -n '${ARGOCD_NS}' -o json -w | jq -r --unbuffered 'def cur: (.object // .); [cur.status.health.status // \"\", cur.status.sync.status // \"\"] | @tsv'"
}

watch_app_degraded_timestamp() {
  local timeout_s=$1 baseline_health=$2
  local current_health current_sync
  IFS=$'\t' read -r current_health current_sync < <(read_app_status_fields)
  if [ "${current_health}" = "Degraded" ]; then
    date +%s
    return 0
  fi

  local prev_health="${baseline_health}"
  local health sync
  while IFS=$'\t' read -r health sync; do
    if [ "${health}" = "Degraded" ] && [ "${prev_health}" != "Degraded" ]; then
      date +%s
      return 0
    fi
    prev_health="${health}"
  done < <(watch_app_status_tsv "${timeout_s}")
  return 1
}

watch_app_healthy_synced_timestamp() {
  local timeout_s=$1 baseline_health=$2 baseline_sync=$3
  local current_health current_sync
  IFS=$'\t' read -r current_health current_sync < <(read_app_status_fields)
  if [ "${current_health}" = "Healthy" ] && [ "${current_sync}" = "Synced" ]; then
    date +%s
    return 0
  fi

  local prev_health="${baseline_health}"
  local prev_sync="${baseline_sync}"
  local health sync
  while IFS=$'\t' read -r health sync; do
    if [ "${health}" = "Healthy" ] && [ "${sync}" = "Synced" ] && { [ "${prev_health}" != "Healthy" ] || [ "${prev_sync}" != "Synced" ]; }; then
      date +%s
      return 0
    fi
    prev_health="${health}"
    prev_sync="${sync}"
  done < <(watch_app_status_tsv "${timeout_s}")
  return 1
}

wait_pods_ready_timestamp() {
  local target=$1 timeout_s=$2
  local max_steps=$((timeout_s * 2))
  local step=0
  while [ ${step} -lt ${max_steps} ]; do
    local ready
    ready=$(kubectl get deployment "${APP}" -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${ready:-0}" = "${target}" ]; then
      date +%s
      return 0
    fi
    sleep 0.5
    step=$((step + 1))
  done
  return 1
}

wait_http_200_streak_timestamp() {
  local target_streak=$1 timeout_s=$2
  local max_steps=$((timeout_s * 2))
  local step=0
  local streak=0
  local first_ok_epoch=""
  local last_code="NA"

  while [ ${step} -lt ${max_steps} ]; do
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
    sleep 0.5
    step=$((step + 1))
  done

  printf '|%s' "${last_code}"
  return 1
}

set_manifest_image() {
  local new_image=$1
  python3 - "${MANIFEST_FILE}" "${new_image}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
new_image = sys.argv[2]
text = path.read_text(encoding="utf-8")

pattern = r"(?m)^(\s*image:\s*)nginx:[^\s#]+\s*$"
replacement = rf"\1{new_image}"

if not re.search(pattern, text):
    raise SystemExit("image line not found in manifest")

path.write_text(re.sub(pattern, replacement, text, count=1), encoding="utf-8")
PY
}

ensure_baseline() {
  log "[baseline] configurando identidad Git..."
  ensure_git_identity
  load_git_push_auth
  log "[baseline] comprobando que el repo local esté limpio..."
  ensure_clean_repo
  log "[baseline] leyendo estado de ArgoCD (Healthy/Synced)..."
  local health sync
  IFS=$'\t' read -r health sync < <(read_app_status_fields)
  log "[baseline] estado actual: health=${health} sync=${sync}"
  if [ "${health}" != "Healthy" ] || [ "${sync}" != "Synced" ]; then
    log "ERROR: la aplicación no quedó en Healthy+Synced antes de la corrida"
    exit 1
  fi
  log "[baseline] baseline OK"
}

echo "run_id,mode,broken_image_tag,t0_push_s,t1_degraded_s,t2_revert_push_s,t3_healthy_synced_s,t4_pods_ready_s,t5_http_first200_s,tiempo_deteccion_s,tiempo_recuperacion_post_revert_s,rollback_method,degraded_ok,recovery_ok,http_ok,notes" > "${CSV}"

log "CSV de resultados: ${CSV}"
echo ""
echo "NOTA: El fallo y el rollback se inyectan por Git push sobre el mismo repo"
echo "      que observa ArgoCD. T1 y T3 se capturan por watch; T4 y T5 por sondeo."
echo ""

log "[preflight] validando syncPolicy.automated (selfHeal/prune)..."
validate_automated_policy_enabled
log "[preflight] syncPolicy.automated OK"
echo ""

run_test_c() {
  local run_id=$1 mode=$2

  log "[C | ${mode} | run ${run_id}] Preparando baseline..."
  ensure_baseline

  local broken_image_tag="broken-tag-$(date +%s)"
  local broken_image="nginx:${broken_image_tag}"
  local base_health base_sync
  IFS=$'\t' read -r base_health base_sync < <(read_app_status_fields)

  log "[C | ${mode} | run ${run_id}] Inyectando imagen rota por Git: ${broken_image}..."
  set_manifest_image "${broken_image}"
  log "[C | ${mode} | run ${run_id}] Haciendo commit del cambio roto..."
  git_no_prompt add "manifests/nginx-demo.yaml"
  git_no_prompt commit -m "scenario-c: inject broken image ${broken_image_tag}" >/dev/null
  local bad_commit_sha
  bad_commit_sha=$(git_no_prompt rev-parse HEAD)

  local t0_push_s
  t0_push_s=$(ts_now)
  log "[C | ${mode} | run ${run_id}] Haciendo push del commit roto..."
  git_push_with_timeout "HEAD:${REPO_BRANCH}"
  log "[C | ${mode} | run ${run_id}] Push del commit roto completado; esperando Degraded..."
  force_argocd_sync

  local t1_degraded_s=""
  local degraded_ok="true"
  if ! t1_degraded_s=$(watch_app_degraded_timestamp "${TIMEOUT_DEGRADED}" "${base_health}"); then
    degraded_ok="false"
  fi

  log "  [C2] Ejecutando git revert + git push..."
  local t2_revert_push_s
  t2_revert_push_s=$(ts_now)
  local rollback_method="git_revert"
  log "[C | ${mode} | run ${run_id}] Haciendo git revert del commit roto..."
  if ! git_no_prompt revert --no-edit "${bad_commit_sha}" >/dev/null; then
    rollback_method="git_revert_failed"
  else
    log "[C | ${mode} | run ${run_id}] Haciendo push del revert..."
    if ! git_push_with_timeout "HEAD:${REPO_BRANCH}"; then
      rollback_method="git_revert_failed"
    fi
  fi
  log "[C | ${mode} | run ${run_id}] Revert enviado; esperando Healthy+Synced..."
  force_argocd_sync

  local post_revert_health post_revert_sync
  IFS=$'\t' read -r post_revert_health post_revert_sync < <(read_app_status_fields)

  local t3_healthy_synced_s=""
  local recovery_ok="true"
  if ! t3_healthy_synced_s=$(watch_app_healthy_synced_timestamp "${TIMEOUT_RECOVERY}" "${post_revert_health}" "${post_revert_sync}"); then
    recovery_ok="false"
  fi

  local t4_pods_ready_s=""
  if ! t4_pods_ready_s=$(wait_pods_ready_timestamp "${ORIGINAL_REPLICAS}" "${TIMEOUT_PODS}"); then
    recovery_ok="false"
  fi

  local t5_http_first200_s=""
  local http_status_final="NA"
  local http_ok="false"
  local http_window=""
  if http_window=$(wait_http_200_streak_timestamp "${HTTP_CONSECUTIVE_200}" "${TIMEOUT_HTTP}"); then
    t5_http_first200_s="${http_window%|*}"
    http_status_final="${http_window#*|}"
    http_ok="true"
  else
    http_status_final="${http_window#*|}"
  fi

  local tiempo_deteccion_s=""
  local tiempo_recuperacion_post_revert_s=""
  if [ -n "${t1_degraded_s}" ] && [ -n "${t0_push_s}" ]; then
    tiempo_deteccion_s=$((t1_degraded_s - t0_push_s))
  fi
  if [ -n "${t3_healthy_synced_s}" ] && [ -n "${t2_revert_push_s}" ]; then
    tiempo_recuperacion_post_revert_s=$((t3_healthy_synced_s - t2_revert_push_s))
  fi

  local notes="git push injection on shared repo; http_status_final=${http_status_final}"
  [ "${degraded_ok}" = "false" ] && notes="${notes}; degraded timeout"
  [ "${recovery_ok}" = "false" ] && notes="${notes}; recovery timeout"
  [ "${http_ok}" = "false" ] && notes="${notes}; http censored or timeout"

  log "  → T1=${t1_degraded_s:-TIMEOUT} | T3=${t3_healthy_synced_s:-TIMEOUT} | pods=${t4_pods_ready_s:-TIMEOUT} | http=${t5_http_first200_s:-TIMEOUT} | rollback_method=${rollback_method}"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
    "${run_id}" "${mode}" "${broken_image_tag}" "${t0_push_s}" "${t1_degraded_s}" "${t2_revert_push_s}" "${t3_healthy_synced_s}" "${t4_pods_ready_s}" "${t5_http_first200_s}" "${tiempo_deteccion_s}" "${tiempo_recuperacion_post_revert_s}" "${rollback_method}" "${degraded_ok}" "${recovery_ok}" "${http_ok}" "${notes}" >> "${CSV}"

  if ! wait_app_healthy_synced_poll "${TIMEOUT_RECOVERY}"; then
    log "ERROR: la aplicación no volvió a Healthy+Synced tras la corrida"
    exit 1
  fi
}

echo "================================================================"
log "ESCENARIO C — Bloque normal (${NORMAL_RUNS} repeticiones)"
echo "================================================================"

if [ "${NORMAL_RUNS}" -gt 0 ]; then
  for i in $(seq 1 ${NORMAL_RUNS}); do
    run_test_c "${i}" "normal"
    [ "${i}" -lt "${NORMAL_RUNS}" ] && sleep "${COOLDOWN}"
  done
else
  log "Bloque normal omitido porque NORMAL_RUNS=0"
fi

echo ""
echo "================================================================"
log "ESCENARIO C — Bloque estrés (${STRESS_RUNS} repeticiones con carga de CPU)"
echo "================================================================"

if [ "${STRESS_RUNS}" -gt 0 ]; then
  bash "${STRESS_SCRIPT}" start
  for i in $(seq 1 ${STRESS_RUNS}); do
    run_test_c "$((NORMAL_RUNS + i))" "stress"
    [ "${i}" -lt "${STRESS_RUNS}" ] && sleep "${COOLDOWN}"
  done
  bash "${STRESS_SCRIPT}" stop
else
  log "Bloque estrés omitido porque STRESS_RUNS=0"
fi

echo ""
echo "================================================================"
log "ESCENARIO C completado. CSV: ${CSV}"
echo "================================================================"
