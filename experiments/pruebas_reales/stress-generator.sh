#!/bin/bash
# stress-generator.sh
# Genera carga de CPU y memoria en el cluster Kind para simular condiciones de estrés.
# Despliega pods que consumen recursos durante las pruebas de estrés.

set -euo pipefail

NAMESPACE="tfm-app"
STRESS_LABEL="tfm-stress"
STRESS_JOB="tfm-stress-load"

log() { echo "[$(date +%H:%M:%S)] [STRESS] $*"; }

# ─────────────────────────────────────────────
# start: Lanza pods de estrés en el cluster
# ─────────────────────────────────────────────
start() {
  log "Iniciando carga de estrés en namespace ${NAMESPACE}..."

  # Eliminar job anterior si existía
  kubectl delete job "${STRESS_JOB}" -n "${NAMESPACE}" --ignore-not-found &>/dev/null

  # Crear Job con 4 pods que queman CPU
  kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${STRESS_JOB}
  namespace: ${NAMESPACE}
  labels:
    role: ${STRESS_LABEL}
spec:
  parallelism: 4
  completions: 4
  template:
    metadata:
      labels:
        role: ${STRESS_LABEL}
    spec:
      restartPolicy: OnFailure
      containers:
      - name: cpu-burner
        image: alpine:3.18
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "Stress pod iniciado"
            # Quema CPU con 2 procesos paralelos
            while true; do
              dd if=/dev/zero of=/dev/null bs=64k count=1024 2>/dev/null
            done &
            while true; do
              dd if=/dev/zero of=/dev/null bs=64k count=1024 2>/dev/null
            done
        resources:
          requests:
            cpu: "500m"
            memory: "64Mi"
          limits:
            cpu: "900m"
            memory: "128Mi"
EOF

  # Esperar a que los pods estén en Running (máx 30s)
  local elapsed=0
  while [ "${elapsed}" -lt 30 ]; do
    local running
    running=$(kubectl get pods -n "${NAMESPACE}" -l "role=${STRESS_LABEL}" \
      --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${running}" -ge 2 ]; then
      log "Carga de estrés activa (${running} pods corriendo)"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  log "ADVERTENCIA: pods de estrés tardaron en iniciar, continuando de todas formas..."
}

# ─────────────────────────────────────────────
# stop: Elimina pods de estrés
# ─────────────────────────────────────────────
stop() {
  log "Deteniendo carga de estrés..."
  kubectl delete job "${STRESS_JOB}" -n "${NAMESPACE}" --ignore-not-found &>/dev/null
  # Eliminar pods terminados del job
  kubectl delete pods -n "${NAMESPACE}" -l "role=${STRESS_LABEL}" \
    --ignore-not-found &>/dev/null || true
  log "Carga de estrés detenida."
}

# ─────────────────────────────────────────────
# status: Muestra estado de los pods de estrés
# ─────────────────────────────────────────────
status() {
  local running
  running=$(kubectl get pods -n "${NAMESPACE}" -l "role=${STRESS_LABEL}" \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "${running}"
}

# Ejecutar según argumento
case "${1:-start}" in
  start)  start ;;
  stop)   stop  ;;
  status) status ;;
  *)
    echo "Uso: $0 {start|stop|status}"
    exit 1
    ;;
esac
