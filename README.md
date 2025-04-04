terraform -version
gcloud --version

gcloud init
gcloud config set project GKE-032525

mkdir terraform-gke
cd terraform-gke

# create main.tf and make sure to include deletion_protection = false so that you can delete and rebuild the cluster as needed during dev
provider "google" {
  project = "gke-032525"
  region  = "us-east1"
}

resource "google_container_cluster" "iot_cluster" {
  name     = "iot-gke-cluster"
  location = "us-east1"

  initial_node_count = 3
  deletion_protection = false

  node_config {
    machine_type = "e2-medium"
    disk_size_gb = 20
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }
}


gcloud auth application-default login
gcloud services enable container.googleapis.com

# Note: make sure you delete any old unused GCP vms to free up IPs and other resources so you don't hit an IP quota limit

terraform init
terraform apply


gcloud container clusters get-credentials iot-gke-cluster --region us-east1 --project gke-032525
kubectl get nodes  # show list of all nodes like this
gke-iot-gke-cluster-default-pool-00e6e95d-q2zp   Ready    <none>   13m   v1.31.6-gke.1020000
gke-iot-gke-cluster-default-pool-00e6e95d-w17g   Ready    <none>   13m   v1.31.6-gke.1020000
gke-iot-gke-cluster-default-pool-00e6e95d-wdtj   Ready    <none>   13m   v1.31.6-gke.1020000
gke-iot-gke-cluster-default-pool-387ee75a-93g5   Ready    <none>   13m   v1.31.6-gke.1020000
gke-iot-gke-cluster-default-pool-387ee75a-wd7p   Ready    <none>   13m   v1.31.6-gke.1020000
gke-iot-gke-cluster-default-pool-387ee75a-zz9q   Ready    <none>   13m   v1.31.6-gke.1020000
gke-iot-gke-cluster-default-pool-859129e7-79f7   Ready    <none>   13m   v1.31.6-gke.1020000
gke-iot-gke-cluster-default-pool-859129e7-lr3x   Ready    <none>   13m   v1.31.6-gke.1020000
gke-iot-gke-cluster-default-pool-859129e7-m3mm   Ready    <none>   13m   v1.31.6-gke.1020000


# Enable required APIs
gcloud services enable compute.googleapis.com
gcloud services enable iam.googleapis.com

# Create cloude router (one time)
gcloud compute routers create nat-router \
  --network=default \
  --region=us-east1

# Create NATgateway
gcloud compute routers nats create nat-config \
  --router=nat-router \
  --region=us-east1 \
  --nat-all-subnet-ip-ranges \
  --auto-allocate-nat-external-ips

# Install cert-manager via Helm:
helm repo add jetstack https://charts.jetstack.io
helm repo update
kubectl create namespace cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set installCRDs=true

# Check pods
kubectl get pods -n cert-manager -w

# Update main.tf to fix secretes base64 encoding issue
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: iot-system
  labels:
    app.kubernetes.io/instance: iot-system
    app.kubernetes.io/name: iot-system
type: Opaque
data:
  POSTGRES_DB: aW90ZGI=
  POSTGRES_USER: aW90dXNlcg==
  POSTGRES_PASSWORD: cHcxMjM=
---
apiVersion: v1
kind: Secret
metadata:
  name: api-credentials
  namespace: iot-system
  labels:
    app.kubernetes.io/instance: iot-system
    app.kubernetes.io/name: iot-system
type: Opaque
data:
  API_KEY: YXBpa2V5MTIz