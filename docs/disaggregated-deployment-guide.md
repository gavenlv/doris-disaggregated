# Apache Doris 4.0.4 存算分离部署指南 - 本地 Docker Desktop Kubernetes

## 概述

本指南帮助你在本地 Docker Desktop Kubernetes 环境中部署 Apache Doris 4.0.4 **存算分离（Disaggregated）** 架构。存算分离架构将存储和计算解耦，存储使用共享对象存储（MinIO），计算节点可以独立扩缩容。

## 架构图

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                     Docker Desktop Kubernetes                                      │
├──────────────────────────────────────────────────────────────────────────────────┤
│                                                                                   │
│  ┌────────────────────────────────────────────────────────────────────────────┐  │
│  │                          Doris Namespace (doris)                            │  │
│  │                                                                             │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │  │
│  │  │ FoundationDB │  │  MetaService │  │     FE       │  │     BE       │   │  │
│  │  │   (Stateful  │  │  (Deploy)    │  │ (StatefulSet)│  │ (StatefulSet)│   │  │
│  │  │    Set)      │  │              │  │              │  │              │   │  │
│  │  │              │  │  ┌─────────┐ │  │  ┌─────────┐ │  │  ┌─────────┐ │   │  │
│  │  │  ┌────────┐  │  │  │  MS-0   │ │  │  │  FE-0   │ │  │  │  BE-0   │ │   │  │
│  │  │  │  FDB-0 │  │  │  │ (Meta   │ │  │  │ (Query  │ │  │  │ (Compute│ │   │  │
│  │  │  │        │  │  │  │ Service)│ │  │  │ Planner)│ │  │  │  Node)  │ │   │  │
│  │  │  └────────┘  │  │  └─────────┘ │  │  └─────────┘ │  │  └─────────┘ │   │  │
│  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘   │  │
│  │         │                 │                  │                  │           │  │
│  │         │    ┌────────────┴──────────────────┘                  │           │  │
│  │         │    │  Meta Service API (instance/cluster/vault)        │           │  │
│  │         │    │                                                   │           │  │
│  │         └────┤                                                   │           │  │
│  │              │  ┌────────────────────────────────────────────────┘           │  │
│  │              │  │  RPC (heartbeat, data transfer)                            │  │
│  │              │  │                                                            │  │
│  └──────────────┼──┼──┼────────────────────────────────────────────────────────┘  │
│                 │  │  │                                                            │
│  ┌──────────────┼──┼──┼────────────────────────────────────────────────────────┐  │
│  │              │  │  │  MinIO (对象存储)                                       │  │
│  │  ┌───────────┼──┼──┼──────────────────────────────────────────────────┐     │  │
│  │  │           │  │  │  doris-data bucket                                │     │  │
│  │  │  ┌────────┼──┼──┼────────────────────────────────────────────┐    │     │  │
│  │  │  │  FDB   │  │  │  /doris/data/{tablet_id}/...               │    │     │  │
│  │  │  │  Meta  │  │  │  (存储所有表数据文件)                        │    │     │  │
│  │  │  └────────┼──┼──┼────────────────────────────────────────────┘    │     │  │
│  │  └───────────┼──┼──┼──────────────────────────────────────────────┘     │  │
│  └──────────────┼──┼──┼────────────────────────────────────────────────────┘  │
│                 │  │  │                                                        │
│  ┌──────────────┼──┼──┼────────────────────────────────────────────────────┐  │
│  │              │  │  │  Recycler (Deploy)                                  │  │
│  │  │  ┌────────┼──┼──┼────────────────────────────────────────────┐      │  │
│  │  │  │  回收  │  │  │  定期清理过期数据文件                        │      │  │
│  │  │  │  过期  │  │  │                                            │      │  │
│  │  │  │  数据  │  │  │                                            │      │  │
│  │  │  └────────┼──┼──┼────────────────────────────────────────────┘      │  │
│  │  └───────────┼──┼──┼──────────────────────────────────────────────────┘  │
│  └──────────────┼──┼──┼────────────────────────────────────────────────────┘  │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

## 架构对比

