#!/bin/bash
clear
set -uo pipefail

# Parse command-line arguments
FORCE_PULL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -pull|--pull)
      FORCE_PULL=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

echo "==> Starting complete rebuild of IoT system..."

# Add image pulling section if flag is set
if [ "$FORCE_PULL" = true ]; then
  echo "==> Force pull flag detected. Pulling latest Docker images..."
  
  echo "==> Pulling web-frontend image..."
  docker pull raraid/web-frontend:latest
  
  echo "==> Pulling web-backend image..."
  docker pull raraid/web-backend:latest
  
  echo "==> Pulling iot-service image..."
  docker pull raraid/iot-service:latest
  
  echo "==> Pulling test-pub image..."
  docker pull raraid/test-pub:latest
  
  echo "==> Pulling mosquitto image..."
  docker pull eclipse-mosquitto:latest
  
  echo "==> Pulling timescaledb image..."
  docker pull timescale/timescaledb:latest-pg14
  
  echo "==> All images pulled successfully"
fi

# Helm and namespace related steps
echo "==> Uninstalling existing Helm releases (if any)..."
helm uninstall iot-system -n iot-system || true
helm uninstall prometheus -n iot-system || true
helm uninstall grafana -n iot-system || true

echo "==> Deleting namespace 'iot-system'..."
kubectl delete namespace iot-system --ignore-not-found

echo "==> Recreating namespace 'iot-system'..."
kubectl create namespace iot-system

echo "==> Setting current context to 'iot-system'..."
kubectl config set-context --current --namespace=iot-system

echo "==> Creating 'db-credentials' secret..."
kubectl create secret generic db-credentials \
  --namespace=iot-system \
  --from-literal=POSTGRES_DB=iotdb \
  --from-literal=POSTGRES_USER=iotuser \
  --from-literal=POSTGRES_PASSWORD=iotpass

# Prepare imagePullPolicy flag if needed
if [ "$FORCE_PULL" = true ]; then
  PULL_POLICY_ARGS="--set webFrontend.image.pullPolicy=Always \
    --set webBackend.image.pullPolicy=Always \
    --set iotService.image.pullPolicy=Always \
    --set testPub.image.pullPolicy=Always \
    --set mosquitto.image.pullPolicy=Always \
    --set timescaledb.image.pullPolicy=Always"
else
  PULL_POLICY_ARGS=""
fi

# Deploy everything using Helm with scale set to 0 for non-DB components
echo "==> PHASE 1: Deploying with database-only (other components scaled to 0)..."
helm upgrade --install iot-system ./charts/iot-system -n iot-system --create-namespace $PULL_POLICY_ARGS \
  --set iotService.replicas=0 \
  --set webBackend.replicas=0 \
  --set webFrontend.replicas=0 \
  --set testPub.replicas=0 \
  --set mosquitto.replicas=0

echo "==> Waiting for TimescaleDB pod to be ready..."
kubectl wait --for=condition=ready pod -l app=timescaledb -n iot-system --timeout=720s

TIMESCALE_POD=$(kubectl get pod -l app=timescaledb -n iot-system -o jsonpath='{.items[0].metadata.name}')
echo "==> Initializing TimescaleDB schema on pod: $TIMESCALE_POD"

# Make sure TimescaleDB is truly ready with a more thorough check
echo "==> Double-checking TimescaleDB connection..."
for i in {1..10}; do
  echo "  Connection test attempt $i..."
  if kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "SELECT 1 as test;" > /dev/null 2>&1; then
    echo "  Connection successful!"
    break
  fi
  echo "  Connection attempt failed, waiting 5 seconds..."
  sleep 5
  if [ $i -eq 10 ]; then
    echo "  WARNING: Could not verify TimescaleDB connection after 10 attempts, continuing anyway..."
  fi
done

# Database initialization
echo "==> Creating the TimescaleDB extension..."
kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
sleep 2

echo "==> Dropping any existing sensor_data table..."
kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "DROP TABLE IF EXISTS sensor_data CASCADE;"
sleep 2

echo "==> Creating new sensor_data table..."
kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "
CREATE TABLE sensor_data (
  time TIMESTAMPTZ NOT NULL,
  device_id TEXT NOT NULL,
  temperature DOUBLE PRECISION,
  humidity DOUBLE PRECISION,
  pressure DOUBLE PRECISION,
  motion TEXT,
  switch TEXT
);"
sleep 2

