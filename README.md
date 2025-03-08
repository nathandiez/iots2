
# Rebuild and redeploy the frontend
eval $(minikube docker-env)
docker build -t web-frontend:latest web/frontend
kubectl delete deployment web-frontend
kubectl apply -f k8s/web-deployment.yaml
or
eval $(minikube docker-env)
docker build -t iot-service:latest ./iot_service
kubectl apply -f k8s/iot_service-deployment.yaml
kubectl rollout restart deployment/iot-service


# Create tunnel from kubernetes minikube cluster to local mac.  Create new ssh and leave it open
ssh -L 32561:192.168.49.2:32561 -L 31734:192.168.49.2:31734 nathan@kma

http://localhost:32561 to render in browser on mac
