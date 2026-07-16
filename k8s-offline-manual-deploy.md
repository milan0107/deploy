# 手动离线安装 Kubernetes（预下载镜像 + kubeadm）

> 适用场景：无法访问公网 / 公网镜像仓库的内网、隔离环境。
> 方式：**不使用 sealos / k3s 等第三方工具**，仅用 Kubernetes 官方安装器 `kubeadm`；
> 先在**有网机器**把镜像和安装包下载好，再拷进内网逐节点安装。
> 目标拓扑：**1 个 master + 2 个 worker**（可类推扩展到多 master / 多 worker）。
> 操作系统：**麒麟 / 统信 UOS / openEuler**（rpm + systemd 系，本文命令以 rpm 系为准）。
> 版本：**Kubernetes v1.32.x**（dnf 提供该线最新补丁，本文实测为 **v1.32.13**），CNI 使用 **Calico v3.28.1**（Flannel 备选）。镜像版本以 `kubeadm config images list` 实际输出为准，不要硬编码。

---

## 目录

0. 核心思路（不看会迷路）
1. 环境与前置要求
2. 阶段一：有网机器下载（rpm 包 / 镜像 / 依赖）
3. 阶段二：传输到内网
4. 阶段三：各节点安装（系统依赖 → 运行时 → kubeadm → 镜像导入 → init/join）
5. 验证集群
6. 常用运维操作
7. 持久化存储（Local PV 本地存储）
8. 国产系统注意事项
9. 常见问题排查
10. 附录：完整文件清单 + 镜像清单
11. 快速执行检查清单（照着打勾）

---

## 0. 核心思路（不看会迷路）

离线装 K8s，本质是把三样东西提前在有网机器准备好，拷进内网后安装：

```
有网机器（能上公网）                    内网节点（隔离）
─────────────────────                  ─────────────────
① rpm 包                             ┌─ master(192.168.0.10)
   kubelet/kubeadm/kubectl  ──┐        │    装 rpm + 导入镜像
   containerd + runc + cni    ├── 拷贝 ├─ worker1(192.168.0.11)
   系统依赖 rpm(socat等)      ──┘  U盘/ ├─ worker2(192.168.0.12)
② 容器镜像 tar（控制面+CNI）  ────── scp └─ 各节点 ctr import 镜像
                                    │
                                    ▼
                          kubeadm init(master) + join(workers)
                                     │
                                     ▼
                          K8s 集群 (1 master + 2 worker)
```

三类产物：
1. **rpm 包**：kubelet、kubeadm、kubectl、kubernetes-cni、containerd、containernetworking-plugins 等 rpm（全链路 rpm 安装，无二进制）。
2. **容器镜像**：K8s 控制面镜像（kube-apiserver、etcd…）+ CNI 插件镜像（Calico / Flannel），`docker save` 成一个 tar。
3. **系统依赖**：socat、conntrack、ebtables、ipset、device-mapper-persistent-data、lvm2、libseccomp、iptables、ipvsadm 等 rpm（kubeadm 自身依赖通常随 `--resolve` 自动带，containerd 相关需单独拉）。

   > ⚠️ 不要包含 `container-selinux`：它是 RHEL/CentOS 专属包，openEuler 仓库没有，会让 `dnf download --resolve` 因 strict 模式直接中止整批下载。openEuler 下等价的是 `selinux-policy-targeted`，且本文已关闭 SELinux，无需此包。

> 关键点：内网节点**永不访问公网**。所有镜像必须先在外部 `docker pull` 并 `save` 成 tar，内网用 `ctr images import` 导入 containerd。

---

## 1. 环境与前置要求

### 1.1 节点规划（示例）

| 角色 | IP | 规格建议 |
|------|----|----------|
| master（控制面） | 192.168.0.10 | 4C8G 起 |
| worker-1 | 192.168.0.11 | 按业务负载 |
| worker-2 | 192.168.0.12 | 按业务负载 |

> 所有节点 **OS 版本、CPU 架构（amd64 或 arm64）必须一致**。本文示例均为 amd64。

### 1.2 硬件 / 系统要求

- master ≥ 4C8G，worker 视负载；最低 2C4G 可跑通。
- 节点间网络互通，SSH（22 端口）可达（仅部署阶段用）。
- 各节点使用 **root** 或具备 `sudo NOPASSWD` 的账号。
- 节点时间同步（chrony / ntpd）。
- 内核 ≥ 3.10（openEuler / 麒麟 / UOS 默认满足）。

### 1.3 需放通的端口

| 端口 | 协议 | 用途 |
|------|------|------|
| 22 | TCP | SSH（部署用） |
| 6443 | TCP | Kubernetes API Server |
| 2379-2380 | TCP | etcd |
| 10250 | TCP | kubelet |
| 10257 / 10259 | TCP | controller-manager / scheduler |
| 4789 / 8472 | UDP | Calico / Flannel VXLAN Overlay |
| 179 | TCP | Calico BGP（若用 BGP 模式） |
| 30000-32767 | TCP | NodePort 服务（按需） |

> 内网测试环境可直接关闭防火墙；生产环境按上表放通。

### 1.4 系统初始化（所有节点执行）

```bash
# 1) 关闭防火墙（内网环境）
systemctl disable --now firewalld 2>/dev/null
# 若用 nftables/ufw，按实际关闭

# 2) 关闭 swap
swapoff -a && sed -i '/swap/s/^/#/' /etc/fstab

# 3) 关闭 SELinux（部分国产系统默认开启）
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config

# 4) 加载内核模块
cat > /etc/modules-load.d/k8s.conf <<'EOF'
br_netfilter
overlay
EOF
modprobe br_netfilter overlay

# 5) 内核参数
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system

# 6) 时间同步
systemctl enable --now chronyd   # 或 ntpd
chronyc sources                  # 确认已同步

# 7) 确保 bash 为默认 shell（kubeadm 脚本依赖 bash）
bash --version
```

### 1.5 准备 SSH 互信（仅部署阶段需要）

在你要操作的机器上生成密钥并分发到所有节点（含本机）：

```bash
ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa
for ip in 192.168.0.10 192.168.0.11 192.168.0.12; do
  ssh-copy-id root@$ip
done
```

---

## 2. 阶段一：有网机器下载与打包

找一台能联网的机器（笔记本 / 跳板机），建议**与目标的发行版相同**（这样 `dnf download` 出来的 rpm 才兼容）。该机器需已安装 `docker`、`dnf`/`yum` 及 `dnf-plugins-core`。

### 2.1 下载 K8s 组件 rpm（全链路 rpm 安装）