| 组件 | 存算分离 (Disaggregated) | 传统架构 (Shared-Nothing) |
|------|--------------------------|---------------------------|
| 元数据存储 | FoundationDB + Meta Service | FE 内部 BDBJE |
| 数据存储 | MinIO (S3 兼容对象存储) | BE 本地磁盘 |
| 存算耦合 | 解耦，独立扩缩容 | 耦合，存储和计算绑定 |
| BE 角色 | 纯计算节点 (Compute Node) | 存储计算一体 |
| 数据持久性 | 对象存储保证 | 依赖副本数 |
| 适用场景 | 云原生、弹性伸缩 | 传统部署、低延迟 |

## 组件说明

| 组件 | 版本 | 说明 |
|------|------|------|
| FoundationDB | 7.3.69 | 分布式 KV 存储，Meta Service 的元数据后端 |
| Meta Service | 4.0.4 | 存算分离核心组件，管理 instance/cluster/vault |
| Recycler | 4.0.4 | 数据回收器，定期清理过期文件 |
| FE | 4.0.4 | 查询解析、优化、协调 (run_mode=disagg) |
| BE | 4.0.4 | 计算节点 (run_mode=disagg) |
| MinIO | latest | S3 兼容对象存储 |

## 前置条件

### 1. 启用 Docker Desktop Kubernetes

1. 打开 Docker Desktop
2. 进入 Settings -> Kubernetes
3. 勾选 "Enable Kubernetes"
4. 点击 "Apply & Restart"
5. 等待 Kubernetes 启动完成

### 2. 准备 Docker 镜像

确保以下镜像已在本地：

```powershell
docker images | Select-String "doris"
# apache/doris:be-4.0.4
# apache/doris:fe-4.0.4
# apache/doris:ms-4.0.4
```

### 3. 资源要求

- **CPU**: 至少 8 核（推荐 12 核）
- **内存**: 至少 16GB（推荐 32GB）
- **磁盘**: 至少 50GB 可用空间

## 快速部署

### 一键部署脚本

```bash
cd /d/workspace/github/doris-disaggregated
chmod +x scripts/deploy-disaggregated.sh
./scripts/deploy-disaggregated.sh
```

### 手动部署步骤

#### Step 1: 创建命名空间

```powershell
kubectl create namespace doris
```

#### Step 2: 部署 FoundationDB

```powershell
kubectl apply -f k8s/local-disaggregated/00-foundationdb.yaml
kubectl wait --for=condition=ready pod -l app=foundationdb -n doris --timeout=120s
```

#### Step 3: 部署 MinIO

```powershell
kubectl apply -f k8s/local-disaggregated/01-minio.yaml
kubectl wait --for=condition=ready pod -l app=minio -n doris --timeout=120s
```

#### Step 4: 部署 Meta Service 和 Recycler

```powershell
kubectl apply -f k8s/local-disaggregated/02-ms.yaml
kubectl wait --for=condition=ready pod -l app=doris-ms -n doris --timeout=120s
```

#### Step 5: 创建 Instance（注册 MinIO Storage Vault）

```powershell
$MINIO_IP = kubectl get svc minio -n doris -o jsonpath='{.spec.clusterIP}'
$MS_POD = kubectl get pod -l app=doris-ms -n doris -o jsonpath='{.items[0].metadata.name}'

kubectl exec $MS_POD -n doris -c meta-service -- /bin/bash -c @"
curl -s -X POST 'http://127.0.0.1:8080/MetaService/http/create_instance?token=greedisgood9999' `
  -H 'Content-Type: application/json' `
  -d '{
    `"instance_id`": `"doris_instance`",
    `"name`": `"doris_cluster`",
    `"user_id`": `"admin`",
    `"vault`": {
      `"obj_info`": {
        `"ak`": `"minioadmin`",
        `"sk`": `"minioadmin`",
        `"bucket`": `"doris-data`",
        `"prefix`": `"doris`",
        `"endpoint`": `"$MINIO_IP:9000`",
        `"external_endpoint`": `"$MINIO_IP:9000`",
        `"region`": `"us-east-1`",
        `"provider`": `"S3`"
      }
    }
  }'
