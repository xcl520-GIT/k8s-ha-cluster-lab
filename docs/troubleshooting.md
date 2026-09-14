# 踩坑总集（Troubleshooting）

> 本文件汇总集群运维过程中**实际踩到**的每一个坑。
> 每个坑都按「现象 → 排查 → 根因 → 解决 → 生产启示」记录。
> 记录本身也有用：下次遇到同样现象，先来这份文件里搜一遍。

---

## 坑 01 · `systemctl stop kubelet` 不会停止容器

| 项 | 内容 |
|---|---|
| **发生场景** | etcd 快照恢复 |
| **严重度** | 高 —— 导致恢复"假成功"，且现象极具欺骗性 |

### 现象

执行 etcd 快照恢复后：
- `etcdutl snapshot restore` 报告成功
- `systemctl start kubelet` 后 `kubectl get --raw=/readyz` **返回正常**
- **但被删除的数据没有回来**

### 排查过程

```bash
# 1. 数据目录对不对？
$ ls -la /var/lib/etcd/member/snap/
  -rw-------. 1 root root 5967872 Sep 13 16:44 db     # 恢复的新数据在
$ ls -d /var/lib/etcd.bak-*
  /var/lib/etcd.bak-20260913-164456                   # 旧数据也保全了

# 2. 转折点：看容器启动时间
$ docker ps --filter name=etcd --format 'table {{.Names}}\t{{.Status}}'
  k8s_etcd_etcd-k8s-master01_...   Up 49 minutes      # 49 分钟没重启过！

# 3. apiserver 呢？
$ ss -lntp | grep 6443
  LISTEN ... users:(("kube-apiserver",pid=2705,fd=3)) # 还是 1 小时前的 PID

# 4. 有多少容器还在？
$ docker ps --filter name=k8s_ -q | wc -l
  18                                                  # 一个都没停
```

### 根因

**`systemctl stop kubelet` 不会杀掉它管理的容器。**

这是 kubelet 的**正确设计** —— 重启 kubelet 不应该导致业务容器中断。但对 etcd 恢复来说是致命的：

```
① mv /var/lib/etcd
     ↓
   运行中的 etcd 进程仍持有被移动文件的 inode 句柄
   → 继续用【旧数据】对外服务，完全不受目录改名影响

② etcdutl snapshot restore → /var/lib/etcd
     ↓
   新数据老老实实写到了磁盘 
   但没有任何进程会去读它

③ systemctl start kubelet
     ↓
   kubelet 检查发现容器"已经在运行" → 什么都不做
   → etcd 仍用旧数据 → 恢复等于没做
```

**为什么 `readyz` 还是正常**：apiserver 从头到尾就没停过，一直连着那个还在运行的旧 etcd。

### 解决

```bash
systemctl stop kubelet
sleep 3

# 关键：显式停止所有 kubelet 管理的容器
docker ps --filter "name=k8s_" -q | xargs -r docker stop -t 20

# 必须确认端口真的释放了，否则恢复无效
ss -lntp | grep -E ':6443|:2379'    # 应该无输出

systemctl start kubelet              # 从已恢复的数据目录重建静态 Pod
```

### 生产启示

> **恢复流程必须有"端口释放校验"这一步，不能只看 `systemctl is-active kubelet`。**
>
> 更稳妥的做法是把整个恢复流程脚本化，并在关键节点插入断言（assert），
> 避免依赖人的判断。

---

## 坑 02 · etcd 3.6 移除了 `etcdctl snapshot status`

| 项 | 内容 |
|---|---|
| **发生场景** | 备份脚本的校验环节 |
| **严重度** | 高 —— **不报错**，导致脚本误判成功 |

### 现象

```bash
$ etcdctl snapshot status /var/backups/etcd/etcd-xxx.db -w table
NAME:
  snapshot - Manages etcd node snapshots

USAGE:
  etcdctl snapshot <subcommand> [flags]
...
```

**没有报错，退出码 0**，只打印了一屏 help 文本。

### 根因

- etcd **3.5** 起：`snapshot status/restore` 被标记为弃用
- etcd **3.6** 起：**彻底移除**，相关功能迁移到独立的 **`etcdutl`** 二进制

`etcdctl snapshot` 现在只剩 `save` 一个子命令。

### 危险点

因为**退出码是 0**，脚本里的这种写法会静默失效：