用 `dnf download` 把 K8s 组件拉成 rpm（rpm 安装自带 systemd 单元，无需手动写 unit）：

```bash
# 先添加 Kubernetes 官方 yum 源（el 兼容系，如 openEuler/Anolis 等）
cat > /etc/yum.repos.d/kubernetes.repo <<'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/repodata/repomd.xml.key
EOF

mkdir -p /tmp/k8s-rpms && cd /tmp/k8s-rpms
# 关键：社区 kubernetes 源是多架构仓库，必须加 --archlist 限定本机架构，
# 否则 dnf 会尝试解析 aarch64/ppc64le/s390x 等跨架构包，因缺对应 glibc 依赖而报错：
#   "package kubelet-...aarch64 does not have a compatible architecture"
dnf download --resolve --archlist=$(uname -m) kubelet kubeadm kubectl kubernetes-cni
# kubernetes-cni 提供 CNI 插件（/usr/libexec/cni 下的可执行文件）
# 若个别包系统源已自带（rpm -q 有输出），可跳过；缺失的包 dnf 会一并下载
```

### 2.2 下载容器运行时 rpm（containerd + runc + CNI 插件）

用 `dnf download` 把容器运行时相关包拉成 rpm：

```bash
mkdir -p /tmp/containerd-rpms && cd /tmp/containerd-rpms
# containerd 主包；--resolve 会把 runc 一并拉来（runc 是 containerd 的依赖）
# containernetworking-plugins 提供 CNI 插件（/usr/libexec/cni 下的可执行文件）
dnf download --resolve --archlist=$(uname -m) containerd containernetworking-plugins
# 若 runc 未被自动带上，显式补：dnf download --resolve --archlist=$(uname -m) runc
# 部分国产系统已自带 containerd，可直接用系统版本；否则用上面下载的 rpm
# 验证：rpm -qp --qf '%{NAME} %{VERSION}\n' *.rpm | sort -u
```

### 2.3 下载系统依赖 rpm

```bash
cd /tmp && mkdir -p sys-deps && cd sys-deps
dnf download --resolve --archlist=$(uname -m) socat conntrack-tools ebtables ipset \
  device-mapper-persistent-data lvm2 libseccomp iptables ipvsadm
# 说明：
#   conntrack-tools 提供 conntrack 命令
#   device-mapper-persistent-data / lvm2 为 containerd devicemapper 存储驱动依赖，离线环境必带
#   libseccomp 为 runc/containerd 硬依赖，缺则 containerd 起不来（极易漏）
#   iptables(kube-proxy iptables 模式必用) / ipvsadm(kube-proxy ipvs 模式推荐)
#   ⚠️ 不要加 container-selinux：该包是 RHEL/CentOS 专属，openEuler 仓库无此包，
#      dnf download --resolve 的 strict 模式会因它找不到而直接中止整个下载。
#      openEuler 的等价物是 selinux-policy-targeted（且我们已 SELINUX=disabled，根本不需要）。
#   注意：kubelet/kubeadm 的依赖（socat conntrack ebtables ipset cri-tools 等）已被 --resolve 自动拉取
#   若系统已自带这些包（rpm -q socat conntrack-tools libseccomp 有输出），可跳过
#   验证所有包都已就位：rpm -qp --qf '%{NAME} %{ARCH}\n' *.rpm | sort -u
```

> 若目标机有 OS 安装 ISO，也可把 ISO 挂成本地仓库来装这些基础包，彻底不依赖外网下载。

### 2.4 下载并打包容器镜像（核心步骤）

> **前置须知**：
> - 本机需装 docker，且**必须配置国内镜像源**（否则 `registry.k8s.io` 直连超时、docker.io 也很慢）。
> - **架构必须与目标节点一致**（都 x86_64 或都 aarch64），否则 `ctr import` 后 kubeadm 报架构不匹配。

**第 0 步：配置 docker 国内镜像加速器（前置，必做）**

`/etc/docker/daemon.json` 的 `registry-mirrors` **只对 `docker.io`（Docker Hub）生效**，可加速 Calico 等 docker.io 镜像；
`registry.k8s.io` 的核心组件镜像**不走这个配置**，仍需第 2 步的 retag 循环（`k8s.m.daocloud.io`）。

```bash
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://hub.rat.dev"
  ]
}
EOF
systemctl daemon-reload && systemctl restart docker
docker info | grep -A3 Mirrors    # 确认配置已生效
```

拉取前先测两个镜像源连通性（避免白等，应有 200/401）：
```bash
curl -sI https://k8s.m.daocloud.io/v2/ | head -1      # registry.k8s.io 镜像源
curl -sI https://docker.m.daocloud.io/v2/ | head -1   # docker.io 镜像源
```
若某个源不通，换用其他可用镜像（如 `https://dockerpull.com`、`https://hub-mirror.c.163.com`、`registry.aliyuncs.com/google_containers`）。

**第 1 步：拿到 K8s 控制面镜像清单（自动匹配本机 kubeadm 版本）**

> ⚠️ **版本对齐（最关键）**：`kubeadm config images list` **不要**加 `--kubernetes-version` 硬编码版本，
> 它自动取本机已安装 kubeadm 的版本。你用 dnf 拉到的 kubeadm 是最新的 1.32.x 补丁
> （例如 1.32.13），若硬编码成 1.32.10，拉下的镜像与 `kubeadm init` 实际要用的版本对不上，
> 离线 init 会因找不到镜像而失败。**务必保证：拉取的镜像版本 = 你实际安装的 kubeadm 版本。**

```bash
# 在有 docker 的有网机上（kubeadm 已安装）：
IMAGES=$(kubeadm config images list)     # 不加版本号，自动匹配本机 kubeadm
echo "$IMAGES"
# 典型输出（版本随实际安装变化，以下以 1.32.13 为例）：
#   registry.k8s.io/kube-apiserver:v1.32.13
#   registry.k8s.io/kube-controller-manager:v1.32.13
#   registry.k8s.io/kube-scheduler:v1.32.13
#   registry.k8s.io/kube-proxy:v1.32.13
#   registry.k8s.io/coredns/coredns:v1.11.x
#   registry.k8s.io/pause:3.10
#   registry.k8s.io/etcd:3.5.16-0
```

**第 2 步：拉取并打包 K8s 控制面镜像（走国内镜像 + 打回原 tag）**

