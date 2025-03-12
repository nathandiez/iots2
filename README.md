Below is the updated, all‑inclusive deployment guide that now includes the additional steps needed to log in to Docker and Docker Hub. Review the complete guide below:

---

# Complete IoT Application Deployment Guide on K3s

This guide walks you through deploying your IoT application on a new 3‑node K3s cluster running on Ubuntu minimal VMs. It’s designed for a learning environment and uses your existing project files (charts, mosquitto_passwd, rebuild.sh, etc.) without modification. Follow the steps carefully to understand each phase of the deployment.

> **Assumptions:**
> - You have three fresh Ubuntu minimal VMs (for example, Ubuntu Server 22.04).
> - You have a non‑root user (e.g., `eric`) with sudo privileges on all VMs.
> - Example hostnames/IPs (replace with your own):
>   - **k3s-server** (control plane)
>   - **k3s-agent1** (worker)
>   - **k3s-agent2** (worker)
> - Your local workstation has `kubectl`, `helm`, and SSH access to all VMs.
> - All project files (charts, scripts, etc.) are in `~/projects/iots2` on your workstation.
> - Docker images for `web-frontend`, `web-backend`, `iot-service`, and `test-pub` are available on Docker Hub (or your private registry).
> - The mosquitto password file (`mosquitto_passwd`) exists in `~/projects/iots2` with the content:
>   ```
>   iot_service:na123
>   test_pub:na123
>   ```
> - Your rebuild.sh script (shown below) orchestrates the deployment phases.
> - If you’re using private Docker Hub images, you must log in to Docker Hub (and on nodes if necessary) before pulling images.

---

## Table of Contents

