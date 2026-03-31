#!/bin/bash
set -e
MS_URL="http://127.0.0.1:8080"
TOKEN="greedisgood9999"
echo "=== Drop old BE cluster ==="
curl -s -X POST "${MS_URL}/MetaService/http/drop_cluster?token=${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"instance_id":"doris_instance","cluster_name":"default_compute_cluster","cluster_id":"10001"}'
echo ""
echo "=== Add BE cluster with new IP ==="
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
          "ip": "10.1.0.231",
          "heartbeat_port": 9050,
          "be_port": 9060,
          "brpc_port": 8060
        }
      ]
    }
  }'
echo ""
echo "=== Verify ==="
curl -s "${MS_URL}/MetaService/http/get_cluster?token=${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"instance_id":"doris_instance","cloud_unique_id":"1:doris_instance:cloud_unique_id_be00","cluster_name":"default_compute_cluster","cluster_id":"10001"}'
echo ""
echo "=== Done ==="
