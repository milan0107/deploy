#!/usr/bin/env bash
# ==========================================================================
# Milvus 1+2 实验环境 —— cluster 压缩渲染+部署脚本（适配 Milvus 2.6.x 架构）
# （mixCoord 合并协调者 + streamingNode 新组件；indexCoord/indexNode 在 2.6 已移除，勿开）
#
# 做了三件事：
#   1) 清理旧实例（含 finalizer 兜底，避免 PVC/PV 卡 Terminating）
#   2) helm template 渲染 cluster 清单（Milvus 2.6 推荐：mixCoordinator 默认开 + streaming.enabled=true + indexNode.enabled=false）
#   3) kubectl apply 并查看 Pod 状态
#
# 重要：Milvus 2.6.x 已把独立 Coordinator 合并成 mixCoord、把 indexNode 合并进 dataNode。
#       不要尝试 --set xxxCoordinator.enabled=true 或 indexNode.enabled=true，否则 Pod 会报
#       "unknown server type=indexcoord/indexnode" 起不来。
#
# 离线注意：CHART 必须改成你本地解压的 chart 目录（不能写在线 repo 名）
# 运行环境：在装有 helm + kubectl 的集群节点上用 Git Bash 执行
# ==========================================================================
set -uo pipefail

# =========================== 配置区（按需修改） ===========================
RELEASE="my-release"                       # 统一 release 名。脚本会顺手清掉旧的 my-release / demo-release，避免两套并存抢 Longhorn 盘
NAMESPACE="default"
CHART="zilliztech/milvus"                  # 【离线必改】改成你本地解压的 chart 目录，如 /d/soft/milvus-chart 或 /root/milvus-5.0.24
MANIFEST="/d/wq/docker/milvus_manifest_cluster.yaml"   # 渲染产物路径（默认覆盖你原来的那份；若在 D:\wq\docker 下运行可改成 ./milvus_manifest_cluster.yaml）
CLEANUP=1                                  # 1=先清理旧实例再装；0=跳过清理直接渲染+应用（仅当你已手动清干净时用）
# ===========================================================================

echo "=================================================="
echo " Milvus 方案A 渲染/部署  RELEASE=$RELEASE  NS=$NAMESPACE"
echo "=================================================="

if [ "$CLEANUP" = "1" ]; then
  echo ">>> [1/4] 清理旧实例（含 finalizer 兜底）..."
  # 1a) 清空所有 PVC / PV 的 finalizer（防 Terminating 卡死）
  for p in $(kubectl -n "$NAMESPACE" get pvc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl -n "$NAMESPACE" patch pvc "$p" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  done
  for v in $(kubectl get pv -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl patch pv "$v" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  done
  # 1b) 临时卸 Longhorn webhook，防止它反复给 PV 加 finalizer 卡清理
  kubectl delete validatingwebhookconfiguration longhorn-admission-webhook 2>/dev/null || true
  kubectl delete mutatingwebhookconfiguration longhorn-admission-webhook 2>/dev/null || true
  # 1c) 按 instance 标签清掉旧 release（my-release / demo-release / 本次 RELEASE）
  for r in my-release demo-release "$RELEASE"; do
    kubectl -n "$NAMESPACE" delete all,cm,secret,sa,pvc -l "app.kubernetes.io/instance=$r" --force --grace-period=0 --wait=false 2>/dev/null || true
    kubectl delete pv -l "app.kubernetes.io/instance=$r" --force --grace-period=0 --wait=false 2>/dev/null || true
  done
  # 1d) 清残留 Longhorn 卷
  kubectl -n longhorn-system delete lhv --all --force --grace-period=0 2>/dev/null || true
  # 1e) 重建 webhook
  kubectl -n longhorn-system rollout restart deployment/longhorn-admission-webhook 2>/dev/null || true
  echo "    清理完成。部署前请确认 Longhorn 盘可调度："
  echo "      kubectl -n longhorn-system get lhn -o wide"
  echo "        -> node1 应为 Schedulable（若 Unschedulable，到 Longhorn UI 开启调度）"
  echo "      kubectl -n longhorn-system get setting storage-reserved-percentage-for-default-disk -o jsonpath='{.value}'"
  echo "        -> 建议 <= 10（保留比例过高会导致新卷建不出来）"
  sleep 3
fi

echo ">>> [2/4] helm template 渲染 Milvus 2.6 cluster 清单..."
helm template "$RELEASE" "$CHART" -n "$NAMESPACE" \
  --set cluster.enabled=true \
  --set mixCoordinator.enabled=true \
  --set streaming.enabled=true \
  --set indexNode.enabled=false \
  --set msgStreamType=woodpecker \
  --set etcd.replicaCount=1 \
  --set minio.mode=standalone \
  --set minio.replicas=1 \
  --set pulsar.enabled=false \
  --set pulsarv3.enabled=false \
  > "$MANIFEST"

echo ">>> [3/4] 校验 2.6 关键组件是否在清单中..."
if grep -q "milvus-mixcoord" "$MANIFEST"; then
  echo "  [OK] 清单含 mixcoord（合并协调者，2.6 正确拓扑）"
else
  echo "  [WARN] 未发现 mixcoord！请检查 chart 是否匹配 Milvus 2.6"
fi
if grep -q "milvus-streamingnode" "$MANIFEST"; then
  echo "  [OK] 清单含 streamingnode（2.6 新组件已开启）"
else
  echo "  [WARN] 未发现 streamingnode！请确认 --set streaming.enabled=true 已生效"
fi
if grep -q "milvus-indexnode" "$MANIFEST" || grep -q "milvus-indexcoord" "$MANIFEST"; then
  echo "  [ERROR] 清单里出现了 indexnode/indexcoord！这是 2.6 已移除的角色，会导致 unknown server type。请确认 indexNode.enabled=false 且未开独立 Coordinator。"
else
  echo "  [OK] 未出现已移除的 indexnode/indexcoord（正确）"
fi
echo "  组件清单预览（Deployment/StatefulSet 名）："
grep -E "^\s*name: ${RELEASE}-(milvus|etcd|minio)" "$MANIFEST" | sort -u

echo ">>> [4/4] kubectl apply 部署..."
kubectl apply -f "$MANIFEST"

echo "=================================================="
echo " 部署已提交。观察 Pod 就绪情况："
echo "   kubectl -n $NAMESPACE get pods -w"
echo " 重点关注：etcd 先 Running（之前是 I/O error），再等各 coord/node 起来。"
echo " 若 etcd 仍 CrashLoop：大概率是 Longhorn 卷/权限问题，回看排障记录。"
echo "=================================================="
