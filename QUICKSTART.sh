#!/usr/bin/env bash
# QUICKSTART.sh - Ejecuta esto primero!
# Instala todo automaticamente en 4 fases

set -euo pipefail

# Banner
clear
echo "╔════════════════════════════════════════════════════════╗"
echo "║  TFM GitOps Stack - Quick Start                        ║"
echo "║  Kind + ArgoCD + Nginx                                 ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "Este script ejecutará 4 fases:"
echo "  1. Fase 0 - Instalar dependencias"
echo "  2. Fase 1 - Crear cluster Kind + Nginx"  
echo "  3. Fase 2 - Instalar ArgoCD"
echo "  4. Fase 3 - Instalar Prometheus para metricas"
echo ""
echo "Tiempo total: ~4.7 horas"
echo ""
echo "Deseas continuar? (escribe 'si' para empezar):"
read -r START_SETUP

if [ "$START_SETUP" != "si" ]; then
    echo "Cancelado. Puedes ejecutar cada fase manualmente:"
    echo ""
    echo "  bash scripts/phase-0-dependencies.sh"
    echo "  bash scripts/phase-1-cluster.sh"
    echo "  bash scripts/phase-2-argocd.sh"
    echo "  bash scripts/phase-3-prometheus.sh"
    exit 0
fi

echo ""
echo "Iniciando..."
echo ""

# Función para ejecutar fase y manejar errores
run_phase() {
    local phase_num=$1
    local phase_script=$2
    local phase_name=$3
    
    echo "═══════════════════════════════════════════════════════"
    echo "Fase ${phase_num}: ${phase_name}"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    if [ ! -f "$phase_script" ]; then
        echo "ERROR: $phase_script no encontrado"
        exit 1
    fi
    
    bash "$phase_script"
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "Fase $phase_num completada exitosamente"
        return 0
    else
        echo ""
        echo "Error en Fase $phase_num"
        return 1
    fi
}

# Ejecutar fases en secuencia
run_phase 0 "scripts/phase-0-dependencies.sh" "Dependencias" || exit 1
echo ""
echo "Pausa: Presiona ENTER para continuar a Fase 1"
read -r CONTINUE

run_phase 1 "scripts/phase-1-cluster.sh" "Cluster Kind + Nginx" || exit 1
echo ""
echo "Pausa: Presiona ENTER para continuar a Fase 2"
read -r CONTINUE

run_phase 2 "scripts/phase-2-argocd.sh" "ArgoCD" || exit 1
echo ""
echo "Pausa: Presiona ENTER para continuar a Fase 3"
read -r CONTINUE

run_phase 3 "scripts/phase-3-prometheus.sh" "Prometheus Metrics" || exit 1

# Summary
echo ""
echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║             SETUP COMPLETADO EXITOSAMENTE!             ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "Estado actual:"
echo "  Cluster:     gitops-lab (Kind)"
echo "  Namespace:   tfm-app"
echo "  Nginx:       http://localhost:30080"
echo "  ArgoCD:      https://localhost:30443"
echo "  Prometheus:  http://localhost:9090 (via port-forward)"
echo ""
echo "Proximos pasos:"
echo "  1. Crea repositorio en GitHub"
echo "  2. Sube manifiestos a: github.com/TU_USUARIO/TU_REPO"
echo "  3. Actualiza argocd/application.yaml con tu repo"
echo "  4. Aplica: kubectl apply -f argocd/application.yaml"
echo "  5. Verifica en: https://localhost:30443"
echo "  6. Activa Prometheus UI: kubectl -n argocd port-forward svc/prometheus 9090:9090"
echo ""
echo "Documentacion:"
echo "  README.md          - Guia principal"
echo "  EXPERIMENTS.md     - Como experimentar con selfHeal"
echo "  GITHUB_SETUP.md    - Como estructurar tu repo"
echo ""
echo "Comandos utiles:"
echo "  kubectl get pods -n tfm-app"
echo "  kubectl get app -n argocd"
echo "  kubectl logs -f -n argocd deployment/argocd-server"
echo ""
echo "Listo para experimentar con GitOps!"
echo ""
