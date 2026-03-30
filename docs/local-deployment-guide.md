# Apache Doris 4.0.4 本地部署指南 - Docker Desktop Kubernetes

## 概述

本指南帮助你在本地Docker Desktop Kubernetes环境中部署Apache Doris 4.0.4，用于开发、测试和学习。

## 架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Docker Desktop Kubernetes                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                          Doris Namespace                               │  │
│  │                                                                       │  │
│  │  ┌─────────────────┐         ┌─────────────────┐                     │  │
│  │  │      FE         │         │      BE         │                     │  │
│  │  │  ┌───────────┐  │         │  ┌───────────┐  │                     │  │
│  │  │  │  FE-0     │  │◄──────►│  │  BE-0     │  │                     │  │
│  │  │  │ (Leader)  │  │  RPC   │  │ (Storage) │  │                     │  │
│  │  │  └───────────┘  │         │  └───────────┘  │                     │  │
│  │  └────────┬────────┘         └────────┬────────┘                     │  │
│  │           │                           │                               │  │
│  │  ┌────────┴────────┐         ┌─────────┴────────┐                     │  │
│  │  │  FE Service    │         │  BE Service      │                     │  │
│  │  │  ClusterIP     │         │  ClusterIP       │                     │  │
│  │  └────────────────┘         └─────────────────┘                     │  │
│  │                                                                       │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                         MinIO (对象存储)                              │  │
│  │  ┌─────────────────┐    ┌─────────────────┐                           │  │
│  │  │   minio        │    │   minio-setup   │                           │  │
│  │  │   (Deployment) │    │   (Job)         │                           │  │
│  │  └─────────────────┘    └─────────────────┘                           │  │
│  │                                                                       │  │
│  │  ┌─────────────────────────────────────────┐                          │  │
│  │  │         doris-data Bucket                │                          │  │
│  │  │    (用于未来存算分离架构的数据存储)       │                          │  │
│  │  └─────────────────────────────────────────┘                          │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                       Storage (emptyDir)                              │  │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐                     │  │
│  │  │  FE Meta    │ │  BE Storage │ │  BE Cache   │                     │  │
│  │  │  (10Gi)     │ │  (20Gi)    │ │  (10Gi)    │                     │  │
│  │  └─────────────┘ └─────────────┘ └─────────────┘                     │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 架构对比

| 组件 | GKE生产环境 | 本地开发环境 |
|------|-------------|--------------|
| 对象存储 | GCS | MinIO |
| 存储类 | GCE PD | hostpath |
| FE节点 | 3 (高可用) | 1 (单节点) |
| BE节点 | 3+ | 1 |
| FE内存 | 32GB | 4GB |
| BE内存 | 128GB | 8GB |

> **注意**: 本地部署使用传统FE+BE架构，MS(MetaService)和CN(Compute Node)需要FoundationDB等额外依赖，适合生产环境的存算分离架构需要额外的配置。

## 前置条件

### 1. 启用Docker Desktop Kubernetes

1. 打开Docker Desktop
2. 进入 Settings -> Kubernetes
3. 勾选 "Enable Kubernetes"
4. 点击 "Apply & Restart"
5. 等待Kubernetes启动完成（左下角显示绿色K图标）

### 2. 验证Kubernetes

```powershell
# 检查集群状态
kubectl cluster-info

# 检查节点
kubectl get nodes

# 确认使用docker-desktop context
kubectl config current-context
```

### 3. 资源要求

确保Docker Desktop分配了足够的资源：

- **CPU**: 至少8核
- **内存**: 至少16GB（推荐32GB）
- **磁盘**: 至少100GB可用空间

配置方法：Docker Desktop -> Settings -> Resources

## 快速部署

### 使用PowerShell脚本（推荐）

```powershell
# 进入项目目录
cd d:\workspace\github\doris-disaggregated

# 一键部署
.\scripts\deploy-local.ps1 deploy
```

### 使用Bash脚本

```bash
# 进入项目目录
cd /d/workspace/github/doris-disaggregated

# 添加执行权限
chmod +x scripts/deploy-local.sh

# 一键部署
./scripts/deploy-local.sh deploy
```

### 手动部署