```bash
# 危险：退出码 0，但 STATUS 是 help 文本
STATUS=$(etcdctl snapshot status "$SNAPSHOT" -w json 2>/dev/null) || { echo "校验失败"; exit 1; }
REVISION=$(echo "$STATUS" | grep -o '"revision":[0-9]*' | cut -d: -f2)
# REVISION 为空 → 但如果后续没做空值检查，就会误判成功
```

### 解决

```bash
# etcd >= 3.5 用 etcdutl
etcdutl snapshot status "$SNAPSHOT" -w table
etcdutl snapshot restore "$SNAPSHOT" --data-dir=/var/lib/etcd

# 脚本中做工具自动检测
if command -v etcdutl >/dev/null 2>&1; then
  STATUS=$(etcdutl snapshot status "$SNAPSHOT" -w json)
else
  STATUS=$(etcdctl snapshot status "$SNAPSHOT" -w json)   # etcd < 3.5
fi

# 必须检查输出内容，而不是只看退出码
REVISION=$(echo "$STATUS" | grep -o '"revision":[0-9]*' | cut -d: -f2)
[[ -z "$REVISION" || "$REVISION" -eq 0 ]] && { echo "校验失败"; rm -f "$SNAPSHOT"; exit 1; }
```

### 生产启示

> **"没报错" ≠ "执行成功"。**
>
> 校验类脚本必须检查**输出内容是否符合预期**，不能只信退出码。
> 这个原则适用于所有"验证"环节：备份校验、健康检查、部署验证。

---

## 坑 03 · etcd 官方镜像是 distroless，没有 shell

| 项 | 内容 |
|---|---|
| **发生场景** | 从容器里提取 etcdctl |
| **严重度** | 低 —— 换个方法就解决 |

### 现象

```bash
$ docker exec k8s_etcd_xxx sh -c 'command -v etcdctl'
OCI runtime exec failed: exec failed: unable to start container process:
exec: "sh": executable file not found in $PATH
```

### 根因

etcd 官方镜像基于 **distroless** 构建 —— 只包含应用二进制和必要库，
**没有 shell、没有包管理器、没有常用命令**。这是安全最佳实践（攻击面最小）。

### 解决

```bash
# 方法 1：直接 exec 二进制（不需要 shell）
docker exec k8s_etcd_xxx /usr/local/bin/etcdctl version

# 方法 2：docker cp 提取到宿主机（docker cp 不依赖容器内 shell）
docker cp k8s_etcd_xxx:/usr/local/bin/etcdctl /usr/local/bin/etcdctl
docker cp k8s_etcd_xxx:/usr/local/bin/etcdutl  /usr/local/bin/etcdutl
chmod +x /usr/local/bin/etcdctl /usr/local/bin/etcdutl
```

### 生产启示

> distroless 是**正确**的镜像实践（我们自己的 Exporter 项目也用了 distroless）。
> 但要提前准备好排障手段：
> - 构建一个带 shell 的 `:debug` 变体镜像
> - 或用 `kubectl debug` 注入临时容器
> - 涉及工具的运维脚本要能在"无 shell 容器"下工作

---

## 坑 04 · kube-proxy iptables 规则陈旧，导致 Calico CNI 失效

| 项 | 内容 |
|---|---|
| **发生场景** | etcd 恢复后创建新 Pod |
| **严重度** | 高 —— 整个集群无法创建新 Pod |
| **关联** | 这是 **坑 01 的连锁反应** |

### 现象

```bash
$ kubectl run test --image=...
# Pod 卡在 ContainerCreating

$ kubectl describe pod test
Warning  FailedCreatePodSandBox:
  Failed to create pod sandbox: rpc error: 
  networkPlugin cni failed to set up pod network: 
  plugin type="calico" failed (add): 
  error getting ClusterInformation: 
  Get "https://10.0.0.1:443/apis/crd.projectcalico.org/v1/clusterinformations/default": 
  dial tcp 10.0.0.1:443: connect: connection refused
```

**连锁现象**：
- 命名空间删除卡在 `Terminating`，报 `ContentDeletionFailed: unexpected items still remain ... Resource=pods`
- Deployment 的 ReplicaSet 显示 `DESIRED=4 CURRENT=0`（无法创建 Pod）

### 排查过程

