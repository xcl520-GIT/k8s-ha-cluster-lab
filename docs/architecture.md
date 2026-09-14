# 集群架构与设计决策

> 本文档记录这套 Kubernetes 三节点集群的**真实架构**与**每一项设计决策的理由**。
> 所有数据来自 `scripts/audit-cluster.sh` 的实测输出（2026-09-13）。

---

## 一、集群拓扑

```
                     192.168.16.0/24  (VMware VMnet8 NAT)
                     网关/DHCP: 192.168.16.2

   ┌─────────────────────┐   ┌─────────────────────┐   ┌─────────────────────┐
   │   k8s-master01      │   │    k8s-node01       │   │    k8s-node02       │
   │   192.168.16.11     │   │   192.168.16.12     │   │   192.168.16.13     │
   │   Rocky Linux 10.2  │   │   Rocky Linux 10.2  │   │   Rocky Linux 10.2  │
   │   4C / 3.5G / 45G   │   │   4C / 3.5G / 45G   │   │   4C / 3.5G / 45G   │
   │   ROLES: control-plane │  │   ROLES: <none>     │   │   ROLES: <none>     │
   ├─────────────────────┤   ├─────────────────────┤   ├─────────────────────┤
   │ kube-apiserver      │   │ kubelet             │   │ kubelet             │
   │ kube-scheduler      │   │ kube-proxy          │   │ kube-proxy          │
   │ kube-controller-mgr │   │ cri-dockerd         │   │ cri-dockerd         │
   │ etcd  (static Pod)  │   │ calico-node         │   │ calico-node         │
   │ kubelet             │   │                     │   │                     │
   │ kube-proxy          │   │                     │   │                     │
   │ cri-dockerd         │   │                     │   │                     │
   │ calico-node         │   │                     │   │                     │
   └─────────────────────┘   └─────────────────────┘   └─────────────────────┘
        │  污点:                     │                          │
        │  node-role.kubernetes.io/  │                          │
        │  control-plane:NoSchedule  │                          │
        └────────────────────────────┴──────────────────────────┘
                Calico IPIP (Always) · Pod 网段 10.244.0.0/16
```

---

## 二、版本与参数清单（实测）

### 核心组件

| 组件 | 版本 | 备注 |
|---|---|---|
| Kubernetes | **v1.34.10**（kubelet/kubeadm/kubectl） | Server 侧 `kubeadm-config` 记录为 v1.34.3 |
| 容器运行时 | **cri-dockerd 0.4.4 + Docker 29.6.2** | 见下方"已知短板" |
| containerd | v2.2.6（`containerd.io` 包，供 Docker 使用） | 未作为 kubelet 的 CRI |
| CNI | **Calico v3.25.0** | `docker.io/calico/node:v3.25.0` |
| CoreDNS | v1.12.1 | 2 副本 |
| etcd | v3.6.5（存储格式 3.6.0） | 单节点 |
| pause 镜像 | `registry.aliyuncs.com/google_containers/pause:3.10.1` | |

### 网络参数

| 参数 | 值 |
|---|---|
| Pod CIDR | `10.244.0.0/16` |
| Service CIDR | `10.10.0.0/12` |
| ClusterDNS | `10.0.0.10`（Service 网段内） |
| kubernetes Service | `10.0.0.1:443` |
| DNS 域名 | `cluster.local` |
| kube-proxy 模式 | iptables（`mode: ""` 即默认） |
| Calico 封装 | **IPIP，`ipipMode: Always`** |
| `natOutgoing` | `true` |
| IPIP MTU | 1480（1500 − 20 IPIP 头） |

### kubelet 关键配置

| 参数 | 值 | 说明 |
|---|---|---|
| `cgroupDriver` | **`systemd`** | 与 containerd/cri-dockerd 必须一致 |
| `cgroup 版本` | **v2**（`cgroup2fs`） | 现代内核默认 |
| `containerRuntimeEndpoint` | `unix:///var/run/cri-dockerd.sock` | |
| `rotateCertificates` | `true` | 客户端证书自动轮换 |
| `authorization.mode` | `Webhook` | |
| `authentication.anonymous.enabled` | `false` | 关闭匿名访问 |

### 证书有效期