> ⚠️ `registry.k8s.io` 实际解析到 Google 欧洲仓库（`europe-west3-docker.pkg.dev`），**国内直连必超时**，
> 报错形如 `dial tcp ...:443: i/o timeout`。**绝不能**直接 `docker pull registry.k8s.io/...`。
> 正确做法：从国内镜像 `k8s.m.daocloud.io` 拉取，再**打回 `registry.k8s.io/...` 的 tag**
> （离线节点 `kubeadm init` 只认 `registry.k8s.io` 前缀）。备选镜像：`registry.aliyuncs.com/google_containers`。

```bash
cd /tmp
MIRROR=k8s.m.daocloud.io                        # 国内可达；不通则换 registry.aliyuncs.com/google_containers

for img in $IMAGES; do
  echo "==> $img"
  name=${img#registry.k8s.io/}                  # 去掉前缀 → kube-apiserver:v1.32.13
  docker pull "$MIRROR/$name" && docker tag "$MIRROR/$name" "$img"
done

# 校验：应能看到全部 registry.k8s.io/... 镜像（即上面打回的 tag）
docker images --format '{{.Repository}}:{{.Tag}}' | grep '^registry.k8s.io'

docker save $IMAGES -o k8s-images-$(date +%Y%m%d).tar
```

**第 3 步：拉取并打包 CNI 镜像（Calico，走 docker.io 镜像）**

```bash
# 先下载官方 manifest，从中精确提取镜像地址（避免版本/仓库写错）
# 注意：docs.tigera.io/archive/... 路径已废弃（404），改从 Calico GitHub 仓库取：
wget https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/calico.yaml -O calico.yaml
CALICO_IMAGES=$(grep -oE 'image: [^ ]+' calico.yaml | awk '{print $2}' | sort -u)
echo "$CALICO_IMAGES"     # 以你下载的 yaml 为准，可能含 node / cni / kube-controllers / typha / csi 等

for img in $CALICO_IMAGES; do
  echo "==> $img"
  docker pull "$img" || echo "FAILED: $img"     # 若已配 docker.io 镜像且生效可直拉；否则见下方显式镜像法
done
docker save $CALICO_IMAGES -o calico-images-v3.28.1.tar
```

> ⚠️ **Calico 拉取失败（连 registry-1.docker.io 超时）的处理**：
> `docker pull docker.io/calico/...` 直接去官方源会超时；`registry-mirrors` 加速器若未生效（重启过 docker 仍直连官方源）或镜像源失效，都不稳。
> **最稳：显式走 docker.io 镜像 + 打回原 tag**（与核心镜像 retag 法一致），不依赖 daemon 配置：
> ```bash
> MIRROR=docker.m.daocloud.io      # 备选：docker.1ms.run / hub.rat.dev / dockerpull.com
> # 先测连通性（应有 200/401）
> curl -sI https://docker.m.daocloud.io/v2/ | head -1
> for img in $CALICO_IMAGES; do
>   site=${img#docker.io/}          # docker.io/calico/cni:v3.28.1 -> calico/cni:v3.28.1
>   echo "==> $img (via $MIRROR)"
>   docker pull "$MIRROR/$site" && docker tag "$MIRROR/$site" "$img" || echo "FAILED: $img"
> done
> docker save $CALICO_IMAGES -o calico-images-v3.28.1.tar
> ```
> 若 `docker info | grep -iA3 mirrors` 显示为空，说明之前 daemon.json 没生效，可忽略它，直接用上面显式镜像法即可。
> ```bash
> wget https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml -O flannel.yaml
> FLANNEL_IMAGES=$(grep -oE 'image: [^ ]+' flannel.yaml | awk '{print $2}' | sort -u)
> MIRROR=docker.m.daocloud.io      # 备选 docker.1ms.run / hub.rat.dev / dockerpull.com
> for img in $FLANNEL_IMAGES; do
>   site=${img#docker.io/}
>   docker pull "$MIRROR/$site" && docker tag "$MIRROR/$site" "$img" || echo "FAILED: $img"
> done
> docker save $FLANNEL_IMAGES -o flannel-images.tar
> ```

> 💡 **需要本地持久化存储（Local PV）时**：有网机还要额外拉 `local-path-provisioner.tar`（rancher/local-path-provisioner + busybox 两个镜像），做法与上面 Calico 完全一致（显式走 docker.io 镜像 + 打回原 tag），详见 **第 7.4 节 ①**。若不需要 PVC 持久化，可跳过。

**第 4 步：跨架构提醒**

若本机架构与目标节点不同（如本机 x86_64、目标 aarch64），拉取时加 `--platform`：
```bash
docker pull --platform linux/arm64 "$MIRROR/$name" && docker tag "$MIRROR/$name" "$img"
```

### 2.5 阶段一产物清单

```
/tmp/
├── k8s-rpms/           (kubelet*.rpm kubeadm*.rpm kubectl*.rpm kubernetes-cni*.rpm)
├── containerd-rpms/    (containerd*.rpm runc*.rpm containernetworking-plugins*.rpm)
├── sys-deps/           (socat*.rpm conntrack-tools*.rpm ebtables*.rpm ipset*.rpm device-mapper-persistent-data*.rpm lvm2*.rpm libseccomp*.rpm iptables*.rpm ipvsadm*.rpm)
├── k8s-images-*.tar               (控制面镜像，文件名带日期，约 0.6~0.9 GB)
├── calico-images-v3.28.1.tar      (CNI 镜像，约 0.2~0.3 GB)
├── local-path-provisioner.tar      (本地存储组件镜像：provisioner + busybox，约 30 MB)
└── calico.yaml / flannel.yaml / local-path-storage.yaml   (CNI / 本地存储 manifests，提前下好)
```

---

## 3. 阶段二：传输到内网

用 U 盘 / 内网 scp，把**全部文件**拷到内网（建议先集中放到 master，再分发到各 worker）：

```bash
# 在 master(192.168.0.10) 上建立目录
mkdir -p /opt/k8s-offline/{rpms,images,manifests}
# 从有网机拷过来（示例，用 U 盘则直接复制）
scp -r /tmp/k8s-rpms /tmp/containerd-rpms \
      /tmp/sys-deps /tmp/k8s-images-*.tar /tmp/calico-images-v3.28.1.tar \
      /tmp/calico.yaml root@192.168.0.10:/opt/k8s-offline/
```

> **注意**：镜像 tar 必须**分发到每一个节点**（master + 两个 worker），因为每个节点的 containerd 都要本地导入这些镜像，`kubeadm init` / `join` 才不会去公网拉取。

---

## 4. 阶段三：各节点安装

以下步骤 **所有节点都要做**（4.1~4.4），然后 master 做 4.5~4.6，workers 做 4.7。

