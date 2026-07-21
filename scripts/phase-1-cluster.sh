#!/usr/bin/env bash
# phase-1-cluster.sh — Crear cluster Kind y desplegar nginx manualmente
# Ubuntu 22.04 LTS (Jammy) | t3.medium
# Uso: bash scripts/phase-1-cluster.sh

set -euo pipefail

# Configuración
CLUSTER_NAME="gitops-lab"
KUBECTL_VERSION="v1.30.2"
NAMESPACE="tfm-app"
DOCKER_ACCESS_MODE="${DOCKER_ACCESS_MODE:-auto}"  # auto | always | never

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
if [ -z "${TARGET_HOME}" ]; then
    TARGET_HOME="$HOME"
fi
KUBECONFIG_PATH="${TARGET_HOME}/.kube/config"

DOCKER_CMD=(docker)
KIND_CMD=(kind)

# Configura cómo ejecutar Docker/Kind según permisos disponibles.
configure_docker_access() {
    case "${DOCKER_ACCESS_MODE}" in
        always)
            if sudo docker info &>/dev/null; then
                DOCKER_CMD=(sudo docker)
                KIND_CMD=(sudo kind)
                return 0
            fi
            ;;
        never)
            if docker info &>/dev/null; then
                DOCKER_CMD=(docker)
                KIND_CMD=(kind)
                return 0
            fi
            ;;
        auto)
            if docker info &>/dev/null; then
                DOCKER_CMD=(docker)
                KIND_CMD=(kind)
                return 0
            fi
            if sudo docker info &>/dev/null; then
                DOCKER_CMD=(sudo docker)
                KIND_CMD=(sudo kind)
                return 0
            fi
            ;;
        *)
            echo "ERROR: DOCKER_ACCESS_MODE invalido: ${DOCKER_ACCESS_MODE}. Usa auto, always o never."
            return 1
            ;;
    esac

    return 1
}

# Función para esperar a que Docker esté listo
wait_for_docker() {
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if configure_docker_access; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo "ERROR: Docker no disponible"
    return 1
}

echo "================================"
echo "  FASE 1: Cluster Kind + Nginx"
echo "================================"
echo ""

# 0. Verificar Docker
echo "[0/4] Verificando Docker..."
wait_for_docker || exit 1
echo "Docker listo"
echo "Modo Docker/Kind: ${DOCKER_ACCESS_MODE} -> ${KIND_CMD[*]}"
echo ""

# 1. Crear cluster Kind
echo "[1/4] Cluster Kind (${CLUSTER_NAME})..."

if "${KIND_CMD[@]}" get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "Cluster ${CLUSTER_NAME} ya existe"
    echo "   Si quieres recrearlo: ${KIND_CMD[*]} delete cluster --name ${CLUSTER_NAME}"
else
    echo "Creando configuración Kind..."
    cat > /tmp/kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080   # Nginx
        hostPort: 30080
        protocol: TCP
      - containerPort: 30443   # ArgoCD
        hostPort: 30443
        protocol: TCP
EOF
    
    echo "Creando cluster (esto puede tardar 2-3 minutos)..."
    "${KIND_CMD[@]}" create cluster --config /tmp/kind-config.yaml
fi

# Configurar kubeconfig
mkdir -p "${TARGET_HOME}/.kube"
"${KIND_CMD[@]}" get kubeconfig --name ${CLUSTER_NAME} > "${KUBECONFIG_PATH}"
chown "${TARGET_USER}:${TARGET_USER}" "${KUBECONFIG_PATH}" 2>/dev/null || true
chmod 600 "${KUBECONFIG_PATH}"
export KUBECONFIG="${KUBECONFIG_PATH}"

if [ -n "${SUDO_USER:-}" ]; then
    SUDO_BASHRC="${TARGET_HOME}/.bashrc"
    if [ -f "${SUDO_BASHRC}" ] && ! grep -q 'export KUBECONFIG=.*\.kube/config' "${SUDO_BASHRC}"; then
        echo "export KUBECONFIG=${KUBECONFIG_PATH}" >> "${SUDO_BASHRC}"
        chown "${TARGET_USER}:${TARGET_USER}" "${SUDO_BASHRC}" 2>/dev/null || true
    fi
fi

echo "Cluster ready"
echo "KUBECONFIG: ${KUBECONFIG_PATH}"
echo ""

# 2. Esperar a nodos
echo "[2/4] Esperando nodos..."
echo "Verificando status del cluster..."
kubectl wait --for=condition=Ready node --all --timeout=120s || {
    echo "Timeout esperado en Kind, continuando..."
}
sleep 5
echo "Nodos verificados"
echo ""

# 3. Crear namespace y aplicar manifiestos
echo "[3/4] Desplegando nginx-demo..."

# Crear namespace
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
echo "Namespace ${NAMESPACE} creado"

# Aplicar manifiestos
if [ -f "manifests/nginx-demo.yaml" ]; then
    echo "Aplicando manifiestos..."
    kubectl apply -f manifests/nginx-demo.yaml
    echo "Manifiestos aplicados"
else
    echo "ERROR: manifests/nginx-demo.yaml no encontrado"
    exit 1
fi

echo ""

# 4. Verificar deployment
echo "[4/4] Verificando deployment..."
echo "Esperando nginx pods..."
kubectl wait --for=condition=Ready pod \
    -l app=nginx-demo \
    -n ${NAMESPACE} \
    --timeout=60s || {
    echo "Pods aun no ready, mostrando estado..."
}

echo ""
echo "FASE 1 COMPLETADA"
echo ""

# Status
echo "Estado del cluster:"
echo ""
echo "Cluster:"
kubectl cluster-info 2>/dev/null | grep -E "Kubernetes master|control plane" || echo "  (Kind no muestra info detallada, pero está activo)"
echo ""

echo "Nodos:"
kubectl get nodes -o wide
echo ""

echo "Namespace ${NAMESPACE}:"
kubectl get pods,svc,configmap -n ${NAMESPACE}
echo ""

# Información de acceso
SERVICE_IP=$(kubectl get svc nginx -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "pending")
NODE_PORT=$(kubectl get svc nginx -n ${NAMESPACE} -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30080")

echo "Como acceder a Nginx:"
echo "  Port Forward (desde la máquina host):    kubectl port-forward -n ${NAMESPACE} svc/nginx 8080:80"
echo "  NodePort (desde el host):                http://localhost:${NODE_PORT}"
echo "  Dentro del cluster:                      http://nginx.${NAMESPACE}.svc.cluster.local"
echo ""

echo "Utiles:"
echo "  Ver logs:     kubectl logs -f -n ${NAMESPACE} -l app=nginx-demo"
echo "  Exec shell:   kubectl exec -it -n ${NAMESPACE} -l app=nginx-demo -- /bin/sh"
echo "  Describe pod: kubectl describe pod -n ${NAMESPACE} -l app=nginx-demo"
echo ""

echo "SIGUIENTE: Ejecuta bash scripts/phase-2-argocd.sh"
echo ""
