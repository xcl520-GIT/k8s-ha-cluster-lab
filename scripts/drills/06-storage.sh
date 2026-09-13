#!/bin/bash
# ============================================================
# P1-06  Storage: static PV/PVC, RWX sharing, dynamic provisioning,
#        StatefulSet volumeClaimTemplates, Retain policy, data tiering
# Target: k8s-master01.  ASCII only.  Idempotent.
# ============================================================
set -u
export KUBECONFIG=/etc/kubernetes/admin.conf
REPORT=/root/lab-reports/P1-06-storage.txt
mkdir -p /root/lab-reports
: > "$REPORT"
NS=storage-lab
NFS_SERVER=192.168.16.11
NFS_ROOT=/data/nfs
PROV_IMG=${PROV_IMG:-m.daocloud.io/registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2}
say()  { echo "$@" | tee -a "$REPORT"; }
step() { echo "" | tee -a "$REPORT"; echo "==================== $* ====================" | tee -a "$REPORT"; }

step "0. Preflight: NFS server + capacity"
exportfs -v 2>&1 | tee -a "$REPORT"
df -h "$NFS_ROOT" | tee -a "$REPORT"
kubectl get sc,pv 2>&1 | tee -a "$REPORT"
mkdir -p "$NFS_ROOT"/{pv-lab-static,pv-lab-reclaim,dynamic}
chmod 777 "$NFS_ROOT"/{pv-lab-static,pv-lab-reclaim,dynamic}
kubectl create ns $NS 2>/dev/null || true

# ============================================================
step "1. Static PV/PVC + data persistence across pod recreation  [LANDMARK A]"
cat <<YAML | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-lab-static
spec:
  capacity: {storage: 2Gi}
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-storage-class
  nfs: {server: $NFS_SERVER, path: $NFS_ROOT/pv-lab-static}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: pvc-lab-static, namespace: $NS}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs-storage-class
  resources: {requests: {storage: 2Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: writer, namespace: $NS}
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: ["sh","-c","echo \"written by \$(hostname) at \$(date -u +%FT%TZ)\" > /data/proof.txt; cat /data/proof.txt; sleep 3600"]
    volumeMounts: [{name: v, mountPath: /data}]
  volumes:
  - name: v
    persistentVolumeClaim: {claimName: pvc-lab-static}
YAML
kubectl -n $NS wait --for=condition=Ready pod/writer --timeout=120s 2>&1 | tee -a "$REPORT"
kubectl -n $NS get pv,pvc 2>&1 | tee -a "$REPORT"
say ""
say "--- writer wrote, now DESTROY the pod ---"
kubectl -n $NS logs writer 2>&1 | tee -a "$REPORT"
kubectl -n $NS delete pod writer --wait=true 2>&1 | tee -a "$REPORT"
cat <<YAML | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: v1
kind: Pod
metadata: {name: reader, namespace: $NS}
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: ["sh","-c","echo READBACK:; cat /data/proof.txt; ls -l /data; sleep 3600"]
    volumeMounts: [{name: v, mountPath: /data}]
  volumes:
  - name: v
    persistentVolumeClaim: {claimName: pvc-lab-static}
YAML
kubectl -n $NS wait --for=condition=Ready pod/reader --timeout=120s 2>&1 | tee -a "$REPORT"
sleep 4
say ""
say "--- [LANDMARK A] data survived pod deletion (new pod, same PVC) ---"
kubectl -n $NS logs reader 2>&1 | tee -a "$REPORT"
kubectl -n $NS exec reader -- cat /data/proof.txt 2>&1 | tee -a "$REPORT"

# ============================================================
step "2. RWX: two pods on DIFFERENT nodes share one volume  [LANDMARK B]"
cat <<YAML | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: v1
kind: PersistentVolume
metadata: {name: pv-lab-shared}
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-storage-class
  nfs: {server: $NFS_SERVER, path: $NFS_ROOT/pv-lab-shared}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: pvc-lab-shared, namespace: $NS}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs-storage-class
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: rwx-writer, namespace: $NS}
spec:
  nodeSelector: {kubernetes.io/hostname: k8s-node01}
  containers:
  - name: c
    image: busybox:1.36
    command: ["sh","-c","i=0; while true; do i=\$((i+1)); echo \"tick \$i from \$(hostname)\" >> /shared/log.txt; sleep 3; done"]
    volumeMounts: [{name: v, mountPath: /shared}]
  volumes:
  - name: v
    persistentVolumeClaim: {claimName: pvc-lab-shared}
---
apiVersion: v1
kind: Pod
metadata: {name: rwx-reader, namespace: $NS}
spec:
  nodeSelector: {kubernetes.io/hostname: k8s-node02}
  containers:
  - name: c
    image: busybox:1.36
    command: ["sh","-c","sleep 3600"]
    volumeMounts: [{name: v, mountPath: /shared}]
  volumes:
  - name: v
    persistentVolumeClaim: {claimName: pvc-lab-shared}
