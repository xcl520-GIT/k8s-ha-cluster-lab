#!/bin/bash
# ============================================================
# P1-04  Scheduling drills + metrics-server + ResourceQuota/PDB
# Target: k8s-master01.  ASCII only.  Idempotent.
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf
REPORT=/root/lab-reports/P1-04-scheduling-metrics-quota.txt
mkdir -p /root/lab-reports
: > "$REPORT"
MSG_IMG="${MS_IMAGE:-registry.aliyuncs.com/google_containers/metrics-server:v0.7.2}"
say()  { echo "$@" | tee -a "$REPORT"; }
step() { echo "" | tee -a "$REPORT"; echo "==================== $* ====================" | tee -a "$REPORT"; }

step "0. Preflight"
kubectl get nodes -o wide | tee -a "$REPORT"
kubectl get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints[*].key' | tee -a "$REPORT"
say "metrics-server image = $MSG_IMG"

# ============================================================
step "1. Install metrics-server v0.7.2"
sed -e "s|__MSG_IMG__|$MSG_IMG|" > /tmp/metrics-server.yaml <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  labels: {k8s-app: metrics-server}
  name: metrics-server
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    k8s-app: metrics-server
    rbac.authorization.k8s.io/aggregate-to-admin: "true"
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
    rbac.authorization.k8s.io/aggregate-to-view: "true"
  name: system:aggregated-metrics-reader
rules:
- apiGroups: [metrics.k8s.io]
  resources: [pods, nodes]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels: {k8s-app: metrics-server}
  name: system:metrics-server
rules:
- apiGroups: [""]
  resources: [nodes/metrics]
  verbs: [get]
- apiGroups: [""]
  resources: [pods, nodes]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels: {k8s-app: metrics-server}
  name: metrics-server-auth-reader
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: extension-apiserver-authentication-reader
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels: {k8s-app: metrics-server}
  name: metrics-server:system:auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels: {k8s-app: metrics-server}
  name: system:metrics-server
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:metrics-server
subjects:
- kind: ServiceAccount
  name: metrics-server
  namespace: kube-system
---
apiVersion: v1
kind: Service
metadata:
  labels: {k8s-app: metrics-server}
  name: metrics-server
  namespace: kube-system
spec:
  ports:
  - name: https
    port: 443
    protocol: TCP
    targetPort: https
  selector:
    k8s-app: metrics-server
---
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  labels: {k8s-app: metrics-server}
  name: v1beta1.metrics.k8s.io
spec:
  group: metrics.k8s.io
  groupPriorityMinimum: 100
  insecureSkipTLSVerify: true
  service:
    name: metrics-server
    namespace: kube-system
  version: v1beta1
  versionPriority: 100
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels: {k8s-app: metrics-server}
  name: metrics-server
  namespace: kube-system
spec:
  selector:
    matchLabels: {k8s-app: metrics-server}
  strategy:
    rollingUpdate: {maxUnavailable: 1}
  template:
    metadata:
      labels: {k8s-app: metrics-server}
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels: {k8s-app: metrics-server}
              topologyKey: kubernetes.io/hostname
      containers:
      - args:
        - --cert-dir=/tmp
        - --secure-port=10250
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --kubelet-use-node-status-port
        - --metric-resolution=15s
        - --kubelet-insecure-tls
        image: __MSG_IMG__
        imagePullPolicy: IfNotPresent
        livenessProbe:
          failureThreshold: 3
          httpGet: {path: /livez, port: https, scheme: HTTPS}
          periodSeconds: 10
        name: metrics-server
        ports:
        - {containerPort: 10250, name: https, protocol: TCP}
        readinessProbe:
          failureThreshold: 3
          httpGet: {path: /readyz, port: https, scheme: HTTPS}
          initialDelaySeconds: 20
          periodSeconds: 10
        resources:
          requests: {cpu: 100m, memory: 200Mi}
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: [ALL]
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 1000
        volumeMounts:
        - {mountPath: /tmp, name: tmp-dir}
      nodeSelector:
        kubernetes.io/os: linux
      priorityClassName: system-cluster-critical
      serviceAccountName: metrics-server
      tolerations:
      - {key: CriticalAddonsOnly, operator: Exists}
      volumes:
      - emptyDir: {}
        name: tmp-dir
YAML
kubectl apply -f /tmp/metrics-server.yaml 2>&1 | tee -a "$REPORT"
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s 2>&1 | tee -a "$REPORT"
kubectl -n kube-system get pods -l k8s-app=metrics-server -o wide 2>&1 | tee -a "$REPORT"
kubectl -n kube-system logs -l k8s-app=metrics-server --tail=12 2>&1 | tee -a "$REPORT"

say ""
say "wait for the metrics API to start serving ..."
for i in $(seq 1 30); do kubectl top nodes >/dev/null 2>&1 && break; sleep 5; done
say "--- [LANDMARK 1] kubectl top nodes ---"
kubectl top nodes 2>&1 | tee -a "$REPORT"
say "--- [LANDMARK 1] kubectl top pods (top 10 by cpu) ---"
kubectl top pods -A --sort-by=cpu 2>&1 | head -12 | tee -a "$REPORT"
say "--- apiservice state ---"
kubectl get apiservice v1beta1.metrics.k8s.io 2>&1 | tee -a "$REPORT"

