# Apache Doris 4.0.4 存算分离部署指南 - GKE 生产环境

## 概述

本指南帮助你在 Google Kubernetes Engine (GKE) 环境中部署 Apache Doris 4.0.4 **存算分离（Disaggregated）** 架构的生产级别集群。

## 架构设计

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                                      Google Cloud Platform                                    │
├─────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐    │
│  │                           GKE Cluster (doris-cluster)                                 │    │
│  │                                                                                       │    │
│  │  ┌───────────────────────────────────────────────────────────────────────────────┐  │    │
│  │  │                        Doris Namespace (doris)                                     │  │    │
│  │  │                                                                               │  │    │
│  │  │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐            │  │    │
│  │  │  │   Cloud Storage   │  │     MetaService  │  │       FE         │            │  │    │
│  │  │  │      (GCS)       │  │    (Deployment)  │  │  (StatefulSet)   │            │  │    │
│  │  │  │                  │  │                  │  │                  │            │  │    │
│  │  │  │  ┌────────────┐ │  │  ┌────────────┐ │  │  ┌────────────┐ │  │            │  │    │
│  │  │  │  │ doris-data │ │  │  │    MS-0    │ │  │  │    FE-0    │ │  │            │  │    │
│  │  │  │  │  (bucket)  │ │  │  │            │ │  │  │            │ │  │            │  │    │
│  │  │  │  └────────────┘ │  │  └────────────┘ │  │  └────────────┘ │  │            │  │    │
│  │  │  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘            │  │    │
│  │  │           │                   │                   │                       │  │    │
│  │  │           │    ┌──────────────┴───────────────────┘                       │  │    │
│  │  │           │    │  Meta Service API (instance/cluster/vault)                │  │    │
│  │  │           │    │                                                            │  │    │
│  │  └───────────┼────┼────────────────────────────────────────────────────────┘  │    │
│  │              │    │  RPC + Heartbeat                                            │    │
│  │              │    │                                                             │    │
│  │  ┌───────────┴────┼────────────────────────────────────────────────────────┐  │    │
│  │  │                │                                                             │  │    │
│  │  │  ┌─────────────┴─────────────────────────────────────────────────────┐  │  │    │
│  │  │  │                    Compute Nodes (cg1)                             │  │  │    │
│  │  │  │                                                                     │  │  │    │
│  │  │  │  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐   │  │  │    │
│  │  │  │  │   CG1-0    │  │   CG1-1    │  │   CG1-2    │  │   CG1-N    │   │  │  │    │
│  │  │  │  │  (Compute  │  │  (Compute  │  │  (Compute  │  │  (Compute  │   │  │  │    │
│  │  │  │  │   Node)    │  │   Node)    │  │   Node)    │  │   Node)    │   │  │  │    │
│  │  │  │  └────────────┘  └────────────┘  └────────────┘  └────────────┘   │  │  │    │
│  │  │  └─────────────────────────────────────────────────────────────────────┘  │  │    │
│  │  │                                                                            │  │    │
│  │  │  ┌─────────────────────────────────────────────────────────────────────┐  │  │    │
│  │  │  │                    Recycler (Deployment)                             │  │  │    │
│  │  │  │  ┌────────────┐  ┌────────────┐                                       │  │  │    │
│  │  │  │  │ Recycler-0 │  │ Recycler-1 │  (高可用部署)                          │  │  │    │
│  │  │  │  └────────────┘  └────────────┘                                       │  │  │    │
│  │  │  └─────────────────────────────────────────────────────────────────────┘  │  │    │
│  │  └───────────────────────────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────────────────┐    │
│  │                           Cloud Load Balancing                                       │    │
│  │                                                                                       │    │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐                   │    │
│  │  │   FE L4 LB       │  │   FE HTTP LB     │  │   MS Health LB   │                   │    │
│  │  │   (MySQL:9030)  │  │   (HTTP:8030)    │  │   (HTTP:5000)    │                   │    │
│  │  │                  │  │                  │  │                  │                   │    │
│  │  └──────────────────┘  └──────────────────┘  └──────────────────┘                   │    │
│  └─────────────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

## 架构对比

