# Apache Doris 4.0.4 存算分离部署方案 - GKE高可用架构

## 一、整体架构设计

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              GKE Cluster                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         Ingress / GCLB                              │   │
│  │                    (Global Load Balancer)                           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│  ┌─────────────────────────────────┼────────────────────────────────────┐  │
│  │                    FE Service (3 replicas)                          │  │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────┐                       │  │
│  │  │  FE-1    │◄──►│  FE-2    │◄──►│  FE-3    │  (Leader Election)    │  │
│  │  │ (Leader) │    │(Follower)│    │(Follower)│                       │  │
│  │  └──────────┘    └──────────┘    └──────────┘                       │  │
│  │       │              │               │                               │  │
│  │       └──────────────┴───────────────┘                               │  │
│  │                      │                                               │  │
│  │              ┌───────┴───────┐                                       │  │
│  │              │  FE Service   │  (ClusterIP)                          │  │
│  │              └───────────────┘                                       │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│  ┌─────────────────────────────────┼────────────────────────────────────┐  │
│  │                    Meta Service (MS)                                 │  │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────┐                       │  │
│  │  │  MS-1    │◄──►│  MS-2    │◄──►│  MS-3    │  (Raft Consensus)     │  │
│  │  └──────────┘    └──────────┘    └──────────┘                       │  │
│  │                      │                                               │  │
│  │              ┌───────┴───────┐                                       │  │
│  │              │  MS Service   │  (Headless)                           │  │
│  │              └───────────────┘                                       │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│  ┌─────────────────────────────────┼────────────────────────────────────┐  │
│  │              Compute Node (CN) Pool - Auto Scaling                   │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐             │  │
│  │  │   CN-1   │  │   CN-2   │  │   CN-3   │  │   CN-n   │  (HPA)      │  │
│  │  │(Spot VM) │  │(Spot VM) │  │(Spot VM) │  │(Spot VM) │             │  │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘             │  │
│  │                      │                                               │  │
│  │              ┌───────┴───────┐                                       │  │
│  │              │  CN Service   │  (Headless)                           │  │
│  │              └───────────────┘                                       │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│  ┌─────────────────────────────────┼────────────────────────────────────┐  │
│  │              Backend (BE) Pool - Storage Nodes                       │  │
│  │  ┌──────────────────────────────────────────────────────────────┐   │  │
│  │  │  BE-1 (Local SSD + GCS)  │  BE-2 (Local SSD + GCS)           │   │  │
│  │  │  BE-3 (Local SSD + GCS)  │  BE-n (Local SSD + GCS)           │   │  │
│  │  └──────────────────────────────────────────────────────────────┘   │  │
│  │                      │                                               │  │
│  │              ┌───────┴───────┐                                       │  │
│  │              │  BE Service   │  (Headless)                           │  │
│  │              └───────────────┘                                       │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                    Shared Storage Layer                              │  │
│  │  ┌─────────────────────┐    ┌─────────────────────┐                 │  │
│  │  │   GCS Bucket        │    │   Cloud SQL         │                 │  │
│  │  │   (Data Files)      │    │   (Optional Config) │                 │  │
│  │  └─────────────────────┘    └─────────────────────┘                 │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 二、核心组件说明

### 2.1 Frontend (FE) - 查询协调节点

**职责：**
- SQL解析、查询优化、查询调度
- 元数据管理（表结构、分区信息等）
- 查询结果缓存
- 负载均衡和路由

**高可用设计：**
- 3节点部署，采用BDBJE（类Raft）共识协议
- 1个Leader + 2个Follower
- Leader故障时自动选举新Leader（秒级切换）
- 跨可用区部署，确保AZ级别容灾

**资源配置：**
```yaml
FE节点配置:
  CPU: 8核
  内存: 32GB
  存储: 100GB SSD (元数据存储)
  JVM堆内存: 16GB
```

### 2.2 Meta Service (MS) - 元数据服务

**职责：**
- 存算分离架构的核心组件
- 管理数据文件元信息
- 协调CN和BE之间的数据访问
- 提供全局一致的元数据视图

**高可用设计：**
- 3节点部署，Raft共识协议
- 独立于FE，避免单点故障
- 持久化到GCS，确保数据安全

**资源配置：**
```yaml
MS节点配置:
  CPU: 4核
  内存: 16GB
  存储: 50GB SSD
```

### 2.3 Compute Node (CN) - 纯计算节点

