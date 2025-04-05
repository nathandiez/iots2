#!/bin/bash
# deploy.sh - Deploys IoT system on AKS with configured Ingress
# Usage: ./deploy.sh [IMAGE_TAG]
# If IMAGE_TAG is not provided, it defaults to "latest".

set -euo pipefail
echo " "
echo "======================================================================="
echo "==> Running deploy.sh - Deploying IoT system on AKS..."

# Determine image tag from first argument, default to "latest"
IMAGE_TAG="${1:-latest}"
echo "==> Deploying with image tag: ${IMAGE_TAG}"

export KUBECONFIG=~/.kube/config
export DOCKER_DEFAULT_PLATFORM=linux/amd64

# Get AKS ingress IP from the existing service
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ -z "$INGRESS_IP" ]; then
  echo "ERROR: Ingress controller doesn't have an external IP assigned."
  echo "       Run 'kubectl get svc -n ingress-nginx ingress-nginx-controller' to check status."
  exit 1
fi

# Set the host value for ingress
HOST_VALUE="iot.${INGRESS_IP}.nip.io"
echo "==> Using host: ${HOST_VALUE}"

echo "==> Pulling Docker images with tag ${IMAGE_TAG}..."
docker pull nathandiez12/web-frontend:${IMAGE_TAG}
docker pull nathandiez12/web-backend:${IMAGE_TAG}
docker pull nathandiez12/iot-service:${IMAGE_TAG}
docker pull nathandiez12/test-pub:${IMAGE_TAG}
docker pull eclipse-mosquitto:2.0.18
echo "==> All images pulled successfully"

echo "==> Deploying all components with Helm..."
helm upgrade --install iot-system ./charts/iot-system -n iot-system \
    --set apiCredentials.apiKey=V2Rvl3oopKZovBFElU83BhbwNqr6WaAd \
    --set mosquitto.config.allowAnonymous=false \
    --set mosquitto.credentials.iotServicePassword=pw123 \
    --set mosquitto.credentials.testPubPassword=pw123 \
    --set ingress.useTLS=false \
    --set ingress.className=nginx \
    --set ingress.host=$HOST_VALUE \
    --set iotService.image.tag=${IMAGE_TAG} \
    --set webBackend.image.tag=${IMAGE_TAG} \
    --set webFrontend.image.tag=${IMAGE_TAG} \
    --set testPub.image.tag=${IMAGE_TAG}

echo "==> Waiting for components to be ready..."
components=("mosquitto" "web-backend" "web-frontend" "timescaledb")
for component in "${components[@]}"; do
  echo "==> Waiting for $component..."
  kubectl wait --for=condition=ready pod -l app=$component -n iot-system --timeout=120s || \
    echo "Timed out waiting for $component"
done

# Special handling for iot-service component which might have a different label
echo "==> Waiting for iot-service..."
kubectl wait --for=condition=ready pod -l app=iotService -n iot-system --timeout=120s || \
  echo "Timed out waiting for iot-service"

echo "==> Deployment complete. Verifying all pods..."
kubectl get pods -n iot-system

echo ""
echo "==> Access your services at:"
echo "Web Frontend: http://${HOST_VALUE}"
echo "Web Backend API: http://${HOST_VALUE}/api"

echo ""
echo "==> DONE! Your IoT system is deployed on AKS."

echo ""
echo "==> Getting external IP for mosquitto:"
kubectl get service mosquitto -n iot-system

echo ""
echo "==> Tailing logs from iot-service (Ctrl+C to exit):"
kubectl logs -l app=iotService -n iot-system -f