```powershell
# 1. 部署MinIO（对象存储）
kubectl apply -f k8s/local/00-minio.yaml
kubectl wait --for=condition=ready pod -l app=minio -n doris --timeout=120s

# 2. 部署存储类
kubectl apply -f k8s/local/00-storageclass.yaml

# 3. 部署Frontend
kubectl apply -f k8s/local/02-fe.yaml
kubectl wait --for=condition=ready pod -l app=doris-fe -n doris --timeout=180s

# 4. 部署Backend
kubectl apply -f k8s/local/03-be.yaml
kubectl wait --for=condition=ready pod -l app=doris-be -n doris --timeout=180s

# 5. 注册Backend到Frontend（重要！）
# 获取BE Pod IP
$BE_IP = kubectl get pod doris-be-0 -n doris -o jsonpath='{.status.podIP}'
# 注册BE（使用heartbeat端口9050）
kubectl exec doris-fe-0 -n doris -- mysql -h 127.0.0.1 -P 9030 -u root -e "ALTER SYSTEM ADD BACKEND '${BE_IP}:9050';"

# 6. 验证注册成功
kubectl exec doris-fe-0 -n doris -- mysql -h 127.0.0.1 -P 9030 -u root -e "SHOW BACKENDS;"
```

## 验证部署

### 检查组件状态

```powershell
# 查看所有Pod
kubectl get pods -n doris -o wide

# 查看服务
kubectl get svc -n doris

# 查看PVC
kubectl get pvc -n doris
```

### 连接Doris

#### 方式1: MySQL客户端

```powershell
# 后台运行端口转发
Start-Process -FilePath "kubectl" -ArgumentList "port-forward","-n","doris","svc/doris-fe","9030:9030" -WindowStyle Hidden

# 连接Doris
mysql -h 127.0.0.1 -P 9030 -u root
```

#### 方式2: HTTP API

```powershell
# 后台运行端口转发
Start-Process -FilePath "kubectl" -ArgumentList "port-forward","-n","doris","svc/doris-fe","8030:8030" -WindowStyle Hidden

# 浏览器访问
# http://localhost:8030
```

#### 方式3: MinIO控制台

```powershell
# 后台运行端口转发
Start-Process -FilePath "kubectl" -ArgumentList "port-forward","-n","doris","svc/minio","9001:9001" -WindowStyle Hidden

# 浏览器访问
# http://localhost:9001
# 用户名: minioadmin
# 密码: minioadmin
```

### 访问凭据汇总

| 服务 | 地址 | 用户名 | 密码 |
|------|------|--------|------|
| Doris FE (MySQL) | 127.0.0.1:9030 | root | (空) |
| Doris FE (HTTP) | 127.0.0.1:8030 | root | (空) |
| MinIO Console | http://127.0.0.1:9001 | minioadmin | minioadmin |
| MinIO S3 | 127.0.0.1:9000 | minioadmin | minioadmin |

> **提示**: 部署脚本已配置为自动设置后台端口转发，每次部署完成后可直接访问上述服务。

## 功能验证

### 1. 基础功能测试

```sql
-- 连接到Doris
mysql -h 127.0.0.1 -P 9030 -u root

-- 查看FE状态
SHOW FRONTENDS;

-- 查看BE状态
SHOW BACKENDS;

-- 创建数据库
CREATE DATABASE test_db;
USE test_db;

-- 创建表
CREATE TABLE test_table (
    id INT,
    name VARCHAR(100),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=OLAP
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 3
PROPERTIES (
    "replication_num" = "1"
);

-- 插入数据
INSERT INTO test_table VALUES (1, 'test1', NOW());
INSERT INTO test_table VALUES (2, 'test2', NOW());
INSERT INTO test_table VALUES (3, 'test3', NOW());

-- 查询数据
SELECT * FROM test_table;

-- 统计查询
SELECT COUNT(*) FROM test_table;
```

### 2. 存算分离验证

```sql
-- 查看数据文件位置
SHOW TABLET FROM test_table;

-- 验证数据存储在MinIO
-- 打开MinIO控制台: http://localhost:9001
-- 查看 doris-data bucket
```

### 3. 性能测试

