# Apache Doris 4.0.4 GKE部署指南

## 一、前置条件

### 1.1 工具安装

```bash
# 安装 gcloud CLI
# macOS
brew install google-cloud-sdk

# Windows (使用 PowerShell)
(New-Object Net.WebClient).DownloadFile("https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe", "$env:Temp\GoogleCloudSDKInstaller.exe")
& $env:Temp\GoogleCloudSDKInstaller.exe

# 安装 kubectl
gcloud components install kubectl

# 安装 terraform
# macOS
brew install terraform

# Windows
choco install terraform
```

### 1.2 GCP项目准备

```bash
# 登录GCP
gcloud auth login

# 设置项目
gcloud config set project YOUR_PROJECT_ID

# 启用必要的API
gcloud services enable container.googleapis.com
gcloud services enable compute.googleapis.com
gcloud services enable storage.googleapis.com
gcloud services enable cloudkms.googleapis.com
gcloud services enable monitoring.googleapis.com
gcloud services enable logging.googleapis.com
```

## 二、基础设施部署

### 2.1 使用Terraform创建GKE集群

```bash
# 进入terraform目录
cd terraform

# 创建terraform.tfvars
cp terraform.tfvars.example terraform.tfvars

# 编辑terraform.tfvars，填入你的项目信息
vim terraform.tfvars

# 初始化Terraform
terraform init

# 查看执行计划
terraform plan

# 应用配置
terraform apply -auto-approve

# 获取集群凭证
gcloud container clusters get-credentials doris-cluster --region us-central1
```

### 2.2 创建GCS Service Account

```bash
# 创建Service Account
gcloud iam service-accounts create doris-gcs-sa \
    --display-name="Doris GCS Service Account"

# 授予GCS权限
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
    --member="serviceAccount:doris-gcs-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/storage.objectAdmin"

# 创建密钥
gcloud iam service-accounts keys create ./gcs-credentials.json \
    --iam-account=doris-gcs-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com

# 创建Kubernetes Secret
kubectl create namespace doris
kubectl create secret generic doris-gcs-secret \
    --from-file=google-credentials.json=./gcs-credentials.json \
    -n doris
```

## 三、Doris组件部署

### 3.1 部署顺序

```bash
# 1. 创建命名空间和基础资源
kubectl apply -f k8s/base/00-namespace-and-secrets.yaml

# 2. 部署Meta Service
kubectl apply -f k8s/base/ms-statefulset.yaml

# 3. 等待MS就绪
kubectl wait --for=condition=ready pod -l app=doris-ms -n doris --timeout=300s

# 4. 部署Frontend
kubectl apply -f k8s/base/fe-statefulset.yaml

# 5. 等待FE就绪
kubectl wait --for=condition=ready pod -l app=doris-fe -n doris --timeout=300s

# 6. 部署Backend
kubectl apply -f k8s/base/be-statefulset.yaml

# 7. 等待BE就绪
kubectl wait --for=condition=ready pod -l app=doris-be -n doris --timeout=300s

# 8. 部署Compute Node
kubectl apply -f k8s/base/cn-deployment.yaml

# 9. 配置自动扩缩容
kubectl apply -f k8s/base/autoscaling.yaml
```

### 3.2 验证部署

```bash
# 检查所有Pod状态
kubectl get pods -n doris -o wide

# 检查服务状态
kubectl get svc -n doris

# 检查HPA状态
kubectl get hpa -n doris

# 连接到FE
kubectl port-forward svc/doris-fe 9030:9030 -n doris

# 使用MySQL客户端连接
mysql -h 127.0.0.1 -P 9030 -u root
```

### 3.3 初始化集群配置

```sql
-- 连接到Doris后执行

-- 1. 查看FE状态
SHOW FRONTENDS;

-- 2. 查看BE状态
SHOW BACKENDS;

-- 3. 查看CN状态
SHOW COMPUTE GROUPS;

-- 4. 创建存储策略（存算分离必需）
CREATE STORAGE POLICY gcs_policy
PROPERTIES (
    "type" = "S3",
    "s3.endpoint" = "https://storage.googleapis.com",
    "s3.region" = "us-central1",
    "s3.bucket" = "doris-data-bucket",
    "s3.prefix" = "doris/",
    "s3.access_key" = "YOUR_ACCESS_KEY",
    "s3.secret_key" = "YOUR_SECRET_KEY"
);

-- 5. 创建资源组
CREATE RESOURCE GROUP cn_group
PROPERTIES (
    "compute_group_id" = "1",
    "workload_group" = "normal"
);

-- 6. 创建测试表
CREATE DATABASE test_db;
USE test_db;

CREATE TABLE test_table (
    id BIGINT,
    name VARCHAR(100),
    created_at DATETIME
) ENGINE=OLAP
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 3
PROPERTIES (
    "replication_num" = "3",
    "storage_policy" = "gcs_policy"
);

-- 7. 插入测试数据
INSERT INTO test_table VALUES (1, 'test', NOW());

-- 8. 验证查询
SELECT * FROM test_table;
```

