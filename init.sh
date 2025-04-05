#!/bin/bash
# init.sh - Initialize AKS environment for IoT System
set -euo pipefail

echo " "
echo "=========================================================================="
echo "==> Running init.sh - starting initialization of IoT system environment for AKS..."

# Check if cert-manager is installed
echo "==> Checking if cert-manager is installed..."
if ! kubectl get deployment -n cert-manager cert-manager > /dev/null 2>&1; then
  echo "Installing cert-manager..."
  helm repo add jetstack https://charts.jetstack.io
  helm repo update
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.13.2 \
    --set installCRDs=true

  # Wait for cert-manager to be ready
  echo "Waiting for cert-manager to be ready..."
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s
else
  echo "cert-manager is already installed, skipping installation."
fi

# Create cluster issuers
echo "==> Creating certificate issuers..."
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ericdiez99@gmail.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

# Clean up and recreate namespace
echo "==> Cleaning up existing resources..."
helm uninstall iot-system -n iot-system || true
kubectl delete namespace iot-system --ignore-not-found
kubectl create namespace iot-system

# Create CA certificate for Mosquitto (but let Helm create the issuer)
echo "==> Creating CA certificate..."
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: iot-ca
  namespace: iot-system
spec:
  isCA: true
  commonName: iot-system-ca
  secretName: iot-ca
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
EOF

echo "==> Waiting for CA certificate to be ready..."
kubectl wait --for=condition=Ready certificate/iot-ca -n iot-system --timeout=60s

# Create Mosquitto password file and secret
echo "==> Creating Mosquitto password file and secret..."
# Create temporary password file
touch mosquitto_passwd
chmod 0700 mosquitto_passwd 
mosquitto_passwd -b mosquitto_passwd iot_service pw123
mosquitto_passwd -b mosquitto_passwd test_pub pw123
mosquitto_passwd -b mosquitto_passwd pico_device pico_pw123

# Create the secret
kubectl create secret generic mosquitto-credentials \
  --from-file=mosquitto_passwd \
  -n iot-system

# Clean up local file
rm mosquitto_passwd
echo "==> Mosquitto credentials created successfully"

# Verify Azure IP configuration
echo "==> Verifying Azure ingress controller configuration..."
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ -z "$INGRESS_IP" ]; then
  echo "WARNING: Ingress controller doesn't have an external IP assigned yet."
  echo "         Check service with: kubectl get svc -n ingress-nginx ingress-nginx-controller"
else
  echo "==> Ingress controller external IP: $INGRESS_IP"
  echo "==> Your application will be available at: http://iot.$INGRESS_IP.nip.io"
fi

echo "==> AKS initialization complete!"
cd terraform
terraform output
cd ..
echo "==> Run deploy.sh to deploy the application components"