# Azure AKS IoT System Deployment Guide

This guide provides step‑by‑step instructions for standing up an AKS cluster with an NGINX ingress controller and deploying your IoT system.

---
## 1. Prerequisites Installation
Install the required tooling on your workstation:
```bash
# Update package lists
sudo apt-get update

# Common utilities
sudo apt-get install -y git curl wget apt-transport-https ca-certificates gnupg lsb-release unzip

# ───────── Docker Engine ─────────
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update && \
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo usermod -aG docker $USER   # log out / in afterwards

# ───────── Azure CLI ─────────
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# ───────── Terraform ─────────
sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | \
  sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt-get update && sudo apt-get install -y terraform

# ───────── kubectl ─────────
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# ───────── Helm 3 ─────────
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Mosquitto client utilities (for mosquitto_passwd etc.)
sudo apt-get install -y mosquitto

# Add cert‑manager chart repo (the install happens later)
helm repo add jetstack https://charts.jetstack.io && helm repo update
```

---
## 2. Authorization and Authentication
```bash
az login --use-device-code
```

---
## 3. Infrastructure Deployment with Terraform
```bash
cd terraform
terraform init
terraform plan
terraform validate
terraform apply -auto-approve

# Copy the ingress_public_ip output
```

---
## 4. Configure Kubernetes
```bash
# Merge AKS credentials into your kube‑config
az aks get-credentials --resource-group rg-iotsystem-port --name aks-iotsystem-cluster

# Verify cluster access
kubectl get nodes

# Install cert‑manager (CRDs included)
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.13.2 \
  --set installCRDs=true

# Wait until the webhooks are ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager --timeout=120s
```

---
## 5. Deploy Ingress Controller
```bash
# Add the NGINX ingress repo
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update

# Install NGINX Ingress Controller
INGRESS_IP=$(terraform output -raw ingress_public_ip)
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --create-namespace \
  --namespace ingress-nginx \
  --set controller.service.loadBalancerIP="$INGRESS_IP" \
  --set controller.service.externalTrafficPolicy=Local \   # ← AKS health‑probe fix
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-resource-group"=rg-iotsystem-port

# Verify the service shows the correct external IP
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

---
## 6. Initialize the Environment
```bash
chmod +x init.sh && ./init.sh
```

---
## 7. Deploy the IoT Application
```bash
chmod +x deploy.sh && ./deploy.sh
```

---
## 8. Access Your IoT Application
Your endpoints will be available at:
* Web Frontend  →  http://iot.<YOUR_INGRESS_IP>.nip.io
* Web Backend   →  http://iot.<YOUR_INGRESS_IP>.nip.io/api

The Mosquitto broker is exposed through its own LoadBalancer service for IoT devices to publish events.

