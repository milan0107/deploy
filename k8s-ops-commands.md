# Kubernetes 排障与运维常用命令手册

> 适用场景：日常运维、定位 Pod 起不来、PVC 绑不上、节点 NotReady、资源卡 Terminating 等。
> 约定：`<ns>` = 命名空间（如 `default`）；`<name>` = 资源名；`<label>` = 标签（如 `app=milvus`）。
> 环境：1 master + 2 worker（openEuler 24、containerd），离线 + Longhorn 存储。命令在 Windows Git Bash 下均可用。

---

## 0. 总览思路：排障先看哪几层

遇到"东西不对"，按这个顺序由外到内查，能最快定位：

```
集群/节点层  →  工作负载层(Deploy/STS)  →  Pod 层  →  存储/PVC 层  →  日志/事件
```

对应命令先看：`get nodes` → `get deploy/sts` → `get pods` → `get pvc/pv` → `logs` / `describe`。

---

## 1. 集群与节点

### 1.1 看集群整体状态
```bash
kubectl cluster-info
```
**做什么**：打印控制平面（apiserver、controller-manager、scheduler）和各插件的访问地址，确认集群基本可用。

### 1.2 看所有节点状态
```bash
kubectl get nodes -o wide
```
**做什么**：列出节点名称、状态（Ready/NotReady）、角色（master/worker）、版本、内部 IP、容器运行时。节点 NotReady 时整节点 Pod 都受影响。

### 1.3 看节点详细信息（排查 NotReady / 污点 / 资源）
```bash
kubectl describe node <node名>
```
**做什么**：输出该节点的容量、可分配资源、已分配情况、污点（Taints）、Conditions（DiskPressure/MemoryPressure/Ready）、Events。
- `Taints:` 有 `NoSchedule` → 普通 Pod 调度不进来（master 默认有）。
- `Conditions` 里 `DiskPressure=True` → 磁盘压力，节点被标记为不可调度新 Pod。

### 1.4 看节点资源占用
```bash
kubectl top nodes
kubectl top pods -n <ns> --sort-by=memory
```
**做什么**：实时看节点/ Pod 的 CPU、内存占用（需 metrics-server 已装）。定位"谁把节点吃满了"导致别的 Pod 排不进。

### 1.5 给节点打/去污点（让 master 也能跑 Pod）
```bash
kubectl taint nodes <node名> node-role.kubernetes.io/control-plane:NoSchedule-
# 加回污点：把末尾的 - 去掉
kubectl taint nodes <node名> node-role.kubernetes.io/control-plane:NoSchedule
```
**做什么**：`-` 结尾 = 删除该污点。实验环境想让 master 也参与调度时去掉；生产别动。

### 1.6 封锁/恢复节点调度（维护用）
```bash
kubectl cordon <node名>     # 标记不可调度（已有 Pod 继续跑）
kubectl uncordon <node名>   # 恢复可调度
```
**做什么**：`cordon` 让节点不再接收新 Pod（维护前用），`uncordon` 恢复。注意：Longhorn 的节点 Unschedulable 是 Longhorn 自己管理的，和这个 kubectl cordon 不是一回事。

---

## 2. Pod 排障（最高频）

### 2.1 看 Pod 列表与状态
```bash
kubectl -n <ns> get pods -o wide
```
**做什么**：列出 Pod 名、就绪状态（如 `1/1`）、状态（Running/Pending/CrashLoopBackOff/Error/Terminating）、重启次数、所在节点、Pod IP。
- `Pending` → 调度不进（资源不够/污点/节点不可调度/ PVC 没绑）。
- `CrashLoopBackOff` → 容器反复崩溃（配置/依赖/存储错误）。
- `Terminating` → 正在删但卡住（通常是 finalizer，见第 8 节）。

### 2.2 看 Pod 详情与事件（Pending/CrashLoop 第一手原因）
```bash
kubectl -n <ns> describe pod <pod名>
```
**做什么**：输出容器镜像、命令、环境变量、挂载卷、 readiness/liveness 探针、以及最关键的 **Events**（调度失败原因、镜像拉取失败、挂载失败等）。
- 末尾 `Events:` 里 `FailedScheduling ... Insufficient cpu/memory` → 资源不够。
- `FailedMount ... timeout` → PVC 没绑或存储后端问题。
- `ImagePullBackOff` / `ErrImagePull` → 镜像没导入（离线环境常见）。

### 2.3 看当前容器日志
```bash
kubectl -n <ns> logs <pod名> --tail=100
```
**做什么**：打印容器最近 100 行日志，定位应用层报错。

