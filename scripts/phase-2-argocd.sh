#!/usr/bin/env bash
# phase-2-argocd.sh — Instalar ArgoCD y crear Application
# Ubuntu 24.04 LTS | t3.medium
# Uso: bash scripts/phase-2-argocd.sh

set -euo pipefail

# Configuración
ARGOCD_VERSION="v2.11.3"
NAMESPACE_ARGOCD="argocd"
NAMESPACE_APP="tfm-app"

echo "================================"
echo "  FASE 2: ArgoCD + Application"
echo "================================"
echo ""

# 1. Crear namespace ArgoCD
echo "[1/5] Creando namespace ArgoCD..."
kubectl create namespace ${NAMESPACE_ARGOCD} --dry-run=client -o yaml | kubectl apply -f -
echo "Namespace ${NAMESPACE_ARGOCD} creado"
echo ""

# 2. Instalar ArgoCD
echo "[2/5] Instalando ArgoCD v${ARGOCD_VERSION}..."
echo "Descargando manifiestos (esto puede tardar 1-2 minutos)..."

kubectl apply -n ${NAMESPACE_ARGOCD} \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
    --wait=false

echo "Manifiestos aplicados"
echo ""

# 3. Esperar a que ArgoCD esté ready
echo "[3/5] Esperando ArgoCD..."
echo "Esperando deployment/argocd-server (máximo 5 minutos)..."

kubectl wait --for=condition=Available deployment/argocd-server \
    -n ${NAMESPACE_ARGOCD} \
    --timeout=300s 2>/dev/null || {
    echo "Timeout pero continuando (puede estar iniciando aun)..."
}

# Esperar secret de admin
echo "Esperando creación del secret (máximo 2 minutos)..."
for i in {1..60}; do
    if kubectl get secret argocd-initial-admin-secret -n ${NAMESPACE_ARGOCD} &>/dev/null; then
        break
    fi
    sleep 2
done

echo "ArgoCD instalado"
echo ""

# 4. Configurar acceso NodePort
echo "[4/5] Configurando acceso NodePort..."
kubectl patch svc argocd-server -n ${NAMESPACE_ARGOCD} \
    -p '{"spec":{"type":"NodePort","ports":[{"port":443,"targetPort":8080,"nodePort":30443}]}}' \
    2>/dev/null || echo "Servicio ya esta configurado"

echo "ArgoCD accesible en puerto 30443"
echo ""

# 5. Crear Application de ArgoCD
echo "[5/5] Creando Application de ArgoCD..."

# Crear o usar Application local
if [ -f "argocd/application.yaml" ]; then
    echo "Aplicando Application desde argocd/application.yaml..."
    kubectl apply -f argocd/application.yaml
    echo "Application creada/actualizada"
else
    echo "argocd/application.yaml no encontrado"
    echo "   Crea el archivo con los manifiestos de tu repositorio."
    echo "   Puedes usar este template:"
    cat > /tmp/app-template.yaml <<'APPEOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nginx-demo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/TU_USUARIO/TU_REPO
    targetRevision: HEAD
    path: manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: tfm-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
APPEOF
    echo ""
    echo "Template guardado en /tmp/app-template.yaml"
    echo "Aplicando template de fallback..."
    kubectl apply -f /tmp/app-template.yaml
    echo "Application creada desde template"
fi

# Garantia idempotente: deja automated.selfHeal/prune activos aunque el YAML venga distinto.
if kubectl get application nginx-demo -n ${NAMESPACE_ARGOCD} >/dev/null 2>&1; then
    echo "Forzando syncPolicy.automated (selfHeal=true, prune=true)..."
    kubectl patch application nginx-demo -n ${NAMESPACE_ARGOCD} --type merge \
      -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":true}}}}' >/dev/null
    echo "syncPolicy.automated garantizado"
fi

echo ""
echo "FASE 2 COMPLETADA"
echo ""

# Información de acceso
echo "Acceso a ArgoCD:"
echo ""

# Obtener contraseña
if kubectl get secret argocd-initial-admin-secret -n ${NAMESPACE_ARGOCD} &>/dev/null; then
    ARGOCD_PASS=$(kubectl -n ${NAMESPACE_ARGOCD} get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [ -n "$ARGOCD_PASS" ]; then
        echo "Credenciales ArgoCD:"
        echo "  Usuario:  admin"
        echo "  Password: ${ARGOCD_PASS}"
        echo ""
    fi
fi

# IP del host
PUBLIC_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")
if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "" ]; then
    PUBLIC_IP="localhost"
fi

echo "URLs:"
echo "  ArgoCD UI:        https://${PUBLIC_IP}:30443"
echo "  Nginx (si sync):  http://${PUBLIC_IP}:30080"
echo ""

echo "Utiles:"
echo "  Ver Applications:    kubectl get applications -n ${NAMESPACE_ARGOCD}"
echo "  Ver status:          kubectl describe app nginx-demo -n ${NAMESPACE_ARGOCD}"
echo "  Forzar sync:         argocd app sync nginx-demo"
echo "  Logs ArgoCD:         kubectl logs -f -n ${NAMESPACE_ARGOCD} -l app.kubernetes.io/name=argocd-server"
echo "  Port-forward:        kubectl port-forward -n ${NAMESPACE_ARGOCD} svc/argocd-server 8443:443"
echo ""

echo "Stack completamente desplegado"
echo ""
echo "Estado actual:"
echo ""

echo "Pods ArgoCD:"
kubectl get pods -n ${NAMESPACE_ARGOCD} -o wide
echo ""

echo "Namespace ${NAMESPACE_APP}:"
kubectl get pods,svc -n ${NAMESPACE_APP} -o wide
echo ""

echo "SIGUIENTE:"
echo "  1. Sube ~/gitops-lab/ a tu repositorio GitHub"
echo "  2. Actualiza argocd/application.yaml con tu repo"
echo "  3. Aplica: kubectl apply -f argocd/application.yaml"
echo "  4. Accede a ArgoCD en https://${PUBLIC_IP}:30443"
echo ""
