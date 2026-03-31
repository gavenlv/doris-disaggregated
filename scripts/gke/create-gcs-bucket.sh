#!/bin/bash

set -e

PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}
REGION=${REGION:-asia-east1}
BUCKET_NAME=${BUCKET_NAME:-doris-gcs-data-${PROJECT_ID}}
SERVICE_ACCOUNT=${SERVICE_ACCOUNT:-doris-sa}

echo "============================================"
echo "创建 GCS Bucket for Doris"
echo "============================================"
echo "Project: ${PROJECT_ID}"
echo "Region: ${REGION}"
echo "Bucket: ${BUCKET_NAME}"
echo "Service Account: ${SERVICE_ACCOUNT}"
echo "============================================"

echo "[1/4] 创建 GCS Bucket..."
if gsutil mb -p ${PROJECT_ID} -l ${REGION} gs://${BUCKET_NAME} 2>/dev/null; then
    echo "Bucket 创建成功"
else
    echo "Bucket 已存在，跳过创建"
fi

echo "[2/4] 配置生命周期管理..."
cat > /tmp/lifecycle-config.json <<EOF
{"rule": [{"action": {"type": "Delete"}, "condition": {"age": 365}}]}
EOF
gsutil lifecycle set /tmp/lifecycle-config.json gs://${BUCKET_NAME}
rm /tmp/lifecycle-config.json

echo "[3/4] 启用版本控制..."
gsutil versioning set on gs://${BUCKET_NAME}

echo "[4/4] 创建服务账号并配置权限..."
if ! gcloud iam service-accounts describe ${SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com --project=${PROJECT_ID} 2>/dev/null; then
    gcloud iam service-accounts create ${SERVICE_ACCOUNT} \
        --display-name="Doris Service Account" \
        --project=${PROJECT_ID}
fi

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/storage.objectAdmin"

echo ""
echo "============================================"
echo "GCS Bucket 配置完成!"
echo "============================================"
echo ""
echo "Bucket 信息:"
echo "  gs://${BUCKET_NAME}"
echo ""
echo "Service Account:"
echo "  ${SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com"
echo ""
echo "下一步:"
echo "  1. 运行 ./deploy-gke.sh 部署集群"
echo "  2. 或运行 ./init-cluster.sh 初始化集群"
echo ""
