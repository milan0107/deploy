# Milvus 分布式集群 · 离线 K8s 部署文档

> 配套文档：[k8s-offline-manual-deploy.md](./k8s-offline-manual-deploy.md)（K8s 1.32 离线基础环境、镜像 retag 套路、本地存储 local-path/OpenEBS）
>
> 参考官方文档：[Install Milvus Cluster with Helm — Offline install](https://milvus.io/docs/install_cluster-helm.md#Offline-install)（milvus.io 官方，本文 Helm 路线严格对齐其离线流程）。
>
> 适用环境：**离线内网**、openEuler、1 master + 2 worker、K8s 1.32、已具备 local-path 或 OpenEBS 本地存储。
> 目标形态：**分布式 Milvus（`cluster`/`mixcoord`），副本可压缩**，能在 3 节点上跑起来做 PoC / 预生产验证。
> 本文以 **Milvus v2.6.19** 为例（版本以 2.1 反查法 / 渲染产物为准）。

**两条部署路线**（二选一，效果等价）：

| | 路线 A：Helm（官方推荐） | 路线 B：Operator |
|---|---|---|
| 适用文件 | 你桌面的 `milvus_manifest.yaml`（`helm template` 渲染产物，`demo-release`） | 你桌面的 `milvus_deploy.yaml`（Operator CRD+RBAC+控制器） |
| 镜像清单来源 | `helm template` 渲染出的 manifest → `save_image.py` 自动提取 | 基线清单 + 部署后反查 |
| 推荐度 | ⭐⭐⭐ 离线最省心（镜像/版本自动对齐） | ⭐⭐ 适合要长期用 CR 管理 Milvus 的场景 |

---

## 0. 架构与组件一览

```
┌──────────────────────── K8s 集群 (1 master + 2 worker) ────────────────────────┐
│                                                                                │
│  Milvus 服务栈（无状态计算，数据在 MinIO）                                       │
│   2.5+ 默认 mixcoord 模式：单个 milvus-mixcoord 合并 root/index/query/data coord │
│   proxy·mixcoord·dataNode·indexNode·queryNode                                  │
│                                                                                │
│  依赖服务（自动部署）                                                            │
│   etcd   → 元数据（Raft）                                                       │
│   MinIO  → 对象存储（向量 chunk / 索引 / 日志）                                 │
│   Pulsar → 消息队列（zookeeper/bookkeeper/broker/proxy）                       │
│                                                                                │
│  持久化：etcd PVC + MinIO PVC  →  本地存储 local-path / OpenEBS                 │
└────────────────────────────────────────────────────────────────────────────────┘
```

**关键认知**：Milvus 自身的 proxy / coord / node **基本无状态**，数据全在 MinIO。所以真正要落盘、要 PV 的只有 **etcd 和 MinIO**。

> **关于 mixcoord**：Milvus 2.5 起默认把 4 个 coord 组件合并成单个 `milvus-mixcoord` Pod（Mix 模式），降低小集群资源占用。你 `helm template` 出来的清单里会看到 `milvus-mixcoord-0` 而不是分开的 `rootcoord`/`indexcoord`/`querycoord`/`datacoord`。这是**正常行为**，不是部署缺组件。Operator 路线（路线 B）的 CR 仍可显式拆开各 coord 副本。
>
> **版本注意**：官方在线文档当前示例基于 **v3.0-beta**，新引入了 **Streaming Node**（`milvus-streaming-node-*`，默认开启）并把 **Index Node 合并进 Data Node**，消息队列默认推荐 **Woodpecker**（替代 Pulsar）。你本文固定的是 **v2.6.19**（和你真实 `milvus_manifest.yaml` 一致），该版本仍有独立 `indexNode`、默认用 Pulsar、**没有 streaming-node**。无论哪版，pod 列表里出现的组件都是正常的，缺/多某个 pod 以你实际渲染的 manifest 为准，不必强求与官方示例截图一字不差。

---

## 1. 先决条件（在你已有的离线 K8s 上确认）

- [ ] K8s 1.32 三节点 `Ready`（见配套文档第 11 节清单）
- [ ] containerd 命名空间 `k8s.io` 已就绪
- [ ] 本地存储可用：`kubectl get sc` 能看到 `local-path`（或 `openebs-hostpath`）
- [ ] **把本地存储设为默认 StorageClass**（etcd/MinIO 会自动用它，避免逐个指定 storageClass 字段踩坑）：

```bash
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

kubectl get sc   # 确认 local-path 带 (default) 标记
```

> 若不想改默认 SC，也可以在部署清单里显式指定 storageClass（见各路线注释），但字段路径随 chart 版本变化，反不如直接设默认 SC 稳。

---

## 2. 有网机：准备离线镜像（两种手法）

### 2.1 确定精确镜像列表（两步法）

离线镜像**最稳的来源是"从渲染产物反查"**，因为依赖镜像版本会随 Milvus 版本漂移。流程：

1. 先按下面的**基线清单**拉一批（覆盖 90% 情况）；
2. 在离线集群 apply 后，用下面命令把 Milvus 实际要的镜像**一个不漏**列出来，缺哪个补哪个。

```bash
# 离线集群上，Milvus 部署后执行
kubectl get pods -n milvus -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u
```

**基线镜像清单（Milvus v2.6.19，已对照你真实部署清单修正）**：

| 镜像 | 用途 | 来源 registry |
|------|------|---------------|
| `milvusdb/milvus:v2.6.19` | Milvus 全部组件共用 | docker.io |
| `docker.io/milvusdb/etcd:3.5.25-r1` | 元数据（Milvus 维护的 etcd fork，**非** quay.io/coreos） | docker.io |
| `minio/minio:RELEASE.2024-12-18T13-15-44Z` | 对象存储 | docker.io |
| `minio/mc:RELEASE.2024-12-18T13-15-44Z` | MinIO 客户端（init 作业用） | docker.io |
| `apachepulsar/pulsar:3.0.7` | 消息队列 | docker.io |
| `zilliz/attu:v2.5.3` | 可视化管理台（可选，启用 Attu 时需要） | docker.io |
| `busybox:1.36` | init 容器 | docker.io |

> ⚠️ etcd / minio / pulsar 的**精确版本以 2.1 反查结果为准**。Operator 路线另需 `milvusdb/milvus-operator:v1.3.7`（见路线 B）。

### 2.2 手法一：daocloud 拉取 + retag + save（手动清单）

retag 的原因和配套文档一致：K8s 只认原 tag（`docker.io/...`、`quay.io/...`），所以必须拉到镜像后**打回原 tag**，再 `docker save`。

```bash
DOCKER_MIRROR=docker.m.daocloud.io
MILVUS_VER=v2.6.19

pull_retag() {
  local img="$1"
  echo "==> $img"
  docker pull "$DOCKER_MIRROR/$img" && docker tag "$DOCKER_MIRROR/$img" "$img" || echo "FAILED: $img"
}

for img in \
  "milvusdb/milvus:$MILVUS_VER" \
  "docker.io/milvusdb/etcd:3.5.25-r1" \
  "minio/minio:RELEASE.2024-12-18T13-15-44Z" \
  "minio/mc:RELEASE.2024-12-18T13-15-44Z" \
  "apachepulsar/pulsar:3.0.7" \
  "zilliz/attu:v2.5.3" \
  "busybox:1.36" ; do
  pull_retag "$img"
done

docker images | grep -E 'milvus|etcd|minio|pulsar|attu|busybox'

docker save \
  "milvusdb/milvus:$MILVUS_VER" \
  "docker.io/milvusdb/etcd:3.5.25-r1" \
  "minio/minio:RELEASE.2024-12-18T13-15-44Z" \
  "minio/mc:RELEASE.2024-12-18T13-15-44Z" \
  "apachepulsar/pulsar:3.0.7" \
  "zilliz/attu:v2.5.3" \
  "busybox:1.36" \
  -o milvus-offline-images.tar
```

> 此手法需**手工维护镜像清单**。版本漂移时容易漏。对 Helm 路线，**手法二（save_image.py）更省心**——它从渲染出的 manifest 自动读出全部镜像。

### 2.3 手法二（官方推荐）：save_image.py 自动提取

Milvus 官方提供离线镜像脚本，能**直接解析渲染后的 manifest，自动拉取并打包全部镜像**，彻底避免"版本漂移导致漏镜像"。这是官方 Offline install 的标准手法，**Helm 路线优先用此法**。

> 前置：先按 4.2 节 `helm template` 生成 `milvus_manifest.yaml`，本步才能从其中读到精确镜像列表。

```bash
# 在有网机
wget https://raw.githubusercontent.com/milvus-io/milvus/master/deployments/offline/requirements.txt
wget https://raw.githubusercontent.com/milvus-io/milvus/master/deployments/offline/save_image.py

# 安装依赖（国内可用清华源加速）
pip3 install -r requirements.txt -i https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple
# ⚠️ 若报 ModuleNotFoundError: No module named 'yaml'，补装：pip3 install pyyaml

# 从渲染好的 manifest 自动提取并下载镜像（每个镜像一个 .tar.gz，存到 ./images/）
python3 save_image.py --manifest milvus_manifest.yaml

ls -lh images/
# 例如：apachepulsar-pulsar.tar.gz / docker.io-milvusdb-etcd.tar.gz /
#       milvusdb-milvus.tar.gz / minio-minio.tar.gz / zilliz-attu.tar.gz

# 打包带走（拷到离线环境）
tar zcvf milvus-offline-images.tar.gz images
```

> **为什么推荐**：`save_image.py` 读的是你实际要部署的 manifest，版本 100% 对齐，不会出现"文档写 2.5.x、实际要 2.6.x"的漏镜像问题。
> 若 `save_image.py` 默认从公网 Docker Hub 拉取失败（你的"有网机"也受网络限制），可改用 **2.2 节 daocloud 手动清单法**作为兜底——两者最终都得到一份离线镜像包。

### 2.4 镜像分发：逐节点导入 vs 私有仓库

镜像准备好后，有两种方式送到离线集群：

- **小集群（≤3 节点，如你的 PoC）**：直接把 tar 拷到每个节点 `ctr -n k8s.io images import`（见第 3 节）。简单、无需额外组件。
- **大集群（≥6 节点，如生产）**：建议在离线环境自建 **Harbor / Registry 私有镜像仓库**，把镜像 `docker tag` + `docker push` 进去，再让各节点从仓库拉取（避免逐机导包）。文章即采用 Harbor 方案：

```bash
# 在能连外网的中转机上，把 images/ 里的包 load 进 docker，重新 tag 推到 Harbor
tar xvf milvus-offline-images.tar.gz
cd images
for image in $(find . -type f -name "*.tar.gz"); do gunzip -c "$image" | docker load; done

# 假设内网仓库地址 harbor.milvus.local（用你的实际地址替换）
docker tag docker.io/milvusdb/etcd:3.5.25-r1        harbor.milvus.local/docker.io/milvusdb/etcd:3.5.25-r1
docker tag milvusdb/milvus:v2.6.19                   harbor.milvus.local/milvusdb/milvus:v2.6.19
docker tag minio/minio:RELEASE.2024-12-18T13-15-44Z harbor.milvus.local/minio/minio:RELEASE.2024-12-18T13-15-44Z
docker tag apachepulsar/pulsar:3.0.7                harbor.milvus.local/apachepulsar/pulsar:3.0.7
docker tag zilliz/attu:v2.5.3                        harbor.milvus.local/zilliz/attu:v2.5.3
# 推送
for img in docker.io/milvusdb/etcd:3.5.25-r1 milvusdb/milvus:v2.6.19 \
           minio/minio:RELEASE.2024-12-18T13-15-44Z apachepulsar/pulsar:3.0.7 zilliz/attu:v2.5.3; do
  docker push harbor.milvus.local/$img
done
```

用 Harbor 时，部署前要把 manifest 里的镜像地址整体替换成仓库地址（Helm 路线 4.4 节 `sed` 法）。

---

## 3. 内网每个节点导入镜像

把镜像包拷到**每个节点**（master + 所有 worker），导入到 `k8s.io` 命名空间。

> ⚠️ 官方离线文档用的是 `docker load`，但你的集群是 **containerd（无 docker）**，必须换成 `ctr -n k8s.io images import`。下面两种来源都给出。

**来源 A：手法一（单一 tar 包 `milvus-offline-images.tar`）**

```bash
ctr -n k8s.io images import milvus-offline-images.tar
```

**来源 B：手法二 / 官方 `save_image.py` 产出的 `images/` 目录（推荐）**

```bash
# 把 milvus-offline-images.tar.gz 解压出 images/ 目录后
cd images
for image in $(find . -type f -name "*.tar.gz"); do
  echo "==> importing $image"
  gunzip -c "$image" | ctr -n k8s.io images import -
done
```

> 说明：`save_image.py` 内部是 `docker save | gzip`，产出的是 gzip 后的 docker 格式 tar；`gunzip -c` 解压后管道给 `ctr images import -` 直接从标准输入读，和 `docker load` 等价、且兼容 containerd。

**每个节点验证（应看到全部镜像）**：

```bash
ctr -n k8s.io images ls | grep -E 'milvus|etcd|minio|pulsar|attu|busybox'
```

> ⚠️ **每个节点都要导**。etcd/MinIO 是 StatefulSet，会调度到具体节点并就地起 Pod；Milvus 组件也可能被调度到任意 worker。漏导的节点上的 Pod 会 `ImagePullBackOff`。
> 若用 Harbor（2.4 节），则各节点只需 `docker login harbor.milvus.local` 并确保 containerd 配置了该仓库的 `mirror`/`insecure-registry`，无需逐机 import。

---

## 4. 路线 A：Helm 离线部署（官方推荐，对应 milvus_manifest.yaml）

> 这条路线与你桌面的 `milvus_manifest.yaml` 完全对应：先 `helm template` 渲染出静态 manifest，再 `kubectl apply`。

### 4.1 有网机装 Helm

```bash
wget https://get.helm.sh/helm-v3.15.4-linux-amd64.tar.gz
tar -zxvf helm-v3.15.4-linux-amd64.tar.gz
mv linux-amd64/helm /usr/local/bin/
rm -rf linux-amd64/
helm version   # 确认 ≥ 3.15
```

### 4.2 生成部署清单（helm template）

```bash
# ⚠️ 官方已从 milvus-io/milvus-helm 迁移到 zilliztech/milvus-helm
#    （旧仓库已归档，仅保留到 4.0.31；新版本一律用 zilliztech）
helm repo add zilliztech https://zilliztech.github.io/milvus-helm/
helm repo update

# 渲染出静态清单（demo-release 是 release 名，可改）
# 用 --set image.all.tag 锁死版本，确保渲染出的镜像与离线预拉的镜像完全一致
helm template demo-release zilliztech/milvus \
  --set image.all.tag=v2.6.19 \
  > milvus_manifest.yaml

# 如需自定义配置（鉴权 / Attu 等），把 --set 换成 -f values.yaml：
#   helm template demo-release zilliztech/milvus --set image.all.tag=v2.6.19 -f values.yaml > milvus_manifest.yaml
```

> 渲染产物 `milvus_manifest.yaml` 即你桌面上那份文件：含 etcd / MinIO / Pulsar / Milvus 全部资源，命名空间默认 `default`。
>
> **离线必读顺序**：先 `helm template` 拿到 `milvus_manifest.yaml` → 再回到第 2.3 节用 `save_image.py --manifest milvus_manifest.yaml` 从中提取全部镜像（版本 100% 对齐）→ 再按第 3 节把镜像导入各节点 → 最后 `kubectl apply -f milvus_manifest.yaml`。

**附：standalone（单 Pod）渲染命令**（官方）：

```bash
# 全部 Milvus 组件压进单 Pod，etcd 1 副本、MinIO standalone、关 Pulsar
helm template demo-release zilliztech/milvus \
  --set image.all.tag=v2.6.19 \
  --set cluster.enabled=false \
  --set etcd.replicaCount=1 \
  --set minio.mode=standalone \
  --set pulsarv3.enabled=false \
  > milvus_manifest_standalone.yaml
```

### 4.3 values.yaml 关键配置（鉴权 + Attu）

默认部署**不启用安全认证**（任何人可读写），生产不符合要求。建 `values.yaml`：

```yaml
extraConfigFiles:
  user.yaml: |+
    common:
      security:
        authorizationEnabled: true
attu:
  enabled: true
```

- `authorizationEnabled: true`：开启 Milvus 认证，默认账号 `root` / 密码 `Milvus`，**部署后务必立即改密**。
- `attu.enabled: true`：一并部署 Attu 可视化管理台（需 `zilliz/attu` 镜像，记得纳入离线镜像清单）。

> **Attu 还是内置 WebUI？** Milvus 新版（2.4+）已内置 **Milvus WebUI**，端口 `9091`，无需额外部署即可通过 `kubectl port-forward service/<release>-milvus 27018:9091` 访问（`http://localhost:27018/webui/`）。所以 **Attu 已非必需**——小集群/内网用内置 WebUI 更轻；想要更全的管理能力再开 `attu.enabled: true`。两者任选其一，不要都开以免端口/资源冲突。

> 若只需快速 PoC 不想开鉴权，可省略 `extraConfigFiles` 段；但**生产务必开启**。

### 4.4 镜像地址替换为私有仓库（用 Harbor 时）

若第 2.4 节已把镜像推到 Harbor，部署前把 manifest 里的原地址整体替换：

```bash
sed -i 's#apachepulsar/pulsar:3.0.7#harbor.milvus.local/apachepulsar/pulsar:3.0.7#g' milvus_manifest.yaml
sed -i 's#milvusdb/milvus:v2.6.19#harbor.milvus.local/milvusdb/milvus:v2.6.19#g' milvus_manifest.yaml
sed -i 's#docker.io/milvusdb/etcd:3.5.25-r1#harbor.milvus.local/docker.io/milvusdb/etcd:3.5.25-r1#g' milvus_manifest.yaml
sed -i 's#minio/minio:RELEASE.2024-12-18T13-15-44Z#harbor.milvus.local/minio/minio:RELEASE.2024-12-18T13-15-44Z#g' milvus_manifest.yaml
sed -i 's#zilliz/attu:v2.5.3#harbor.milvus.local/zilliz/attu:v2.5.3#g' milvus_manifest.yaml
```

> 若走**逐节点 `ctr import`**（第 3 节），镜像地址**不用改**，原 tag 已在各节点本地，直接 apply 即可。

### 4.5 部署

```bash
kubectl apply -f milvus_manifest.yaml

# 看 Pod（除一次性 init 任务外应全部 Running；2.5+ 会看到 milvus-mixcoord-0）
kubectl get pods -n default
```

### 4.6 外部访问：NodePort 暴露 Milvus / Attu

离线内网用 **NodePort** 最省事。建两个 svc：

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
      protocol: TCP
      port: 19530
      targetPort: 19530
      nodePort: 31800
  selector:
    app.kubernetes.io/instance: demo-release
    app.kubernetes.io/name: milvus
    component: proxy
  type: NodePort
---
# demo-release-milvus-attu-external-svc.yaml
kind: Service
apiVersion: v1
metadata:
  name: demo-release-milvus-attu-external-svc
  namespace: default
spec:
  ports:
    - name: attu
      protocol: TCP
      port: 3000
      targetPort: 3000
      nodePort: 31801
  selector:
    app.kubernetes.io/instance: demo-release
    app.kubernetes.io/name: milvus
    component: attu
  type: NodePort
```

```bash
kubectl apply -f demo-release-milvus-external-svc.yaml
kubectl apply -f demo-release-milvus-attu-external-svc.yaml
```

> 浏览器访问 `http://<任意节点IP>:31801` 即 Attu；应用连 `<任意节点IP>:31800`。需要更细访问控制再上 Ingress。
> 选择器 `app.kubernetes.io/instance: demo-release` 必须与 `helm template` 的 release 名一致。

### 4.7 登录 Attu（默认账号，务必改密）

打开 `http://<节点IP>:31801`，勾选「认证」，输入默认账号 `root` / `Milvus` 连接。**登录后立即修改默认密码**：

```python
from pymilvus import utility
utility.reset_password("root", "Milvus", "你的新强密码")
```

### 4.8 连通性验证（端口转发法，替代 NodePort）

```bash
kubectl port-forward --address 0.0.0.0 service/demo-release-milvus 27017:19530 -n default &
# 用 pymilvus 连 127.0.0.1:27017 建集合/插向量/搜向量
```

---

## 5. 路线 B：Operator 离线部署（对应 milvus_deploy.yaml）

> 适合想用 `MilvusCluster` CR 长期管理 Milvus 的场景。镜像清单见 2.1（额外需 `milvusdb/milvus-operator:v1.3.7`）。

### 5.1 安装 Milvus Operator

你手上已有一份静态安装清单 `milvus_deploy.yaml`（含 CRD + RBAC + 控制器 Deployment）。**直接 apply 即可，无需 helm、无需 tgz**：

```bash
kubectl apply -f milvus_deploy.yaml
kubectl get pods -n milvus-operator -w   # 等 Operator Running
```

> 备选（若更想用 helm）：`helm install milvus-operator -n milvus-operator --create-namespace --wait --wait-for-jobs ./milvus-operator-1.3.7.tgz`（tgz 需提前在有网机下好）。

安装后 Operator 会注册 `MilvusCluster` CRD。验证字段（写 CR 前对照一下，避免版本差异）：

```bash
kubectl explain milvuscluster.spec.dependencies.etcd.inCluster.values
kubectl explain milvuscluster.spec.dependencies.storage.inCluster.values
```

### 5.2 预创建命名空间

```bash
kubectl create namespace milvus
```

### 5.3 编写 MilvusCluster CR（副本压缩版）

保存为 `milvus-cluster.yaml`。要点：`mode: cluster`、`components.image` 锁死导入版本、`imagePullPolicy: IfNotPresent`、依赖全压缩到 1 副本、PVC 走默认 StorageClass。

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
    proxy:
      replicas: 1
    rootCoord:
      replicas: 1
    indexCoord:
      replicas: 1
    queryCoord:
      replicas: 1
    dataCoord:
      replicas: 1
    indexNode:
      replicas: 1
    queryNode:
      replicas: 1
    dataNode:
      replicas: 1

  dependencies:
    etcd:
      inCluster:
        values:
          replicaCount: 1
          resources:
            requests: { cpu: 200m, memory: 512Mi }
            limits:   { cpu: "1", memory: 1Gi }
    storage:
      type: MinIO
      inCluster:
        deletionPolicy: Retain
        values:
          statefulset:
            replicaCount: 1
          resources:
            requests: { cpu: 200m, memory: 512Mi }
            limits:   { cpu: "1", memory: 2Gi }
    pulsar:
      inCluster:
        values:
          zookeeper:
            replicaCount: 1
          bookkeeper:
            replicaCount: 1
            resources:
              requests: { cpu: 200m, memory: 512Mi }
              limits:   { cpu: "1", memory: 1Gi }
          broker:
            replicaCount: 1
            configData:
              autoSkipNonRecoverableData: "true"
              managedLedgerDefaultEnsembleSize: "1"
              managedLedgerDefaultWriteQuorum: "1"
              managedLedgerDefaultAckQuorum: "1"
          proxy:
            replicaCount: 1

  config: {}
```

> **副本数：PoC 压缩 vs 真实 HA**。上面 etcd/MinIO/Pulsar 全压成 1 副本，仅为 3 节点 PoC 能跑。你真实 Helm 渲染清单里是 **etcd 3（Raft 容忍 1）、MinIO 4（4-drive set 容忍 2）、Pulsar zk3/bookie3/broker2/proxy2**。生产/预生产请至少 etcd→3、MinIO→4，并参阅第 6 节理解 local-path 无复制、节点故障、单 pool 等硬约束。Operator 走 subchart 部署 MinIO，**同样是单 pool**，drive 数（replicaCount）创建后不可在线改，扩容只能加新 pool 或重建。

### 5.4 部署与验证

```bash
kubectl apply -f milvus-cluster.yaml
kubectl get milvus -n milvus -w          # status 变 Healthy 即就绪
kubectl get pods -n milvus
```

就绪后预期（副本压缩）：`milvus-etcd-0` / `milvus-minio-0` / `milvus-pulsar-*` / `milvus-milvus-proxy-*` / `milvus-milvus-rootcoord-*` / `milvus-milvus-datanode-*` / `milvus-milvus-querynode-*` / `milvus-milvus-indexnode-*` 全部 Running。

> 想启 Attu：Operator 路线需在 CR 或额外部署 Attu（可参考 Helm 路线 4.3 的 attu 镜像与 4.6 的 NodePort svc 写法）。

---

## 6. MinIO 扩容操作说明

MinIO 的"扩容"有两种完全不同的含义：

### 6.1 两种扩容方式对比

| 方式 | 做法 | 改的是什么 | 数据影响 | 推荐度 |
|------|------|-----------|---------|--------|
| **垂直扩容** | 扩大每块盘的容量（PVC size） | 单盘容量，drive 数不变 | 无，原地扩 | ⭐ 首选 |
| **横向扩容** | 增加 drive 总数（加新 erasure pool） | 加实例/盘，形成新 set | 老数据留原 pool，不迁移 | 容量不够时再上 |

> ⚠️ **核心认知**：横向扩容加的是**容量**，不是**容错**。想提高单 pool 容错（如容忍 4 个），必须**初始部署**就用更大的 erasure set（8 drive），后期无法在线升 4→8 drive set。

### 6.2 垂直扩容（扩单盘容量）

前提：底层 StorageClass 支持卷扩容（`allowVolumeExpansion: true`）。**local-path 默认不支持**，OpenEBS LocalPV / Rook-Ceph 通常支持。

```bash
kubectl get sc local-path -o jsonpath='{.allowVolumeExpansion}'   # 输出 true 才行
# Helm 路线：kubectl edit pvc <release>-minio-0 -n default，改 storage 大小
# Operator 路线：kubectl edit milvuscluster milvus -n milvus，改 storage.inCluster.values.persistence.size
kubectl rollout restart statefulset/<release>-minio -n <ns>   # 未自动识别新容量时重启
```

### 6.3 横向扩容（加 drive / 新 erasure pool）

MinIO 不能在线给已有 erasure set 加 drive。扩容 = **加一组新 drive 形成新 erasure set（Server Pool）**。

- **Helm 路线**：chart 只渲染单 pool，`helm template` 只支持一个 `{0...N}` 区间。要把 4 drive 扩成 8，需改 `minio.replicas` 并**新建第二个 MinIO StatefulSet（pool2）**，两个 pool 用空格分隔写进启动命令（pool1 端点必须与旧 `format.json` 完全一致，否则数据不可读）。或干脆停掉 chart 的 MinIO、改用**外部自建多 pool MinIO**（`external` 模式），扩容更自由。
- **Operator 路线**：改 CR `storage.inCluster.values.statefulset.replicaCount` 4→8，但同样受单 pool 限制，旧数据需清后重建；想无损扩请改用 `spec.dependencies.storage.external: true` 指向外部多 pool MinIO。

**约束**：MinIO 不支持缩容、不支持在线改单 set drive 数；erasure set 大小 4~16 偶数；集群内所有 server 的 drive 数需一致。

---

## 7. 常见问题排查（离线专属）

### 7.1 Pod ImagePullBackOff（离线最常见）
- 根因：镜像没导入、或 tag 前缀不对。
- 修复：反查实际缺的镜像 → 有网机补拉（retag 回原 tag）→ `docker save` → 拷到**对应节点** `ctr -n k8s.io images import` → 删失败 Pod 重建。
  ```bash
  kubectl get pods -n milvus -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u
  ```

### 7.2 PVC 一直 Pending
- 根因：StorageClass 不对 / 默认 SC 没设 / local-path 在当前节点没就绪。
- 修复：`kubectl describe pvc` 看 event；确认 `kubectl get sc` 有带 `(default)` 的本地 SC。

### 7.3 节点内存不足 / OOMKilled
- 3 节点小集群跑全套 Milvus 很吃内存（尤其 queryNode / dataNode）。
- 修复：给计算组件加 `resources.requests/limits`；或把 dataNode/queryNode 调度到不同节点（节点亲和性）。

### 7.4 Pulsar 起不来 / bookkeeper 反复重启
- 压缩到单副本后，bookkeeper 无持久化会丢数据，已用 `autoSkipNonRecoverableData: "true"` + quorum=1 规避。
- 若仍崩，看日志 `kubectl logs -n milvus <release>-pulsar-bookie-0`，多数情况是镜像版本不对（回 2.1 反查）。

### 7.5 etcd / MinIO 数据丢失风险（重要）
- **local-path 是单节点本地盘、无副本**。节点宕机 = 该盘数据没了。
- PoC 可接受；正式环境改用有 replication 的存储（Rook-Ceph / Longhorn），或把 `storage` 改为**外部对象存储**（Helm：`external` 段；Operator：`spec.dependencies.storage.external: true` 指向已有 S3 / MinIO / OSS），etcd 也可指向外部 etcd 集群。详见 [longhorn-offline-deploy.md](./longhorn-offline-deploy.md)。

---

## 8. 卸载

> 卸载方式取决于你**当初怎么装的**：
> - 本文 Helm 路线用的是 `helm template ... > milvus_manifest.yaml` + `kubectl apply`（静态清单，**Helm 并未跟踪 release**）→ 用 `kubectl delete -f`。
> - 若你当初是直接 `helm install`（而非渲染成静态文件）→ 用 `helm uninstall`。

**Helm 路线（本文方式，静态清单）**：
```bash
kubectl delete -f demo-release-milvus-external-svc.yaml   # 先删外部 svc
kubectl delete -f milvus_manifest.yaml
```

**若当初是 `helm install` 安装的（官方在线/离线皆可）**：
```bash
helm uninstall demo-release            # 删除 release 及 chart 渲染的所有资源
# 升级命令（官方）：helm upgrade demo-release zilliztech/milvus --reset-then-reuse-values
```

**Operator 路线**：
```bash
kubectl delete milvus milvus -n milvus        # 只删 Milvus（依赖默认保留）
kubectl delete -f milvus-cluster.yaml         # 连依赖一起删（谨慎，会丢数据）
```

---

## 9. 生产部署建议（从官方教程提炼）

- **务必开启鉴权**：默认无认证任何人可读写，生产必须 `authorizationEnabled: true`（见 4.3），并立即改默认密码 `root/Milvus`。
- **存储上 SSD**：向量查询对磁盘延迟敏感，机械盘会卡顿，etcd/MinIO 尽量用 SSD。
- **资源预留 30% 冗余**：整体 CPU/内存预留约三成，应对突发流量。
- **外部访问优先 NodePort，再考虑 Ingress**：内网复杂环境 NodePort 最省事，需细粒度访问控制再上 Ingress。
- **规模大就建私有仓库**：≥6 节点建议内网自建 Harbor，统一分发镜像，避免逐机导包。
- **可用性 vs 复杂度**：团队已熟悉 K8s、需多环境切换部署 → Helm 最合适（改 values 即可）；想用 CR 精细管理 Milvus 生命周期 → Operator。
- **数据 durability**：3 节点 PoC 可压缩副本；真正生产至少 etcd→3、MinIO→4，并给 etcd/MinIO 配带 replication 的存储或外部对象存储。

---

## 10. 附录：文件清单 + 镜像清单

**有网机产出（拷到离线环境）**：
```
milvus_manifest.yaml          # 路线 A：helm template 渲染产物（demo-release）
milvus_deploy.yaml            # 路线 B：Operator 安装清单
milvus-cluster.yaml           # 路线 B：MilvusCluster CR
values.yaml                   # 路线 A：helm 自定义值（鉴权+Attu）
demo-release-*-external-svc.yaml  # 路线 A：NodePort 外部访问
milvus-offline-images.tar(.gz)    # 离线镜像（手法一 save / 手法二 images/）
```

**离线镜像清单（v2.6.19 基线，实际以 2.1 反查为准）**：
```
milvusdb/milvus:v2.6.19
docker.io/milvusdb/etcd:3.5.25-r1
minio/minio:RELEASE.2024-12-18T13-15-44Z
minio/mc:RELEASE.2024-12-18T13-15-44Z
apachepulsar/pulsar:3.0.7
zilliz/attu:v2.5.3
busybox:1.36
# Operator 路线额外需要：
milvusdb/milvus-operator:v1.3.7
```

---

### 与配套文档的关系
- 镜像 retag / `ctr -n k8s.io import` 套路：见 [k8s-offline-manual-deploy.md](./k8s-offline-manual-deploy.md) 第 2、4 节。
- 本地存储 local-path / OpenEBS / Longhorn 部署：见配套文档第 7 节 及 [longhorn-offline-deploy.md](./longhorn-offline-deploy.md)。
- CoreDNS / 网络就绪：见配套文档第 4.6.1、9 节。
