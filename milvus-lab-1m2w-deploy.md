# Milvus 离线部署要点（实验环境：1 Master + 2 Worker）

> 本文是 [milvus-offline-deploy.md](./milvus-offline-deploy.md) 的**特化版**，针对你当前的实验环境裁剪：
> - 节点：**1 master + 2 worker**
> - StorageClass：**仅 longhorn 一个**（已部署，`default-replica-count` 已改为 **2**；local-path 已删除，当前只有 Longhorn 可用）
> - 运行时：containerd，离线镜像 `ctr -n k8s.io import`
> - 版本基线：**Milvus v2.6.19**
>
> ⚠️ **测试阶段存储说明**：因 local-path 已删，本环境暂时只有 Longhorn。所以 etcd / MinIO / Pulsar 的 PVC **都先落 Longhorn** 做功能验证。**MinIO on Longhorn 的双写放大是已知权衡**（详见第 2 节），仅用于跑通功能；正式压性能 / 评估容量前，应给 MinIO 恢复本地盘 SC 或接外部 MinIO。
>
> 镜像准备、`save_image.py`、Operator 完整流程见主文档。本文只讲 **1+2 下怎么裁**、**存储怎么落**、**哪些是 1+2 独有的坑**。

## 0. TL;DR 选型
| 你想要 | 路线 | 一句话 |
|------|------|------|
| 最快验证 Milvus 能跑通 | **Helm standalone** | 单 Pod 自包含 etcd/MinIO，1 个 PVC，命令最少 |
| 练习生产架构（cluster） | **Helm cluster 压缩** | etcd/MinIO 全 1 副本（woodpecker 替代 Pulsar），按本文显式指定 SC |
| 用 CR 长期管理 | Operator 压缩 | 同 cluster，但用 MilvusCluster CR |

实验环境 **默认推荐 Helm standalone**（命令最少、最稳）；若目标是**练生产架构、体验组件拆分/独立扩缩**（为 1+6 预演），选 **Helm cluster 压缩（第 5 节）**。

## 1. 部署前已就绪确认
任一不满足都会卡：
```bash
kubectl get nodes                                              # 3 节点 Ready（1 master + 2 worker）
kubectl get sc                                                 # 仅 longhorn 带 (default)（local-path 已删除）
kubectl -n longhorn-system get lhn                            # 参与存储的节点都 READY（2 worker 或含 master）
kubectl -n longhorn-system get lhs default-replica-count -o jsonpath='{.value}'   # 应输出 2
```
若 `lhn` 有节点 `NotReady`，先修（磁盘/标签），否则将来 PVC 会 Pending。

## 2. 存储规划（1+2 核心决策）
默认 SC 已是 **longhorn**，且当前**只有它一个 SC**，所以所有 PVC 都落 Longhorn。决策表：

| 组件 | 落盘方式 | storageClassName | 副本/模式 | 说明 |
|------|---------|------------------|-----------|------|
| **etcd** | PVC | **longhorn** | etcd 1 副本；PVC 由 Longhorn 给 2 副本 | Longhorn 2 副本提供磁盘冗余；etcd 单节点实验够用 |
| **MinIO** | PVC | **longhorn** | standalone 单 pod | 测试阶段用 Longhorn（⚠️ 双写放大已知，功能验证后再优化） |
| Pulsar（若启用） | PVC | **longhorn** | 单副本 | 测试阶段，单副本即可 |
| Milvus 计算组件 | 无状态 | — | — | 数据全在 MinIO |

铁律：
1. 本环境**仅 Longhorn 一个 SC（默认）**，所有 PVC 显式写 `storageClassName: longhorn` 即可（etcd / MinIO / Pulsar 都走它）。
2. **MinIO on Longhorn 的双写放大是已知权衡**：MinIO 写 1 份数据，Longhorn 底层再写 2 副本 = 实际 2 份写、空间/IO 翻倍，且故障域没增加（仍在同 2 节点）。仅用于功能测试。
3. 正式性能 / 容量评估前，应为 MinIO 单独准备本地盘 SC（重建 local-path 或外部 MinIO），避开双写放大；etcd 落 Longhorn 吃 2 副本冗余，配置不变。

