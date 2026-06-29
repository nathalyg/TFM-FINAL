#!/bin/bash
# run-scenario-c-local.sh
# Ejecuta scenario-c.sh en una worktree temporal y una rama temporal remota.
# Aísla por completo el experimento de la rama main principal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP="nginx-demo"
ARGOCD_NS="argocd"
DEFAULT_MAIN_BRANCH="main"

TS="$(date +%Y%m%d-%H%M%S)"
BRANCH_NAME="scenario-c-exp-${TS}"
WORKTREE_DIR="$(mktemp -d "/tmp/tfm-scenario-c-${TS}-XXXXXX")"
TARGET_REVISION_ORIGINAL=""
GIT_PUSH_TARGET="origin"
PERSISTENT_RESULTS_DIR="${REPO_ROOT}/experiments/pruebas_reales/results"

log() { echo "[$(date +%H:%M:%S)] $*"; }

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

patch_target_revision() {
  local branch_name=$1
  kubectl patch application "${APP}" -n "${ARGOCD_NS}" --type merge -p "{\"spec\":{\"source\":{\"targetRevision\":\"${branch_name}\"}}}" >/dev/null
}

current_target_revision() {
  kubectl get application "${APP}" -n "${ARGOCD_NS}" -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null || echo "${DEFAULT_MAIN_BRANCH}"
}

push_branch_to_origin() {
  local push_ref="HEAD:refs/heads/${BRANCH_NAME}"
  if ! env GIT_TERMINAL_PROMPT=0 timeout 180s git -C "${WORKTREE_DIR}" push "${GIT_PUSH_TARGET}" "${push_ref}" >/dev/null; then
    log "ERROR: no se pudo crear la rama temporal remota ${BRANCH_NAME}"
    exit 1
  fi
}

delete_remote_branch() {
  env GIT_TERMINAL_PROMPT=0 timeout 180s git -C "${REPO_ROOT}" push "${GIT_PUSH_TARGET}" ":refs/heads/${BRANCH_NAME}" >/dev/null 2>&1 || true
}

copy_results_to_repo() {
  local source_results_dir="${WORKTREE_DIR}/experiments/pruebas_reales/results"
  if [ ! -d "${source_results_dir}" ]; then
    log "No se encontró carpeta de resultados para copiar"
    return 0
  fi

  mkdir -p "${PERSISTENT_RESULTS_DIR}"
  cp -a "${source_results_dir}/." "${PERSISTENT_RESULTS_DIR}/"
  log "Resultados copiados a ${PERSISTENT_RESULTS_DIR}"
}

cleanup() {
  set +e
  if [ -n "${TARGET_REVISION_ORIGINAL}" ]; then
    patch_target_revision "${TARGET_REVISION_ORIGINAL}" >/dev/null 2>&1 || true
  fi
  delete_remote_branch
  git -C "${REPO_ROOT}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  git -C "${REPO_ROOT}" branch -D "${BRANCH_NAME}" >/dev/null 2>&1 || true
  rm -rf "${WORKTREE_DIR}" >/dev/null 2>&1 || true
}

print_final_state() {
  log "Estado final de ArgoCD:"
  kubectl get application "${APP}" -n "${ARGOCD_NS}" -o jsonpath='  sync={.status.sync.status} health={.status.health.status} targetRevision={.spec.source.targetRevision}{"\n"}' 2>/dev/null || true
}

trap cleanup EXIT

load_git_push_auth

log "Preparando worktree aislada en ${WORKTREE_DIR}"
git -C "${REPO_ROOT}" fetch origin "${DEFAULT_MAIN_BRANCH}" --prune >/dev/null
git -C "${REPO_ROOT}" worktree add -b "${BRANCH_NAME}" "${WORKTREE_DIR}" "origin/${DEFAULT_MAIN_BRANCH}" >/dev/null

if [ -f "${REPO_ROOT}/.env" ]; then
  cp "${REPO_ROOT}/.env" "${WORKTREE_DIR}/.env"
fi

TARGET_REVISION_ORIGINAL="$(current_target_revision)"
log "ArgoCD targetRevision actual: ${TARGET_REVISION_ORIGINAL}"

log "Creando rama temporal remota: ${BRANCH_NAME}"
push_branch_to_origin

log "Cambiando ArgoCD a la rama temporal: ${BRANCH_NAME}"
patch_target_revision "${BRANCH_NAME}"

log "Lanzando scenario-c.sh en la worktree aislada"
cd "${WORKTREE_DIR}/experiments/pruebas_reales"
NORMAL_RUNS="${NORMAL_RUNS:-30}" STRESS_RUNS="${STRESS_RUNS:-10}" REPO_BRANCH="${BRANCH_NAME}" bash scenario-c.sh "$@"

copy_results_to_repo
print_final_state