### 4.1 安装系统依赖（所有节点）

```bash
cd /opt/k8s-offline/sys-deps
dnf install -y --skip-broken ./*.rpm
```

> **⚠️ 版本冲突处理**：如果下载机的 openEuler 小版本（如 sp3）和目标机（如 sp4）不一致，
> 部分依赖包（如 `ipset`、`ipset-libs`）可能出现版本冲突报错：
> `nothing provides xxx = x.y-z.oe2403sp3 needed by xxx from @commandline`。
> 这说明目标机已有**更新版本**（sp4），无需降级。加 `--skip-broken` 跳过冲突包即可，
> 系统自带的新版本完全可用。安装完后用以下命令确认关键组件就位：
> ```bash
> rpm -qa | grep -E 'kubelet|kubeadm|kubectl|containerd|ipset|conntrack'
> ```
>
> **根本解法**：确保下载机和目标机执行 `cat /etc/os-release` 输出的 `VERSION_ID` 一致，
> 并在下载时使用与目标机相同版本的仓库源。

### 4.2 安装容器运行时 containerd（所有节点）

先装 rpm（containerd 自带 runc，containernetworking-plugins 提供 CNI 插件）：

```bash
dnf install -y /opt/k8s-offline/containerd-rpms/*.rpm
# 验证：rpm -q containerd runc containernetworking-plugins 均有输出
```

**生成并修改 containerd 配置（关键，所有节点）：**

```bash
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# 修改两处（sed）：
#   1) SystemdCgroup = false  ->  true（让 containerd 用 systemd 管理 cgroup，与 kubelet 一致）
#   2) 确认 sandbox_image 的 pause 版本与导入的一致（默认 pause:3.10，一般无需改）
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 启动
systemctl daemon-reload
systemctl enable --now containerd
systemctl status containerd   # 应为 active (running)
```

### 4.3 安装 kubelet / kubeadm / kubectl（所有节点）

用 rpm 安装（rpm 自带 systemd 单元，无需手动写 unit 文件）：

```bash
dnf install -y /opt/k8s-offline/k8s-rpms/kubelet*.rpm \
               /opt/k8s-offline/k8s-rpms/kubeadm*.rpm \
               /opt/k8s-offline/k8s-rpms/kubectl*.rpm
```

### 4.4 导入镜像到 containerd（所有节点，必须）

containerd 的 K8s 镜像命名空间是 `k8s.io`，导入时务必指定 `-n k8s.io`：

```bash
cd /opt/k8s-offline/images
ctr -n k8s.io images import k8s-images-*.tar
ctr -n k8s.io images import calico-images-v3.28.1.tar
# Flannel 时：ctr -n k8s.io images import flannel-images.tar

# 校验（应能看到 registry.k8s.io/* 与 docker.io/calico/*）
ctr -n k8s.io images list | grep -E 'k8s.io|calico'
```

> 导入后镜像已在本地，**kubeadm init / join 不会再去公网拉取**。每个节点都要导入（master 和 2 个 worker 各做一次）。

### 4.5 master 初始化（仅 master）

```bash
# 启动 kubelet（init 前先起，会以 crashloop 等待，属正常）
systemctl enable --now kubelet

# 初始化控制面（镜像已本地存在，init 不会拉取）
kubeadm init \
  --apiserver-advertise-address=192.168.0.10 \
  --pod-network-cidr=10.244.0.0/16 \
  --image-repository=registry.k8s.io

# 说明：
#   --pod-network-cidr 必须与节点网段（本例 192.168.0.0/24）不重叠，否则 Pod 无法通信。
#     本例节点在 192.168.0.0/24，故 Pod 网段用 10.244.0.0/16：
#     - Flannel 默认即 10.244.0.0/16，直接可用；
#     - Calico 默认从集群自动获取 Pod CIDR（manifest 中 CALICO_IPV4POOL_CIDR 保持注释即可），
#       若被显式改成 192.168.0.0/16，必须改回 10.244.0.0/16 与 init 一致（见 4.6）。
#   --image-repository=registry.k8s.io 与导入的镜像 tag 一致（默认即此，可省略）
```

初始化成功末尾会输出 `kubeadm join ...` 命令（含 token 和 ca-cert-hash），**先复制保存**。

### 4.6 配置 kubectl + 安装 CNI（仅 master）

```bash
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# 安装 Calico（用提前下好的离线 yaml；yaml 内镜像地址须与导入 tag 一致）
kubectl apply -f /opt/k8s-offline/manifests/calico.yaml
# Flannel：kubectl apply -f /opt/k8s-offline/manifests/flannel.yaml

# ⚠️ 网段一致性（极易踩坑）：init 用的 --pod-network-cidr 必须和 CNI 的 Pod 网段一致。
#   - Calico：确认 calico.yaml 里 CALICO_IPV4POOL_CIDR 处于【注释】状态（默认即从集群自动获取），
#     不要写成 192.168.0.0/16；写死的话必须等于 init 的 10.244.0.0/16。
#   - Flannel：kube-flannel.yml 默认就是 10.244.0.0/16，无需改动。
#   不一致的典型症状：节点 Ready 但 Pod 一直 ContainerCreating / 拿不到 IP。
```

> 若 `kubectl apply` 后 Pod 卡在 `ImagePullBackOff`，说明 yaml 里某个镜像 tag 与本地导入的不一致——用 `kubectl describe pod -n kube-system <pod>` 看缺哪个，回到有网机补拉对应 tag 再 `docker save`/`ctr import`。

#### 4.6.1 修复 CoreDNS CrashLoopBackOff（离线环境必做）

CNI 装好后，若 `kubectl get pods -n kube-system` 看到 **coredns 一直 `CrashLoopBackOff`**，
查日志会显示：

```
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=20
# plugin/forward: no nameservers found
```

**原因**：CoreDNS 默认配置 `forward . /etc/resolv.conf`，会读**节点的 `/etc/resolv.conf`** 作为上游 DNS。
离线内网节点该文件里通常没有有效 nameserver，CoreDNS 拿不到上游 DNS → 启动即崩。

**修复（二选一）：**

**方案 A：纯离线，不解析外网域名（推荐）** —— 删掉 `forward` 段，CoreDNS 只做集群内服务发现（`*.svc.cluster.local`）：