## 四、性能调优

### 4.1 FE调优

```sql
-- 查询优化
SET GLOBAL enable_vectorized_engine = true;
SET GLOBAL enable_pipeline_engine = true;
SET GLOBAL parallel_fragment_exec_instance_num = 8;

-- 缓存优化
SET GLOBAL enable_query_cache = true;
SET GLOBAL query_cache_size = 2147483648;

-- 并行度设置
SET GLOBAL default_max_filter_ratio = 0.1;
SET GLOBAL max_query_instances = 128;
```

### 4.2 CN调优

```yaml
# 在cn.conf中调整
pipeline_task_thread_pool_size = 64
scan_thread_pool_thread_num = 64
datacache_size = 536870912000
```

### 4.3 BE调优

```yaml
# 在be.conf中调整
base_compaction_num_threads_per_disk = 4
cumulative_compaction_num_threads_per_disk = 4
compaction_task_num_per_disk = 8
```

### 4.4 JVM调优

```bash
# FE JVM参数
JAVA_OPTS="-Xmx16384m -Xms16384m \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=200 \
  -XX:+PrintGCDetails \
  -XX:+PrintGCDateStamps \
  -XX:+PrintGCTimeStamps \
  -Xloggc:/opt/doris/fe/log/gc.log"
```

## 五、监控配置

### 5.1 配置Google Cloud Monitoring

```bash
# 创建告警策略
gcloud alpha monitoring policies create \
    --display-name="Doris FE High CPU" \
    --condition-display-name="FE CPU > 90%" \
    --condition-filter='metric.type="kubernetes.io/container/cpu/core_usage_time" resource.type="k8s_container" resource.labels."container_name"="frontend"' \
    --condition-threshold-value=0.9 \
    --condition-threshold-duration=300s \
    --notification-channels="YOUR_CHANNEL_ID"
```

### 5.2 关键监控指标

| 组件 | 指标 | 阈值 | 说明 |
|------|------|------|------|
| FE | fe_query_latency_ms | < 5000 | 查询延迟 |
| FE | fe_connection_num | < 1000 | 连接数 |
| CN | cn_cpu_usage | < 80% | CPU使用率 |
| CN | cn_cache_hit_rate | > 60% | 缓存命中率 |
| BE | be_disk_usage | < 80% | 磁盘使用率 |
| BE | be_compaction_score | < 100 | 压积分数 |

## 六、故障排查

### 6.1 常见问题

**问题1: FE无法启动**
```bash
# 检查日志
kubectl logs -f doris-fe-0 -n doris

# 常见原因:
# 1. 元数据损坏 - 需要恢复备份
# 2. 内存不足 - 调整JVM参数
# 3. 网络问题 - 检查Service配置
```

**问题2: CN节点无法注册**
```bash
# 检查CN日志
kubectl logs -f doris-cn-xxx -n doris

# 常见原因:
# 1. FE地址配置错误
# 2. 网络策略阻止
# 3. 资源不足
```

**问题3: 查询超时**
```sql
-- 检查查询状态
SHOW RUNNING QUERIES;

-- 取消慢查询
CANCEL QUERY 'query_id';

-- 调整超时时间
SET query_timeout = 300;
```

### 6.2 日志收集

```bash
# 收集所有组件日志
kubectl logs -l app=doris-fe -n doris > fe.log
kubectl logs -l app=doris-be -n doris > be.log
kubectl logs -l app=doris-cn -n doris > cn.log
kubectl logs -l app=doris-ms -n doris > ms.log
```

## 七、备份与恢复

### 7.1 数据备份

```sql
-- 创建备份仓库
CREATE REPOSITORY gcs_backup
WITH BROKER "gcs_broker"
ON LOCATION "gs://doris-backup"
PROPERTIES (
    "type" = "S3",
    "s3.endpoint" = "https://storage.googleapis.com",
    "s3.region" = "us-central1",
    "s3.bucket" = "doris-backup",
    "s3.access_key" = "YOUR_ACCESS_KEY",
    "s3.secret_key" = "YOUR_SECRET_KEY"
);

-- 备份数据库
BACKUP SNAPSHOT test_db.snapshot_20240101
TO gcs_backup
ON (test_db);
```

### 7.2 数据恢复

```sql
-- 查看备份
SHOW SNAPSHOT ON gcs_backup;

-- 恢复数据
RESTORE SNAPSHOT test_db.snapshot_20240101
FROM gcs_backup
PROPERTIES (
    "backup_timestamp" = "2024-01-01-00-00-00"
);
```