| 组件 | 存算分离 (Disaggregated) | 传统架构 (Shared-Nothing) |
|------|--------------------------|---------------------------|
| 元数据存储 | FoundationDB + Meta Service | FE 内部 BDBJE |
| 数据存储 | GCS (Google Cloud Storage) | BE 本地磁盘 |
| 存算耦合 | 解耦，独立扩缩容 | 耦合，存储和计算绑定 |
| BE 角色 | 纯计算节点 (Compute Node) | 存储计算一体 |
| 数据持久性 | GCS 保证 (11个9可用性) | 依赖副本数 |
| 适用场景 | 云原生、弹性伸缩、生产环境 | 传统部署、低延迟 |

## 组件说明

| 组件 | 版本 | 说明 |
|------|------|------|
| FoundationDB | 7.3.69 | 分布式 KV 存储，Meta Service 的元数据后端 |
| Meta Service | 4.0.4 | 存算分离核心组件，管理 instance/cluster/vault |
| Recycler | 4.0.4 | 数据回收器，定期清理过期文件 |
| FE | 4.0.4 | 查询解析、优化、协调 (run_mode=disagg) |
| BE | 4.0.4 | 计算节点 (run_mode=disagg) |
| GCS | - | Google Cloud Storage，对象存储后端 |

## 前置条件

### 1. Google Cloud SDK

```bash
# 安装 gcloud CLI
curl https://sdk.cloud.google.com | bash
gcloud init
gcloud auth login
```

### 2. 启用 GCP API

```bash
# 启用 Kubernetes Engine API
gcloud services enable container.googleapis.com

# 启用 Cloud Storage API
gcloud services enable storage.googleapis.com

# 启用 Cloud DNS API (可选)
gcloud services enable dns.googleapis.com
```

### 3. 准备 Docker 镜像

```bash
# 构建并推送到 Google Container Registry
gcloud builds submit --tag gcr.io/${PROJECT_ID}/doris-fe:4.0.4 ./docker
gcloud builds submit --tag gcr.io/${PROJECT_ID}/doris-be:4.0.4 ./docker
gcloud builds submit --tag gcr.io/${PROJECT_ID}/doris-ms:4.0.4 ./docker
gcloud builds submit --tag gcr.io/${PROJECT_ID}/doris-operator:25.8.0 ./docker
gcloud builds submit --tag gcr.io/${PROJECT_ID}/foundationdb:7.3.69 ./docker
```

## GKE 集群配置

### 1. 创建集群

```bash
# 区域模式高可用集群
gcloud container clusters create doris-cluster \
    --region=asia-east1 \
    --node-pool=default-pool \
    --num-nodes=3 \
    --machine-type=n2-standard-8 \
    --disk-size=100GB \
    --disk-type=pd-ssd \
    --enable-autoscaling \
    --min-nodes=3 \
    --max-nodes=10 \
    --enable-network-egress \
    --network=default \
    --subnetwork=default \
    --async

# 或使用 Autopilot 模式（推荐生产环境）
gcloud container clusters create doris-cluster \
    --region=asia-east1 \
    --enable-autopilot \
    --num-nodes=3
```

### 2. 配置 kubectl

```bash
gcloud container clusters get-credentials doris-cluster --region=asia-east1
kubectl create namespace doris
```

## 高可用配置

### 组件副本数

| 组件 | 副本数 | 说明 |
|------|--------|------|
| FE | 3 | 高可用，支持 Leader 选举 |
| Meta Service | 2+ | 高可用，依赖 FoundationDB |
| Recycler | 2 | 高可用，支持故障转移 |
| FoundationDB | 3 | 高可用，3 副本仲裁 |
| Compute Node | 3+ | 按需扩展 |

### Storage Class

```yaml
# 使用 GCP Persistent Disk
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: doris-storage
provisioner: pd.csi.storage.gke.io
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: pd-ssd
reclaimPolicy: Retain
allowVolumeExpansion: true
```

## GCS Bucket 配置

### 1. 创建 GCS Bucket

```bash
# 创建用于存储数据的 GCS Bucket
gsutil mb -l asia-east1 gs://doris-gcs-data-${PROJECT_ID}

# 配置生命周期管理
gsutil lifecycle set lifecycle-config.json gs://doris-gcs-data-${PROJECT_ID}

# 配置版本控制
gsutil versioning set on gs://doris-gcs-data-${PROJECT_ID}

# 配置 IAM 服务账号
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:doris-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/storage.objectAdmin"
```

