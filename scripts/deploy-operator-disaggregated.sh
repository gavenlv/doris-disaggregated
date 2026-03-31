#!/bin/bash
set -e

echo "============================================"
echo "  Apache Doris 4.0.4 Disaggregated Deploy"
echo "  Using Doris Operator (Local K8s)"
echo "============================================"

NS="doris"
DIR="$(cd "$(dirname "$0")/.." && pwd)/k8s/operator-disaggregated"

echo ""
echo "=== Step 1: Create namespace ==="
kubectl create namespace ${NS} 2>/dev/null || true

echo ""
echo "=== Step 2: Deploy FDB CRDs ==="
kubectl apply -f https://raw.githubusercontent.com/FoundationDB/fdb-kubernetes-operator/main/config/crd/bases/apps.foundationdb.org_foundationdbclusters.yaml
kubectl apply -f https://raw.githubusercontent.com/FoundationDB/fdb-kubernetes-operator/main/config/crd/bases/apps.foundationdb.org_foundationdbbackups.yaml
kubectl apply -f https://raw.githubusercontent.com/FoundationDB/fdb-kubernetes-operator/main/config/crd/bases/apps.foundationdb.org_foundationdbrestores.yaml

echo ""
echo "=== Step 3: Deploy FDB Operator ==="
kubectl apply -f ${DIR}/00-fdb-operator.yaml
echo "Waiting for FDB Operator to be ready..."
kubectl wait --for=condition=available deployment/fdb-kubernetes-operator-controller-manager -n ${NS} --timeout=120s

echo ""
echo "=== Step 4: Deploy FoundationDB Cluster ==="
kubectl apply -f ${DIR}/01-fdb-cluster.yaml
echo "Waiting for FoundationDB to be available..."
for i in $(seq 1 60); do
  FDB_STATUS=$(kubectl get fdb doris-fdb -n ${NS} -o jsonpath='{.status.health}' 2>/dev/null || echo "")
  if [ "$FDB_STATUS" = "healthy" ]; then
    echo "FoundationDB is healthy!"
    break
  fi
  echo "Waiting for FDB... (attempt ${i}, status: ${FDB_STATUS:-not ready})"
  sleep 10
done

echo ""
echo "=== Step 5: Deploy Doris Operator CRDs ==="
kubectl apply -f https://raw.githubusercontent.com/apache/doris-operator/master/config/crd/bases/disaggregated.cluster.doris.com_dorisdisaggregatedclusters.yaml

echo ""
echo "=== Step 6: Deploy Doris Operator ==="
kubectl apply -f ${DIR}/02-doris-operator.yaml
echo "Waiting for Doris Operator to be ready..."
kubectl wait --for=condition=available deployment/doris-operator -n ${NS} --timeout=120s

echo ""
echo "=== Step 7: Deploy ConfigMaps ==="
kubectl apply -f ${DIR}/03-ms-configmap.yaml
kubectl apply -f ${DIR}/04-fe-configmap.yaml
kubectl apply -f ${DIR}/05-be-configmap.yaml
kubectl apply -f ${DIR}/06-recycler-configmap.yaml

echo ""
echo "=== Step 8: Deploy MinIO ==="
kubectl apply -f ${DIR}/07-minio.yaml
echo "Waiting for MinIO to be ready..."
kubectl wait --for=condition=available deployment/minio -n ${NS} --timeout=120s

echo ""
echo "=== Step 9: Create MinIO bucket ==="
MINIO_POD=$(kubectl get pod -l app=minio -n ${NS} -o jsonpath='{.items[0].metadata.name}')
kubectl exec ${MINIO_POD} -n ${NS} -- mc alias set local http://localhost:9000 minioadmin minioadmin
kubectl exec ${MINIO_POD} -n ${NS} -- mc mb local/doris-data --ignore-existing

echo ""
echo "=== Step 10: Deploy DorisDisaggregatedCluster ==="
kubectl apply -f ${DIR}/08-doris-disaggregated-cluster.yaml

echo ""
echo "Waiting for DorisDisaggregatedCluster to be ready (this may take several minutes)..."
for i in $(seq 1 60); do
  DDC_STATUS=$(kubectl get ddc doris-disaggregated -n ${NS} -o jsonpath='{.status.fePhase}' 2>/dev/null || echo "")
  if [ "$DDC_STATUS" = "Ready" ]; then
    echo "DorisDisaggregatedCluster is Ready!"
    break
  fi
  echo "Waiting for cluster... (attempt ${i}, FE phase: ${DDC_STATUS:-not ready})"
  sleep 10
done

echo ""
echo "=== Step 11: Create Storage Vault ==="
FE_SVC="doris-disaggregated-fe"
for i in $(seq 1 30); do
  MINIO_IP=$(kubectl get svc minio -n ${NS} -o jsonpath='{.spec.clusterIP}')
  kubectl run mysql-check --image=mysql:5.7 -it --rm --restart=Never --namespace=${NS} -- \
    mysql -uroot -P9030 -h ${FE_SVC} -e "
    CREATE STORAGE VAULT IF NOT EXISTS s3_vault
    PROPERTIES (
      \"type\"=\"S3\",
      \"s3.endpoint\" = \"${MINIO_IP}:9000\",
      \"s3.region\" = \"us-east-1\",
      \"s3.bucket\" = \"doris-data\",
      \"s3.root.path\" = \"doris\",
      \"s3.access_key\" = \"minioadmin\",
      \"s3.secret_key\" = \"minioadmin\",
      \"provider\" = \"S3\"
    );
    SET s3_vault AS DEFAULT STORAGE VAULT;
  " 2>/dev/null && echo "Storage vault created and set as default!" && break
  echo "Waiting for FE to be ready for SQL... (attempt ${i})"
  sleep 10
done

echo ""
echo "============================================"
echo "  Deployment Complete!"
echo "============================================"
echo ""
echo "Resources:"
kubectl get ddc -n ${NS}
echo ""
echo "Pods:"
kubectl get pods -n ${NS}
echo ""
echo "Services:"
kubectl get svc -n ${NS}
echo ""
echo "Access:"
echo "  MySQL: kubectl exec -it <mysql-pod> -- mysql -uroot -P9030 -h doris-disaggregated-fe"
echo "  FE Web: kubectl port-forward svc/doris-disaggregated-fe 8030:8030 -n ${NS}"
echo "  MinIO Console: kubectl port-forward svc/minio 9001:9001 -n ${NS}"
echo "  MinIO Credentials: minioadmin / minioadmin"
