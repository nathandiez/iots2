#!/bin/bash
# clear
# set -euo pipefail

# Check for -nuke flag and purge minikube and docker artifacts if requested
if [[ "${1:-}" == "-nuke" ]]; then
  echo "==> Nuke flag detected! Deleting EVERYTHING: minikube, docker artifacts..."
  # Use --all --purge for complete removal
  echo "==> deleting minikub ..."
  minikube delete --all --purge
  rm -rf ~/.minikube

  # Include --volumes for complete Docker cleanup
  echo "==> Prune docker..."
  docker system prune -a --force --volumes
  echo "==> Restarting minikube ..."
  minikube start --network-plugin=cni --cni=calico
  minikube status

  # Verify Calico pods are running *before* continuing
  echo "==> Waiting for Calico to be ready..."
  until kubectl get pods -n kube-system -l k8s-app=calico-node | grep -q Running; do
    echo "  Calico pods not yet running, waiting 5 seconds..."
    sleep 5
  done
  echo "==> Calico is ready."
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
  --from-literal=POSTGRES_PASSWORD=iotpass \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Deploying Helm chart 'iot-system'..."
helm upgrade --install iot-system ./charts/iot-system -n iot-system --create-namespace

echo "==> Waiting for TimescaleDB pod to be ready..."
kubectl wait --for=condition=ready pod -l app=timescaledb -n iot-system --timeout=720s

TIMESCALE_POD=$(kubectl get pod -l app=timescaledb -n iot-system -o jsonpath='{.items[0].metadata.name}')
echo "==> Initializing TimescaleDB schema on pod: $TIMESCALE_POD"

echo "==> Waiting for TimescaleDB to accept connections..."
until kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "SELECT 1;" >/dev/null 2>&1; do
  echo "TimescaleDB not ready for connections, waiting 5 seconds..."
  sleep 5
done

echo "==> Creating sensor_data table..."
kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE TABLE IF NOT EXISTS sensor_data (
  time TIMESTAMPTZ NOT NULL,
  device_id TEXT NOT NULL,
  temperature DOUBLE PRECISION,
  humidity DOUBLE PRECISION,
  pressure DOUBLE PRECISION,
  motion TEXT,
  switch TEXT
);
SELECT create_hypertable('sensor_data', 'time', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_sensor_device_id ON sensor_data (device_id, time DESC);
"

# Add Prometheus and Grafana setup
echo "==> Setting up Prometheus and Grafana..."
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

echo "==> Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=timescaledb -n iot-system --timeout=180s || true
kubectl wait --for=condition=ready pod -l app=iot-service -n iot-system --timeout=180s || true
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n iot-system --timeout=180s || true

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

echo "==> Reset complete. Verify all pods in 10 seconds..."
sleep 10
kubectl get pods -n iot-system

echo "==> Running test queries from database in 10 seconds..."
sleep 10
kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "SELECT COUNT(*) FROM sensor_data;"
kubectl exec -it "$TIMESCALE_POD" -n iot-system -- psql -U iotuser -d iotdb -c "SELECT * FROM sensor_data ORDER BY time DESC LIMIT 5;"
echo ""
echo "==> Cleaning up any existing port forwards..."
for port in 8001 8002; do
    echo "Checking port: '$port'"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
        pids=$(lsof -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null)

        if [[ -n "$pids" ]]; then
            echo "Killing processes using port $port: $pids"
            kill -9 $pids 2>/dev/null || true
        else
            echo "No processes found using port $port"
        fi
    else
        echo "Invalid port number: $port"
    fi
done
echo "Port cleanup completed successfully."
echo "Exit status after cleanup: $?"

MINIKUBE_IP=$(minikube ip)
WEB_FRONTEND_NODEPORT=$(kubectl get service web-frontend -n iot-system -o jsonpath='{.spec.ports[0].nodePort}')
WEB_BACKEND_NODEPORT=$(kubectl get service web-backend -n iot-system -o jsonpath='{.spec.ports[0].nodePort}')
GRAFANA_NODEPORT=$(kubectl get service grafana -n iot-system -o jsonpath='{.spec.ports[0].nodePort}')
PROMETHEUS_NODEPORT=$(kubectl get service prometheus-server -n iot-system -o jsonpath='{.spec.ports[0].nodePort}')
echo ""
echo "==> Setting up port forwarding for web services..."
echo "Starting port forwarding in the background. Use 'pkill -f \"port-forward\"' to terminate them."
kubectl port-forward -n iot-system svc/web-frontend 8001:3000 --address 0.0.0.0 &
echo "Frontend port forwarding PID: $!"
kubectl port-forward -n iot-system svc/web-backend 8002:5000 --address 0.0.0.0 &
echo "Backend port forwarding PID: $!"
echo ""
echo "Using kubectl port-forward (more reliable)"
echo "Use this SSH command from your local machine:"
SSH_CMD2="ssh -L 8081:localhost:8001 -L 30145:localhost:8002 -L 3001:${MINIKUBE_IP}:${GRAFANA_NODEPORT} -L 9091:${MINIKUBE_IP}:${PROMETHEUS_NODEPORT} ${USER}@$(hostname)"
echo "$SSH_CMD2"
echo ""
echo "Then access these URLs with OPTION 2:"
echo "Web Frontend: http://localhost:8081"
echo "Web Backend API: http://localhost:30145"
echo "Grafana Dashboard: http://localhost:3001 (username: admin, password shown below)"
echo "Prometheus: http://localhost:9091"
echo ""
echo "==> Grafana admin password:"
kubectl get secret --namespace iot-system grafana -o jsonpath="{.data.admin-password}" | base64 --decode; echo