YAML
mkdir -p "$NFS_ROOT/pv-lab-shared"; chmod 777 "$NFS_ROOT/pv-lab-shared"
kubectl -n $NS wait --for=condition=Ready pod/rwx-writer pod/rwx-reader --timeout=150s 2>&1 | tee -a "$REPORT"
sleep 12
kubectl -n $NS get pods -o wide 2>&1 | tee -a "$REPORT"
say ""
say "--- [LANDMARK B] reader on node02 sees the writer's file from node01 ---"
kubectl -n $NS exec rwx-reader -- sh -c 'echo READER-NODE=$(hostname); echo ---; cat /shared/log.txt | tail -6' 2>&1 | tee -a "$REPORT"

# ============================================================
step "3. Dynamic provisioning: nfs-subdir-external-provisioner  [LANDMARK C]"
kubectl create ns nfs-provisioner 2>/dev/null || true
cat <<YAML | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: v1
kind: ServiceAccount
metadata: {name: nfs-client-provisioner, namespace: nfs-provisioner}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: nfs-client-provisioner-runner}
rules:
- apiGroups: [""]
  resources: [nodes]
  verbs: [get, list, watch]
- apiGroups: [""]
  resources: [persistentvolumes]
  verbs: [get, list, watch, create, delete]
- apiGroups: [""]
  resources: [persistentvolumeclaims]
  verbs: [get, list, watch, update]
- apiGroups: [storage.k8s.io]
  resources: [storageclasses]
  verbs: [get, list, watch]
- apiGroups: [""]
  resources: [events]
  verbs: [create, update, patch]
- apiGroups: [""]
  resources: [pods]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: run-nfs-client-provisioner}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: nfs-client-provisioner-runner}
subjects:
- {kind: ServiceAccount, name: nfs-client-provisioner, namespace: nfs-provisioner}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: leader-locking-nfs-client-provisioner, namespace: nfs-provisioner}
rules:
- apiGroups: [""]
  resources: [endpoints]
  verbs: [get, list, watch, create, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: leader-locking-nfs-client-provisioner, namespace: nfs-provisioner}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: leader-locking-nfs-client-provisioner}
subjects:
- {kind: ServiceAccount, name: nfs-client-provisioner, namespace: nfs-provisioner}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: nfs-client-provisioner, namespace: nfs-provisioner}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: nfs-client-provisioner}}
  template:
    metadata: {labels: {app: nfs-client-provisioner}}
    spec:
      serviceAccountName: nfs-client-provisioner
      containers:
      - name: nfs-client-provisioner
        image: $PROV_IMG
        imagePullPolicy: IfNotPresent
        env:
        - {name: PROVISIONER_NAME, value: k8s-sigs.io/nfs-subdir-external-provisioner}
        - {name: NFS_SERVER, value: "$NFS_SERVER"}
        - {name: NFS_PATH, value: "$NFS_ROOT/dynamic"}
        volumeMounts:
        - {name: nfs-client-root, mountPath: /persistentvolumes}
        resources:
          requests: {cpu: 50m, memory: 64Mi}
          limits: {cpu: 200m, memory: 128Mi}
      volumes:
      - name: nfs-client-root
        nfs: {server: $NFS_SERVER, path: $NFS_ROOT/dynamic}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-dynamic
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  archiveOnDelete: "true"
YAML
kubectl -n nfs-provisioner rollout status deploy/nfs-client-provisioner --timeout=180s 2>&1 | tee -a "$REPORT"
kubectl -n nfs-provisioner get pods -o wide 2>&1 | tee -a "$REPORT"
say ""
say "--- create a PVC with NO PV and NO explicit storageClass -> should self-provision ---"
cat <<YAML | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: pvc-auto, namespace: storage-lab}
spec:
  accessModes: [ReadWriteMany]
  resources: {requests: {storage: 1Gi}}
