#!/bin/bash
# deploy.sh - Deploys using a static IP for Ingress and a specified image tag.
# Usage: ./deploy.sh [IMAGE_TAG]
# If IMAGE_TAG is not provided, it defaults to "latest".

set -euo pipefail
echo " "
echo "======================================================================="
echo "==> Running deploy.sh - Deploying IoT system using static Ingress IP..."

# Determine image tag from first argument, default to "latest"
IMAGE_TAG="${1:-latest}"
echo "==> Deploying with image tag: ${IMAGE_TAG}"

export KUBECONFIG=~/.kube/config
export DOCKER_DEFAULT_PLATFORM=linux/amd64

# --- You MUST know your static IP name and value here ---
# Ideally, get this from terraform output or configuration
INGRESS_STATIC_IP_NAME="iot-system-ingress-ip"
# Replace with your actual static IP address
INGRESS_STATIC_IP_VALUE="34.111.177.125" 
HOST_VALUE="iot.${INGRESS_STATIC_IP_VALUE}.nip.io"
# ---

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
    --set ingress.staticIpName=$INGRESS_STATIC_IP_NAME \
    --set ingress.host=$HOST_VALUE \
    --set iotService.image.tag=${IMAGE_TAG} \
    --set webBackend.image.tag=${IMAGE_TAG} \
    --set webFrontend.image.tag=${IMAGE_TAG} \
    --set testPub.image.tag=${IMAGE_TAG}

echo "==> Waiting for components to be ready..."
components=("mosquitto" "iotService" "web-backend" "web-frontend" "test-pub")
for component in "${components[@]}"; do
  echo "==> Waiting for $component..."
  kubectl wait --for=condition=ready pod -l app=$component -n iot-system --timeout=120s || \
    echo "Timed out waiting for $component"
done

echo "==> Deployment complete. Verifying all pods..."
kubectl get pods -n iot-system

echo ""
echo "==> Access your services at:"
echo "Web Frontend: http://${HOST_VALUE}"
echo "Web Backend API: http://${HOST_VALUE}/api"

echo ""
echo "==> DONE! Your IoT system is deployed on GKE."

echo ""
echo "==> Getting external IP for mosquitto:"
kubectl get service mosquitto -n iot-system

echo ""
echo "==> Tailing logs from iot-service (Ctrl+C to exit):"
kubectl logs -l app=iotService -n iot-system