```bash
# 1. 分层定位：apiserver 本身通不通？
$ curl -k https://192.168.16.11:6443/healthz     # → HTTP 200 
$ curl -k https://10.0.0.1:443/healthz           # → 失败 
# 结论：apiserver 没问题，是 Service IP 的转发有问题

# 2. Calico 为什么用 10.0.0.1？
$ cat /etc/cni/net.d/calico-kubeconfig | grep server
  server: https://10.0.0.1:443     # ← CNI 插件通过 Service IP 访问 apiserver

# 3. 查 kube-proxy 的 iptables 规则
$ iptables -t nat -S KUBE-SERVICES
  -N KUBE-SERVICES
  -A KUBE-SERVICES -d 10.0.0.10/32 ... kube-dns          # 只有 kube-dns
  -A KUBE-SERVICES -d 10.0.0.10/32 ... kube-dns:dns-tcp
  -A KUBE-SERVICES -d 10.0.0.10/32 ... kube-dns:metrics
  -A KUBE-SERVICES ... -j KUBE-NODEPORTS
  # 没有 default/kubernetes:https 的规则！
  # 连当时存在的 prod-app/web-svc 规则也没有

# 4. 对比 master 与 worker 的 kube-proxy 运行时长
$ kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
  kube-proxy-xc7t2   master   17 (36m ago)     # 重启过（我们修 etcd 时）
  kube-proxy-l6dpv   node01   15 (33d ago)     # 33 天没重启 
  kube-proxy-zpt96   node02   15 (33d ago)     # 33 天没重启 
```

### 根因

**kube-proxy 的 iptables 规则处于陈旧/不完整状态** —— 它的 `KUBE-SERVICES` 链里
缺少部分 Service 的 DNAT 规则（包括 `kubernetes` 这个最关键的）。

推测触发链路：
1. 坑 01 中强制 `docker stop` 了 master 上所有 k8s 容器
2. 静态 Pod 重建时，kube-proxy 与 apiserver 的 informer 建立过程中出现了状态不一致
3. kube-proxy 的 iptables 规则在部分同步的状态下固化下来

**结果**：Calico CNI 无法通过 `10.0.0.1:443` 访问 apiserver → 新 Pod 分配不到 IP

### 解决

```bash
kubectl -n kube-system rollout restart ds kube-proxy
kubectl -n kube-system rollout status ds/kube-proxy
```

重启后规则重建，验证：

```bash
$ iptables -t nat -S KUBE-SERVICES | grep '10\.0\.0\.1/32'
  -A KUBE-SERVICES -d 10.0.0.1/32 -p tcp \
     --comment "default/kubernetes:https cluster IP" --dport 443 \
     -j KUBE-SVC-NPX46M4PTMTKRN6Y      # 回来了

$ kubectl run cni-test --image=... ; kubectl get pods -o wide
  cni-test   1/1  Running  10.244.85.226  k8s-node01   # 拿到 IP
```

### 生产启示

> **CRI 的强制重启会牵连 kube-proxy 的规则状态。**
>
> 在生产环境做 etcd 恢复或 CRI 迁移时，恢复流程的最后一步应该包含：
> 1. **重启 kube-proxy**（或验证 `KUBE-SERVICES` 链完整）
> 2. **重启 CNI DaemonSet**（calico-node / cilium）
> 3. **创建一个测试 Pod 验证 CNI 正常**
>
> 否则会出现"集群看起来正常、但无法创建新 Pod"的隐性故障。

---

## 坑 05 · 诊断命令写错，导致误判（自我复盘）

| 项 | 内容 |
|---|---|
| **发生场景** | 排查坑 04 的过程中 |
| **严重度** | 低（但浪费了约 15 分钟） |

### 现象

我用这条命令判断"有没有 kubernetes Service 的规则"：

```bash
iptables -t nat -S KUBE-SERVICES | grep -cF '10.0.0.1 '
# 返回 0 → 我以为规则不存在
```

但实际规则长这样：

```
-A KUBE-SERVICES -d 10.0.0.1/32 -p tcp ...
                          ^^^^ 是 /32，后面没有空格！
```

**`grep -F '10.0.0.1 '`（带尾空格）永远匹配不到 `10.0.0.1/32`。**

### 教训

> **诊断工具本身也会骗人。**
>
> 得出"某个东西不存在"的结论前，先用一个**已知存在**的样本验证你的检查命令。
> 例如：`grep -cF '10.0.0.10 '` 应该匹配到 kube-dns，
> 如果连这个都返回 0，说明是命令写错了，而不是"东西不存在"。

