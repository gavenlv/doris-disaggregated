$msPod = kubectl get pod -l app=doris-ms -n doris -o jsonpath='{.items[0].metadata.name}'
$feIP = kubectl get pod doris-fe-0 -n doris -o jsonpath='{.status.podIP}'
$beIP = kubectl get pod doris-be-0 -n doris -o jsonpath='{.status.podIP}'

Write-Host "MS Pod: $msPod"
Write-Host "FE IP: $feIP"
Write-Host "BE IP: $beIP"

Write-Host "`n=== Adding FE to cluster ==="
kubectl exec $msPod -n doris -- /bin/bash -c @"
echo '{"instance_id":"doris_instance","cluster":{"type":"SQL","cluster_name":"RESERVED_CLUSTER_NAME_FOR_SQL_SERVER","cluster_id":"RESERVED_CLUSTER_ID_FOR_SQL_SERVER","nodes":[{"cloud_unique_id":"1:doris_instance:cloud_unique_id_fe00","ip":"$feIP","edit_log_port":9010,"node_type":"FE_MASTER","heartbeat_port":9050}]}}' > /tmp/add_fe.json
curl -s -X POST 'http://127.0.0.1:8080/MetaService/http/add_cluster?token=greedisgood9999' -H 'Content-Type: application/json' -d @/tmp/add_fe.json
"@

Write-Host "`n=== Adding BE to cluster ==="
kubectl exec $msPod -n doris -- /bin/bash -c @"
echo '{"instance_id":"doris_instance","cluster":{"type":"COMPUTE","cluster_name":"default_compute_cluster","cluster_id":"10001","nodes":[{"cloud_unique_id":"1:doris_instance:cloud_unique_id_be00","ip":"$beIP","heartbeat_port":9050,"be_port":9060,"brpc_port":8060}]}}' > /tmp/add_be.json
curl -s -X POST 'http://127.0.0.1:8080/MetaService/http/add_cluster?token=greedisgood9999' -H 'Content-Type: application/json' -d @/tmp/add_be.json
"@

Write-Host "`n=== Verifying instance ==="
kubectl exec $msPod -n doris -- curl -s "http://127.0.0.1:8080/MetaService/http/get_instance?instance_id=doris_instance&token=greedisgood9999"

Write-Host "`n=== Done ==="
