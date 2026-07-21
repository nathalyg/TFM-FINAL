#!/usr/bin/env bash
# phase-0-dependencies.sh — Instalación de dependencias base
# Ubuntu 22.04 LTS (Jammy) | t3.medium
# Uso: bash scripts/phase-0-dependencies.sh

set -euo pipefail

# Versiones
KIND_VERSION="v0.23.0"
KUBECTL_VERSION="v1.30.2"
HELM_VERSION="v3.14.2"
ARGOCD_VERSION="v2.11.3"

# Ejecuta Docker con fallback a sudo mientras la sesión actual aún no refleja el grupo docker.
docker_ready() {
    if docker info &>/dev/null; then
        return 0
    fi

    if sudo docker info &>/dev/null; then
        return 0
    fi

    return 1
}

# Función para esperar a que Docker quede listo
wait_for_docker() {
    local max_attempts=30
    local attempt=0
    echo "Esperando Docker..."
    while [ $attempt -lt $max_attempts ]; do
        if docker_ready; then
            echo "Docker listo"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo "ERROR: Docker no disponible despues de 30 segundos"
    return 1
}

# Función para verificar si un comando existe
command_exists() {
    command -v "$1" &>/dev/null
}

echo "================================"
echo "  FASE 0: Dependencias Base"
echo "================================"
echo ""

# 1. Dependencias base del sistema
echo "[1/7] Actualizando sistema..."
sudo apt-get update -qq
sudo apt-get upgrade -y -qq
sudo apt-get install -y -qq \
    curl wget git apt-transport-https \
    ca-certificates gnupg lsb-release \
    python3 python3-pip python3-venv jq \
    net-tools build-essential

echo "Dependencias base instaladas"
echo ""

# 2. Docker
echo "[2/7] Docker..."
if command_exists docker; then
    echo "Docker ya instalado ($(docker --version))"
else
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"
    wait_for_docker
    echo "Docker instalado"
    echo "Abre una nueva sesion o ejecuta: newgrp docker"
fi
echo ""

# 3. kubectl
echo "[3/7] kubectl v${KUBECTL_VERSION}..."
if command_exists kubectl; then
    echo "kubectl ya instalado ($(kubectl version --client --short 2>/dev/null || echo "version desconocida"))"
else
    curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
    echo "kubectl instalado"
fi
echo ""

# 4. Kind
echo "[4/7] Kind v${KIND_VERSION}..."
if command_exists kind; then
    echo "Kind ya instalado ($(kind version 2>/dev/null))"
else
    curl -sLo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    sudo install -o root -g root -m 0755 kind /usr/local/bin/kind
    rm -f kind
    echo "Kind instalado"
fi
echo ""

# 5. Helm
echo "[5/7] Helm v${HELM_VERSION}..."
if command_exists helm; then
    echo "Helm ya instalado ($(helm version --short 2>/dev/null))"
else
    curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz | \
        tar xz -O linux-amd64/helm | sudo tee /usr/local/bin/helm >/dev/null
    sudo chmod +x /usr/local/bin/helm
    echo "Helm instalado"
fi
echo ""

# 6. ArgoCD CLI (solo CLI, no el servidor)
echo "[6/7] ArgoCD CLI v${ARGOCD_VERSION}..."
if command_exists argocd; then
    echo "ArgoCD CLI ya instalado"
else
    curl -sLo /tmp/argocd \
        "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"
    sudo install -o root -g root -m 0755 /tmp/argocd /usr/local/bin/argocd
    rm -f /tmp/argocd
    echo "ArgoCD CLI instalado"
fi
echo ""

# 7. Python environment
echo "[7/7] Python environment..."
if [ ! -d ~/.venv ]; then
    python3 -m venv ~/.venv
    source ~/.venv/bin/activate
    pip install --upgrade pip setuptools wheel -q
    pip install pyyaml jinja2 matplotlib pandas numpy scipy requests -q
    echo "Python venv creado (usar con: source ~/.venv/bin/activate)"
else
    echo "Python venv ya existe"
fi
echo ""

# Resumen
echo "================================"
echo "  FASE 0 COMPLETADA"
echo "================================"
echo ""
echo "Versiones instaladas:"
echo "  Docker:    $(docker --version)"
echo "  kubectl:   $(kubectl version --client --short 2>/dev/null || echo 'v' ${KUBECTL_VERSION})"
echo "  Kind:      $(kind version 2>/dev/null || echo 'v'${KIND_VERSION})"
echo "  Helm:      $(helm version --short 2>/dev/null || echo 'v'${HELM_VERSION})"
echo "  ArgoCD:    $(argocd version 2>/dev/null | head -1 || echo 'v'${ARGOCD_VERSION})"
echo "  Python:    $(python3 --version)"
echo ""
echo "SIGUIENTE: Ejecuta bash scripts/phase-1-cluster.sh"
echo ""
