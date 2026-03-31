#!/bin/bash
set -e
MS_URL="http://127.0.0.1:8080"
TOKEN="greedisgood9999"

cat > /tmp/drop_be.json << 'EOF'
{"instance_id":"doris_instance","cluster_name":"default_compute_cluster","cluster_id":"10001"}
EOF

cat > /tmp/drop_fe.json << 'EOF'
{"instance_id":"doris_instance","cluster_name":"RESERVED_CLUSTER_NAME_FOR_SQL_SERVER","cluster_id":"RESERVED_CLUSTER_ID_FOR_SQL_SERVER"}
EOF

cat > /tmp/drop_inst.json << 'EOF'
{"instance_id":"doris_instance"}
EOF

echo "=== Drop BE cluster ==="
curl -s -X POST "${MS_URL}/MetaService/http/drop_cluster?token=${TOKEN}" \
  -H "Content-Type: application/json" \
  -d @/tmp/drop_be.json
echo ""

echo "=== Drop FE cluster ==="
curl -s -X POST "${MS_URL}/MetaService/http/drop_cluster?token=${TOKEN}" \
  -H "Content-Type: application/json" \
  -d @/tmp/drop_fe.json
echo ""

echo "=== Drop instance ==="
curl -s -X POST "${MS_URL}/MetaService/http/drop_instance?token=${TOKEN}" \
  -H "Content-Type: application/json" \
  -d @/tmp/drop_inst.json
echo ""

echo "=== Done ==="