| 证书 | 到期时间 | 剩余 |
|---|---|---|
| 全部组件证书（11 张） | 2027-07-26 | 316 天 |
| CA 证书（ca / etcd-ca / front-proxy-ca） | 2036-07-23 | 9 年 |

> 证书有效期由 `certificateValidityPeriod: 8760h`（1 年）决定，
> `caCertificateValidityPeriod: 87600h`（10 年）。

---

## 三、设计决策与理由

### 决策 1：Calico 采用 IPIP 模式（`ipipMode: Always`）

**为什么**：本集群跑在 VMware NAT（VMnet8）网络里。Calico 的纯 BGP 模式要求节点间能直接交换 BGP 路由，而 **NAT 网络不做 BGP 转发**，BGP 邻居建立不起来。IPIP 通过把 Pod 包封装成 IP 包解决跨网段寻址，在 NAT 环境下最稳。

**代价**：多 20 字节封装头，MTU 从 1500 降到 1480，有轻微性能损耗。

**对比**：

| 模式 | 适用 | 本环境 |
|---|---|---|
| BGP（无封装） | 物理网络/L2 直连，性能最好 | NAT 下建不起邻居 |
| **IPIP** | 跨网段、NAT、云环境 | 已验证可用 |
| VXLAN | 大二层、需要隧道 | 可用但开销更大 |

### 决策 2：Service CIDR 用 `10.10.0.0/12`

**为什么**：与 Pod 网段 `10.244.0.0/16`、Docker 默认网桥 `172.17.0.0/16`、VMware 宿主网段 `192.168.16.0/24` **完全不重叠**。

**这是很容易被忽视但很关键的一点** —— 网段重叠会导致：
- Pod 无法访问同网段的外部服务
- Service IP 与真实主机 IP 冲突
- 路由表出现歧义条目

**检查过的四个网段**：

| 用途 | 网段 | 冲突？ |
|---|---|---|
| 宿主机/管理网 | 192.168.16.0/24 | 无 |
| Pod | 10.244.0.0/16 | 无 |
| Service | 10.10.0.0/12 | 无 |
| Docker 默认网桥 | 172.17.0.0/16 | 无 |

### 决策 3：kubelet `cgroupDriver: systemd`

**为什么**：Linux 上用 systemd 管理服务时，systemd 自己也在管理 cgroup。如果 kubelet 用 `cgroupfs`，就会出现**两个 cgroup 管理器**同时操作同一棵 cgroup 树，导致资源限制失效、Pod 状态混乱。

**这是新手最高频的坑之一**，本集群配置正确 。

### 决策 4：NFS 存储用 `WaitForFirstConsumer`

```yaml
nfs-storage-class:
  provisioner: kubernetes.io/no-provisioner
  reclaimPolicy: Retain
  volumeBindingMode: WaitForFirstConsumer   # ← 关键
```

**为什么用 `WaitForFirstConsumer`**：本地/NFS 这类卷有节点亲和性（只能在特定节点挂载）。如果提前绑定（`Immediate`），PVC 可能在 A 节点绑定，而 Pod 被调度到 B 节点，于是 Pod 永远起不来（`volume node affinity conflict`）。

`WaitForFirstConsumer` 让**绑定推迟到 Pod 调度时**，先确定 Pod 落在哪个节点，再绑对应节点的卷。

**为什么用 `Retain`**：删除 PVC 时不自动删底层存储数据，避免误操作丢数据。代价是需要人工清理。

### 决策 5（已知短板）：CRI 使用 cri-dockerd

```
kubelet → cri-dockerd (0.4.4) → dockerd (29.6.2) → containerd (2.2.6) → runc
```

**现状**：Kubernetes 1.24 起**移除了内置的 dockershim**，kubelet 无法直接对接 Docker。本集群通过安装社区方案 **cri-dockerd** 来实现 CRI 对接。

**为什么这是短板**：
1. **多一层转发**：kubelet → cri-dockerd → dockerd → containerd，相比「kubelet → containerd」多两次进程间调用，资源占用和延迟都更高
2. **非上游维护**：cri-dockerd 由 Mirantis 维护，不在 Kubernetes 官方支持路径上
3. **生产已淘汰**：主流发行版（RKE2、kubeadm 官方文档、各大云厂商托管 K8s）都默认或只支持 containerd / CRI-O