**职责：**
- 执行查询计算任务
- 无状态设计，可随时扩缩容
- 从共享存储读取数据
- 本地缓存热数据

**弹性伸缩设计：**
- 使用GKE Autopilot或HPA
- 支持Spot VM降低成本
- 最小3节点，最大可扩展至100+节点
- 基于CPU/内存/查询队列深度自动伸缩

**资源配置：**
```yaml
CN节点配置:
  CPU: 16核
  内存: 64GB
  本地缓存: 500GB NVMe SSD
  网络: 10Gbps
```

### 2.4 Backend (BE) - 存储节点

**职责：**
- 数据写入和存储管理
- 数据压缩和编码
- 索引构建和维护
- 冷热数据分层

**存储架构：**
- 本地SSD：热数据缓存（最近访问的数据）
- GCS：持久化存储（所有数据文件）
- 自动数据分层：热数据在本地，冷数据在GCS

**资源配置：**
```yaml
BE节点配置:
  CPU: 16核
  内存: 128GB
  本地存储: 2TB NVMe SSD (缓存)
  GCS存储: 无限扩展
```

## 三、存算分离架构原理

### 3.1 数据写入流程

```
┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│  Client  │────►│    FE    │────►│    BE    │────►│   GCS    │
└──────────┘     └──────────┘     └──────────┘     └──────────┘
                      │                │
                      │                │
                      ▼                ▼
                 ┌──────────┐    ┌──────────┐
                 │    MS    │    │ Local    │
                 │(元数据)  │    │  Cache   │
                 └──────────┘    └──────────┘
```

1. 数据写入请求发送到FE
2. FE协调，将数据写入BE节点
3. BE将数据写入本地缓存，并异步上传到GCS
4. 元数据注册到MS
5. 本地缓存保留热数据，冷数据自动淘汰

### 3.2 数据读取流程

```
┌──────────┐     ┌──────────┐     ┌──────────┐
│  Client  │────►│    FE    │────►│    CN    │
└──────────┘     └──────────┘     └──────────┘
                      │                │
                      ▼                │
                 ┌──────────┐          │
                 │    MS    │◄─────────┘
                 │(元数据)  │          │
                 └──────────┘          │
                      │                ▼
                      │         ┌──────────────┐
                      │         │  CN Local    │
                      │         │  Cache       │
                      │         └──────────────┘
                      │           │ Hit? │ Miss
                      │           ▼      ▼
                      │         ┌───┐  ┌──────────┐
                      └────────►│ ✓ │  │   GCS    │
                                └───┘  └──────────┘
```

1. 查询请求发送到FE
2. FE解析查询，从MS获取元数据
3. 查询下推到CN节点执行
4. CN首先检查本地缓存
5. 缓存命中直接返回，未命中从GCS读取
6. 结果返回给FE，再返回给客户端

### 3.3 为什么这样设计？

**1. 存储计算分离的优势：**

| 特性 | 传统架构 | 存算分离架构 |
|------|----------|--------------|
| 扩展性 | 必须同时扩展存储和计算 | 独立扩展，按需分配 |
| 成本 | 计算资源闲置时浪费 | Spot VM + 按需计算 |
| 数据量 | 受单节点存储限制 | 理论无限（GCS） |
| 故障恢复 | 需要数据迁移 | 秒级恢复（无状态CN） |

**2. 高可用设计原理：**

- **FE高可用**：BDBJE共识协议，多数派写入，Leader故障自动选举
- **MS高可用**：Raft协议，确保元数据一致性
- **CN无状态**：可随时销毁重建，不影响数据完整性
- **BE数据持久化**：数据存储在GCS，BE故障不影响数据安全

**3. 低延迟查询设计：**

- **本地缓存**：CN节点配置NVMe SSD缓存热数据
- **智能路由**：FE根据数据分布优化查询计划
- **向量化执行**：Doris 4.0的向量化引擎
- **Pipeline执行**：并行执行，充分利用多核CPU

## 四、GKE部署架构

### 4.1 节点池设计

```yaml
节点池配置:

1. FE Pool:
   - 机器类型: n2-standard-8
   - 节点数: 3 (固定)
   - 可用区: 跨3个AZ
   - 磁盘: 100GB SSD

2. MS Pool:
   - 机器类型: n2-standard-4
   - 节点数: 3 (固定)
   - 可用区: 跨3个AZ
   - 磁盘: 50GB SSD

3. CN Pool (Spot):
   - 机器类型: n2-highmem-16
   - 最小节点: 3
   - 最大节点: 50
   - 使用Spot VM (节省60-70%成本)
   - 自动扩缩容

4. BE Pool:
   - 机器类型: n2-highmem-16
   - 本地SSD: 2TB NVMe
   - 节点数: 根据数据量动态调整
   - 最小节点: 3
```

