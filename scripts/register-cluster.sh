#!/bin/bash
MS_POD=$(kubectl get pod -l app=doris-ms -n doris -o jsonpath='{.items[0].metadata.name}')
FE_IP=$(kubectl get pod doris-fe-0 -n doris -o jsonpath='{.status.podIP}')
BE_IP=$(kubectl get pod doris-be-0 -n doris -o jsonpath='{.status.podIP}')

echo "MS Pod: $MS_POD"
echo "FE IP: $FE_IP"
echo "BE IP: $BE_IP"

echo "=== Adding FE to cluster ==="
kubectl exec $MS_POD -n doris -- /bin/bash -c "curl -s -X POST 'http://127.0.0.1:8080/MetaService/http/add_cluster?token=greedisgood9999' -H 'Content-Type: application/json' -d '{\"instance_id\":\"doris_instance\",\"cluster\":{\"type\":\"SQL\",\"cluster_name\":\"RESERVED_CLUSTER_NAME_FOR_SQL_SERVER\",\"cluster_id\":\"RESERVED_CLUSTER_ID_FOR_SQL_SERVER\",\"nodes\":[{\"cloud_unique_id\":\"1:doris_instance:cloud_unique_id_fe00\",\"ip\":\"${FE_IP}\",\"edit_log_port\":9010,\"node_type\":\"FE_MASTER\",\"heartbeat_port\":9050}]}}'"

echo ""
echo "=== Adding BE to cluster ==="
kubectl exec $MS_POD -n doris -- /bin/bash -c "curl -s -X POST 'http://127.0.0.1:8080/MetaService/http/add_cluster?token=greedisgood9999' -H 'Content-Type: application/json' -d '{\"instance_id\":\"doris_instance\",\"cluster\":{\"type\":\"COMPUTE\",\"cluster_name\":\"default_compute_cluster\",\"cluster_id\":\"10001\",\"nodes\":[{\"cloud_unique_id\":\"1:doris_instance:cloud_unique_id_be00\",\"ip\":\"${BE_IP}\",\"heartbeat_port\":9050,\"be_port\":9060,\"brpc_port\":8060}]}}'"

echo ""
echo "=== Verifying instance ==="
kubectl exec $MS_POD -n doris -- curl -s "http://127.0.0.1:8080/MetaService/http/get_instance?instance_id=doris_instance&token=greedisgood9999"

echo ""
echo "=== Done ==="