> **测试阶段说明**：本环境已删除 local-path，暂时只有 Longhorn 可用，所以 MinIO 也先落 Longhorn 把功能跑通。等验证完、要压性能或评估容量时，再给 MinIO 换回本地盘 SC（重建 local-path）或接外部 MinIO 即可——Milvus 数据本身存在 MinIO 里，切换 MinIO 后端时只要数据不丢，已写入的向量不受影响。

## 3. 离线镜像（简版，详见证主文档第 2/3 节）
镜像基线（v2.6.19，已与原 manifest 对齐）：
```
milvusdb/milvus:v2.6.19
docker.io/milvusdb/etcd:3.5.25-r1
minio/minio:RELEASE.2024-12-18T13-15-44Z
minio/mc:RELEASE.2024-12-18T13-15-44Z
apachepulsar/pulsar:3.0.7        # 仅 cluster 路线且保留 Pulsar 时需要
zilliz/attu:v2.5.3               # 可选
busybox:1.36
milvusdb/milvus-operator:v1.3.7  # 仅 Operator 路线
```
- **提取**：有网机先 `helm template ... > manifest.yaml`，再 `python3 save_image.py --manifest manifest.yaml`（自动读全镜像，版本 100% 对齐）。
- **导入（每个节点）**：`gunzip -c xxx.tar.gz | ctr -n k8s.io images import -`，**必须 `k8s.io`**。
- 逐节点验证：`ctr -n k8s.io images ls | grep -E 'milvus|etcd|minio|pulsar'`。

## 4. 路线 A-1：Helm standalone（实验最推荐）
单 Pod 自包含 etcd + MinIO + 元数据，只需 **1 个 PVC**（走 longhorn）。

**有网机渲染**（显式指定 PVC 的 SC 为 longhorn）：
```bash
helm repo add zilliztech https://zilliztech.github.io/milvus-helm/
helm repo update

helm template demo-release zilliztech/milvus \
  --set image.all.tag=v2.6.19 \
  --set cluster.enabled=false \
  --set etcd.replicaCount=1 \
  --set minio.mode=standalone \
  --set pulsarv3.enabled=false \
  --set persistence.storageClass=longhorn \
  > milvus_manifest_standalone.yaml
```
> `pulsarv3.enabled=false` 让 Milvus 回退到内置 rocksmq（消息存本地 PVC），省掉 Pulsar 那一坨。实验完全够用。
> 本环境仅 Longhorn，直接指定 `longhorn` 即可（单 PVC 走 Longhorn 2 副本）。
> 参数名以 `helm show values zilliztech/milvus` 为准；若 `persistence.storageClass` 不生效，改在 `values.yaml` 的 `persistence` 段指定。

**离线机部署**：
```bash
kubectl apply -f milvus_manifest_standalone.yaml
kubectl get pods -n default -w     # 等 milvus-standalone-xxx Running
```

**验证**：
```bash
kubectl port-forward --address 0.0.0.0 service/demo-release-milvus 27017:19530 -n default &
# 用 pymilvus 连 127.0.0.1:27017 建集合 / 插向量 / 搜向量
```

## 5. 路线 A-2：Helm cluster 压缩（为 1+6 生产预演）
> 你选定的路线。这条不是"能跑就行"，而是**用 1+2 的小资源把 1+6 生产的组件拓扑完整跑一遍**——组件拆分、独立扩缩、依赖分离都和生产一致，只是每个副本压缩成 1。将来上 1+6 时，只需把副本数拉高、MinIO 改分布式、恢复本地盘 SC，拓扑不变。