```bash
kubectl get configmap coredns -n kube-system -o json | python3 -c '
import sys, json, re
d = json.load(sys.stdin)
cf = d["data"]["Corefile"]
cf = re.sub(r"\n\s*forward \. .*?\n\s*\}", "\n", cf, flags=re.S)   # 带 { } 块形式
cf = re.sub(r"\n\s*forward \. [^\n]*", "", cf)                      # 单行形式
d["data"]["Corefile"] = cf
json.dump(d, sys.stdout)
' | kubectl apply -f -

# CoreDNS 有 reload 插件会自动重载；若未恢复，手动重启：
kubectl rollout restart deployment/coredns -n kube-system
```

**方案 B：内网有 DNS 服务器（需解析公司内部域名）** —— 把 forward 指向真实内部 DNS：

```bash
kubectl edit configmap coredns -n kube-system
# 把  forward . /etc/resolv.conf {   改成   forward . 10.1.13.1 {   （换成你的内部 DNS IP）
kubectl rollout restart deployment/coredns -n kube-system
```

**验证：**

```bash
kubectl get pods -n kube-system | grep coredns     # 应变 Running
kubectl run test-dns --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default
kubectl delete pod test-dns                         # 能解析出 kubernetes.default.svc.cluster.local 即正常
```

### 4.7 worker 加入集群（仅两个 worker）

每个 worker 执行 4.1~4.4 后，运行 master 初始化输出的 join 命令：

```bash
kubeadm join 192.168.0.10:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

若 token 过期/丢失，在 master 重新生成：

```bash
kubeadm token create --print-join-command
```

---

## 5. 验证集群

在 master 上：

```bash
# 查看节点（kubectl 已自动配置好）
kubectl get nodes
# 期望：
# NAME            STATUS   ROLES           AGE   VERSION
# 192.168.0.10    Ready    control-plane   5m    v1.32.13
# 192.168.0.11    Ready    <none>          4m    v1.32.13
# 192.168.0.12    Ready    <none>          4m    v1.32.13

kubectl get pods -A
# 重点：kube-system 下 coredns、calico-*、kube-apiserver 等均为 Running

kubectl cluster-info

# 跑个测试 Pod 验证网络（用本地导入的镜像或先不依赖外部镜像）
kubectl run test --image=registry.k8s.io/pause:3.10 --restart=Never -- sleep 3600
kubectl exec test -- wget -qO- https://kubernetes.default.svc
kubectl delete pod test
```

---

## 6. 常用运维操作

### 6.1 增加 worker 节点（离线）
新节点完成 4.1~4.4（含镜像导入），再执行 `kubeadm join`（从 master 用 `kubeadm token create --print-join-command` 获取）。

### 6.2 删除节点
```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node>
# 节点上清理：kubeadm reset
```

### 6.3 重置 / 重装
```bash
kubeadm reset        # 各节点执行，清理 /etc/kubernetes、/var/lib/kubelet 等
# 必要时手动清理：rm -rf /etc/cni /var/lib/cni /var/lib/etcd
```

### 6.4 升级集群（离线）
有网机拉取新版本镜像 + rpm，拷入内网导入/安装后：
```bash
kubeadm upgrade plan
kubeadm upgrade apply v1.32.x
# 各节点：kubeadm upgrade node
```

### 6.5 让 master 也跑业务 Pod（可选）
默认 master 有 `NoSchedule` 污点。若想单 master 也承载负载：
```bash
kubectl taint nodes <master> node-role.kubernetes.io/control-plane:NoSchedule-
```

---

## 7. 持久化存储（Local PV 本地存储）

> 离线集群默认**没有 StorageClass、没有动态供给器**。要让业务 Pod 用 PVC 持久化，必须额外装一套本地存储方案。本节给出与本文离线流程一致的实施方案。

### 7.1 先建立认知：local 不是"真分布式存储"

"采用 local" 指 **Local Persistent Volume（本地持久卷）**：把某台节点上的磁盘/目录直接当一个 PV 给 Pod 用。

| 特征 | 影响 |
|------|------|
| **节点亲和** | 绑定该 PV 的 Pod 必须调度到那台节点，否则起不来 |
| **无跨节点副本** | 数据只写在单块本地盘，节点/磁盘故障 = 数据丢失，不会自动恢复 |
| **无在线迁移** | 节点维护/排空时要先腾空上面的有状态负载 |
| **性能好** | 直写本地盘，无网络开销，适合 DB / 消息队列等 |

即："分布式存储采用 local" 的准确含义 = **用各节点本地盘组成集群级存储池，由调度器把 Pod 放到有数据的节点**。它提供容量分散与性能，但**不提供副本/高可用/容灾**。需要数据跨节点不丢应改 Longhorn / Ceph（见 7.6）。

### 7.2 方案选型

| 方案 | 额外组件 | 动态供给 | 离线友好度 | 适合 |
|------|----------|----------|-----------|------|
| **Local Path Provisioner**（Rancher） | 1 个 Deployment | 是 | 极好（单镜像+busybox） | **1+2 小集群首选** |
| **OpenEBS LocalPV** | openebs 组件 | 是 | 好 | 想要裸盘 / 多 StorageClass |
| **静态 Local PV**（k8s 原生） | 否 | 否（手建 PV） | 最友好 | 卷少且固定 |

下面以 **Local Path Provisioner** 为主线写实施；另两种见 7.5。

### 7.3 节点磁盘规划（实施前必做）

本地存储的"容量"来自每台节点本地盘。一般只在 **worker** 上放（master 有 `NoSchedule`）。

```bash
# 每台 worker（示例 192.168.0.11 / 192.168.0.12）执行：
mkdir -p /mnt/local-storage
chmod 777 /mnt/local-storage          # provisioner 以自身用户写入，按需收紧

# 若用独立数据盘（建议 SSD）：
mkfs.ext4 /dev/sdb
mount /dev/sdb /mnt/local-storage
echo '/dev/sdb /mnt/local-storage ext4 defaults 0 0' >> /etc/fstab
```

> openEuler 若 **SELinux 为 enforcing**（已按 1.4 关闭可跳过），需给目录打标签：
> `semanage fcontext -a -e /var/lib /mnt/local-storage && restorecon -Rv /mnt/local-storage`

### 7.4 离线镜像准备 + 部署（Local Path Provisioner）

**① 外网机拉镜像（与 Calico 同理，走 docker.io 镜像 + 打回原 tag）**

```bash
PROV_IMG=rancher/local-path-provisioner:v0.0.30
HELPER_IMG=busybox:1.36

# rancher/ 与 busybox/ 都在 docker.io，直连会超时 → 显式走 docker.io 镜像源 + 打回原 tag
MIRROR=docker.m.daocloud.io      # 备选：docker.1ms.run / hub.rat.dev / dockerpull.com
# 先测连通性（应有 200/401）
curl -sI https://docker.m.daocloud.io/v2/ | head -1