# ============================================================
step "2. Scheduling lab (nodeSelector / nodeAffinity / podAntiAffinity / taint+toleration)"
kubectl create ns sched-lab 2>/dev/null || true
kubectl -n sched-lab delete deploy --all >/dev/null 2>&1 || true
kubectl taint node k8s-node02 dedicated=db:NoSchedule- >/dev/null 2>&1 || true
sleep 3

cat <<'YAML' | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: apps/v1
kind: Deployment
metadata: {name: pin-node02, namespace: sched-lab}
spec:
  replicas: 2
  selector: {matchLabels: {app: pin-node02}}
  template:
    metadata: {labels: {app: pin-node02}}
    spec:
      nodeSelector: {kubernetes.io/hostname: k8s-node02}
      containers:
      - name: c
        image: nginx:1.27-alpine
        resources:
          requests: {cpu: 50m, memory: 32Mi}
          limits: {cpu: 200m, memory: 64Mi}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: aff-node01, namespace: sched-lab}
spec:
  replicas: 2
  selector: {matchLabels: {app: aff-node01}}
  template:
    metadata: {labels: {app: aff-node01}}
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - {key: kubernetes.io/hostname, operator: In, values: [k8s-node01]}
      containers:
      - name: c
        image: nginx:1.27-alpine
        resources:
          requests: {cpu: 50m, memory: 32Mi}
          limits: {cpu: 200m, memory: 64Mi}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: spread-app, namespace: sched-lab}
spec:
  replicas: 4
  selector: {matchLabels: {app: spread-app}}
  template:
    metadata: {labels: {app: spread-app}}
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels: {app: spread-app}
            topologyKey: kubernetes.io/hostname
      containers:
      - name: c
        image: nginx:1.27-alpine
        resources:
          requests: {cpu: 50m, memory: 32Mi}
          limits: {cpu: 200m, memory: 64Mi}
YAML
sleep 12
kubectl -n sched-lab get pods -o wide --sort-by=.spec.nodeName 2>&1 | tee -a "$REPORT"

say ""
say "--- taint node02 dedicated=db:NoSchedule, then compare tolerating vs non-tolerating pod ---"
kubectl taint node k8s-node02 dedicated=db:NoSchedule --overwrite 2>&1 | tee -a "$REPORT"
cat <<'YAML' | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: apps/v1
kind: Deployment
metadata: {name: tol-app, namespace: sched-lab}
spec:
  replicas: 1
  selector: {matchLabels: {app: tol-app}}
  template:
    metadata: {labels: {app: tol-app}}
    spec:
      nodeSelector: {kubernetes.io/hostname: k8s-node02}
      tolerations:
      - {key: dedicated, operator: Equal, value: db, effect: NoSchedule}
      containers:
      - name: c
        image: nginx:1.27-alpine
        resources:
          requests: {cpu: 50m, memory: 32Mi}
          limits: {cpu: 200m, memory: 64Mi}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: noperm, namespace: sched-lab}
spec:
  replicas: 1
  selector: {matchLabels: {app: noperm}}
  template:
    metadata: {labels: {app: noperm}}
    spec:
      nodeSelector: {kubernetes.io/hostname: k8s-node02}
      containers:
      - name: c
        image: nginx:1.27-alpine
        resources:
          requests: {cpu: 50m, memory: 32Mi}
          limits: {cpu: 200m, memory: 64Mi}
YAML
sleep 12
say ""
say "--- [LANDMARK 2] full placement matrix ---"
kubectl -n sched-lab get pods -o wide --sort-by=.spec.nodeName 2>&1 | tee -a "$REPORT"
say ""
say "--- why 'noperm' stays Pending ---"
kubectl -n sched-lab describe pod -l app=noperm 2>&1 | grep -E "taint|Events" -A2 | head -8 | tee -a "$REPORT"
kubectl -n sched-lab get events --field-selector reason=FailedScheduling 2>&1 | head -6 | tee -a "$REPORT"
say ""
say "--- remove the taint again: 'noperm' must flip Pending -> Running ---"
kubectl taint node k8s-node02 dedicated=db:NoSchedule- 2>&1 | tee -a "$REPORT"
sleep 12
kubectl -n sched-lab get pods -l app=noperm -o wide 2>&1 | tee -a "$REPORT"

# ============================================================
step "3. ResourceQuota + LimitRange"
kubectl create ns quota-lab 2>/dev/null || true
cat <<'YAML' | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: v1
kind: ResourceQuota
metadata: {name: team-quota, namespace: quota-lab}
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "10"
    count/deployments.apps: "5"
---
apiVersion: v1
kind: LimitRange
metadata: {name: default-limits, namespace: quota-lab}
spec:
  limits:
  - type: Container
    default: {cpu: 200m, memory: 256Mi}
    defaultRequest: {cpu: 100m, memory: 128Mi}
    max: {cpu: "1", memory: 1Gi}