> ⚠️ **Milvus 2.6 架构变更（必读，踩坑点）**：v2.6.0 起 Milvus 做了重大重构——
> - 4 类独立 Coordinator（rootCoord/dataCoord/queryCoord/indexCoord）**合并成单一 `mixCoord`**；独立 `milvus run indexcoord` 会报 `unknown server type`（Pod 起不来）。
> - **indexNode 已移除**，建索引能力合并进 **dataNode**；独立 `milvus run indexnode` 同样报 `unknown server type`。
> - 新增 **streamingNode**（流节点），需 `streaming.enabled=true` 开启。
> 所以 2.6 下**不要**尝试拆独立 coord 或开 indexNode——这俩在 2.6 二进制里已不存在。`my-release-etcd-0` 之前报 `unknown server type=indexcoord` 正是这个原因。

**2.6 真实 cluster 拓扑（压缩后）**：
```
my-release-etcd-0                       # 依赖：etcd（Longhorn PVC）
my-release-minio-xxx                    # 依赖：MinIO（Longhorn PVC）
my-release-milvus-mixcoord-xxx          # 4 类 coord 合并于此（官方推荐，勿拆）
my-release-milvus-proxy-xxx             # 接入层
my-release-milvus-datanode-xxx          # 数据节点（含建索引能力，原 indexNode 已并入）
my-release-milvus-querynode-xxx         # 查询节点
my-release-milvus-streamingnode-xxx     # 2.6 新组件：流节点
```

**关键原则**：cluster 模式 = 组件以独立 Pod 部署；2.6 下"独立"体现在 **mixCoord / proxy / dataNode / queryNode / streamingNode** 各自是独立进程、可独立扩缩，而 coordinator 作为轻量组件合并进 mixCoord（这是 2.6 架构，不是缩配）。1+2 下只压缩**副本数**，不压缩**组件拓扑**。

建 `values-cluster-1m2w.yaml`：
```yaml
image:
  all:
    tag: v2.6.20

cluster:
  enabled: true

# 2.6 推荐：使用默认 mixCoord（合并协调者）。不要设独立 coord，会报 unknown server type
# mixCoordinator.enabled 默认即 true，可省略；如显式写：
mixCoordinator:
  enabled: true

# 2.6 新组件：streamingNode，必须开（否则缺流式处理组件）
streaming:
  enabled: true

# indexNode 在 2.6 已移除（合并进 dataNode），必须关（默认已 false，显式写更稳）
indexNode:
  enabled: false

# woodpecker 消息流替代 pulsar（离线无需拉 pulsar 镜像）；同时关掉 pulsar 子图
msgStreamType: woodpecker
pulsar:
  enabled: false
pulsarv3:
  enabled: false

# ===== 依赖组件（全部压 1 副本）=====
etcd:
  replicaCount: 1
  persistence:
    enabled: true
    storageClass: longhorn      # 落 Longhorn，吃 2 副本冗余
  resources:
    requests: { cpu: 200m, memory: 512Mi }
    limits:   { cpu: "1", memory: 1Gi }

minio:
  mode: standalone              # 单 pod，不需要 4 drive
  persistence:
    enabled: true
    storageClass: longhorn      # 测试阶段落 Longhorn（双写放大已知，后续优化）
  resources:
    requests: { cpu: 200m, memory: 512Mi }
    limits:   { cpu: "1", memory: 1Gi }

# ===== Milvus 工作组件（组件独立，压 1 副本）=====
proxy:
  replicas: 1
  resources:
    requests: { cpu: 500m, memory: 1Gi }
    limits:   { cpu: "2", memory: 4Gi }
dataNode:
  replicas: 1                    # 含 index 建索引能力（原 indexNode 已并入）
  resources:
    requests: { cpu: 500m, memory: 1Gi }
    limits:   { cpu: "2", memory: 4Gi }
queryNode:
  replicas: 1
  resources:
    requests: { cpu: 500m, memory: 1Gi }
    limits:   { cpu: "2", memory: 4Gi }
streamingNode:
  replicas: 1
  resources:
    requests: { cpu: 300m, memory: 512Mi }
    limits:   { cpu: "1", memory: 1Gi }

# 可选：开鉴权（实验可省，生产必开）
# extraConfigFiles:
#   user.yaml: |+
#     common:
#       security:
#         authorizationEnabled: true
```
渲染并部署：
```bash
# 离线环境：把 zilliztech/milvus 换成你本地解压的 chart 目录（如 /d/soft/milvus-chart）
helm template demo-release zilliztech/milvus \
  -f values-cluster-1m2w.yaml \
  > milvus_manifest_cluster.yaml

kubectl apply -f milvus_manifest_cluster.yaml
kubectl get pods -n default -w
```