1. [Phase 1: Operating System and K3s Setup (All Nodes)](#phase-1-operating-system-and-k3s-setup-all-nodes)
2. [Phase 2: K3s Installation](#phase-2-k3s-installation)
3. [Phase 3: Certificate Generation (Local Workstation)](#phase-3-certificate-generation-local-workstation)
4. [Phase 4: Application Deployment (Local Workstation)](#phase-4-application-deployment-local-workstation)
5. [Phase 5: Accessing the Application](#phase-5-accessing-the-application)
6. [Troubleshooting](#troubleshooting)
7. [Next Steps (Beyond the Basics)](#next-steps-beyond-the-basics)

---

## Phase 1: Operating System and K3s Setup (All Nodes)

Perform the following on **all three VMs** (`k3s-server`, `k3s-agent1`, and `k3s-agent2`).

### 1.1. OS Installation and Update

- **Install Ubuntu minimal** (e.g., Ubuntu Server 22.04) on each VM.
- **Update the system:**
  ```bash
  sudo apt update && sudo apt upgrade -y && sudo apt dist-upgrade -y && sudo apt autoremove -y
  ```

### 1.2. Install Required Dependencies

Install packages needed for Docker, K3s, and certificate generation:
```bash
sudo apt install -y curl openssl apt-transport-https ca-certificates gnupg lsb-release
```

### 1.3. Install Docker

Even though K3s comes with containerd, installing Docker gives you more control and aligns with many Kubernetes setups:

1. **Add Docker’s GPG key and repository:**
   ```bash
   curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
   echo \
     "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
     $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
   sudo apt update
   ```
2. **Install Docker Engine:**
   ```bash
   sudo apt install -y docker-ce docker-ce-cli containerd.io
   sudo systemctl enable docker
   sudo systemctl start docker
   ```

3. **(Optional) Log In to Docker Hub:**  
   If your images are in a private repository or you want to ensure you’re pulling the latest images:
   ```bash
   docker login
   ```
   Enter your Docker Hub username and password when prompted.  
   *You may also need to repeat this on your build host if you’re pushing images to Docker Hub.*

### 1.4. Disable Swap

Kubernetes requires swap to be disabled:
```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

### 1.5. Enable Kernel Modules and Sysctl Settings

Load the necessary kernel modules and set system parameters:
```bash
sudo modprobe br_netfilter
sudo modprobe overlay
sudo tee /etc/modules-load.d/k3s.conf <<EOF
br_netfilter
overlay
EOF
sudo tee /etc/sysctl.d/99-k3s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system
```

### 1.6. Set Hostname and Update /etc/hosts

1. **Set a unique hostname:**
   ```bash
   sudo hostnamectl set-hostname <hostname>  # e.g., k3s-server, k3s-agent1, k3s-agent2
   ```
2. **Edit `/etc/hosts` on each node:**  
   Add entries for all nodes (replace with your actual IP addresses):
   ```
   192.168.6.11 k3s-server
   192.168.6.12 k3s-agent1
   192.168.6.13 k3s-agent2
   ```
3. **Reboot each node:**
   ```bash
   sudo reboot
   ```

---

## Phase 2: K3s Installation

### 2.1. On the Control Plane Node (`k3s-server`)

1. **Install K3s with additional flags:**
   ```bash
   curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --disable=traefik --cluster-init" sh -
   ```
   - `--write-kubeconfig-mode 644`: Makes kubeconfig readable.
   - `--disable=traefik`: Disables Traefik if you plan to use Nginx Ingress.
   - `--cluster-init`: Initializes the embedded etcd datastore.

2. **Retrieve the node token:**
   ```bash
   sudo cat /var/lib/rancher/k3s/server/node-token
   ```
   Copy the token; it will be needed on the agent nodes.

### 2.2. On Worker Nodes (`k3s-agent1` and `k3s-agent2`)

1. **Set environment variables and install K3s:**
   ```bash
   export K3S_URL="https://k3s-server:6443"  # Replace with your server's hostname or IP
   export K3S_TOKEN="YOUR_K3S_TOKEN"          # Replace with the token from k3s-server
   curl -sfL https://get.k3s.io | sh -
   ```

### 2.3. Verify the Cluster

- **On k3s-server:**
  ```bash
  sudo kubectl get nodes -o wide
  ```
  All three nodes should be listed as `Ready`.

### 2.4. Configure kubectl on Your Local Workstation

- **Copy the kubeconfig from k3s-server:**
  ```bash
  scp eric@k3s-server:/etc/rancher/k3s/k3s.yaml ~/.kube/config
  ```
- **Edit the file** and change the `server:` field from `127.0.0.1` to `k3s-server`’s IP or hostname.

---

## Phase 3: Certificate Generation (Local Workstation)

Perform these steps on your local workstation (where your project resides in `~/projects/iots2`).

### 3.1. Create a Certificates Directory
```bash
mkdir -p ~/projects/iots2/certs
cd ~/projects/iots2/certs
```

### 3.2. Generate the CA Key and Certificate
```bash
openssl genrsa -out ca.key 2048
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/CN=mosquitto-ca"
```

### 3.3. Generate the Server Key, CSR, and Certificate

The Common Name must match the Kubernetes service name and namespace:
```bash
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=mosquitto.iot-system.svc.cluster.local"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650
```

### 3.4. (Optional) Verify the Server Certificate
```bash
openssl verify -CAfile ca.crt server.crt
```
The output should indicate that `server.crt: OK`.

---

## Phase 4: Application Deployment (Local Workstation)

This phase uses your provided `rebuild.sh` script (located in `~/projects/iots2`) to deploy the IoT system using Helm. It deploys in phases—first the database only, then the full application stack.

### 4.1. Prepare the Namespace and Secrets

1. **Create the `iot-system` namespace and set context:**
   ```bash
   kubectl create namespace iot-system --dry-run=client -o yaml | kubectl apply -f -
   kubectl config set-context --current --namespace=iot-system
   ```
2. **Create the Mosquitto password secret:**
   ```bash
   kubectl create secret generic mosquitto-passwd --from-file=mosquitto_passwd -n iot-system
   ```
3. **Create the Mosquitto certificates secret:**
   ```bash
   kubectl create secret generic mosquitto-certs \
     --from-file=ca.crt=./certs/ca.crt \
     --from-file=server.crt=./certs/server.crt \
     --from-file=server.key=./certs/server.key \
     -n iot-system
   ```
# this worked!
# Create a new password file with both users
touch mosquitto_passwd
mosquitto_passwd -c mosquitto_passwd iot_service
# Enter "na123" when prompted

# Add the second user (likely for test-pub)
mosquitto_passwd -b mosquitto_passwd test_pub na123
# This adds the user 'test_pub' with password 'na123' non-interactively

# Update the secret
kubectl delete secret mosquitto-passwd -n iot-system
kubectl create secret generic mosquitto-passwd --from-file=mosquitto_passwd -n iot-system


> **Docker Login Reminder:**  
> If your Docker images reside in a private Docker Hub repository, ensure you are logged in on your local build machine using:
> ```bash
> docker login
> ```
> Additionally, if Kubernetes must pull from a private registry, create an imagePullSecret and attach it to your service account.

### 4.2. Deploy Using Helm via the rebuild.sh Script

Your rebuild.sh script orchestrates the following steps:

1. **Optional Image Pull:**  
   If the `--pull` flag is provided, the script pulls the latest Docker images for all components.

2. **Cleanup:**  
   It uninstalls any existing Helm releases and deletes/recreates the `iot-system` namespace.

3. **Phase 1 – Database-Only Deployment:**  
   Deploy the Helm chart with non‑database components scaled to zero. This brings up TimescaleDB and lets you initialize the schema first.
   ```bash
   helm upgrade --install iot-system ./charts/iot-system -n iot-system \
     --set timescaledb.database.password=na123 \
     --set mosquitto.config.allowAnonymous=false \
     --set iotService.replicas=0 \
     --set webBackend.replicas=0 \
     --set webFrontend.replicas=0 \
     --set testPub.replicas=0 \
     --set mosquitto.replicas=0
   ```
4. **Wait for TimescaleDB and Initialize the Database:**  
   The script waits until the TimescaleDB pod is ready and then runs a series of commands to:
   - Create the TimescaleDB extension.
   - Drop any existing `sensor_data` table.
   - Create a new `sensor_data` table.
   - Convert it to a hypertable.
   - Create an index.
   - Insert test data.
   
   (These commands are executed via `kubectl exec` on the TimescaleDB pod.)

5. **Phase 2 – Scale Up the Rest:**  
   Once the database is ready, re‑deploy the Helm chart with the default replica counts to start all services.
   ```bash
   helm upgrade --install iot-system ./charts/iot-system -n iot-system \
     --set timescaledb.database.password=na123 \
     --set mosquitto.config.allowAnonymous=false
   ```
6. **Deploy Monitoring Components (Prometheus & Grafana):**  
   Add the necessary Helm repositories and install Prometheus and Grafana using your custom values files:
   ```bash
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
   helm repo add grafana https://grafana.github.io/helm-charts || true
   helm repo update

   helm upgrade --install prometheus prometheus-community/prometheus \
     -f ./charts/iot-system/k8s/prometheus-values.yaml \
     --namespace iot-system

   helm upgrade --install grafana grafana/grafana \
     -f ./charts/iot-system/k8s/grafana-values.yaml \
     --namespace iot-system
   ```
7. **Wait for All Pods:**  
   The script waits until all pods (core services and monitoring) are ready and prints out access information for NodePort and Ingress.
8. **Tail Logs (Optional):**  
   Finally, the script tails logs for the iot-service to confirm everything is running.

> **Run the Entire Process:**  
> Execute the rebuild.sh script from your project directory:
> ```bash
> cd ~/projects/iots2
> ./rebuild.sh [--pull]
> ```

---

## Phase 5: Accessing the Application

After deployment, use these steps to access your services:

1. **Retrieve NodePort Information:**
   ```bash
   WEB_FRONTEND_NODEPORT=$(kubectl get service web-frontend -n iot-system -o jsonpath='{.spec.ports[0].nodePort}')
   WEB_BACKEND_NODEPORT=$(kubectl get service web-backend -n iot-system -o jsonpath='{.spec.ports[0].nodePort}')
   ```
2. **Retrieve Ingress IP (if applicable):**
   ```bash
   INGRESS_IP=$(kubectl get ingress -n iot-system -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
   ```
3. **Access URLs Example:**
   - **Direct NodePort Access:**
     - Web Frontend: `http://<NODE_IP>:${WEB_FRONTEND_NODEPORT}`
     - Web Backend API: `http://<NODE_IP>:${WEB_BACKEND_NODEPORT}`
   - **Ingress Access:**
     - Web Frontend: `http://${INGRESS_IP}`
     - Web Backend API: `http://${INGRESS_IP}/api`

> **Important:** Follow the NOTES provided by the Helm chart (printed at the end of rebuild.sh) to clear your browser cache before testing.

---

## Troubleshooting

- **Pod Not Ready:**  
  Use `kubectl get pods -n iot-system` and `kubectl describe pod <pod-name> -n iot-system` to inspect pod status and events.
- **Database Connection Issues:**  
  Verify that TimescaleDB is running and that the initialization commands have executed properly using `kubectl logs` and `kubectl exec`.
- **Ingress Issues:**  
  If Ingress isn’t working, check your Nginx Ingress controller logs and ensure that DNS entries or /etc/hosts entries are correctly set up.
- **Docker Image Issues:**  
  If you encounter image pull errors, ensure you’re logged in with `docker login` and that your Kubernetes imagePullSecrets (if needed) are properly configured.

---

## Next Steps (Beyond the Basics)

- **Security Enhancements:**  
  For a production‑like environment, consider using a proper certificate authority (or cert‑manager) instead of self‑signed certificates and tightening security on container runtimes.
- **Monitoring & Logging:**  
  Further customize Prometheus and Grafana dashboards to monitor application performance.
- **CI/CD Integration:**  
  Automate image builds and deployments with your preferred CI/CD tools.
- **Scaling and Resilience:**  
  Experiment with resource requests/limits and horizontal pod autoscaling to understand Kubernetes scaling.

---

This complete guide now covers every step—from OS setup and Docker login to K3s installation, certificate generation, and multi‑phase application deployment—ensuring that you follow best practices while deploying your IoT application on K3s.

Feel free to ask if you need any further clarification or adjustments!