**这个坑让我在错误的假设上多花了 15 分钟**，值得记录下来提醒自己。

---

## 坑 06 · 命名空间卡在 Terminating 无法删除

| 项 | 内容 |
|---|---|
| **发生场景** | 坑 04 的连锁现象 |
| **严重度** | 中 |

### 现象

```bash
$ kubectl delete ns drill-ns
# 卡住，长时间处于 Terminating

$ kubectl get ns drill-ns -o jsonpath='{.status.conditions}'
NamespaceDeletionContentFailure=True
Reason: ContentDeletionFailed
Message: Failed to delete all resource types, 1 remaining:
         unexpected items still remain in namespace: drill-ns for gvr: /v1, Resource=pods
```

Pod 状态为 `Pending` 且带 `deletionTimestamp`，但**没有 finalizer** —— 删不掉。

### 根因

Pod 从未成功启动（CNI 分配 IP 失败，见坑 04），
但 sandbox 容器已经创建了一部分。kubelet 尝试清理时又因为 Calico 不可用而失败，
Pod 卡在"已标记删除但无法真正终止"的状态。命名空间控制器因此无法完成清理。

### 解决

```bash
# 1. 强制删除卡住的 Pod
kubectl -n <ns> get pods -o name | xargs -r kubectl -n <ns> delete --force --grace-period=0

# 2. 如果命名空间仍卡住，清掉它的 finalizer
kubectl get ns <ns> -o json | \
  python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; json.dump(d,sys.stdout)" | \
  kubectl replace --raw /api/v1/namespaces/<ns>/finalize -f -
```

### 生产启示

> **命名空间删除卡住，本质上是"有资源删除失败"的信号**，
> 不要第一反应就去清 finalizer —— 那只是掩盖问题。
> 先搞清楚**哪个资源删不掉、为什么删不掉**，根因解决了，命名空间自然就删掉了。

---

## 坑 07 · `docker stop` 提示 "triggering units are still active"

| 项 | 内容 |
|---|---|
| **发生场景** | 模拟节点硬故障时 |
| **严重度** | 无害，但需理解 |

### 现象

```bash
$ systemctl stop docker
Stopping 'docker.service', but its triggering units are still active:
docker.socket
```

### 根因

`docker.socket` 是 systemd socket 激活单元。停止 `docker.service` 后，
socket 仍然监听，**下一次有连接访问时会自动重新拉起 docker.service**。

### 解决

模拟完全宕机时要一起停掉：

```bash
systemctl stop kubelet cri-docker docker.socket docker
```

### 生产启示

> 用 systemd socket 激活的服务（docker、部分数据库、某些代理）
> 停服务时要连 socket 一起停，否则会"停不干净"。

---

## 汇总：本项目的坑清单

| # | 坑 | 严重度 | 类型 |
|---|---|---|---|
| 01 | `systemctl stop kubelet` 不停止容器 | | etcd 恢复 |
| 02 | etcd 3.6 移除 `etcdctl snapshot status`（不报错） | | 版本兼容 |
| 03 | etcd 镜像 distroless 无 shell | | 容器镜像 |
| 04 | kube-proxy iptables 陈旧 → CNI 失效 | | 网络 |
| 05 | 诊断命令 grep 模式写错导致误判 | | 方法论 |
| 06 | 命名空间卡 Terminating | | K8s 对象 |
| 07 | docker.socket 导致服务停不干净 | | systemd |

---

## 通用排查原则（从上述坑中提炼）

1. **分层验证**：网络不通时，先确认"目标服务本身是否可达"，再排查"转发/解析/策略"
   （坑 04：先测 `192.168.16.11:6443` 通，再测 `10.0.0.1:443` 不通 → 定位到转发层）

2. **看时间戳而不是看状态**：`docker ps` 的 `Up 49 minutes` 比 `systemctl is-active`
   更能说明问题（坑 01）

3. **"没报错" ≠ "成功"**：校验脚本必须检查输出内容（坑 02）

4. **先验证你的诊断工具**：用已知存在的样本测试你的检查命令（坑 05）

5. **连锁反应意识**：一个组件的异常会以完全不同的现象出现在另一个组件上
   （坑 01 → 坑 04 → 坑 06）