### 2.4 看上一次崩溃的日志（CrashLoopBackOff 必看）
```bash
kubectl -n <ns> logs <pod名> --previous --tail=100
```
**做什么**：`--previous` 看容器**上一次启动**的日志。CrashLoop 时当前容器已退出，只有 `--previous` 才能看到崩溃原因（如 Milvus 的 `unknown server type`、`input/output error`）。

### 2.5 多容器 Pod 指定容器
```bash
kubectl -n <ns> logs <pod名> -c <容器名> --previous
```
**做什么**：Pod 里有多个容器时（如 initContainer + 主容器），用 `-c` 指定看哪个容器的日志。

### 2.6 进容器排障（最后手段）
```bash
kubectl -n <ns> exec -it <pod名> -- sh
# 容器没 sh 时：
kubectl -n <ns> exec -it <pod名> -- bash
```
**做什么**：进到运行中的容器里手动排查（看文件、env、网络连通性）。容器已崩溃则进不去，改用 `--previous` 看日志。

### 2.7 删 Pod 触发重建
```bash
kubectl -n <ns> delete pod <pod名> --force --grace-period=0
```
**做什么**：强制删除 Pod（Deployment/StatefulSet 会立即重建一个）。常用于：配置改了想让它重读、或卡在坏状态。注意 StatefulSet 的 PVC 不会被删（除非手动删 PVC）。

---

## 3. 工作负载：Deploy / StatefulSet / DaemonSet

### 3.1 看工作负载状态
```bash
kubectl -n <ns> get deploy,sts,ds -o wide
```
**做什么**：列出 Deployment / StatefulSet / DaemonSet 的就绪副本数、镜像、年龄。READY 不是 `N/N` 说明 Pod 没起来。

### 3.2 看工作负载详情（滚动失败/镜像/探针）
```bash
kubectl -n <ns> describe deploy <deploy名>
```
**做什么**：输出 Deploy 的副本、滚动更新状态、挂载卷、以及 Events（镜像拉取失败、副本起不来等）。

### 3.3 扩缩容（独立扩缩练习）
```bash
kubectl -n <ns> scale deploy <deploy名> --replicas=2
kubectl -n <ns> scale statefulset <sts名> --replicas=2
```
**做什么**：手动改副本数。`--replicas=0` 可临时停掉一套组件；调大就是在练"独立扩缩"。

### 3.4 重启工作负载（让配置生效）
```bash
kubectl -n <ns> rollout restart deploy <deploy名>
kubectl -n <ns> rollout restart daemonset <ds名>
```
**做什么**：触发一次滚动重启（逐个新建 Pod 替换旧的），让改过的环境变量/配置映射生效，不动底层存储。

### 3.5 看滚动更新状态/历史
```bash
kubectl -n <ns> rollout status deploy <deploy名>
kubectl -n <ns> rollout history deploy <deploy名>
kubectl -n <ns> rollout undo deploy <deploy名>        # 回滚到上一版
```
**做什么**：`status` 等滚动完成；`history` 看版本；`undo` 回滚（配置改错时救命）。

---

## 4. Service 与网络

### 4.1 看 Service
```bash
kubectl -n <ns> get svc -o wide
```
**做什么**：列出 Service 的 TYPE（ClusterIP/NodePort/LoadBalancer）、ClusterIP、端口映射（`PORT(S)` 列 `容器端口:对外端口`）。
- `ClusterIP` → 仅集群内访问。
- `NodePort` → 集群外可用 `<任意节点IP>:<节点端口>` 访问（端口范围 30000–32767）。

### 4.2 改 Service 类型为 NodePort
```bash
kubectl -n <ns> patch svc <svc名> -p '{"spec":{"type":"NodePort"}}'
# 或固定端口：
kubectl -n <ns> patch svc <svc名> -p '{"spec":{"type":"NodePort","ports":[{"port":19530,"nodePort":31030}]}}'
```
**做什么**：把 Service 从 ClusterIP 改成 NodePort，让集群外能直连（如 Milvus 客户端连 `节点IP:31030`）。`nodePort` 必须在 30000–32767 且未被占用。

### 4.3 临时暴露端口（本地调试）
```bash
kubectl -n <ns> port-forward svc/<svc名> 8080:19530
```
**做什么**：把集群内 Service 端口映射到**你本机** 8080，浏览器/客户端访问 `localhost:8080` 即可调试，无需改 Service 类型。

### 4.4 看 Service 背后端点（排查连不上）
```bash
kubectl -n <ns> get endpoints <svc名>
```
**做什么**：Endpoints 为空 = Service 没选中任何 Pod（标签不匹配）→ 请求转不出去。这是"Service 建了但连不上"的第一排查点。