for img in "$PROV_IMG" "$HELPER_IMG"; do
  echo "==> $img (via $MIRROR)"
  docker pull "$MIRROR/$img" && docker tag "$MIRROR/$img" "$img" || echo "FAILED: $img"
done

# 校验：应见到原 tag
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'local-path-provisioner|busybox'
docker save "$PROV_IMG" "$HELPER_IMG" -o local-path-provisioner.tar
```

**② 拷入内网，每台 worker 导入 containerd（tag 保持原样）**

```bash
ctr -n k8s.io images import local-path-provisioner.tar
ctr -n k8s.io images ls | grep -E 'local-path-provisioner|busybox'
```

**③ 下载并改 manifest（外网机 / 内网均可，apply 前改好）**

```bash
wget https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml -O local-path-storage.yaml
```

> ⚠️ **离线必改（否则 helper pod 会 ImagePullBackOff）**：v0.0.30 的 helper 镜像由
> ConfigMap `local-path-config` 的 `config.json` 控制（**不是** deployment 的 `HELPER_IMAGE`
> 环境变量，那个在新版已不生效）。默认 `config.json` 只含 `nodePathMap`、没有 `pods`，
> 于是 provisioner 走代码内置默认 `busybox`（= latest），而内网只有 `busybox:1.36`
> → helper pod 拉 `busybox:latest` 失败 → PVC 一直 Pending。
>
> **正确做法：在 `kubectl apply` 之前，把 helper 镜像显式写进 `config.json` 的 `pods` 段。**

用一条命令把 `local-path-storage.yaml` 里的 ConfigMap `config.json` 注入 helper 镜像
（同时把存储基目录改到 7.3 创建的 `/mnt/local-storage`，按需保留默认 `/var/local-path-provisioner` 也可）：

```bash
python3 - <<'PY'
import json
p = "local-path-storage.yaml"
s = open(p, encoding="utf-8").read()

# 定位 config.json 的 JSON 块（用括号匹配，避免误吞 setup/cleanup 段）
marker = "config.json: |-"
i = s.index(marker) + len(marker)
j = s.index("{", i)                 # JSON 起始 {
depth = 0
k = j
for ch in s[j:]:
    if ch == "{": depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            break
    k += 1
cfg = json.loads(s[j:k+1])

cfg["nodePathMap"] = [{
    "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
    "paths": ["/mnt/local-storage"]          # 与 7.3 目录一致；用默认则填 /var/local-path-provisioner
}]
cfg["pods"] = [{
    "forProvision": {
        "image": "busybox:1.36",             # 与你导入的 tag 一致
        "command": ["sh", "-c", "chmod 0777 /data/shared || true"],
        "volumes": [{"name": "data", "hostPath": {"path": "/data"}}]
    },
    "forDeletion": {
        "image": "busybox:1.36",
        "command": ["sh", "-c", "rm -rf /data/shared/* || true"],
        "volumes": [{"name": "data", "hostPath": {"path": "/data"}}]
    }
}]
new_block = json.dumps(cfg, indent=4)
new_block = "\n".join(("    " + ln) if ln.strip() else ln for ln in new_block.split("\n"))
s = s[:j] + new_block + s[k+1:]
open(p, "w", encoding="utf-8").write(s)
print("patched local-path-storage.yaml: helper image -> busybox:1.36, base -> /mnt/local-storage")
PY
```

> 不想改基目录就保留 `/var/local-path-provisioner`；只想锁 helper 镜像，把上面 `paths` 改回默认即可。
> 若已部署过、现在才补：直接 `kubectl edit configmap local-path-config -n local-path-storage`
> 或在 master 上跑后面第 9 节那条 `kubectl get configmap ... | python3 -c ... | kubectl apply` 命令，
> 然后 `kubectl rollout restart deployment/local-path-provisioner -n local-path-storage`。

**④ master 部署并设为默认 StorageClass**

```bash
kubectl apply -f /opt/k8s-offline/manifests/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get pods -n local-path-storage     # Running
kubectl get storageclass                   # 应见 local-path (default)
```

> 关键：manifest 里 Deployment 的 `imagePullPolicy` 须为 `IfNotPresent`，否则离线仍去公网拉。

**⑤ 验证（通用）**

```bash
cat > /opt/k8s-offline/manifests/test-local.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test-pvc }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
  storageClassName: local-path
---
apiVersion: v1
kind: Pod
metadata: { name: test-local }
spec:
  containers:
  - name: busy
    image: busybox:1.36
    command: ["sh","-c","echo hello > /data/hello.txt && sleep 3600"]
    volumeMounts: [{ name: data, mountPath: /data }]
  volumes:
  - name: data
    persistentVolumeClaim: { claimName: test-pvc }