```sql
-- 创建大表测试
CREATE TABLE perf_test (
    id BIGINT,
    value DOUBLE,
    data VARCHAR(1000)
) ENGINE=OLAP
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 10
PROPERTIES (
    "replication_num" = "1"
);

-- 插入测试数据（需要一些时间）
INSERT INTO perf_test 
SELECT 
    seq AS id,
    RAND() AS value,
    CONCAT('data_', seq) AS data
FROM (
    SELECT @rownum := @rownum + 1 AS seq
    FROM information_schema.columns a, information_schema.columns b,
    (SELECT @rownum := 0) r
    LIMIT 100000
) t;

-- 查询测试
SELECT COUNT(*) FROM perf_test;
SELECT AVG(value) FROM perf_test;
SELECT * FROM perf_test WHERE id < 100;

-- 开启向量化引擎
SET enable_vectorized_engine = true;
SET enable_pipeline_engine = true;

-- 再次查询，观察性能差异
SELECT AVG(value) FROM perf_test;
```

## 常见问题

### 1. Pod一直处于Pending状态

```powershell
# 检查Pod事件
kubectl describe pod <pod-name> -n doris

# 常见原因:
# - 资源不足: 减少资源配置或增加Docker Desktop资源
# - PVC未绑定: 检查storageclass
```

### 2. Pod启动失败

```powershell
# 查看Pod日志
kubectl logs <pod-name> -n doris

# 查看Pod详情
kubectl describe pod <pod-name> -n doris
```

### 3. 无法连接Doris

```powershell
# 检查端口转发是否正常
kubectl get svc -n doris

# 重新建立端口转发
kubectl port-forward svc/doris-fe 9030:9030 -n doris
```

### 4. MinIO无法访问

```powershell
# 检查MinIO Pod状态
kubectl get pods -l app=minio -n doris

# 查看MinIO日志
kubectl logs -l app=minio -n doris

# 重新部署MinIO
kubectl rollout restart deployment/minio -n doris
```

## 清理资源

```powershell
# 删除所有资源
.\scripts\deploy-local.ps1 cleanup

# 或手动删除
kubectl delete namespace doris
```

## 配置说明

### 资源配置（本地环境优化）

| 组件 | CPU请求 | CPU限制 | 内存请求 | 内存限制 |
|------|---------|---------|----------|----------|
| MinIO | 500m | 1 | 1Gi | 2Gi |
| MS | 500m | 1 | 2Gi | 4Gi |
| FE | 1 | 2 | 4Gi | 8Gi |
| BE | 2 | 4 | 8Gi | 16Gi |
| CN | 2 | 4 | 4Gi | 8Gi |

### 存储配置

| 组件 | 存储大小 | 用途 |
|------|----------|------|
| MinIO | 50Gi | 对象存储数据 |
| MS-meta | 5Gi | 元数据 |
| MS-raft | 2Gi | Raft日志 |
| FE-meta | 10Gi | FE元数据 |
| BE-storage | 20Gi | BE数据 |
| BE-cache | 10Gi | 缓存 |
| CN-cache | 10Gi | 计算缓存 |

## 开发调试

### 查看组件日志

```powershell
# FE日志
kubectl logs -f -l app=doris-fe -n doris

# BE日志
kubectl logs -f -l app=doris-be -n doris

# CN日志
kubectl logs -f -l app=doris-cn -n doris

# MS日志
kubectl logs -f -l app=doris-ms -n doris
```

### 进入容器

```powershell
# 进入FE容器
kubectl exec -it -l app=doris-fe -n doris -- /bin/bash

# 进入BE容器
kubectl exec -it -l app=doris-be -n doris -- /bin/bash
```

### 修改配置

```powershell
# 编辑ConfigMap
kubectl edit cm doris-fe-config -n doris

# 重启Pod使配置生效
kubectl rollout restart statefulset/doris-fe -n doris
```

## 下一步

1. **学习Doris SQL**: 参考 [Apache Doris SQL参考](https://doris.apache.org/docs/sql-manual/)
2. **数据导入**: 尝试使用Stream Load、Broker Load等方式导入数据
3. **性能调优**: 学习分区、分桶、索引等优化技术
4. **生产部署**: 参考 [GKE生产部署指南](../docs/deployment-guide.md)

## 相关文档

- [架构设计文档](../docs/architecture-design.md)
- [设计决策详解](../docs/design-decisions.md)
- [GKE生产部署指南](../docs/deployment-guide.md)
