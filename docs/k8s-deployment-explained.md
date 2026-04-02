# Kubernetes 部署详解 - 让小白也能明白

## 什么是 Kubernetes (K8s)?

想象一下 **Kubernetes 是一个大型游乐场的管理系统**：

- **Pod** = 游乐场的每个游乐设施（比如旋转木马、摩天轮）
- **Service** = 游乐设施的「排队区入口」，让游客能找到设施
- **Deployment/StatefulSet** = 游乐设施的「维护手册」，告诉系统如何建造和管理设施
- **ConfigMap** = 设施的「操作指南」，告诉设施怎么运转
- **Namespace** = 游乐场的「分区」（比如儿童区、成人区）

---

## 存算分离集群组件概览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Doris 存算分离集群                                    │
│                                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐        │
│  │  FoundationDB   │    │   Meta Service  │    │       FE        │        │
│  │    (数据库)      │    │   (大脑)        │    │   (服务员)       │        │
│  │                 │    │                 │    │                 │        │
│  │  存储元数据      │    │  管理整个集群    │    │  接收用户请求    │        │
│  │  重要数据不能丢  │    │  协调各组件      │    │  返回查询结果    │        │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘        │
│                                                             │              │
│                                                             ▼              │
│                                                   ┌─────────────────┐        │
│                                                   │       BE        │        │
│                                                   │   (计算节点)     │        │
│                                                   │                 │        │
│                                                   │  真正执行查询    │        │
│                                                   │  存储数据缓存    │        │
│                                                   └─────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 组件详解

### 1. FoundationDB - 分布式数据库（记忆系统）

**想象**：图书馆的「索引卡片系统」

```yaml
# 01-fdb-cluster.yaml
apiVersion: apps.foundationdb.org/v1beta2
kind: FoundationDBCluster
metadata:
  name: doris-fdb          # 索引卡片柜的名字
spec:
  version: 7.3.69          # 卡片系统版本
  processes:
    general:               # 一般存储进程
      podTemplate:
        spec:
          containers:
          - name: foundationdb
            resources:
              requests:
                cpu: "1"       # 需要 1 个 CPU
                memory: "4Gi"  # 需要 4GB 内存
```

**作用**：
- 存储 Doris 集群的「元数据」——什么是数据库、表、用户
- 就像图书馆的索引卡片：告诉你哪本书在哪个书架
- **高可用**：数据自动复制多份，一台机器坏了不会丢数据

---

### 2. FDB Operator - 自动管理员

**想象**：图书馆的「自动索引机器人」

```yaml
# 00-fdb-operator.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fdb-kubernetes-operator-controller-manager
spec:
  replicas: 1               # 只运行 1 个机器人
  selector:
    matchLabels:
      app: fdb-kubernetes-operator
  template:
    spec:
      containers:
      - name: manager
        image: foundationdb/fdb-kubernetes-operator:v1.12.0
        args:
        - --enable-leader-election  # 选举确保只有 1 个工作
```

**作用**：
- 自动监控 FoundationDB 是否正常运行
- 自动修复故障（如果一个 FDB Pod 挂了，自动启动新的）
- 自动扩缩容（需要更多存储？自动加节点）
- **不需要人工干预**：机器人自动管理

---

### 3. Doris Operator - 集群管理员

**想象**：游乐场的「总经理」

```yaml
# 02-doris-operator.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: doris-operator-controller-manager
spec:
  replicas: 1
  selector:
    matchLabels:
      app: doris-operator
  template:
    spec:
      containers:
      - name: manager
        image: apache/doris:operator-25.8.0
        args:
        - --leader-elect
        - --webhook-port=9443  # 接收配置变更的端口
```

**作用**：
- 监听 Doris 集群配置的变化
- 自动创建/更新/删除 Doris 组件（FE、BE、MS）
- 处理故障自动恢复
- 保持期望状态（比如说要 3 个 FE，就必须有 3 个）

---

### 4. DorisDisaggregatedCluster - 集群定义（订单）

**想象**：游乐场的「建设订单」

```yaml
# 03-doris-disaggregated-cluster.yaml
apiVersion: disaggregated.cluster.doris.com/v1
kind: DorisDisaggregatedCluster
metadata:
  name: doris-disaggregated    # 游乐场名字
spec:
  metaService:                 # 大脑配置
    image: apache/doris:ms-4.0.4
    replicas: 2                 # 要 2 个大脑
    fdb:
      address: "doris-fdb:4500"  # 大脑连接索引系统
  feSpec:                       # 服务员配置
    image: apache/doris:fe-4.0.4
    replicas: 3                # 要 3 个服务员
  computeGroups:               # 计算节点配置
  - uniqueId: cg1
    image: apache/doris:be-4.0.4
    replicas: 3               # 要 3 个计算节点
```