### 4.2 网络架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPC Network                              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Subnet: doris-subnet                    │   │
│  │  - FE Pod CIDR: 10.0.0.0/24                         │   │
│  │  - MS Pod CIDR: 10.0.1.0/24                         │   │
│  │  - CN Pod CIDR: 10.0.2.0/22 (可扩展)                │   │
│  │  - BE Pod CIDR: 10.0.6.0/24                         │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Private Google Access                   │   │
│  │  - GCS访问: 私有网络连接                             │   │
│  │  - Cloud SQL: 私有IP访问                            │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## 五、性能优化策略

### 5.1 查询延迟 < 5秒 的关键设计

**1. 多级缓存架构：**
```
┌─────────────────────────────────────────────────────────────┐
│                     查询缓存层次                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Level 1: FE查询结果缓存 (内存)                            │
│  └── 相同查询直接返回，延迟 < 10ms                         │
│                                                             │
│  Level 2: CN本地缓存 (NVMe SSD)                            │
│  └── 热数据本地访问，延迟 < 100ms                          │
│                                                             │
│  Level 3: BE本地缓存 (NVMe SSD)                            │
│  └── 近期写入数据，延迟 < 200ms                            │
│                                                             │
│  Level 4: GCS (对象存储)                                   │
│  └── 冷数据访问，延迟 < 1s                                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**2. 查询优化配置：**
```sql
-- 开启向量化引擎
SET enable_vectorized_engine = true;

-- 开启Pipeline引擎
SET enable_pipeline_engine = true;

-- 并行度设置
SET parallel_fragment_exec_instance_num = 8;

-- 查询超时设置
SET query_timeout = 5;
```

**3. 表设计最佳实践：**
```sql
-- 分区表设计（按日期分区）
CREATE TABLE large_table (
    id BIGINT,
    date_col DATE,
    value DECIMAL(18,2),
    data VARCHAR(1000)
) ENGINE=OLAP
PARTITION BY RANGE(date_col) (
    PARTITION p202401 VALUES LESS THAN ('2024-02-01'),
    PARTITION p202402 VALUES LESS THAN ('2024-03-01'),
    ...
)
DISTRIBUTED BY HASH(id) BUCKETS 32
PROPERTIES (
    "replication_num" = "3",
    "storage_policy" = "cold_hot_separation",
    "enable_unique_key_merge_on_write" = "true"
);
```

### 5.2 超大数据量支持

**1. 分区分桶策略：**
- 按时间分区：便于数据管理和冷热分离
- 按业务键分桶：数据均匀分布
- 动态分区：自动创建新分区

**2. 存储策略：**
```sql
-- 冷热数据分离策略
CREATE STORAGE POLICY hot_cold_policy
PROPERTIES (
    "storage_policy" = "cold_hot_separation",
    "hot_data_duration" = "7d",
    "cold_data_storage" = "gcs"
);

-- 应用到表
ALTER TABLE large_table SET STORAGE POLICY hot_cold_policy;
```

**3. 数据量估算：**
```
单表数据量: 100TB+
总数据量: PB级别
分区数: 1000+
分桶数: 每分区32-128个
```

## 六、监控和运维

### 6.1 监控指标

```yaml
关键监控指标:

FE监控:
  - fe_query_total: 查询总数
  - fe_query_latency_ms: 查询延迟
  - fe_connection_num: 连接数
  - fe_edit_log_size: 元数据日志大小

CN监控:
  - cn_cpu_usage: CPU使用率
  - cn_memory_usage: 内存使用率
  - cn_cache_hit_rate: 缓存命中率
  - cn_scan_rows: 扫描行数

BE监控:
  - be_disk_usage: 磁盘使用率
  - be_compaction_score: 压缩分数
  - be_write_bytes: 写入字节数
  - be_read_bytes: 读取字节数

MS监控:
  - ms_meta_ops: 元数据操作数
  - ms_consistency_check: 一致性检查
```

### 6.2 告警规则

```yaml
告警规则:

P0 (紧急):
  - FE Leader切换
  - MS多数节点不可用
  - CN节点数 < 3
  - 查询延迟 > 10s

