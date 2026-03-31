#!/bin/bash
set -e

FE_IP="10.1.0.228"
BE_IP="10.1.0.229"
MINIO_IP="10.109.238.205"
MS_URL="http://127.0.0.1:8080"
TOKEN="greedisgood9999"

echo "=== Step 1: Create instance with MinIO vault ==="
curl -s -X POST "${MS_URL}/MetaService/http/create_instance?token=${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "instance_id": "doris_instance",
    "name": "doris_cluster",
    "user_id": "admin",
    "vault": {
      "obj_info": {
        "ak": "minioadmin",
        "sk": "minioadmin",
        "bucket": "doris-data",
        "prefix": "doris",
        "endpoint": "'${MINIO_IP}':9000",
        "external_endpoint": "'${MINIO_IP}':9000",
        "region": "us-east-1",
        "provider": "S3"
      }
    }
  }'

echo ""
echo "=== Step 2: Verify instance ==="
curl -s "${MS_URL}/MetaService/http/get_instance?instance_id=doris_instance&token=${TOKEN}"

echo ""
echo "=== Step 3: Add FE cluster ==="
curl -s -X POST "${MS_URL}/MetaService/http/add_cluster?token=${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "instance_id": "doris_instance",
    "cluster": {
      "type": "SQL",
      "cluster_name": "RESERVED_CLUSTER_NAME_FOR_SQL_SERVER",
      "cluster_id": "RESERVED_CLUSTER_ID_FOR_SQL_SERVER",
      "nodes": [
        {
          "cloud_unique_id": "1:doris_instance:cloud_unique_id_fe00",
          "ip": "'${FE_IP}'",
          "edit_log_port": 9010,
          "node_type": "FE_MASTER"
        }
      ]
    }
  }'

echo ""
echo "=== Step 4: Add BE cluster ==="
curl -s -X POST "${MS_URL}/MetaService/http/add_cluster?token=${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "instance_id": "doris_instance",
    "cluster": {
      "type": "COMPUTE",
      "cluster_name": "default_compute_cluster",
      "cluster_id": "10001",
      "nodes": [
        {
          "cloud_unique_id": "1:doris_instance:cloud_unique_id_be00",
          "ip": "'${BE_IP}'",
          "heartbeat_port": 9050,
          "be_port": 9060,
          "brpc_port": 8060
        }
      ]
    }
  }'

echo ""
echo "=== Step 5: Verify FE cluster ==="
curl -s "${MS_URL}/MetaService/http/get_cluster?token=${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "instance_id": "doris_instance",
    "cloud_unique_id": "1:doris_instance:cloud_unique_id_fe00",
    "cluster_name": "RESERVED_CLUSTER_NAME_FOR_SQL_SERVER",
    "cluster_id": "RESERVED_CLUSTER_ID_FOR_SQL_SERVER"
  }'

echo ""
echo "=== All Done ==="