echo "==> Converting to TimescaleDB hypertable..."
kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "
SELECT create_hypertable('sensor_data', 'time');"
sleep 2

echo "==> Creating index..."
kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "
CREATE INDEX idx_sensor_device_id ON sensor_data (device_id, time DESC);"
sleep 2

echo "==> Adding test data..."
kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "
INSERT INTO sensor_data (time, device_id, temperature, humidity, pressure, motion, switch)
VALUES 
  (NOW(), 'test-device', 72.5, 45.2, 29.92, 'false', 'true');"
sleep 2

echo "==> Verifying data insertion..."
kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "
SELECT COUNT(*) FROM sensor_data;"

echo "==> Database initialization complete and verified."

# PHASE 2: Scale up other components now that the database is ready
echo "==> PHASE 2: Scaling up other components now that database is ready..."
helm upgrade --install iot-system ./charts/iot-system -n iot-system $PULL_POLICY_ARGS

# Phase 3: Setting up monitoring components
echo "==> PHASE 3: Setting up Prometheus and Grafana..."
echo "==> Creating Prometheus ConfigMap..."
kubectl apply -f k8s/prometheus-config.yaml

echo "==> Creating ConfigMap with correct name for Prometheus..."
kubectl get configmap prometheus-config -n iot-system -o yaml | \
  sed 's/name: prometheus-config/name: prometheus-prometheus-config/' | \
  kubectl apply -f -

echo "==> Adding Helm repositories if needed..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add grafana https://grafana.github.io/helm-charts || true
helm repo update

echo "==> Installing Prometheus with Helm..."
helm upgrade --install prometheus prometheus-community/prometheus \
  -f k8s/prometheus-values.yaml \
  --namespace iot-system

echo "==> Installing Grafana with Helm..."
helm upgrade --install grafana grafana/grafana \
  -f k8s/grafana-values.yaml \
  --namespace iot-system

echo "==> Setting up Ingress for monitoring tools..."
kubectl apply -f k8s/monitoring-ingress.yaml

echo "==> Applying app-ingress.yaml for routing..."
kubectl apply -f k8s/app-ingress.yaml

# Phase 4: Waiting for all other services to be ready
echo "==> PHASE 4: Waiting for all pods to be ready..."
echo "==> Waiting for core services..."
kubectl wait --for=condition=ready pod -l app=iot-service -n iot-system --timeout=180s || true
kubectl wait --for=condition=ready pod -l app=web-frontend -n iot-system --timeout=180s || true
kubectl wait --for=condition=ready pod -l app=web-backend -n iot-system --timeout=180s || true

# Use a different approach for Prometheus server
echo "==> Waiting for Prometheus server pod..."
sleep 30
PROM_POD=$(kubectl get pod -l app.kubernetes.io/component=server -n iot-system -o name 2>/dev/null || echo "")
if [ -n "$PROM_POD" ]; then
  echo "Found Prometheus pod: $PROM_POD"
  kubectl wait --for=condition=ready $PROM_POD -n iot-system --timeout=180s || true
else
  echo "No Prometheus pod found yet, continuing anyway"
fi

sleep 10
echo "==> Reset complete. Verify all pods..."
kubectl get pods -n iot-system

echo "==> Running test queries from database in 10 seconds..."
sleep 10
kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "SELECT COUNT(*) FROM sensor_data;"
kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "SELECT * FROM sensor_data ORDER BY time DESC LIMIT 5;"
echo ""

# Display access information
echo ""
echo "==> Access your services at:"

# Get NodePort information
WEB_FRONTEND_NODEPORT=$(kubectl get service web-frontend -n iot-system -o jsonpath='{.spec.ports[0].nodePort}')
WEB_BACKEND_NODEPORT=$(kubectl get service web-backend -n iot-system -o jsonpath='{.spec.ports[0].nodePort}')
INGRESS_IP=$(kubectl get ingress -n iot-system -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

echo "Direct NodePort access:"
echo "Web Frontend: http://192.168.6.11:${WEB_FRONTEND_NODEPORT}"
echo "Web Backend API: http://192.168.6.11:${WEB_BACKEND_NODEPORT}"

echo ""
echo "Ingress access:"
echo "Web Frontend: http://${INGRESS_IP}"
echo "Web Backend API: http://${INGRESS_IP}/api"

echo ""
echo "==> DONE!  Don't forget to clear your browser cache completely before testing!"
kubectl logs -l app=iot-service -n iot-system -f