#!/bin/bash

# nuke.sh
# Complete Kubernetes environment wipe script - NO BACKUPS, NO MERCY!
# This aggressively removes all resources from the iot-system namespace
# and recreates only the bare minimum needed for a fresh start

# Define namespace
NAMESPACE="iot-system"

# Process command line flags
DEAUTH=false
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -deauth)
      DEAUTH=true
      shift
      ;;
    *)
      echo "Unknown option: $key"
      echo "Usage: $0 [-deauth]"
      echo "  -deauth: Also deauthorize from GCP and Kubernetes"
      exit 1
      ;;
  esac
done

clear
echo "NUCLEAR WIPE INITIATED"
echo "This will completely destroy all resources in the ${NAMESPACE} namespace"
echo "No backups will be made. All data will be permanently lost."
if [ "$DEAUTH" = true ]; then
  echo "DEAUTH FLAG ENABLED: Will also clear GCP and Kubernetes credentials"
fi
echo "5 second countdown to abort (Ctrl+C to cancel)..."
for i in {5..1}; do
  echo "$i..."
  sleep 1
done
echo "COMMENCING NUCLEAR WIPE!"

# Step 1: Uninstall any Helm releases in the namespace
echo "Removing all Helm releases in the ${NAMESPACE} namespace..."
for release in $(helm list -n ${NAMESPACE} -q); do
  echo "Uninstalling Helm release: $release"
  helm uninstall $release -n ${NAMESPACE}
done

# Step 2: Remove all finalizers from all resources
echo "Removing all finalizers from PVCs..."
for pvc in $(kubectl get pvc -n ${NAMESPACE} -o name); do
  echo "Removing finalizers from: $pvc"
  kubectl patch $pvc -n ${NAMESPACE} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' || true
done

echo "Removing all finalizers from StatefulSets..."
for sts in $(kubectl get statefulset -n ${NAMESPACE} -o name); do
  echo "Removing finalizers from: $sts"
  kubectl patch $sts -n ${NAMESPACE} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' || true
done

echo "Removing all finalizers from Pods..."
for pod in $(kubectl get pods -n ${NAMESPACE} -o name); do
  echo "Removing finalizers from: $pod"
  kubectl patch $pod -n ${NAMESPACE} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' || true
done

# Step 3: Aggressively delete high-level resources first
echo "Deleting all Deployments, StatefulSets, DaemonSets..."
kubectl delete deployment,statefulset,daemonset --all -n ${NAMESPACE} --force --grace-period=0 || true

# Step 4: Delete all pods extremely aggressively
echo "Force deleting all pods..."
for pod in $(kubectl get pods -n ${NAMESPACE} -o name); do
  echo "Force deleting: $pod"
  kubectl delete $pod -n ${NAMESPACE} --force --grace-period=0 || true
done

# Step 5: Delete all remaining resource types
echo "Deleting all other resources..."
kubectl delete services,ingress,configmaps,secrets,pvc,pv,jobs,cronjobs --all -n ${NAMESPACE} --force --grace-period=0 || true

# Step 6: Special handling for any network policies
echo "Deleting network policies..."
kubectl delete networkpolicy --all -n ${NAMESPACE} --force --grace-period=0 || true

# Step 7: Clean up cert-manager resources
echo "Deleting cert-manager resources..."
kubectl delete certificates,issuers,certificaterequests --all -n ${NAMESPACE} --force --grace-period=0 || true

# Step 8: Nuclear option - delete namespace with cascading deletion
echo "DESTROYING NAMESPACE: ${NAMESPACE}"
kubectl delete namespace ${NAMESPACE} --force --grace-period=0

# Step 9: Wait for namespace to be fully removed
echo "Waiting for namespace to be fully removed..."
while kubectl get namespace ${NAMESPACE} >/dev/null 2>&1; do
  echo "Waiting for namespace ${NAMESPACE} to be deleted..."
  sleep 2
done

# Run terraform destroy BEFORE removing credentials
echo "Running terraform destroy to remove all cloud resources..."
cd terraform
terraform destroy -auto-approve
cd ..

# Additional Cleanup Steps - only if deauth flag is set
if [ "$DEAUTH" = true ]; then
  echo "Clearing Kubernetes config context..."
  kubectl config unset current-context
  rm -f ~/.kube/config

  echo "Resetting gcloud configuration..."
  gcloud auth revoke --all
  rm -rf ~/.config/gcloud
  # gcloud init
  
  echo "Deauthorization complete"
else
  echo "Skipping deauthorization (use -deauth flag to include)"
fi

# Always delete local Terraform state
echo "Deleting local Terraform state..."
rm -rf terraform/.terraform terraform/terraform.tfstate*

echo "=========================================="
echo "NUCLEAR WIPE COMPLETE"
echo "The infrastructure has been completely destroyed"
if [ "$DEAUTH" = true ]; then
  echo "GCP and Kubernetes credentials have been cleared"
  echo "Run post-nuke.sh to restore credentials, then"
else
  echo "Credentials were preserved"
fi
echo "terraform init and apply to rebuild everything"
echo "=========================================="

# Show namespace state - but only if not deauthorized
if [ "$DEAUTH" = false ]; then
  echo "Attempting to show namespace state:"
  kubectl get all -n ${NAMESPACE} || echo "Namespace does not exist (this is expected)"
else
  echo "kubectl command would fail due to credential removal"
fi