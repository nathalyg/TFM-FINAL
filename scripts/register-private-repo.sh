#!/bin/bash
# register-private-repo.sh
# Registra credenciales del repositorio privado en ArgoCD desde .env
# Uso: bash scripts/register-private-repo.sh

set -euo pipefail

# Verificar que .env existe
if [ ! -f ".env" ]; then
  echo "════════════════════════════════════════════════════════"
  echo "Archivo .env no encontrado"
  echo "════════════════════════════════════════════════════════"
  echo ""
  echo "Crea un archivo .env en la raíz del proyecto:"
  echo ""
  echo "  GITHUB_USER=\"tu-usuario-github\""
  echo "  GITHUB_TOKEN=\"ghp_tu_token_fino\""
  echo "  REPO_URL=\"https://github.com/tu-usuario/tfm-gitops-setup.git\""
  echo ""
  echo "O copia desde .env.example:"
  echo "  cp .env.example .env"
  echo "  # Luego edita .env con tus datos"
  echo ""
  exit 1
fi

# Cargar variables desde .env
set +u  # Permitir variables indefinidas temporalmente
source .env
set -u

# Validar que las variables están presentes
if [ -z "${GITHUB_USER:-}" ] || [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${REPO_URL:-}" ]; then
  echo "════════════════════════════════════════════════════════"
  echo "Variables incompletas en .env"
  echo "════════════════════════════════════════════════════════"
  echo ""
  echo "Asegúrate de que .env contiene:"
  echo "  GITHUB_USER=..."
  echo "  GITHUB_TOKEN=..."
  echo "  REPO_URL=..."
  echo ""
  exit 1
fi

echo "════════════════════════════════════════════════════════"
echo "Registrando repositorio privado en ArgoCD"
echo "════════════════════════════════════════════════════════"
echo ""
echo "Usuario:     $GITHUB_USER"
echo "Repo URL:    $REPO_URL"
echo ""

# Crear Secret
echo "[1/3] Creando Secret en ArgoCD..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-tfm-private
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${REPO_URL}
  username: ${GITHUB_USER}
  password: ${GITHUB_TOKEN}
EOF

if [ $? -eq 0 ]; then
  echo "Secret creado"
else
  echo "Error al crear Secret"
  exit 1
fi
echo ""

# Esperar a que se propague
echo "[2/3] Esperando propagación del Secret..."
sleep 3

# Forzar refresh de la app
echo "[3/3] Forzando refresh de la Application..."
kubectl annotate app nginx-demo -n argocd argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true

echo "✓ Refresh forzado"
echo ""

# Mostrar estado
echo "════════════════════════════════════════════════════════"
echo "Estado de la Application:"
echo "════════════════════════════════════════════════════════"
kubectl get app -n argocd
echo ""

# Verificar si está sincronizado
STATUS=$(kubectl get app nginx-demo -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
HEALTH=$(kubectl get app nginx-demo -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

echo "Sync Status:   $STATUS"
echo "Health Status: $HEALTH"
echo ""

if [ "$STATUS" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
  echo "Application sincronizada correctamente"
else
  echo "Application aún no está sincronizada"
  echo "Esperando a que ArgoCD procese el cambio..."
  sleep 10
  kubectl describe app nginx-demo -n argocd | grep -A 10 "Conditions\|Errors" || true
fi
echo ""
