#!/bin/bash

set -e

PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
CLUSTER_NAME=${CLUSTER_NAME:-doris-cluster}
REGION=${REGION:-asia-east1}
NAMESPACE=${NAMESPACE:-doris}
GCS_BUCKET=${GCS_BUCKET:-doris-gcs-data-${PROJECT_ID}}

echo "============================================"
echo "GKE Doris 存算分离集群部署脚本 (Operator)"
echo "============================================"
echo "Project: ${PROJECT_ID}"
echo "Region: ${REGION}"
echo "Cluster: ${CLUSTER_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "GCS Bucket: ${GCS_BUCKET}"
echo "============================================"

echo "[1/6] 配置 kubectl..."
gcloud container clusters get-credentials ${CLUSTER_NAME} --region=${REGION}
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

echo "[2/6] 部署 FDB Operator..."
kubectl apply -f ../k8s/gke/00-fdb-operator.yaml
kubectl wait --for=condition=ready deployment/fdb-kubernetes-operator-controller-manager -n ${NAMESPACE} --timeout=120s

echo "[3/6] 部署 FoundationDB Cluster (由 FDB Operator 管理)..."
kubectl apply -f ../k8s/gke/01-fdb-cluster.yaml
echo "等待 FoundationDB 就绪..."
kubectl wait --for=condition=ready foundationdbcluster/doris-fdb -n ${NAMESPACE} --timeout=300s

echo "[4/6] 部署 Doris Operator..."
kubectl apply -f ../k8s/gke/02-doris-operator.yaml
kubectl wait --for=condition=ready deployment/doris-operator-controller-manager -n ${NAMESPACE} --timeout=120s

echo "[5/6] 部署 Doris 存算分离集群..."
kubectl apply -f ../k8s/gke/03-doris-disaggregated-cluster.yaml
echo "等待 FE 就绪..."
kubectl wait --for=condition=ready pod -l app=doris-disaggregated-fe -n ${NAMESPACE} --timeout=300s
echo "等待 Compute Nodes 就绪..."
kubectl wait --for=condition=ready pod -l app=doris-disaggregated-cg1 -n ${NAMESPACE} --timeout=300s

echo "[6/6] 部署 Services (LoadBalancer)..."
kubectl apply -f ../k8s/gke/04-services.yaml

echo ""
echo "============================================"
echo "部署完成!"
echo "============================================"
echo ""
echo "FE 访问:"
echo "  MySQL: kubectl exec -it doris-disaggregated-fe-0 -n ${NAMESPACE} -- mysql -h 127.0.0.1 -P 9030 -u root"
echo ""
echo "查看服务:"
echo "  kubectl get svc -n ${NAMESPACE}"
echo ""
echo "查看 Pods:"
echo "  kubectl get pods -n ${NAMESPACE} -o wide"
echo ""
echo "查看 FDB 集群:"
echo "  kubectl get foundationdbcluster -n ${NAMESPACE}"
echo ""
echo "查看 Doris 集群:"
echo "  kubectl get dorisdisaggregatedcluster -n ${NAMESPACE}"
echo ""
