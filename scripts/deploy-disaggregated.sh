#!/bin/bash
set -e

echo "============================================"
echo "  Apache Doris 4.0.4 Disaggregated Deploy"
echo "  Local Kubernetes (Docker Desktop)"
echo "============================================"

NS="doris"
MS_URL="http://127.0.0.1:8080"
TOKEN="greedisgood9999"

echo ""
echo "=== Step 1: Create namespace ==="
kubectl create namespace ${NS} 2>/dev/null || true

echo ""
echo "=== Step 2: Deploy FoundationDB ==="
kubectl apply -f k8s/local-disaggregated/00-foundationdb.yaml
echo "Waiting for FoundationDB to be ready..."
kubectl wait --for=condition=ready pod -l app=foundationdb -n ${NS} --timeout=120s

echo ""
echo "=== Step 3: Deploy MinIO ==="
kubectl apply -f k8s/local-disaggregated/01-minio.yaml
echo "Waiting for MinIO to be ready..."
kubectl wait --for=condition=ready pod -l app=minio -n ${NS} --timeout=120s

echo ""
echo "=== Step 4: Deploy Meta Service & Recycler ==="
kubectl apply -f k8s/local-disaggregated/02-ms.yaml
echo "Waiting for Meta Service to be ready..."
kubectl wait --for=condition=ready pod -l app=doris-ms -n ${NS} --timeout=120s

echo ""
echo "=== Step 5: Create instance with MinIO vault ==="
MINIO_IP=$(kubectl get svc minio -n ${NS} -o jsonpath='{.spec.clusterIP}')
echo "MinIO IP: ${MINIO_IP}"

MS_POD=$(kubectl get pod -l app=doris-ms -n ${NS} -o jsonpath='{.items[0].metadata.name}')
kubectl exec ${MS_POD} -n ${NS} -c meta-service -- /bin/bash -c "
curl -sf -X POST '${MS_URL}/MetaService/http/create_instance?token=${TOKEN}' \
  -H 'Content-Type: application/json' \
  -d '{
    \"instance_id\": \"doris_instance\",
    \"name\": \"doris_cluster\",
    \"user_id\": \"admin\",
    \"vault\": {
      \"obj_info\": {
        \"ak\": \"minioadmin\",
        \"sk\": \"minioadmin\",
        \"bucket\": \"doris-data\",
        \"prefix\": \"doris\",
        \"endpoint\": \"${MINIO_IP}:9000\",
        \"external_endpoint\": \"${MINIO_IP}:9000\",
        \"region\": \"us-east-1\",
        \"provider\": \"S3\"
      }
    }
  }'
echo ''
echo 'Instance created.'
"

echo ""
echo "=== Step 6: Deploy FE and BE ==="
kubectl apply -f k8s/local-disaggregated/03-fe.yaml
kubectl apply -f k8s/local-disaggregated/04-be.yaml

echo ""
echo "Waiting for FE and BE to be ready (this may take a few minutes)..."
kubectl wait --for=condition=ready pod -l app=doris-fe -n ${NS} --timeout=300s || true
kubectl wait --for=condition=ready pod -l app=doris-be -n ${NS} --timeout=300s || true

echo ""
echo "=== Step 7: Set default storage vault ==="
FE_POD=$(kubectl get pod -l app=doris-fe -n ${NS} -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 30); do
  if kubectl exec ${FE_POD} -n ${NS} -- /bin/bash -c "mysql -h 127.0.0.1 -P 9030 -u root -e 'SET built_in_storage_vault AS DEFAULT STORAGE VAULT'" 2>/dev/null; then
    echo "Default storage vault set successfully."
    break
  fi
  echo "Waiting for FE to be ready (attempt ${i})..."
  sleep 10
done

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "All pods:"
kubectl get pods -n ${NS}
echo ""
echo "Services:"
kubectl get svc -n ${NS}
echo ""
echo "Access credentials:"
echo "  MySQL: kubectl exec ${FE_POD} -n ${NS} -- mysql -h 127.0.0.1 -P 9030 -u root"
echo "  FE Web: http://localhost:8030"
echo "  MinIO: http://localhost:9001 (minioadmin/minioadmin)"
echo ""
echo "Port forwarding (run in background):"
echo "  kubectl port-forward svc/doris-fe 8030:8030 9030:9030 -n ${NS}"
echo "  kubectl port-forward svc/minio 9000:9000 9001:9001 -n ${NS}"