**处置**：已在线迁移到 containerd。迁移过程中的几个关键点（docker 与 containerd 的镜像
存储互相独立、停 daemon 不会杀掉容器、静态 Pod 需要 manifest 变化才重建）记在
`scripts/drills/07-cri-migrate.sh` 的注释里。

### 其他值得记录的取值

| 项 | 值 | 评价 |
|---|---|---|
| `vm.swappiness` | **60**（默认值） | K8s 节点建议 0-1，已调整为 1 并持久化 |
| Master 污点 | `node-role.kubernetes.io/control-plane:NoSchedule` | 正确，业务 Pod 不会落到 master |
| `imageRepository` | `registry.aliyuncs.com/google_containers` | 国内可用 |
| yum 源 | `mirrors.aliyun.com/kubernetes-new/core/stable/v1.34/rpm/` | 可用 |
| `reclaimPolicy` | Retain | 安全 |

---

## 四、资源容量与余量

| 节点 | CPU 请求 | 内存请求 | 内存上限 |
|---|---|---|---|
| k8s-master01 | 1100m (27%) | 240Mi (6%) | 340Mi (9%) |
| k8s-node01 | 250m (6%) | 0 (0%) | 0 (0%) |
| k8s-node02 | 250m (6%) | 0 (0%) | 0 (0%) |

**结论**：资源极其空闲，**足够承载 P2（监控栈）、P3（Argo CD）、P5（Exporter）的全部组件**。

但也暴露出问题：**worker 节点的业务 Pod 没有设置 requests/limits**（显示为 0）。这在生产上是隐患 —— 会导致调度失准、节点被撑爆。演练 4 会补上。

---

## 五、当前集群内的负载

| 命名空间 | 工作负载 | 镜像 | 来源 |
|---|---|---|---|
| default | `my-app` (Deployment) | `192.168.16.60/library/busybox:1.0` | 私有仓库 |
| default | `nginx-deployment` (Deployment) | `192.168.16.60/library/nginx:1.27.4` | 私有仓库 |
| default | `rc-demo` ×3 (ReplicationController) | `192.168.16.60/library/myapp:1.0` | 私有仓库 |
| default | `nfs-pvc` (PVC 10Gi RWX) | NFS | |
| kube-system | CoreDNS ×2、calico-node ×3、calico-kube-controllers、kube-proxy ×3、etcd、apiserver、controller-manager、scheduler | | |

> 这些是早期练习留下的负载，保留作为背景噪声，不影响后续演练。
> 私有仓库 `192.168.16.60` 当前未启动，因此这些 Pod 无法重建（镜像拉不到）。

---

## 六、审计发现的缺口清单

| # | 缺口 | 影响 | 计划处理 |
|---|---|---|---|
| 1 | 未安装 **metrics-server**，`kubectl top` 不可用 | HPA 无法工作、无法做资源可见性 | 演练 4 安装 |
| 2 | **无 etcd 备份机制**（无 crontab、无备份目录） | 数据丢失风险 | **演练 1** |
| 3 | **零 NetworkPolicy**，Pod 之间全通 | 无网络隔离，横向移动风险 | **演练 5** |
| 4 | `vm.swappiness = 60` | 内存回收判断可能失准 | 演练 3 调优 |
| 5 | worker 业务 Pod **无 requests/limits** | 调度失准、节点可能被撑爆 | 演练 4 |
| 6 | CRI 为 cri-dockerd | 技术栈落后于现代标准 | **演练 7** |
| 7 | 无 PDB（PodDisruptionBudget） | 节点维护时可能同时驱逐全部副本 | 演练 4 |
| 8 | 无 Ingress Controller | 无法对外暴露 HTTP 服务 | P3 时按需 |

---

## 七、参考命令

```bash
# 一键重新审计（生成完整报告）
bash scripts/audit-cluster.sh

# 集群健康验收
bash scripts/verify-cluster.sh

# 查看证书有效期
kubeadm certs check-expiration

# 查看 etcd 状态
kubectl -n kube-system exec etcd-k8s-master01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status -w table
```