YAML
kubectl -n quota-lab delete deploy auto fillup --ignore-not-found >/dev/null 2>&1
say ""
say "--- LimitRange auto-injects defaults into a deployment that declares no resources ---"
kubectl -n quota-lab create deployment auto --image=nginx:1.27-alpine >/dev/null 2>&1
sleep 8
kubectl -n quota-lab get pod -l app=auto -o jsonpath='{.items[0].spec.containers[0].resources}{"\n"}' 2>&1 | tee -a "$REPORT"

say ""
say "--- [LANDMARK 3] push past quota: 20 replicas x 500m/512Mi ---"
cat <<'YAML' | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: apps/v1
kind: Deployment
metadata: {name: fillup, namespace: quota-lab}
spec:
  replicas: 20
  selector: {matchLabels: {app: fillup}}
  template:
    metadata: {labels: {app: fillup}}
    spec:
      containers:
      - name: c
        image: nginx:1.27-alpine
        resources:
          requests: {cpu: 500m, memory: 512Mi}
          limits: {cpu: 500m, memory: 512Mi}
YAML
sleep 25
kubectl -n quota-lab describe quota team-quota 2>&1 | tee -a "$REPORT"
kubectl -n quota-lab get deploy,rs,pods 2>&1 | tee -a "$REPORT"
say ""
say "--- the rejection message ---"
kubectl -n quota-lab describe rs -l app=fillup 2>&1 | grep -i -m3 "exceeded quota\|forbidden" | tee -a "$REPORT"
kubectl -n quota-lab get events --field-selector reason=FailedCreate 2>&1 | head -4 | tee -a "$REPORT"

# ============================================================
step "4. PodDisruptionBudget blocks a voluntary disruption"
kubectl create ns pdb-lab 2>/dev/null || true
cat <<'YAML' | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: apps/v1
kind: Deployment
metadata: {name: ha-web, namespace: pdb-lab}
spec:
  replicas: 3
  selector: {matchLabels: {app: ha-web}}
  template:
    metadata: {labels: {app: ha-web}}
    spec:
      nodeSelector: {kubernetes.io/hostname: k8s-node02}
      containers:
      - name: c
        image: nginx:1.27-alpine
        resources:
          requests: {cpu: 50m, memory: 32Mi}
          limits: {cpu: 200m, memory: 64Mi}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: ha-web-pdb, namespace: pdb-lab}
spec:
  minAvailable: 3
  selector:
    matchLabels: {app: ha-web}
YAML
sleep 15
kubectl -n pdb-lab get pods -o wide 2>&1 | tee -a "$REPORT"
say ""
say "--- [LANDMARK 4] PDB status: ALLOWED DISRUPTIONS must be 0 ---"
kubectl -n pdb-lab get pdb ha-web-pdb 2>&1 | tee -a "$REPORT"
kubectl -n pdb-lab get pdb ha-web-pdb -o jsonpath='{.status}{"\n"}' 2>&1 | tee -a "$REPORT"
say ""
say "--- [LANDMARK 4] attempt drain of node02 -> must be REFUSED ---"
kubectl drain k8s-node02 --ignore-daemonsets --delete-emptydir-data --pod-selector='app=ha-web' --timeout=45s > /tmp/drain.log 2>&1
say "drain exit code = $?"
tail -6 /tmp/drain.log | tee -a "$REPORT"
say ""
say "--- node02 state after refusal (still cordoned, pods untouched) ---"
kubectl get node k8s-node02 2>&1 | tee -a "$REPORT"
kubectl -n pdb-lab get pods -o wide 2>&1 | tee -a "$REPORT"
say ""
say "--- [LANDMARK 4] raw Eviction subresource: the crisp PDB refusal ---"
victim=$(kubectl -n pdb-lab get pod -l app=ha-web -o jsonpath='{.items[0].metadata.name}')
say "victim pod = $victim"
printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"pdb-lab"}}' "$victim" > /tmp/evict.json
kubectl proxy --port=18001 --address=127.0.0.1 >/tmp/proxy.log 2>&1 &
PROXY_PID=$!
for i in $(seq 1 15); do curl -s -o /dev/null http://127.0.0.1:18001/version && break; sleep 1; done
curl -s -w '\nHTTP_STATUS=%{http_code}\n' -X POST \
  -H 'Content-Type: application/json' \
  --data @/tmp/evict.json \
  "http://127.0.0.1:18001/api/v1/namespaces/pdb-lab/pods/$victim/eviction" 2>&1 | tee -a "$REPORT"
kill $PROXY_PID 2>/dev/null
say ""
say "--- uncordon node02 ---"
kubectl uncordon k8s-node02 2>&1 | tee -a "$REPORT"
kubectl get nodes 2>&1 | tee -a "$REPORT"

# ============================================================
step "5. Cleanup"
kubectl -n quota-lab delete deploy fillup --ignore-not-found >/dev/null 2>&1
kubectl taint node k8s-node02 dedicated=db:NoSchedule- >/dev/null 2>&1 || true
kubectl get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints[*].key' 2>&1 | tee -a "$REPORT"
say "P1-04 complete."
echo "REPORT_FILE=$REPORT"
echo "=== P1-04 DONE ==="