P1 (重要):
  - 缓存命中率 < 50%
  - BE磁盘使用 > 80%
  - CN CPU > 90%

P2 (警告):
  - 节点重启
  - 配置变更
```

## 七、成本优化

### 7.1 Spot VM使用策略

```yaml
CN节点使用Spot VM:
  - 价格优势: 节省60-70%成本
  - 风险控制:
    - 最小保留3个普通节点
    - Spot节点配置优雅终止
    - 查询重试机制

BE节点不使用Spot:
  - 原因: 本地缓存数据，频繁迁移影响性能
  - 建议: 使用Committed Use Discounts
```

### 7.2 存储成本优化

```
存储分层:
  - 热数据 (7天内): 本地SSD + GCS
  - 温数据 (7-30天): GCS Standard
  - 冷数据 (30天+): GCS Nearline/Coldline

成本估算 (每月):
  - 热数据: 100TB * $0.17/GB = $17,000
  - 冷数据: 900TB * $0.01/GB = $9,000
  - 总存储成本: ~$26,000/月
```

## 八、部署步骤

### 8.1 前置条件

```bash
# 1. 创建GKE集群
gcloud container clusters create doris-cluster \
    --region=us-central1 \
    --num-nodes=1 \
    --enable-ip-alias \
    --enable-private-nodes \
    --enable-private-endpoint \
    --master-ipv4-cidr=172.16.0.0/28 \
    --create-subnetwork=name=doris-subnet,range=10.0.0.0/16

# 2. 创建节点池
gcloud container node-pools create fe-pool \
    --cluster=doris-cluster \
    --machine-type=n2-standard-8 \
    --num-nodes=3 \
    --node-labels=component=fe

# 3. 创建GCS Bucket
gsutil mb -l us-central1 gs://doris-data-bucket/

# 4. 创建Kubernetes Secret
kubectl create secret generic doris-gcs-secret \
    --from-file=google-credentials.json=/path/to/service-account.json
```

### 8.2 部署顺序

```bash
# 1. 部署Meta Service
kubectl apply -f ms-configmap.yaml
kubectl apply -f ms-service.yaml
kubectl apply -f ms-statefulset.yaml

# 2. 等待MS就绪
kubectl wait --for=condition=ready pod -l app=doris-ms --timeout=300s

# 3. 部署FE
kubectl apply -f fe-configmap.yaml
kubectl apply -f fe-service.yaml
kubectl apply -f fe-statefulset.yaml

# 4. 等待FE就绪
kubectl wait --for=condition=ready pod -l app=doris-fe --timeout=300s

# 5. 部署BE
kubectl apply -f be-configmap.yaml
kubectl apply -f be-service.yaml
kubectl apply -f be-statefulset.yaml

# 6. 部署CN
kubectl apply -f cn-configmap.yaml
kubectl apply -f cn-service.yaml
kubectl apply -f cn-deployment.yaml
kubectl apply -f cn-hpa.yaml

# 7. 配置Ingress
kubectl apply -f ingress.yaml
```

## 九、容量规划

### 9.1 集群规模参考

| 数据量 | FE节点 | MS节点 | CN节点 | BE节点 | 存储成本/月 |
|--------|--------|--------|--------|--------|-------------|
| 100TB | 3 | 3 | 5-20 | 5 | ~$17,000 |
| 500TB | 3 | 3 | 10-50 | 10 | ~$85,000 |
| 1PB | 5 | 5 | 20-100 | 20 | ~$170,000 |

### 9.2 查询性能基准

| 查询类型 | 数据量 | 预期延迟 |
|----------|--------|----------|
| 点查询 | 1亿行 | < 100ms |
| 聚合查询 | 10亿行 | < 1s |
| 复杂JOIN | 10亿行 | < 3s |
| 全表扫描 | 100亿行 | < 5s |

## 十、总结

本方案基于Apache Doris 4.0.4的存算分离架构，实现了以下目标：

1. **高可用**：FE/MS三节点Raft部署，跨可用区容灾
2. **弹性伸缩**：CN节点支持HPA自动扩缩容，Spot VM降低成本
3. **超大数据量**：GCS无限存储，PB级数据支持
4. **低延迟查询**：多级缓存 + 向量化引擎，查询延迟 < 5秒

核心优势：
- 存储计算独立扩展，资源利用率高
- Spot VM + 冷热分层，成本优化显著
- 无状态CN，故障恢复秒级
- GCS持久化，数据安全可靠