---

## 5. 存储排障（PVC / PV）

### 5.1 看 PVC 与 PV
```bash
kubectl -n <ns> get pvc
kubectl get pv
```
**做什么**：`get pvc` 看申请状态（Bound=已绑 / Pending=绑不上 / Terminating=卡删）。
`get pv` 看物理卷（Bound/Available/Released/Terminating）。PVC 一直 Pending 多半是存储后端（Longhorn）没给建出卷。

### 5.2 看 PVC 详情（绑不上原因）
```bash
kubectl -n <ns> describe pvc <pvc名>
```
**做什么**：Events 里会写为什么绑不上（StorageClass 不存在、provisioner 报错、节点不可调度等）。

### 5.3 看 PVC 绑到了哪个 PV
```bash
kubectl -n <ns> get pvc <pvc名> -o wide
kubectl get pv -o wide | grep <关键字>
```
**做什么**：`get pvc -o wide` 的 `VOLUME` 列就是绑定的 PV 名；据此能反查底层存储卷。

### 5.4 删 PVC（级联清 PV）
```bash
kubectl -n <ns> delete pvc <pvc名> --force --grace-period=0 --wait=false
```
**做什么**：删 PVC。若 PV 的 `reclaimPolicy=Delete`（动态供给默认），PV 和底层存储卷会跟着删。带 `--wait=false` 防止终端卡住。`--force --grace-period=0` 强制立即删。

### 5.5 PVC/PV 卡 Terminating → 清 finalizer
```bash
# 清空 PVC 的 finalizer（PVC 才能真删掉）
kubectl -n <ns> patch pvc <pvc名> --type=merge -p '{"metadata":{"finalizers":[]}}'
# 清空 PV 的 finalizer
kubectl patch pv <pv名> --type=merge -p '{"metadata":{"finalizers":[]}}'
# 然后再删
kubectl -n <ns> delete pvc <pvc名> --force --grace-period=0 --wait=false
```
**做什么**：PVC/PV 卡在 Terminating 通常是 finalizer（pv-protection / pvc-protection）没清掉。先 `patch` 把 finalizer 设空数组，再删。这是存储清理的"万能解"。

### 5.6 批量清所有 PVC/PV 的 finalizer
```bash
for p in $(kubectl -n <ns> get pvc -o jsonpath='{.items[*].metadata.name}'); do
  kubectl -n <ns> patch pvc $p --type=merge -p '{"metadata":{"finalizers":[]}}'
done
for v in $(kubectl get pv -o jsonpath='{.items[*].metadata.name}'); do
  kubectl patch pv $v --type=merge -p '{"metadata":{"finalizers":[]}}'
done
```
**做什么**：一次性给命名空间下所有 PVC、集群所有 PV 清空 finalizer，配合第 8 节做全量清理。**注意 Git Bash 下 `for`/jsonpath 偶尔抽风，抽风就逐条手动跑。**

---

## 6. 事件与全局排障

### 6.1 看命名空间全部事件（按时间）
```bash
kubectl -n <ns> get events --sort-by='.lastTimestamp'
```
**做什么**：列出该命名空间最近发生的所有事件（调度失败、拉镜像失败、探针失败、驱逐等），`--sort-by` 让最新的排最后，顺着看就能找到起点。

### 6.2 看全局 Warning 级事件
```bash
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp'
```
**做什么**：跨命名空间只看 Warning（真实出问题才报），快速扫全局有没有异常。

### 6.3 看所有资源（确认清干净没）
```bash
kubectl -n <ns> get all
```
**做什么**：列出该命名空间下 pod/svc/deploy/sts/ds/cronjob 等，确认清理后是否还有残留。

### 6.4 按标签筛选
```bash
kubectl -n <ns> get pods -l app.kubernetes.io/instance=<release名>
kubectl -n <ns> get all -l app.kubernetes.io/instance=<release名>
```
**做什么**：Helm 装的 Release 都带 `app.kubernetes.io/instance=<release>` 标签，用它一把筛出整套组件、或一把删（`delete all -l ...`，见 8.2）。

---

## 7. 配置与密钥

### 7.1 看 ConfigMap / Secret
```bash
kubectl -n <ns> get cm
kubectl -n <ns> get secret
kubectl -n <ns> describe cm <cm名>
```
**做什么**：列出配置映射/密钥。改了 Milvus 的配置后 `describe cm` 确认内容生效。

### 7.2 直接看 ConfigMap 内容
```bash
kubectl -n <ns> get cm <cm名> -o yaml
```
**做什么**：把 ConfigMap 的完整 yaml（含 data 字段）打出来，确认配置写对了。

