#!/bin/bash
# post-nuke.sh - Restore necessary environment after complete wipe
# Run this after nuke.sh to prepare for init.sh

set -euo pipefail

echo "===================================="
echo "Post-Nuke Environment Restoration"
echo "===================================="

# Set project variables
PROJECT_ID="gke-032825"
REGION="us-east1"
ZONE="us-east1-b"
CLUSTER_NAME="iot-system-cluster"

# Check if already authenticated with gcloud
if gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
  echo "Already authenticated with Google Cloud, skipping login..."
else
  echo "Authenticating with Google Cloud..."
  # Interactive authentication
  gcloud auth login
fi

# Check if application default credentials exist
if [ -f "$HOME/.config/gcloud/application_default_credentials.json" ]; then
  echo "Application Default Credentials exist, skipping ADC login..."
else
  echo "Setting up Application Default Credentials for Terraform..."
  gcloud auth application-default login
fi

# Set project configuration
echo "Setting default project..."
gcloud config set project ${PROJECT_ID}

echo "Setting default compute region and zone..."
gcloud config set compute/region ${REGION}
gcloud config set compute/zone ${ZONE}

# Check if kubectl is configured correctly
if kubectl config current-context 2>/dev/null | grep -q ${CLUSTER_NAME}; then
  echo "kubectl already configured for ${CLUSTER_NAME}, skipping..."
else
  # Re-generate the kubeconfig file (assumes the cluster still exists)
  echo "Regenerating kubectl configuration..."
  if gcloud container clusters list --filter="name=${CLUSTER_NAME}" | grep -q ${CLUSTER_NAME}; then
    echo "Retrieving credentials for cluster ${CLUSTER_NAME}"
    gcloud container clusters get-credentials ${CLUSTER_NAME} --zone ${ZONE} --project ${PROJECT_ID}
  else
    echo "Warning: Cluster ${CLUSTER_NAME} not found. Terraform will need to recreate it."
  fi
fi

# Verify connectivity
echo "Verifying Google Cloud connectivity..."
gcloud projects describe ${PROJECT_ID}

echo "Verifying kubectl configuration (if cluster exists)..."
kubectl config current-context 2>/dev/null || echo "No Kubernetes context available yet."

echo "===================================="
echo "✅ Environment restoration complete"
echo "You can now:"
echo "1. Run 'cd terraform && terraform init' to initialize Terraform"
echo "2. Then 'terraform apply' to rebuild your infrastructure"
echo "===================================="