**预期 Pod 清单（2.6 真实拓扑，组件拆分全貌）**——你会看到这些独立 Pod，正是 1+6 生产架构的缩微版：
```
demo-release-etcd-0                       # 依赖：etcd（Longhorn PVC）
demo-release-minio-xxx                    # 依赖：MinIO（Longhorn PVC，standalone 单 pod）
demo-release-milvus-mixcoord-xxx          # 4 类 coord 合并（rootcoord/datacoord/querycoord/indexcoord 都在内）
demo-release-milvus-proxy-xxx             # 接入层
demo-release-milvus-datanode-xxx          # 数据节点（含建索引能力，原 indexNode 已并入）
demo-release-milvus-querynode-xxx         # 查询节点
demo-release-milvus-streamingnode-xxx     # 2.6 新组件：流节点
```
> 注意：2.6 里**没有**独立的 rootcoord/datacoord/querycoord/indexcoord Pod，也没有 indexnode Pod——它们已在架构层面合并（mixCoord + dataNode 兼任）。若你看到 `unknown server type=indexcoord/indexnode` 报错，就是误开了独立 coord / indexNode，回看本页顶部架构变更说明。

**练"独立扩缩"（为生产准备）**——2.6 下真正可独立扩缩的是工作节点（都是独立 Deployment，注意 querynode/datanode/streamingnode/proxy 用 `kubectl scale deployment`，不是 statefulset）：
```bash
# 查询压力大就加 querynode
kubectl scale deployment demo-release-milvus-querynode --replicas=2
# 建索引/写入压力大就加 datanode（含 index 能力）
kubectl scale deployment demo-release-milvus-datanode --replicas=2
# 流处理压力大加 streamingnode
kubectl scale deployment demo-release-milvus-streamingnode --replicas=2
# 单独观察某组件的扩缩效果
kubectl get pods -l component=querynode -n default
```
> coordinator 在 2.6 合并进 mixCoord，无法像独立 coord 那样单扩 indexcoord——这是架构设计，不是限制；生产 1+6 扩 `mixcoord` 副本即可提升协调层整体吞吐/可用性。1+2 资源紧，扩到 2 可能 Pending/OOM，扩缩练习时盯着 `kubectl top pods`。

⚠️ 2 worker 资源紧：若 Pod `Pending` / `OOMKilled`，把上面 resources 再调小，或实验放开 master 调度（`kubectl taint nodes --all node-role.kubernetes.io/master-`，仅实验用）。

## 6. 路线 B：Operator 压缩（附）
完整流程见主文档第 5 节。1+2 只需把 CR 里的 StorageClass 显式改掉（存为 `milvus-cluster-1m2w.yaml`）：
```yaml
apiVersion: milvus.io/v1alpha1
kind: Milvus
metadata:
  name: milvus
  namespace: milvus
spec:
  mode: cluster
  components:
    image: milvusdb/milvus:v2.6.19
    imagePullPolicy: IfNotPresent
    proxy:        { replicas: 1 }
    rootCoord:    { replicas: 1 }
    indexCoord:   { replicas: 1 }
    queryCoord:   { replicas: 1 }
    dataCoord:    { replicas: 1 }
    indexNode:    { replicas: 1 }
    queryNode:    { replicas: 1 }
    dataNode:     { replicas: 1 }
  dependencies:
    etcd:
      inCluster:
        values:
          replicaCount: 1
          storageClass: longhorn        # etcd → Longhorn
    storage:
      type: MinIO
      inCluster:
        values:
          mode: standalone
          storageClass: longhorn         # 测试阶段 MinIO → longhorn（双写放大已知）
    pulsar:
      inCluster:
        values:
          zookeeper:  { replicaCount: 1 }
          bookkeeper: { replicaCount: 1 }
          broker:     { replicaCount: 1 }
          proxy:      { replicaCount: 1 }
```
部署：
```bash
kubectl create namespace milvus
kubectl apply -f milvus_deploy.yaml          # Operator（CRD + RBAC + 控制器）
kubectl apply -f milvus-cluster-1m2w.yaml
kubectl get milvus -n milvus -w              # Healthy
```