### 7.3 临时改配置（热改）
```bash
kubectl -n <ns> edit cm <cm名>
```
**做什么**：在线编辑 ConfigMap，改完需 `rollout restart` 对应工作负载才生效。

---

## 8. 资源卡住 / 全量清理（运维救命章）

### 8.1 资源卡 Terminating（通用解法）
资源删不掉、状态一直是 Terminating，九成是 finalizer 或 admission-webhook 在拦。顺序：
```bash
# 1) 清 finalizer
kubectl -n <ns> patch <资源类型> <名> --type=merge -p '{"metadata":{"finalizers":[]}}'
# 2) 强删
kubectl -n <ns> delete <资源类型> <名> --force --grace-period=0 --wait=false
# 3) 若还卡，临时卸 Longhorn admission-webhook（存储类资源常见）
kubectl delete validatingwebhookconfiguration longhorn-admission-webhook
kubectl delete mutatingwebhookconfiguration longhorn-admission-webhook
#    清完再重建 webhook：
kubectl -n longhorn-system rollout restart deployment/longhorn-admission-webhook
```
**做什么**：finalizer 是资源删除前的"拦截钩子"，webhook 会反复加回 finalizer 导致永远 Terminating。先撤钩子、再强删，最后把 webhook 拉回来（否则以后正常建卷会被拦）。

### 8.2 按 Release 标签一把清（重装前清理）
```bash
kubectl -n <ns> delete all -l "app.kubernetes.io/instance=<release名>" --force --grace-period=0 --wait=false
```
**做什么**：删掉某 Release 的所有 pod/svc/deploy/sts/ds（不删 PVC/PV/CM/Secret，需另清）。重装 Milvus 前清一套旧实例用这个最快。

### 8.3 全量清 PVC/PV（确认数据可丢时）
```bash
kubectl -n <ns> delete pvc --all --force --grace-period=0 --wait=false
kubectl delete pv --all --force --grace-period=0 --wait=false
```
**做什么**：清空命名空间所有 PVC 和集群所有 PV。⚠️ **数据全没**，只在测试环境、确认可丢时用。

---

## 9. 离线镜像相关（containerd）

### 9.1 导入镜像到 k8s 运行时
```bash
ctr -n k8s.io images import <镜像文件>.tar
```
**做什么**：把离线导出的镜像 tar 导入 containerd 的 `k8s.io` 命名空间（kubelet 只认这个命名空间）。注意 `-n k8s.io` 不能省，否则 Pod 仍拉不到。

### 9.2 看已导入镜像
```bash
ctr -n k8s.io images ls | grep <关键字>
```
**做什么**：确认镜像是否已导入、tag 对不对（离线 ImagePullBackOff 多半是 tag 不对或没导入）。

---

## 10. 速查表（按症状找命令）

| 症状 | 先跑哪条 |
|------|----------|
| 节点 NotReady | `kubectl describe node <节点>` 看 Conditions/Events |
| Pod Pending | `kubectl -n <ns> describe pod <pod>` 看 Events 的 FailedScheduling |
| Pod CrashLoopBackOff | `kubectl -n <ns> logs <pod> --previous` 看上次崩溃日志 |
| 容器起不来/配置错 | `kubectl -n <ns> logs <pod> --previous` + `describe` |
| PVC 一直 Pending | `kubectl -n <ns> describe pvc <pvc>` + `kubectl -n longhorn-system get lhv` |
| 资源卡 Terminating | 清 finalizer（8.1）→ 强删 → 卸 webhook |
| 节点不可调度新 Pod | `kubectl describe node` 看 DiskPressure/Taints；Longhorn 节点看 `kubectl -n longhorn-system get lhn` |
| Service 连不上 | `kubectl -n <ns> get endpoints <svc>` 看是否为空 |
| 集群外要访问 | `patch svc type=NodePort` 或 `port-forward` 本地调试 |
| 镜像拉不到（离线） | `ctr -n k8s.io images ls \| grep <镜像>` 确认是否导入 |

---

## 11. 排障黄金三步（记牢）

1. **describe 看 Events** —— 90% 的调度/挂载/镜像问题，Events 直接给原因。
2. **logs --previous 看崩溃日志** —— CrashLoop 只有 `--previous` 看得到真因。
3. **get <资源> -o wide 看绑定关系** —— PVC↔PV↔Longhorn 卷，一层层往下追。

> 经验：排障前先确认"是什么机制部署的"（Helm / Operator CR / 原生 yaml），命令体系完全不同；先 `get pods -o wide` 看到底有哪些资源、状态如何，再决定下一步，别一上来就删。