"@
```

#### Step 6: 部署 FE 和 BE

```powershell
kubectl apply -f k8s/local-disaggregated/03-fe.yaml
kubectl apply -f k8s/local-disaggregated/04-be.yaml
kubectl wait --for=condition=ready pod -l app=doris-fe -n doris --timeout=300s
kubectl wait --for=condition=ready pod -l app=doris-be -n doris --timeout=300s
```

> **注意**: FE 和 BE 的启动脚本中已内置自动注册逻辑，会自动获取当前 Pod IP 并注册到 Meta Service。

#### Step 7: 设置默认 Storage Vault

```powershell
$FE_POD = kubectl get pod -l app=doris-fe -n doris -o jsonpath='{.items[0].metadata.name}'
kubectl exec $FE_POD -n doris -- mysql -h 127.0.0.1 -P 9030 -u root -e "SET built_in_storage_vault AS DEFAULT STORAGE VAULT"
```

## 验证部署

### 检查组件状态

```powershell
kubectl get pods -n doris -o wide
kubectl get svc -n doris
```

预期输出：
```
NAME                          READY   STATUS    RESTARTS   AGE
doris-be-0                    1/1     Running   0          5m
doris-fe-0                    1/1     Running   0          5m
doris-ms-6b8f9c9d4-xxxxx      1/2     Running   0          10m
doris-recycler-7f8d9c5b-xxx   1/1     Running   0          10m
foundationdb-0                1/1     Running   0          12m
minio-8f9b8dfbd-xxxxx         1/1     Running   0          12m
```

### 连接 Doris

```powershell
# 后台端口转发
Start-Process -FilePath "kubectl" -ArgumentList "port-forward","-n","doris","svc/doris-fe","8030:8030","9030:9030" -WindowStyle Hidden
Start-Process -FilePath "kubectl" -ArgumentList "port-forward","-n","doris","svc/minio","9000:9000","9001:9001" -WindowStyle Hidden

# 连接 MySQL
kubectl exec doris-fe-0 -n doris -- mysql -h 127.0.0.1 -P 9030 -u root
```

### 功能验证

```sql
-- 查看 Clusters
SHOW CLUSTERS;

-- 查看 Storage Vault
SHOW STORAGE VAULT;

-- 创建数据库
CREATE DATABASE test;
USE test;

-- 创建表（存算分离模式需要指定 storage_vault_name）
CREATE TABLE test_table (
    id BIGINT NULL,
    name VARCHAR(256) NULL
) ENGINE=OLAP
UNIQUE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 3
PROPERTIES (
    "replication_num" = "1",
    "storage_vault_name" = "built_in_storage_vault"
);

-- 插入数据
INSERT INTO test_table VALUES (1, 'hello'), (2, 'doris'), (3, 'cloud');

-- 查询数据
SELECT * FROM test_table ORDER BY id;
```

### 验证数据存储在 MinIO

```powershell
$MINIO_POD = kubectl get pod -l app=minio -n doris -o jsonpath='{.items[0].metadata.name}'
kubectl exec $MINIO_POD -n doris -- /bin/bash -c 'mc alias set myminio http://localhost:9000 minioadmin minioadmin; mc ls myminio/doris-data/ --recursive'
```

预期输出（应看到 .dat 数据文件）：
```
[2026-03-30 11:16:44 UTC]  13KiB STANDARD doris/data/1774868674072/02000000000000023e4f659769006b6bf70777e549465aab_0.dat
[2026-03-30 11:17:44 UTC]  14KiB STANDARD doris/data/1774868674072/02000000000000043e4f659769006b6bf70777e549465aab_0.dat
```

## 访问凭据

| 服务 | 地址 | 用户名 | 密码 |
|------|------|--------|------|
| Doris FE (MySQL) | 127.0.0.1:9030 | root | (空) |
| Doris FE (HTTP) | 127.0.0.1:8030 | root | (空) |
| Meta Service API | 127.0.0.1:8080 | token | greedisgood9999 |
| MinIO Console | http://127.0.0.1:9001 | minioadmin | minioadmin |
| MinIO S3 API | 127.0.0.1:9000 | minioadmin | minioadmin |

## Meta Service API 常用操作

```powershell
$MS_URL = "http://127.0.0.1:8080"
$TOKEN = "greedisgood9999"

