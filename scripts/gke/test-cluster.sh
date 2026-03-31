#!/bin/bash

set -e

NAMESPACE=${NAMESPACE:-doris}
FE_POD=${FE_POD:-doris-disaggregated-fe-0}

echo "============================================"
echo "测试 Doris 存算分离集群"
echo "============================================"

echo "[1/6] 检查 Pods 状态..."
kubectl get pods -n ${NAMESPACE} -o wide

echo ""
echo "[2/6] 检查 FE 状态..."
kubectl exec ${FE_POD} -n ${NAMESPACE} -- mysql -h 127.0.0.1 -P 9030 -u root -e "SHOW FRONTENDS\G"

echo ""
echo "[3/6] 检查 BE 状态..."
kubectl exec ${FE_POD} -n ${NAMESPACE} -- mysql -h 127.0.0.1 -P 9030 -u root -e "SHOW BACKENDS\G"

echo ""
echo "[4/6] 检查 Storage Vault..."
kubectl exec ${FE_POD} -n ${NAMESPACE} -- mysql -h 127.0.0.1 -P 9030 -u root -e "SHOW STORAGE VAULT;"

echo ""
echo "[5/6] 创建测试数据库..."
kubectl exec ${FE_POD} -n ${NAMESPACE} -- mysql -h 127.0.0.1 -P 9030 -u root -e "
DROP DATABASE IF EXISTS test_gke;
CREATE DATABASE test_gke;
USE test_gke;

CREATE TABLE test_table (
    id BIGINT NOT NULL,
    name VARCHAR(100) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=OLAP
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 3
PROPERTIES (
    'replication_num' = '1'
);

INSERT INTO test_table (id, name) VALUES (1, 'test1'), (2, 'test2'), (3, 'test3');
SELECT * FROM test_table ORDER BY id;
"

echo ""
echo "[6/6] 验证 GCS 数据持久化..."
kubectl exec ${FE_POD} -n ${NAMESPACE} -- mysql -h 127.0.0.1 -P 9030 -u root -e "
USE test_gke;
SELECT COUNT(*) as total_rows FROM test_table;
"

echo ""
echo "============================================"
echo "测试完成!"
echo "============================================"