EOF
kubectl apply -f /opt/k8s-offline/manifests/test-local.yaml
kubectl get pvc test-pvc      # Bound
kubectl exec test-local -- cat /data/hello.txt   # 应输出 hello
kubectl delete -f /opt/k8s-offline/manifests/test-local.yaml
```

### 7.5 另两种方案（简述）

- **OpenEBS LocalPV**（裸盘 / 目录）：离线镜像 `openebs/localpv-provisioner`（如 `1.5.0`），内网导入后 `kubectl apply` 官方清单，再建 StorageClass（`storageType: hostpath` 用目录，或 `device` 用裸盘如 `/dev/sdb`）。功能比 Local Path 全，但镜像更多。
- **静态 Local PV**（零组件）：每台 worker 手建 PV 对象，指定 `local.path` 与 `nodeAffinity`（hostname 必须与实际节点一致）。每加一块盘手建一个 PV，适合卷少固定。

### 7.6 使用注意事项（重点）

1. **调度约束**：Local PV 与节点强绑定，用它的 Pod 被固定到对应节点，勿强行调度到别处。
2. **数据不跨节点、不自动备份**：节点坏盘 = 数据丢失；有状态应用（DB）务必自带备份（主从 / 定时 dump）。
3. **drain 风险**：排空有 Local PVC 的节点时 Pod 卡 `Terminating`；维护前确认数据可重建，或 `delete-local-data`（会丢数据）。
4. **容量监控**：Local 卷不自动扩容，PVC 申请量勿超节点剩余空间，建议加节点磁盘告警。
5. **跨节点共享（RWX）/ 在线迁移 / 副本容灾**：local 均不支持，应选 **Longhorn**（小集群离线）或 **Ceph**（大规模）。

---

## 8. 国产系统注意事项

- **openEuler / 麒麟 / UOS** 均为 rpm + systemd，按本文 rpm 命令即可；若系统自带源无 Kubernetes 包，使用社区 `kubernetes.repo`（rpm，见 2.1）下载安装。
- 确认 **默认 shell 为 bash**（kubeadm 脚本依赖 bash）。
- 部分国产系统默认开启 SELinux 或安全加固，按 1.4 节关闭 SELinux。
- 时间同步服务名可能是 `chronyd` 或 `ntpd`，按实际启用。
- 若内核较旧，Calico 的 eBPF 数据面可能不支持，**默认用 iptables / VXLAN 模式**即可。
- 防火墙默认管理工具可能是 firewalld 或 nftables，按 1.3 节放通或关闭。
- containerd 的 cgroup 驱动务必设为 `SystemdCgroup = true`（4.2 节），否则节点会 NotReady。

---

## 9. 常见问题排查

### 节点 NotReady
- 查 kubelet：`journalctl -u kubelet -f`
- 查运行时：`systemctl status containerd` / `crictl ps`
- 查 CNI：`kubectl -n kube-system logs -l k8s-app=calico-node`
- 确认 **4789 / 8472 UDP** 已放通（Calico / Flannel VXLAN）

### 镜像拉取失败（ImagePullBackOff）
- 确认 `ctr -n k8s.io images import` 已在**该节点**执行，且 `ctr -n k8s.io images list` 能看到该镜像。
- 确认导入的 tag 与 yaml / kubeadm 期望的**完全一致**（含 `registry.k8s.io` / `docker.io` 前缀、架构 amd64/arm64）。
- 确认 containerd 的命名空间是 `k8s.io`（kubeadm 只看这个命名空间）。

### 控制面 Pod 全部起不来 / kubeadm init 超时（sandbox pause 镜像不匹配）
- 症状：`kubeadm init` 等待 API Server 健康检查 4 分钟后超时；kubelet 日志报
  `RunPodSandbox failed ... failed to pull image "registry.k8s.io/pause:3.6" ... no such host`。
- 根因：containerd 的 `sandbox_image`（默认 `pause:3.6`）与导入的 pause 版本（K8s 1.32 为 `pause:3.10`）不一致，离线又拉不到 → 所有 Pod 的 sandbox 起不来。
- 修复：改 `/etc/containerd/config.toml` 让 sandbox_image 指向已导入的版本：
  ```bash
  grep sandbox_image /etc/containerd/config.toml          # 看当前配的版本
  ctr -n k8s.io images list | grep pause                  # 看实际导入的版本
  sed -i 's|registry.k8s.io/pause:3.6|registry.k8s.io/pause:3.10|' /etc/containerd/config.toml
  systemctl restart containerd && systemctl restart kubelet
  kubeadm reset && kubeadm init ...                       # 重新初始化
  ```

### CoreDNS CrashLoopBackOff（no nameservers found）
- 症状：coredns Pod 反复重启；`kubectl logs -n kube-system -l k8s-app=kube-dns` 报 `plugin/forward: no nameservers found`。
- 根因：CoreDNS 默认 `forward . /etc/resolv.conf`，离线节点 resolv.conf 无有效上游 DNS。
- 修复：删掉 forward 段（纯离线）或改指内部 DNS，详见 **4.6.1 节**。

### Local Path Provisioner 的 helper pod ImagePullBackOff（PVC 一直 Pending）
- 症状：`kubectl get pods -A` 看到 `helper-pod-create-pvc-xxx` 在 `local-path-storage` 命名空间 `ImagePullBackOff`（重启几百次），`test-pvc` 一直 `Pending`，`test-local` 一直 `Pending`。
- 根因：v0.0.30 的 helper 镜像由 ConfigMap `local-path-config` 的 `config.json` 控制，**不是** deployment 的 `HELPER_IMAGE` 环境变量（新版已不读该 env）。默认 `config.json` 无 `pods` 段 → provisioner 用代码内置默认 `busybox`（= latest），而内网只导入了 `busybox:1.36` → 拉不到 latest 失败。
- 修复（部署前改最干净，见 **7.4 ③**）：把 helper 镜像写进 `config.json` 的 `pods` 段为 `busybox:1.36`；若已部署，在 master 上跑：
  ```bash
  kubectl get configmap local-path-config -n local-path-storage -o json | python3 -c '
  import sys, json
  d = json.load(sys.stdin)
  cfg = json.loads(d["data"]["config.json"])
  cfg["pods"] = [{
    "forProvision": {"image":"busybox:1.36","command":["sh","-c","chmod 0777 /data/shared || true"],"volumes":[{"name":"data","hostPath":{"path":"/data"}}]},
    "forDeletion":  {"image":"busybox:1.36","command":["sh","-c","rm -rf /data/shared/* || true"],"volumes":[{"name":"data","hostPath":{"path":"/data"}}]}
  }]
  d["data"]["config.json"] = json.dumps(cfg, indent=2)
  json.dump(d, sys.stdout)
  ' | kubectl apply -f -
  kubectl rollout restart deployment/local-path-provisioner -n local-path-storage
  ```
- 备选兜底：直接在 **每台节点** 给已导入的镜像打 latest tag（无需改配置）：
  `ctr -n k8s.io images tag busybox:1.36 busybox:latest`
- 注意：`busybox:1.36` 必须在 **所有节点**（master + 各 worker）都导入，否则 helper pod 调度到没该镜像的节点仍会失败。


### 主机名含下划线导致 init 失败
- 症状：`kubeadm init` 报 `nodeRegistration.name: Invalid value: "k8s_master": a lowercase RFC 1123 subdomain must consist of ...`。
- 根因：K8s 主机名只允许小写字母、数字、`-`、`.`，**不允许下划线 `_`**。
- 修复：`hostnamectl set-hostname k8s-master`（同步改 `/etc/hosts`），worker 同理改成 `worker-1`/`worker-2`，再重跑 init/join。

### kubeadm join 失败 / token 过期
- master 重新生成：`kubeadm token create --print-join-command`
- 确认 worker 与 master **时间同步**、**端口 6443 可达**。

### 重置后重装报端口 / 文件占用
- 先 `kubeadm reset` 清理，再 `init` / `join`。
- 必要时手动清理：`/etc/kubernetes`、`/var/lib/kubelet`、`/var/lib/etcd`、`/etc/cni`。

### Calico 与 K8s 1.32 版本说明
- Calico 3.28 官方测试到 K8s 1.31，与 1.32 属"实际大多可用但未严格测试"组合。
- 若需 1.32 官方认证的网络插件，可改用 **Flannel**（见 2.4 Flannel 备选），或等官方发布更高版本 Calico。

---

## 10. 附录：完整文件清单

### 10.1 需拷入内网的文件

| 文件 | 说明 | 大小（约） |
|------|------|-----------|
| `k8s-rpms/*.rpm` | K8s 组件（kubelet/kubeadm/kubectl/kubernetes-cni） | 几十 MB |
| `containerd-rpms/*.rpm` | 容器运行时（containerd + runc + containernetworking-plugins） | ~80 MB |
| `sys-deps/*.rpm` | 系统依赖（kubeadm 依赖 + containerd 相关：libseccomp、device-mapper-persistent-data、lvm2、iptables、ipvsadm 等） | 几 MB~几十 MB |
| `k8s-images-*.tar` | 控制面镜像（文件名带日期） | 0.6~0.9 GB |
| `calico-images-v3.28.1.tar` | CNI 镜像 | 0.2~0.3 GB |
| `local-path-provisioner.tar` | 本地存储镜像（provisioner + busybox） | ~30 MB |
| `calico.yaml` / `flannel.yaml` / `local-path-storage.yaml` | CNI / 本地存储 manifests | KB 级 |

> **最小可用交付**：运行时 + kube* 组件 + `k8s-images-*.tar` + `calico-images-*.tar` + `calico.yaml`，即可在内网拉起 1 master + 2 worker 的 K8s 集群（镜像版本以实际安装的 kubeadm 为准），全程不触公网。需要 PVC 持久化时，再补 `local-path-provisioner.tar` + `local-path-storage.yaml`（见第 7 节）。

### 10.2 K8s 控制面镜像清单（示例，版本以实际 `kubeadm config images list` 为准）

```
registry.k8s.io/kube-apiserver:v1.32.x
registry.k8s.io/kube-controller-manager:v1.32.x
registry.k8s.io/kube-scheduler:v1.32.x
registry.k8s.io/kube-proxy:v1.32.x
registry.k8s.io/coredns/coredns:v1.11.x
registry.k8s.io/pause:3.10
registry.k8s.io/etcd:3.5.16-0
```

### 10.3 Calico 镜像清单（v3.28.1，以 `calico.yaml` 中 `image:` 为准）

```
docker.io/calico/node:v3.28.1
docker.io/calico/cni:v3.28.1
docker.io/calico/kube-controllers:v3.28.1
```

> 全文以 `kubeadm config images list` 和 CNI yaml 的实际输出为准，避免手抄版本号出错。

---

## 11. 快速执行检查清单（照着打勾）

> 把"有网机"产物拷到内网后，逐节点按下面顺序执行。所有命令默认在 root 下运行。

### A. 每个节点（master + 2 worker）都要做
- [ ] **系统初始化**（1.4）：关防火墙 / swap / SELinux，加载 br_netfilter、overlay，设 sysctl，chrony 同步
- [ ] **装系统依赖**：`cd /opt/k8s-offline/sys-deps && dnf install -y --skip-broken ./*.rpm`
- [ ] **装 containerd**：`dnf install -y /opt/k8s-offline/containerd-rpms/*.rpm`
      → `containerd config default > /etc/containerd/config.toml` 并把 `SystemdCgroup = true`
      → `systemctl enable --now containerd`，`systemctl status containerd` 为 active
- [ ] **装 kube***：`dnf install -y /opt/k8s-offline/k8s-rpms/kubelet*.rpm /opt/k8s-offline/k8s-rpms/kubeadm*.rpm /opt/k8s-offline/k8s-rpms/kubectl*.rpm`
- [ ] **导入镜像**：`ctr -n k8s.io images import k8s-images-*.tar` 与 `calico-images-v3.28.1.tar`（需要 Local PV 的 worker 再导 `local-path-provisioner.tar`）
      → `ctr -n k8s.io images list | grep -E 'k8s.io|calico'` 能看到全部
- [ ] **启动 kubelet**：`systemctl enable --now kubelet`（init 前会 crashloop 等待，正常）

### B. 仅 master
- [ ] `kubeadm init --apiserver-advertise-address=<本机IP> --pod-network-cidr=10.244.0.0/16 --image-repository=registry.k8s.io`
- [ ] 复制保存末尾输出的 `kubeadm join ...` 命令
- [ ] `mkdir -p $HOME/.kube && cp -i /etc/kubernetes/admin.conf $HOME/.kube/config && chown $(id -u):$(id -g) $HOME/.kube/config`
- [ ] `kubectl apply -f /opt/k8s-offline/manifests/calico.yaml`（确认 CALICO_IPV4POOL_CIDR 未写死成 192.168.0.0/16）
- [ ] 需要本地存储：`kubectl apply -f /opt/k8s-offline/manifests/local-path-storage.yaml` 并设为默认 StorageClass

### C. 每个 worker
- [ ] 执行 B 之前复制的 `kubeadm join ...` 命令
- [ ] token 过期就在 master 跑 `kubeadm token create --print-join-command` 重新生成

### D. 验证（master）
- [ ] `kubectl get nodes` → 三个节点均 `Ready`
- [ ] `kubectl get pods -A` → `kube-system` 下 coredns / calico-* / kube-apiserver 全 `Running`
- [ ] **coredns 若 CrashLoopBackOff** → 按 4.6.1 修 forward（`no nameservers found`）
- [ ] 跑测试 Pod（pause）验证网络：`kubectl run test --image=registry.k8s.io/pause:3.10 --restart=Never -- sleep 3600` 然后 `kubectl delete pod test`
- [ ] DNS 解析：`kubectl run test-dns --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default` 能解析即 OK

### E. 常见卡点速查
- [ ] 主机名含下划线 `_` → init 报 RFC 1123 错误，`hostnamectl set-hostname` 改成 `-`（见第 9 节）
- [ ] init 卡 4 分钟超时 → containerd `sandbox_image` 的 pause 版本与导入的不一致（3.6 vs 3.10，见第 9 节）
- [ ] 节点 NotReady → 查 `journalctl -u kubelet`、`systemctl status containerd`、UDP 4789/8472 是否放通
- [ ] Pod ImagePullBackOff → 镜像是否在**该节点**导入、tag 前缀（registry.k8s.io / docker.io）是否一致、containerd 命名空间是否 `k8s.io`
- [ ] Pod 拿不到 IP / 一直 ContainerCreating → init 的 `--pod-network-cidr` 与 CNI 网段是否一致（见 4.5 / 4.6）
- [ ] coredns CrashLoopBackOff（no nameservers found）→ 改 CoreDNS forward（见 4.6.1）
