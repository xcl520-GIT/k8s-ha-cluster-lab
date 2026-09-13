# ============================================================
# k8s-ha-cluster-lab · Makefile
# 用法: make help
# ============================================================
SHELL := /bin/bash
.DEFAULT_GOAL := help

MASTER     ?= 192.168.16.11
KUBECONFIG ?= /etc/kubernetes/admin.conf
export KUBECONFIG

C_GREEN := \033[1;32m
C_CYAN  := \033[1;36m
C_YELL  := \033[1;33m
C_RESET := \033[0m

.PHONY: help
help: ## 显示所有可用命令
	@echo ""
	@echo "  $(C_CYAN)k8s-ha-cluster-lab$(C_RESET) —— 可用命令"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(C_GREEN)%-22s$(C_RESET) %s\n", $$1, $$2}'
	@echo ""

# ============================================================
# 审计与验收
# ============================================================
.PHONY: audit
audit: ## 集群现状全面审计（生成完整报告）
	@bash scripts/audit-cluster.sh

.PHONY: verify
verify: ## 集群健康快速检查
	@echo "=== 节点 ===" ; kubectl get nodes -o wide
	@echo ""; echo "=== 系统组件 ===" ; kubectl get pods -n kube-system
	@echo ""; echo "=== 业务负载 ===" ; kubectl get pods -A --field-selector=status.phase!=Running | head -20
	@echo ""; echo "=== 证书剩余 ===" ; kubeadm certs check-expiration 2>/dev/null | head -18
	@echo ""; echo "=== etcd 健康 ==="
	@etcdctl --endpoints=https://127.0.0.1:2379 \
	  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
	  --cert=/etc/kubernetes/pki/etcd/server.crt \
	  --key=/etc/kubernetes/pki/etcd/server.key \
	  endpoint health 2>/dev/null || echo "  (需在 master 执行，且已准备 etcdctl)"

.PHONY: nodes pods top
nodes: ## 查看节点
	@kubectl get nodes -o wide
pods: ## 查看所有 Pod
	@kubectl get pods -A -o wide
top: ## 查看资源使用（需 metrics-server）
	@kubectl top nodes 2>/dev/null || echo "⚠️  metrics-server 未安装，见演练 04"

# ============================================================
# etcd 备份
# ============================================================
.PHONY: check-etcd-tools backup
check-etcd-tools: ## 检查/准备 etcdctl 与 etcdutl
	@bash scripts/backup/00-check-etcdctl.sh

backup: ## 备份 etcd 快照（含校验与轮转）
	@bash scripts/backup/etcd-backup.sh

backup-list: ## 列出已有快照
	@ls -lh /var/backups/etcd/*.db 2>/dev/null | tail -20 || echo "无快照"

backup-status: ## 校验所有快照的完整性
	@for f in /var/backups/etcd/etcd-*.db; do \
	  [ -f "$$f" ] || continue; \
	  echo "--- $$f ---"; \
	  etcdutl snapshot status "$$f" -w table 2>/dev/null || \
	  etcdctl snapshot status "$$f" -w table 2>/dev/null; \
	done

# ============================================================
# 演练 01 · etcd 备份与灾难恢复
# ============================================================
.PHONY: drill-1-prepare drill-1-destroy drill-1-restore drill-1-verify drill-1 drill-1-status
drill-1-prepare: ## [演练01] 阶段1：造测试数据 + 备份
	@bash scripts/drills/01-etcd-drill.sh prepare
drill-1-destroy: ## [演练01] 阶段2：模拟误删（灾难）
	@bash scripts/drills/01-etcd-drill.sh destroy
drill-1-restore: ## [演练01] 阶段3：从快照恢复
	@bash scripts/drills/01-etcd-drill.sh restore
drill-1-verify: ## [演练01] 阶段4：验证恢复结果
	@bash scripts/drills/01-etcd-drill.sh verify
drill-1-status: ## [演练01] 查看当前状态
	@bash scripts/drills/01-etcd-drill.sh status

drill-1: ## [演练01] 一键完整演练（4 个阶段）
	@echo "$(C_YELL)⚠️  这会删除并恢复 prod-app 命名空间$(C_RESET)"
	@read -p "确认执行完整演练？(输入 yes) " a; [ "$$a" = "yes" ] || exit 1
	@$(MAKE) drill-1-prepare
	@$(MAKE) drill-1-destroy
	@$(MAKE) drill-1-restore
	@$(MAKE) drill-1-verify

# ============================================================
# 代码质量
# ============================================================
.PHONY: lint
lint: ## Shell 脚本语法检查
	@echo "=== bash -n 语法检查 ==="
	@fail=0; for f in scripts/*.sh scripts/*/*.sh; do \
	  [ -f "$$f" ] || continue; \
	  if bash -n "$$f" 2>/dev/null; then echo "  ✅ $$f"; else echo "  ❌ $$f"; fail=1; fi; \
	done; exit $$fail
	@echo "=== shellcheck（如已安装）==="
	@command -v shellcheck >/dev/null && shellcheck scripts/**/*.sh scripts/*.sh || echo "  (未安装 shellcheck，跳过)"

# ============================================================
# 危险操作
# ============================================================
.PHONY: reset-warning
reset-warning: ## 查看重置集群的命令（不会执行）
	@echo "$(C_YELL)重置集群（危险，仅供参考，请手工确认后执行）：$(C_RESET)"
	@echo "  sudo kubeadm reset -f"
	@echo "  sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet ~/.kube"
	@echo "  sudo systemctl restart cri-docker kubelet"
