# Quick Start Guide: IoT Kubernetes Project

### Prerequisites Installation (Debian Server)
```bash
# Install packages
sudo apt-get update
sudo apt-get install -y curl wget apt-transport-https docker.io
sudo usermod -aG docker $USER
sudo systemctl enable docker
sudo systemctl start docker
```

### Install minikube
```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

### Clean Docker and Kubernetes, and start minikube
```bash
minikube delete
rm -rf ~/.minikube
docker stop $(docker ps -a -q)
docker rm $(docker ps -a -q)
docker system prune -a --force
minikube start
eval $(minikube docker-env)
```

### Deploy Application
```bash
# Get code and enter directory
mkdir ~/projects
cd ~/projects
git clone https://github.com/ecode99/iots2.git
cd iots2
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

### Build docker images
```bash
# NOTE: Run all commands from ~/projects/iots2
eval $(minikube docker-env)
docker build -t web-backend:latest web/backend
docker build -t web-frontend:latest web/frontend
docker build -t iot-service:latest iot_service
docker build -t test-pub:latest test_pub
```

### Deploy TimescaleDB, exec db prompt and create table
```bash
kubectl apply -f k8s/timescaledb-deployment.yaml
sleep 20

kubectl exec -i deployment/timescaledb -- psql -U iotuser -d iotdb << 'EOF'
CREATE TABLE sensor_data (
    time TIMESTAMPTZ NOT NULL,
    device_id TEXT NOT NULL,
    temperature DOUBLE PRECISION,
    humidity DOUBLE PRECISION,
    pressure DOUBLE PRECISION,
    motion TEXT,
    switch TEXT
);
SELECT create_hypertable('sensor_data', 'time');
EOF
```

### Deploy remaining services in order
```bash
kubectl apply -f k8s/mosquitto-deployment.yaml
sleep 10
kubectl apply -f k8s/iot_service-deployment.yaml
sleep 5
kubectl apply -f k8s/test_pub-deployment.yaml
sleep 5
kubectl apply -f k8s/web-deployment.yaml

# Verify all pods running
kubectl get pods
```

### Confirm records are being written to database
```bash
kubectl exec -it deployment/timescaledb -- psql -U iotuser -d iotdb -c "SELECT * FROM sensor_data LIMIT 5;"
```

### Get service URLs
```bash
minikube service web-frontend --url
minikube service web-backend --url
# Example output:
# http://192.168.49.2:31498
# http://192.168.49.2:30160

# Test API on Debian using minikube IPs
curl http://192.168.49.2:30160/api/devices
curl http://192.168.49.2:30160/api/sensor-data?hours=24

THEN, on mac

# Set up SSH tunnel
ssh -L 31498:192.168.49.2:31498 -L 30145:192.168.49.2:30160 eric@debianhp.local

# Test API through tunnel
curl http://localhost:30160/api/devices
curl http://localhost:30160/api/sensor-data?hours=24

# Open dashboard in browser
http://localhost:31498
```

### Troubleshooting
```bash
# Check pod status
kubectl get pods

# View pod logs
kubectl logs -f deployment/iot-service
kubectl logs -f deployment/test-pub
kubectl logs -f deployment/web-backend

# Restart a deployment
kubectl rollout restart deployment/web-frontend
```