## 7. 外部访问（NodePort，离线内网最省）
```yaml
# demo-release-milvus-external-svc.yaml
kind: Service
apiVersion: v1
metadata:
  name: demo-release-milvus-external-svc
  namespace: default
spec:
  ports:
    - name: milvus
      port: 19530
      targetPort: 19530
      nodePort: 31800
  selector:
    app.kubernetes.io/instance: demo-release
    app.kubernetes.io/name: milvus
    component: proxy
  type: NodePort
```
```bash
kubectl apply -f demo-release-milvus-external-svc.yaml
# 应用连 <任意节点IP>:31800；Attu 见主文档 4.6 / 4.7（可选启用）
```
> standalone 模式没有独立 `proxy` component，svc 的 `selector.component` 应为 `standalone`（或按 `kubectl get svc -n default` 看到的真实 selector 调整）。

## 8. 验证清单
- [ ] 所有 Pod Running（`kubectl get pods -n default` 或 `-n milvus`）
- [ ] 无 `ImagePullBackOff`（否则镜像没进 `k8s.io`，回第 3 节逐节点导）
- [ ] PVC 都 Bound 且 **SC 均为 longhorn**：`kubectl get pvc -A`
- [ ] Longhorn volume Healthy：`kubectl -n longhorn-system get lhv`（etcd / MinIO 那些应是 Healthy，2 副本）
- [ ] 连得上：pymilvus 建集合 / 插向量 / 搜向量成功

## 9. 1+2 独有排障
| 现象 | 根因（1+2 特化） | 修复 |
|------|----------------|------|
| PVC Pending（etcd / MinIO） | Longhorn 节点 NotReady / 磁盘满 | `kubectl -n longhorn-system get lhn` 看节点；清盘或修节点 |
| MinIO on Longhorn IO/空间翻倍 | 双写放大（预期，非故障） | 功能测试可接受；压性能前给 MinIO 换本地盘 SC 或外部 MinIO |
| Pod 全 Pending | 2 worker 资源不够 / master 有污点 | 调小 resources；实验放开 master 污点 |
| etcd / MinIO 起不来 | PVC 没绑或 Longhorn volume Degraded | 查 PVC event + `kubectl -n longhorn-system get lhv` |
| OOMKilled | 2 节点内存紧 | 再砍 resources，或改用 standalone 模式最省 |

通用排障（ImagePullBackOff / 镜像反查 / 卸载）见主文档第 7、8 节。

## 10. 与 1+6 生产文档差异对照
| 维度 | 1+2 实验（本文） | 1+6 生产（待出） |
|------|----------------|----------------|
| 节点 | 1 master + 2 worker | 1 master + 6 worker |
| Longhorn 副本 | **2** | 3 |
| etcd | 1 副本（Longhorn PVC 2 副本） | 3 副本 Raft |
| MinIO | standalone（longhorn，双写放大已知） | 分布式 4-drive（local-path） |
| Pulsar | 关闭（rocksmq）或单副本 | zk3 / bookie3 / broker2 / proxy2 |
| 资源 | 紧，大幅压缩 | 充裕 |
| 鉴权 | 可选 | 必开 `authorizationEnabled` |
| 外部访问 | NodePort | NodePort → Ingress |
| 镜像分发 | 逐节点 `ctr import` | 建议 Harbor 私有仓库 |

---

### 与配套文档关系
- 镜像 / 导入 / Operator 全流程：[milvus-offline-deploy.md](./milvus-offline-deploy.md)
- Longhorn 离线部署与排障：[longhorn-offline-deploy.md](./longhorn-offline-deploy.md)
- 基础 K8s 离线环境：[k8s-offline-manual-deploy.md](./k8s-offline-manual-deploy.md)