YAML
for i in $(seq 1 24); do
  ph=$(kubectl -n $NS get pvc pvc-auto -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$ph" = "Bound" ] && break
  sleep 5
done
say ""
say "--- [LANDMARK C] dynamically provisioned PV ---"
kubectl -n $NS get pvc pvc-auto 2>&1 | tee -a "$REPORT"
kubectl get pv 2>&1 | tee -a "$REPORT"
kubectl -n nfs-provisioner logs deploy/nfs-client-provisioner --tail=8 2>&1 | tee -a "$REPORT"
say ""
say "--- NFS side: the directory the provisioner created ---"
ls -ld "$NFS_ROOT"/dynamic/* 2>&1 | tee -a "$REPORT"
kubectl get sc 2>&1 | tee -a "$REPORT"

# ============================================================
step "4. StatefulSet volumeClaimTemplates - stable per-replica storage  [LANDMARK D]"
cat <<'YAML' | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: db-sim, namespace: storage-lab}
spec:
  serviceName: db-sim
  replicas: 3
  selector: {matchLabels: {app: db-sim}}
  template:
    metadata: {labels: {app: db-sim}}
    spec:
      containers:
      - name: c
        image: busybox:1.36
        command: ["sh","-c","echo \"replica=$(hostname) boot=$(date -u +%FT%TZ)\" >> /data/node.txt; sleep 3600"]
        volumeMounts: [{name: data, mountPath: /data}]
  volumeClaimTemplates:
  - metadata: {name: data}
    spec:
      accessModes: [ReadWriteMany]
      storageClassName: nfs-dynamic
      resources: {requests: {storage: 1Gi}}
YAML
kubectl -n $NS rollout status statefulset/db-sim --timeout=240s 2>&1 | tee -a "$REPORT"
kubectl -n $NS get pods -l app=db-sim -o wide 2>&1 | tee -a "$REPORT"
kubectl -n $NS get pvc 2>&1 | tee -a "$REPORT"
say ""
say "--- each replica has its own PVC + PV (1:1) ---"
kubectl get pv 2>&1 | tee -a "$REPORT"
say ""
say "--- restart db-sim-0: identity + data must follow the volume, not the pod ---"
kubectl -n $NS delete pod db-sim-0 --wait=true 2>&1 | tee -a "$REPORT"
kubectl -n $NS wait --for=condition=Ready pod/db-sim-0 --timeout=180s 2>&1 | tee -a "$REPORT"
sleep 4
say "[LANDMARK D] db-sim-0 volume content after pod recreation:"
kubectl -n $NS exec db-sim-0 -- cat /data/node.txt 2>&1 | tee -a "$REPORT"
for p in db-sim-0 db-sim-1 db-sim-2; do
  echo -n "$p -> " | tee -a "$REPORT"
  kubectl -n $NS exec $p -- sh -c 'ls /data; cat /data/node.txt' 2>&1 | tr '\n' ' ' | tee -a "$REPORT"
  echo "" | tee -a "$REPORT"
done

# ============================================================
step "5. Reclaim policy Retain: delete PVC, data must survive  [LANDMARK E]"
mkdir -p "$NFS_ROOT/pv-lab-reclaim"; chmod 777 "$NFS_ROOT/pv-lab-reclaim"
cat <<YAML | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: v1
kind: PersistentVolume
metadata: {name: pv-lab-reclaim}
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-storage-class
  nfs: {server: $NFS_SERVER, path: $NFS_ROOT/pv-lab-reclaim}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: pvc-lab-reclaim, namespace: storage-lab}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs-storage-class
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: reclaim-writer, namespace: storage-lab}
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: ["sh","-c","echo CRITICAL-BACKUP-PAYLOAD > /data/important.db; sync; sleep 3600"]
    volumeMounts: [{name: v, mountPath: /data}]
  volumes:
  - name: v
    persistentVolumeClaim: {claimName: pvc-lab-reclaim}
YAML
kubectl -n $NS wait --for=condition=Ready pod/reclaim-writer --timeout=120s 2>&1 | tee -a "$REPORT"
sleep 3
kubectl -n $NS delete pod reclaim-writer --wait=true 2>&1 | tee -a "$REPORT"
say "deleting the PVC ..."
kubectl -n $NS delete pvc pvc-lab-reclaim --wait=true 2>&1 | tee -a "$REPORT"
sleep 6
say ""
say "--- [LANDMARK E] PV is Released (NOT deleted), the payload is still on the NFS server ---"
kubectl get pv pv-lab-reclaim 2>&1 | tee -a "$REPORT"
say "payload still present under $NFS_ROOT/pv-lab-reclaim :"
cat "$NFS_ROOT/pv-lab-reclaim/important.db" 2>&1 | tee -a "$REPORT"
ls -l "$NFS_ROOT/pv-lab-reclaim" 2>&1 | tee -a "$REPORT"

# ============================================================
step "6. Data lifecycle automation: hot -> cold tiering CronJob  [LANDMARK F]"
cat <<'YAML' | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: pvc-lifecycle, namespace: storage-lab}
spec:
  accessModes: [ReadWriteMany]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: tier-script, namespace: storage-lab}
data:
  tier.sh: |
    #!/bin/sh
    # hot -> cold tiering with integrity check BEFORE delete
    set -e
    H=/data/hot; C=/data/cold; W=/data/warm
    mkdir -p "$H" "$C" "$W"
    n=0
    for f in $(find "$H" -maxdepth 1 -type f -mmin +0 2>/dev/null); do
      b=$(basename "$f")
      gzip -c "$f" > "$C/$b.gz"
      if gzip -t "$C/$b.gz" 2>/dev/null; then
        mv "$f" "$W/$b"
        n=$((n+1))
      fi
    done
    echo "run=$(date -u +%FT%TZ) tiered_files=$n"
    echo "hot=$(find "$H" -maxdepth 1 -type f | wc -l) warm=$(find "$W" -maxdepth 1 -type f | wc -l) cold=$(find "$C" -maxdepth 1 -type f | wc -l)"
    du -sh "$H" "$W" "$C" 2>/dev/null
---
apiVersion: batch/v1
kind: CronJob
metadata: {name: tiering, namespace: storage-lab}
spec:
  schedule: "*/2 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: tier
            image: busybox:1.36
            command: ["/bin/sh","/scripts/tier.sh"]
            volumeMounts:
            - {name: data, mountPath: /data}
            - {name: script, mountPath: /scripts}
          volumes:
          - name: data
            persistentVolumeClaim: {claimName: pvc-lifecycle}
          - name: script
            configMap: {name: tier-script, defaultMode: 0755}
YAML
say ""
say "--- seed 5 x 2MiB 'hot' files and age them by 10 minutes ---"
cat <<'YAML' | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: batch/v1
kind: Job
metadata: {name: seed-hot, namespace: storage-lab}
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: seed
        image: busybox:1.36
        command:
        - sh
        - -c
        - |
          mkdir -p /data/hot /data/warm /data/cold
          # NOTE: busybox touch does NOT support relative "-d '-10 minutes'";
          # use an absolute timestamp with -t so the files really look old.
          for i in 1 2 3 4 5; do
            yes "2026-09-13T00:00:00Z INFO svc=orders status=200 latency=42ms trace_id=abcdef" \
              | head -n 40000 > /data/hot/app-log-$i.log
            touch -t 202001010000 /data/hot/app-log-$i.log
          done
          echo "--- BEFORE tiering ---"
          ls -l /data/hot
          du -sh /data/hot /data/warm /data/cold
        volumeMounts: [{name: data, mountPath: /data}]
      volumes:
      - name: data
        persistentVolumeClaim: {claimName: pvc-lifecycle}
YAML
kubectl -n $NS wait --for=condition=Complete job/seed-hot --timeout=180s 2>&1 | tee -a "$REPORT"
kubectl -n $NS logs job/seed-hot 2>&1 | tee -a "$REPORT"
say ""
say "--- long-lived inspector pod used to look at the tiers ---"
kubectl -n $NS delete pod lc-inspect --ignore-not-found >/dev/null 2>&1
cat <<'YAML' | kubectl apply -f - 2>&1 | tee -a "$REPORT"
apiVersion: v1
kind: Pod
metadata: {name: lc-inspect, namespace: storage-lab}
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: ["sh","-c","sleep 3600"]
    volumeMounts: [{name: data, mountPath: /data}]
  volumes:
  - name: data
    persistentVolumeClaim: {claimName: pvc-lifecycle}
YAML
kubectl -n $NS wait --for=condition=Ready pod/lc-inspect --timeout=120s 2>&1 | tee -a "$REPORT"
say ""
say "--- trigger the tiering CronJob now ---"
kubectl -n $NS delete job tier-run-1 --ignore-not-found >/dev/null 2>&1
kubectl -n $NS create job --from=cronjob/tiering tier-run-1 2>&1 | tee -a "$REPORT"
kubectl -n $NS wait --for=condition=Complete job/tier-run-1 --timeout=180s 2>&1 | tee -a "$REPORT"
say ""
say "--- [LANDMARK F] tiering result: hot emptied, warm = originals, cold = gzip archives ---"
kubectl -n $NS logs job/tier-run-1 2>&1 | tee -a "$REPORT"
say ""
say "--- inspect the three tiers + gzip integrity (busybox gzip has no -l, so size is from ls) ---"
kubectl -n $NS exec lc-inspect -- sh -c '
  echo "hot  : $(find /data/hot  -maxdepth 1 -type f | wc -l) files"
  echo "warm : $(find /data/warm -maxdepth 1 -type f | wc -l) files"
  echo "cold : $(find /data/cold -maxdepth 1 -type f | wc -l) files"
  ls -l /data/hot /data/warm /data/cold
  du -sh /data/hot /data/warm /data/cold
  for f in /data/cold/*.gz; do gzip -t "$f" && echo "GZIP-OK $f"; done
' 2>&1 | tee -a "$REPORT"
kubectl -n $NS get cronjob 2>&1 | tee -a "$REPORT"

# ============================================================
step "7. Summary"
kubectl -n $NS get pvc 2>&1 | tee -a "$REPORT"
kubectl get pv 2>&1 | tee -a "$REPORT"
kubectl get sc 2>&1 | tee -a "$REPORT"
say "P1-06 complete."
echo "REPORT_FILE=$REPORT"
echo "=== P1-06 DONE ==="
