#!/bin/bash

set -e

NAMESPACE=${NAMESPACE:-doris}
MS_TOKEN=${MS_TOKEN:-greedisgood9999}

echo "============================================"
echo "初始化 Doris 存算分离集群"
echo "============================================"

echo "[1/5] 检查 FoundationDB..."
kubectl exec foundationdb-0 -n ${NAMESPACE} -- fdbcli --exec "status" | head -20

echo "[2/5] 检查 Meta Service 健康状态..."
MS_POD=$(kubectl get pod -l app=doris-meta-service -n ${NAMESPACE} -o jsonpath='{.items[0].metadata.name}')
kubectl exec ${MS_POD} -n ${NAMESPACE} -c meta-service -- \
    curl -s "http://127.0.0.1:5000/MetaService/http/health?token=${MS_TOKEN}"

echo "[3/5] 创建 Instance..."
kubectl exec ${MS_POD} -n ${NAMESPACE} -c meta-service -- \
    curl -s -X POST "http://127.0.0.1:5000/MetaService/http/create_instance?token=${MS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
        "instance_id": "doris_instance",
        "name": "doris_cluster",
        "user_id": "admin",
        "vault": {
            "obj_info": {
                "ak": "",
                "sk": "",
                "bucket": "",
                "prefix": "",
                "endpoint": "",
                "external_endpoint": "",
                "region": "",
                "provider": ""
            }
        }
    }'

echo ""
echo "[4/5] 创建 Cluster..."
kubectl exec ${MS_POD} -n ${NAMESPACE} -c meta-service -- \
    curl -s -X POST "http://127.0.0.1:5000/MetaService/http/add_cluster?token=${MS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
        "instance_id": "doris_instance",
        "cluster": {
            "cluster_name": "default_storage_cluster",
            "cluster_type": "SSD",
            "nodes": []
        }
    }'

kubectl exec ${MS_POD} -n ${NAMESPACE} -c meta-service -- \
    curl -s -X POST "http://127.0.0.1:5000/MetaService/http/add_cluster?token=${MS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
        "instance_id": "doris_instance",
        "cluster": {
            "cluster_name": "default_compute_cluster",
            "cluster_type": "SSD",
            "nodes": []
        }
    }'

echo ""
echo "[5/5] 验证集群状态..."
kubectl exec ${MS_POD} -n ${NAMESPACE} -c meta-service -- \
    curl -s "http://127.0.0.1:5000/MetaService/http/get_instance?instance_id=doris_instance&token=${MS_TOKEN}" | \
    python3 -m json.tool 2>/dev/null || cat

echo ""
echo "============================================"
echo "集群初始化完成!"
echo "============================================"