### 2. lifecycle-config.json

```json
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 365}
    }
  ]
}
```

## 部署步骤

### 1. 使用 Operator 部署

```bash
# Step 1: 部署 FDB Operator
kubectl apply -f k8s/gke/00-fdb-operator.yaml
kubectl wait --for=condition=ready deployment/fdb-kubernetes-operator-controller-manager -n doris --timeout=120s

# Step 2: 部署 FoundationDB Cluster (由 FDB Operator 管理)
kubectl apply -f k8s/gke/01-fdb-cluster.yaml
kubectl wait --for=condition=ready foundationdbcluster/doris-fdb -n doris --timeout=300s

# Step 3: 部署 Doris Operator
kubectl apply -f k8s/gke/02-doris-operator.yaml
kubectl wait --for=condition=ready deployment/doris-operator-controller-manager -n doris --timeout=120s

# Step 4: 部署 Doris 存算分离集群 (由 Doris Operator 管理)
kubectl apply -f k8s/gke/03-doris-disaggregated-cluster.yaml
kubectl wait --for=condition=ready pod -l app=doris-disaggregated-fe -n doris --timeout=300s
kubectl wait --for=condition=ready pod -l app=doris-disaggregated-cg1 -n doris --timeout=300s

# Step 5: 部署 Services (LoadBalancer)
kubectl apply -f k8s/gke/04-services.yaml
```

### 2. 配置 Storage Vault

```sql
-- 连接 FE
kubectl exec -it doris-disaggregated-fe-0 -n doris -- mysql -h 127.0.0.1 -P 9030 -u root

-- 创建 GCS Storage Vault
CREATE STORAGE VAULT IF NOT EXISTS gcs_vault
PROPERTIES (
    'type'='GCS',
    'gcs.endpoint'='https://storage.googleapis.com',
    'gcs.region'='asia-east1',
    'gcs.bucket'='doris-gcs-data-${PROJECT_ID}',
    'gcs.root.path'='doris-data',
    'gcs.access_key'='${SERVICE_ACCOUNT_EMAIL}',
    'gcs.secret_key'='${SERVICE_ACCOUNT_KEY}',
    'gcs.project_id'='${PROJECT_ID}',
    'provider'='GCS'
);

-- 设置为默认
SET gcs_vault AS DEFAULT STORAGE VAULT;
```

### 3. 验证部署

```bash
# 检查所有 Pod 状态
kubectl get pods -n doris -o wide

# 检查 Services
kubectl get svc -n doris

# 查看 FE 日志
kubectl logs doris-disaggregated-fe-0 -n doris -c fe --tail=50

# 查看 Compute Node 日志
kubectl logs doris-disaggregated-cg1-0 -n doris -c be --tail=50
```

## 访问配置

### Cloud Load Balancer

| 服务 | LB 类型 | 端口 | 说明 |
|------|---------|------|------|
| FE MySQL | TCP LB | 9030 | JDBC 连接 |
| FE HTTP | HTTP LB | 8030 | Web UI, REST API |
| Meta Service | TCP LB | 5000 | 内部通信 |

### 防火墙规则

```bash
# 允许外部访问 FE
gcloud compute firewall-rules create doris-fe-access \
    --allow=tcp:8030,tcp:9030 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=doris-nodes

# 允许内部通信
gcloud compute firewall-rules create doris-internal \
    --allow=tcp:5000,tcp:4500,tcp:4501 \
    --source-tags=doris-nodes \
    --target-tags=doris-nodes
```

### 获取访问地址

```bash
# 获取 FE LB IP
FE_LB_IP=$(kubectl get svc doris-fe-lb -n doris -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# 获取 FE HTTP IP
FE_HTTP_IP=$(kubectl get svc doris-fe-http -n doris -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "FE MySQL: $FE_LB_IP:9030"
echo "FE HTTP: http://$FE_HTTP_IP:8030"
```

## 自动扩缩容

### Horizontal Pod Autoscaler (HPA)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: doris-cg1-hpa
  namespace: doris
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: StatefulSet
    name: doris-disaggregated-cg1
  minReplicas: 3
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

