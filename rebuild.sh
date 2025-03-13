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

# Check if cert-manager is installed
echo "==> Checking if cert-manager is installed..."
if ! kubectl get clusterissuers letsencrypt-prod > /dev/null 2>&1; then
  echo "WARNING: ClusterIssuer 'letsencrypt-prod' not found. HTTPS for ingress may not work."
  echo "Make sure cert-manager is installed and configured with a 'letsencrypt-prod' ClusterIssuer."
fi

# Add image pulling section if flag is set
if [ "$FORCE_PULL" = true ]; then
  echo "==> Force pull flag detected. Pulling latest Docker images..."
  
  echo "==> Pulling web-frontend image..."
  docker pull nathandiez12/web-frontend:latest
  
  echo "==> Pulling web-backend image..."
  docker pull nathandiez12/web-backend:latest
  
  echo "==> Pulling iot-service image..."
  docker pull nathandiez12/iot-service:latest
  
  echo "==> Pulling test-pub image..."
  docker pull nathandiez12/test-pub:latest
  
  echo "==> Pulling mosquitto image..."
  docker pull eclipse-mosquitto:latest
  
  echo "==> Pulling timescaledb image..."
  docker pull timescale/timescaledb:latest-pg14
  
  echo "==> All images pulled successfully"
fi

echo "==> Updating Helm dependencies..."
helm dependency update ./charts/iot-system

# Helm and namespace related steps
echo "==> Uninstalling existing Helm releases (if any)..."
helm uninstall iot-system -n iot-system || true
helm uninstall prometheus -n iot-system || true
helm uninstall grafana -n iot-system || true

echo "==> Deleting namespace 'iot-system'..."
kubectl delete namespace iot-system --ignore-not-found

echo "==> Recreating namespace 'iot-system'..."
kubectl create namespace iot-system

# REMOVED: Creating mosquitto password secret manually - will be handled by Helm

echo "==> Setting current context to 'iot-system'..."
kubectl config set-context --current --namespace=iot-system

echo "==> Creating 'db-credentials' secret..."
# kubectl create secret generic db-credentials \
#   --namespace=iot-system \
#   --from-literal=POSTGRES_DB=iotdb \
#   --from-literal=POSTGRES_USER=iotuser \
#   --from-literal=POSTGRES_PASSWORD=iotpass

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
  --set ingress.host=your-iot-domain.local \
  --set timescaledb.database.password=na123 \
  --set mosquitto.config.allowAnonymous=false \
  --set mosquitto.credentials.iotServicePassword=na123 \
  --set mosquitto.credentials.testPubPassword=na123 \
  --set iotService.replicas=0 \
  --set webBackend.replicas=0 \
  --set webFrontend.replicas=0 \
  --set testPub.replicas=0 \
  --set mosquitto.replicas=0 \
  --set prometheus.enabled=false \
  --set grafana.enabled=false

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
helm upgrade --install iot-system ./charts/iot-system -n iot-system $PULL_POLICY_ARGS \
  --set ingress.host=your-iot-domain.local \
  --set timescaledb.database.password=na123 \
  --set mosquitto.config.allowAnonymous=false \
  --set mosquitto.credentials.iotServicePassword=na123 \
  --set mosquitto.credentials.testPubPassword=na123 \
  --set prometheus.enabled=true \
  --set grafana.enabled=true

# Create and apply proper certificates for mosquitto
echo "==> Creating proper TLS certificates for Mosquitto..."
cd ~/projects/iots2/certs

# Create a CA key and certificate
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=IoT-Root-CA"

# Create a server key
openssl genrsa -out server.key 2048

# Create a CSR with "mosquitto" as the Common Name
openssl req -new -key server.key -out server.csr -subj "/CN=mosquitto"

# Create a temporary OpenSSL config with both "mosquitto" and the FQDN as SANs
cat > /tmp/openssl.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name

[req_distinguished_name]

[v3_req]
subjectAltName = DNS:mosquitto,DNS:mosquitto.iot-system.svc.cluster.local
EOF

# Generate the certificate
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 365 -extfile /tmp/openssl.cnf -extensions v3_req

# Update the K8s secret with our properly configured certificates
kubectl delete secret mosquitto-certs -n iot-system --ignore-not-found
kubectl create secret generic mosquitto-certs \
  --from-file=ca.crt=./ca.crt \
  --from-file=server.crt=./server.crt \
  --from-file=server.key=./server.key \
  -n iot-system

# Return to original directory
cd ~/projects/iots2

# Restart the deployments to pick up the new certificates
kubectl rollout restart deployment/mosquitto deployment/iot-service deployment/test-pub -n iot-system

# REMOVED: No need to set env variables directly as they are now injected from secrets
# kubectl set env deployment/iot-service MQTT_USERNAME=iot_service MQTT_PASSWORD=na123 -n iot-system
# kubectl set env deployment/test-pub MQTT_USERNAME=test_pub MQTT_PASSWORD=na123 -n iot-system

echo "==> Waiting for services to restart with new certificates..."
sleep 15

echo "==> Updating Helm dependencies..."
helm dependency update ./charts/iot-system

# Phase 4: Waiting for all other services to be ready
echo "==> PHASE 4: Waiting for all pods to be ready..."
echo "==> Waiting for core services..."
kubectl wait --for=condition=ready pod -l app=iot-service -n iot-system --timeout=180s || true
kubectl wait --for=condition=ready pod -l app=web-frontend -n iot-system --timeout=180s || true
kubectl wait --for=condition=ready pod -l app=web-backend -n iot-system --timeout=180s || true

# Use a different approach for Prometheus server
echo "==> Waiting for Prometheus server pod to be created..."
TIMEOUT=120  # Total timeout in seconds
INTERVAL=5   # Check interval in seconds
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
  PROM_POD=$(kubectl get pod -n iot-system | grep prometheus-server | grep -v pushgateway | awk '{print $1}' 2>/dev/null || echo "")
  if [ -n "$PROM_POD" ]; then
    echo "Found Prometheus pod: $PROM_POD"
    kubectl wait --for=condition=ready pod/$PROM_POD -n iot-system --timeout=180s || true
    break
  fi
  echo "Waiting for Prometheus pod to be created... ($ELAPSED/$TIMEOUT seconds)"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo "Timeout waiting for Prometheus pod, continuing anyway"
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
echo "Web Frontend: https://your-iot-domain.local"
echo "Web Backend API: https://your-iot-domain.local/api"

# Add Grafana and Prometheus NodePort information
GRAFANA_NODEPORT=$(kubectl get service iot-system-grafana -n iot-system -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "unknown")
PROMETHEUS_NODEPORT=$(kubectl get service iot-system-prometheus-server -n iot-system -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "unknown")

echo "Grafana: http://192.168.6.11:${GRAFANA_NODEPORT}"
echo "Prometheus: http://192.168.6.11:${PROMETHEUS_NODEPORT}"

echo ""
echo "Monitoring Ingress access:"
echo "Grafana: https://grafana.iot-dashboard.local (add to /etc/hosts if using local DNS)"
echo "Prometheus: https://prometheus.iot-dashboard.local (add to /etc/hosts if using local DNS)"

echo ""
echo "==> DONE!  Don't forget to clear your browser cache completely before testing!"
kubectl logs -l app=iot-service -n iot-system -f


# kubectl logs -l app=mosquitto -n iot-system
# kubectl logs -l app=iot-service -n iot-system
# kubectl logs -l app=web-frontend -n iot-system
# kubectl logs -l app=web-backend -n iot-system
# kubectl logs -l app=test-pub -n iot-system
# kubectl logs -l app=timescaledb -n iot-system