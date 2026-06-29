#!/usr/bin/env bash
# cleanup.sh — Limpiar recursos de Kind y ArgoCD
# ADVERTENCIA: Esto ELIMINA el cluster Kind y todos los datos
# Uso: bash scripts/cleanup.sh

set -euo pipefail

# Configuración
CLUSTER_NAME="gitops-lab"

echo "ADVERTENCIA: Esto eliminará el cluster ${CLUSTER_NAME} y TODOS sus datos"
echo ""
echo "¿Estás seguro? Escribe 'sí' para confirmar:"
read -r CONFIRM

if [ "$CONFIRM" != "sí" ]; then
    echo "Cancelado."
    exit 0
fi

echo ""
echo "Eliminando cluster ${CLUSTER_NAME}..."

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    kind delete cluster --name ${CLUSTER_NAME}
    echo "Cluster eliminado"
else
    echo "Cluster no encontrado"
fi

echo ""
echo "Limpiando kubeconfig..."
if [ -f ~/.kube/config ]; then
    # Respaldar
    cp ~/.kube/config ~/.kube/config.backup.$(date +%s)
    rm -f ~/.kube/config
    echo "kubeconfig eliminado (backup guardado)"
fi

echo ""
echo "Cleanup completado"
echo ""
echo "Para empezar de nuevo:"
echo "  bash scripts/phase-0-dependencies.sh"
echo ""