### Cluster Autoscaler

```bash
# 为节点池启用 autoscaler
gcloud container node-pools update default-pool \
    --cluster=doris-cluster \
    --region=asia-east1 \
    --enable-autoscaling \
    --min-nodes=3 \
    --max-nodes=20
```

## 监控和日志

### Cloud Monitoring

```yaml
# 部署 Prometheus Operator
kubectl apply -f k8s/gke/10-prometheus.yaml

# 部署 Grafana
kubectl apply -f k8s/gke/11-grafana.yaml

# 配置 Cloud Monitoring Export
kubectl apply -f k8s/gke/12-stackdriver.yaml
```

### 日志聚合

```bash
# 使用 Cloud Logging
kubectl apply -f k8s/gke/13-cloud-logging.yaml

# 查看日志
kubectl logs -l app=doris-fe -n doris --timestamps=true
```

## 灾难恢复

### 备份 FoundationDB

```bash
# 创建快照
gsutil mb gs://doris-fdb-backup-${PROJECT_ID}

# 定期备份脚本 (crontab)
0 2 * * * kubectl exec foundationdb-0 -n doris -- fdbbackup start -t fdbackup -d gs://doris-fdb-backup-${PROJECT_ID}
```

### 恢复流程

```bash
# 停止集群
kubectl scale deployment doris-disaggregated-ms -n doris --replicas=0
kubectl scale statefulset doris-disaggregated-fe -n doris --replicas=0
kubectl scale statefulset doris-disaggregated-cg1 -n doris --replicas=0

# 执行恢复
kubectl exec foundationdb-0 -n doris -- fdbbackup stop
kubectl exec foundationdb-0 -n doris -- fdbrestore start -d gs://doris-fdb-backup-${PROJECT_ID} -r

# 重启集群
kubectl scale deployment doris-disaggregated-ms -n doris --replicas=2
kubectl scale statefulset doris-disaggregated-fe -n doris --replicas=3
kubectl scale statefulset doris-disaggregated-cg1 -n doris --replicas=3
```

## 清理资源

```bash
# 删除集群
gcloud container clusters delete doris-cluster --region=asia-east1

# 删除 GCS Bucket
gsutil rm -r gs://doris-gcs-data-${PROJECT_ID}

# 删除防火墙规则
gcloud compute firewall-rules delete doris-fe-access
gcloud compute firewall-rules delete doris-internal
```

## 文件结构

```
k8s/gke/
├── 00-fdb-operator.yaml               # FDB Kubernetes Operator
├── 01-fdb-cluster.yaml                # FoundationDB Cluster (由 FDB Operator 管理)
├── 02-doris-operator.yaml             # Doris Kubernetes Operator
├── 03-doris-disaggregated-cluster.yaml # Doris 存算分离集群 CRD
├── 04-services.yaml                   # Services & LoadBalancers
├── configmaps.yaml                    # ConfigMaps (FE/BE/MS 配置)

scripts/gke/
├── deploy-gke.sh              # 一键部署脚本
├── create-gcs-bucket.sh       # 创建 GCS Bucket
├── init-cluster.sh            # 初始化集群
└── test-cluster.sh            # 测试脚本
```

## 故障排除

### 常见问题

1. **FoundationDB 无法启动**
   ```bash
   # 检查日志
   kubectl logs foundationdb-0 -n doris --tail=100
   
   # 检查 FDB 状态
   kubectl exec foundationdb-0 -n doris -- fdbcli --exec "status"
   ```

2. **FE 无法连接 Meta Service**
   ```bash
   # 检查 MS 日志
   kubectl logs -l app=doris-ms -n doris --tail=50
   
   # 检查 FDB 连接
   kubectl exec foundationdb-0 -n doris -- fdbcli --exec "get \xff\xff"
   ```

3. **Compute Node 无法注册**
   ```bash
   # 检查 BE 日志
   kubectl logs doris-disaggregated-cg1-0 -n doris -c be --tail=100
   
   # 检查网络策略
   kubectl get networkpolicy -n doris
   ```

## 相关文档

- [架构设计文档](architecture-design.md)
- [设计决策详解](design-decisions.md)
- [本地部署指南](disaggregated-deployment-guide.md)