**作用**：
- 定义「我要什么样的游乐场」
- Operator 读取这个配置，自动创建对应组件
- **声明式**：你只管说需要什么，不用管怎么实现

---

### 5. ConfigMap - 配置文件（操作手册）

**想象**：每个设施的「操作手册」

```yaml
# configmaps.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: doris-fe-config        # 服务员手册
data:
  fe.conf: |
    run_mode=disagg           # 存算分离模式
    meta_service_endpoint=... # 大脑在哪里
    cloud_unique_id=...       # 唯一标识
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: doris-be-config        # 计算节点手册
data:
  be.conf: |
    run_mode=disagg           # 存算分离模式
    meta_service_endpoint=... # 大脑在哪里
    cluster_name=cg1         # 我属于哪个计算组
```

**作用**：
- 存放组件的配置参数
- 不用改代码，只改配置就能改变行为
- 挂载到 Pod 中供容器读取

---

### 6. Services - 服务发现（排队入口）

**想象**：游乐设施的「入口闸机」

```yaml
# 04-services.yaml
apiVersion: v1
kind: Service
metadata:
  name: doris-fe-lb           # FE 入口
spec:
  type: LoadBalancer          # 负载均衡类型
  selector:
    app: doris-disaggregated-fe  # 找到哪些是 FE Pod
  ports:
  - name: fe-mysql
    port: 9030               # 外部端口
    targetPort: 9030         # 转发到 Pod 的 9030
```

**作用**：
- 给 Pod 提供固定的访问地址（不因 Pod 重启改变）
- 负载均衡：多个人访问，分发到不同 Pod
- 类型说明：
  - **ClusterIP**：只在集群内部访问
  - **LoadBalancer**：给外部访问（云环境）

---

## 各组件职责总结

| 组件 | 职责 | 类比 |
|------|------|------|
| **FoundationDB** | 存储元数据 | 图书馆索引卡片 |
| **FDB Operator** | 管理 FDB | 自动索引机器人 |
| **Doris Operator** | 管理 Doris 集群 | 游乐场总经理 |
| **DorisDisaggregatedCluster** | 定义集群规格 | 建设订单 |
| **ConfigMap** | 配置文件 | 操作手册 |
| **Service** | 服务发现 | 入口闸机 |

---

## 部署顺序（从底层到上层）

```
Step 1: 部署 FDB Operator (管理员)
        ↓
Step 2: FDB Operator 自动创建 FoundationDB
        ↓
Step 3: 部署 Doris Operator (管理员)
        ↓
Step 4: Doris Operator 自动创建 Doris 集群
        (FE + BE + MetaService)
        ↓
Step 5: 部署 Services (让外部能访问)
```

---

## 常见问题解答

### Q: 为什么需要 Operator？
**A**: 没有 Operator = 人工管理；有 Operator = 机器人自动管理。机器人更高效、更不容易出错。

### Q: 为什么 FoundationDB 要单独部署？
**A**: FoundationDB 是外部依赖，Doris 的元数据存在里面。它有自己的 Operator 来管理。

### Q: ConfigMap 和 Secret 有什么区别？
**A**: ConfigMap 存普通配置（明文）；Secret 存敏感信息（密码、密钥，会加密）。

### Q: StatefulSet 和 Deployment 有什么区别？
**A**:
- **Deployment**：无状态，Pod 可以随意替换（如 nginx）
- **StatefulSet**：有状态，Pod 有固定身份（如数据库）

Doris 的 FE、BE 需要固定身份，所以用 StatefulSet。

---

## 文件结构说明

```
k8s/gke/
├── 00-fdb-operator.yaml              # 管理员：管理 FDB
├── 01-fdb-cluster.yaml              # FDB 数据库实例
├── 02-doris-operator.yaml          # 管理员：管理 Doris
├── 03-doris-disaggregated-cluster.yaml  # Doris 集群规格
├── 04-services.yaml                 # 服务访问入口
└── configmaps.yaml                  # 配置文件
```

---

## 故障排查

```bash
# 查看 FDB 状态
kubectl get foundationdbcluster -n doris

# 查看 FDB Pods
kubectl get pods -l app=foundationdb -n doris

# 查看 Doris 集群状态
kubectl get dorisdisaggregatedcluster -n doris

# 查看所有 Pods
kubectl get pods -n doris -o wide

# 查看某个 Pod 日志
kubectl logs doris-fdb-log-1 -n doris --tail=100
```