## 八、扩缩容操作

### 8.1 手动扩容CN

```bash
# 扩容到10个CN节点
kubectl scale deployment doris-cn --replicas=10 -n doris

# 查看扩容状态
kubectl get pods -l app=doris-cn -n doris -w
```

### 8.2 手动扩容BE

```bash
# 扩容到5个BE节点
kubectl scale statefulset doris-be --replicas=5 -n doris
```

### 8.3 自动扩缩容验证

```bash
# 查看HPA状态
kubectl describe hpa doris-cn-hpa -n doris

# 触发扩容测试
kubectl run -i --tty load-generator --rm --image=busybox --restart=Never -- /bin/sh -c "while sleep 0.01; do wget -q -O- http://doris-fe:8030; done"
```

## 九、安全配置

### 9.1 启用认证

```sql
-- 创建管理员用户
CREATE USER 'admin'@'%' IDENTIFIED BY 'strong_password';

-- 授予权限
GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%';

-- 创建只读用户
CREATE USER 'readonly'@'%' IDENTIFIED BY 'readonly_password';
GRANT SELECT_PRIV ON *.* TO 'readonly'@'%';
```

### 9.2 网络安全

```bash
# 配置VPC防火墙规则
gcloud compute firewall-rules create doris-allow-internal \
    --network=doris-network \
    --allow=tcp:9030,tcp:8030 \
    --source-ranges=10.0.0.0/8

# 限制外部访问
gcloud compute firewall-rules create doris-deny-external \
    --network=doris-network \
    --direction=INGRESS \
    --priority=1000 \
    --action=DENY \
    --rules=all \
    --source-ranges=0.0.0.0/0
```

## 十、性能基准测试

### 10.1 TPC-H测试

```bash
# 下载TPC-H工具
git clone https://github.com/apache/doris/tree/master/tools/tpch-tools

# 生成数据 (SF=100, 约100GB)
./tpch-tools/bin/gen_data.sh 100

# 导入数据
./tpch-tools/bin/load_data.sh

# 执行查询
./tpch-tools/bin/run_query.sh
```

### 10.2 性能基准

| 查询 | 数据量 | 预期延迟 | 优化后延迟 |
|------|--------|----------|------------|
| Q1 | 100GB | < 2s | < 1s |
| Q3 | 100GB | < 3s | < 2s |
| Q5 | 100GB | < 5s | < 3s |
| Q6 | 100GB | < 1s | < 0.5s |

## 十一、成本优化建议

### 11.1 使用Spot VM

CN节点使用Spot VM可以节省60-70%的成本，但需要注意：
- 最少保留3个普通节点作为兜底
- 配置优雅终止，确保查询不中断
- 监控Spot VM回收预警

### 11.2 存储分层

```sql
-- 配置冷热数据分层
CREATE STORAGE POLICY hot_cold_policy
PROPERTIES (
    "storage_policy" = "cold_hot_separation",
    "hot_data_duration" = "7d",
    "cold_data_storage" = "gcs_nearline"
);

-- 应用到表
ALTER TABLE large_table SET STORAGE POLICY hot_cold_policy;
```

### 11.3 资源配额

```yaml
# 设置命名空间资源配额
apiVersion: v1
kind: ResourceQuota
metadata:
  name: doris-quota
  namespace: doris
spec:
  hard:
    requests.cpu: "200"
    requests.memory: 800Gi
    limits.cpu: "400"
    limits.memory: 1.6Ti
```

## 十二、升级指南

### 12.1 滚动升级步骤

```bash
# 1. 备份元数据
kubectl exec doris-fe-0 -n doris -- /opt/doris/fe/bin/backup_fe.sh

# 2. 升级FE (逐个节点)
kubectl set image statefulset/doris-fe frontend=apache/doris:fe-4.0.5 -n doris
kubectl rollout status statefulset/doris-fe -n doris

# 3. 升级BE (逐个节点)
kubectl set image statefulset/doris-be backend=apache/doris:be-4.0.5 -n doris
kubectl rollout status statefulset/doris-be -n doris

# 4. 升级CN
kubectl set image deployment/doris-cn compute-node=apache/doris:cn-4.0.5 -n doris
kubectl rollout status deployment/doris-cn -n doris

# 5. 升级MS
kubectl set image statefulset/doris-ms meta-service=apache/doris:ms-4.0.5 -n doris
kubectl rollout status statefulset/doris-ms -n doris
```

## 十三、联系与支持

- Apache Doris官方文档: https://doris.apache.org/docs/
- Apache Doris社区: https://doris.apache.org/community/
- GitHub Issues: https://github.com/apache/doris/issues