# 查看 Instance 信息
kubectl port-forward svc/doris-ms 8080:8080 -n doris
curl "${MS_URL}/MetaService/http/get_instance?instance_id=doris_instance&token=${TOKEN}"

# 查看 Cluster 信息
curl "${MS_URL}/MetaService/http/get_cluster?instance_id=doris_instance&cluster_name=default_compute_cluster&token=${TOKEN}"

# 查看 Storage Vault
curl "${MS_URL}/MetaService/http/get_vault?instance_id=doris_instance&vault_name=built_in_storage_vault&token=${TOKEN}"
```

## 文件结构

```
k8s/local-disaggregated/
├── 00-foundationdb.yaml    # FoundationDB 部署
├── 01-minio.yaml           # MinIO 对象存储部署
├── 02-ms.yaml              # Meta Service + Recycler 部署
├── 03-fe.yaml              # FE (存算分离模式) 部署
└── 04-be.yaml              # BE (计算节点) 部署

scripts/
├── deploy-disaggregated.sh # 一键部署脚本
├── test-create-table.sql   # 建表测试 SQL
└── test-query.sql          # 数据查询测试 SQL
```

## 关键配置说明

### FE 配置 (disagg 模式)

```properties
run_mode = disagg
meta_service_endpoint = doris-ms:8080
cloud_unique_id = 1:doris_instance:cloud_unique_id_fe00
```

### BE 配置 (disagg 模式)

```properties
run_mode = disagg
meta_service_endpoint = doris-ms:8080
cloud_unique_id = 1:doris_instance:cloud_unique_id_be00
meta_service_use_load_balancer = false
enable_file_cache = true
file_cache_path = [{"path":"/opt/apache-doris/be/file_cache","total_size":10737418240,"query_limit":1073741824}]
storage_root_path = /opt/apache-doris/be/storage
```

### 自动注册机制

FE 和 BE 启动时会自动：
1. 等待 Meta Service 中的 instance 创建完成
2. 获取当前 Pod IP
3. 调用 Meta Service API 注册自己到对应的 cluster
4. 然后启动 Doris 进程

这解决了 Pod 重启后 IP 变化导致注册信息失效的问题。

## 常见问题

### 1. Meta Service 启动失败

```powershell
# 检查 FDB 连接
kubectl exec <ms-pod> -n doris -c meta-service -- cat /etc/foundationdb/fdb.cluster

# 检查 MS 日志
kubectl logs <ms-pod> -n doris -c meta-service --tail=50
```

### 2. FE 报 "No default storage vault"

```sql
-- 在 FE 中执行
SET built_in_storage_vault AS DEFAULT STORAGE VAULT;
```

### 3. BE 无法连接到 Meta Service

```powershell
# 检查 BE 日志
kubectl logs doris-be-0 -n doris --tail=50

# 检查 Meta Service 是否可达
kubectl exec doris-be-0 -n doris -- curl -s http://doris-ms:8080/MetaService/http/health
```

### 4. Pod IP 变化导致注册失效

FE/BE 已内置自动注册逻辑，Pod 重启后会自动使用新 IP 重新注册。如需手动更新：

```powershell
# 获取新 IP
$BE_IP = kubectl get pod doris-be-0 -n doris -o jsonpath='{.status.podIP}'

# 通过 Meta Service API 更新
curl -X POST "http://127.0.0.1:8080/MetaService/http/add_cluster?token=greedisgood9999" `
  -H "Content-Type: application/json" `
  -d "{...}"
```

## 清理资源

```powershell
kubectl delete namespace doris
```

## 相关文档

- [架构设计文档](architecture-design.md)
- [设计决策详解](design-decisions.md)
- [GKE 生产部署指南](deployment-guide.md)
- [本地传统部署指南](local-deployment-guide.md)
