// =============================================================================
// lab-exporter - a zero-dependency Prometheus exporter for this k8s HA lab.
//
// WHY THIS EXISTS
//   node-exporter tells you about the MACHINE, kube-state-metrics tells you what
//   the CONTROL PLANE THINKS. Neither answers the questions that actually wake an
//   SRE up on this cluster:
//     * how long until the control-plane certificates expire?
//     * how stale is the newest etcd backup?
//     * is a workload silently stuck (deployment short of replicas, pod not
//       Running, PDB with zero allowed disruptions, PV stuck Released)?
//   Those are exactly the gaps found by scripts/audit-cluster.sh, so this
//   exporter closes them as first-class, alertable metrics.
//
// WHY NO EXTERNAL MODULES
//   It imports nothing outside the Go standard library, so it builds with plain
//   `go build` and no module proxy. That is deliberate: this lab has no reachable
//   GOPROXY and the original image registry (192.168.16.60) is decommissioned.
//
// ENDPOINTS
//   /metrics   Prometheus exposition format (text/plain; version=0.0.4)
//   /healthz   liveness / readiness
//   /          tiny landing page
// =============================================================================
package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	version            = "1.0.0"
	exporterName       = "lab-exporter"
	defaultListenAddr  = ":9101"
	serviceAccountPath = "/var/run/secrets/kubernetes.io/serviceaccount"
)

var (
	listenAddr = env("LISTEN_ADDR", defaultListenAddr)
	pkiDir     = env("PKI_DIR", "/host-pki")
	backupDir  = env("BACKUP_DIR", "/host-etcd-backups")
	k8sHost    = os.Getenv("KUBERNETES_SERVICE_HOST")
	k8sPort    = env("KUBERNETES_SERVICE_PORT", "443")
	tokenPath  = filepath.Join(serviceAccountPath, "token")
	caPath     = filepath.Join(serviceAccountPath, "ca.crt")
	httpClient *http.Client
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// -----------------------------------------------------------------------------
// minimal metric model
// -----------------------------------------------------------------------------

type sample struct {
	labels string // already rendered, e.g. `certificate="apiserver",path="x.crt"`
	value  float64
}

type metric struct {
	name    string
	help    string
	typ     string // gauge | counter
	samples []sample
}

type registry struct {
	metrics map[string]*metric
	order   []string
}

func newRegistry() *registry { return &registry{metrics: map[string]*metric{}} }

func (r *registry) add(name, help, typ string, s sample) {
	m, ok := r.metrics[name]
	if !ok {
		m = &metric{name: name, help: help, typ: typ}
		r.metrics[name] = m
		r.order = append(r.order, name)
	}
	m.samples = append(m.samples, s)
}

func (r *registry) render() string {
	sort.Strings(r.order)
	var b strings.Builder
	for _, name := range r.order {
		m := r.metrics[name]
		fmt.Fprintf(&b, "# HELP %s %s\n", m.name, m.help)
		fmt.Fprintf(&b, "# TYPE %s %s\n", m.name, m.typ)
		for _, s := range m.samples {
			if s.labels == "" {
				fmt.Fprintf(&b, "%s %s\n", m.name, formatFloat(s.value))
			} else {
				fmt.Fprintf(&b, "%s{%s} %s\n", m.name, s.labels, formatFloat(s.value))
			}
		}
	}
	return b.String()
}

func formatFloat(v float64) string {
	switch {
	case math.IsNaN(v):
		return "NaN"
	case math.IsInf(v, 1):
		return "+Inf"
	case math.IsInf(v, -1):
		return "-Inf"
	}
	return strconv.FormatFloat(v, 'g', -1, 64)
}

func lbl(pairs ...string) string {
	if len(pairs) == 0 {
		return ""
	}
	parts := make([]string, 0, len(pairs)/2)
	for i := 0; i+1 < len(pairs); i += 2 {
		parts = append(parts, fmt.Sprintf("%s=%s", pairs[i], strconv.Quote(pairs[i+1])))
	}
	return strings.Join(parts, ",")
}

// -----------------------------------------------------------------------------
// collector 1: control-plane certificate expiry
// -----------------------------------------------------------------------------

func collectCertificates(r *registry) {
	const (
		name = "lab_certificate_expiry_days"
		help = "Days remaining until a certificate under the mounted PKI directory expires. Negative means already expired."
	)
	found := 0
	_ = filepath.Walk(pkiDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil || info.IsDir() || !strings.HasSuffix(path, ".crt") {
			return nil
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		block, _ := pem.Decode(raw)
		if block == nil {
			return nil
		}
		crt, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(pkiDir, path)
		days := time.Until(crt.NotAfter).Hours() / 24
		r.add(name, help, "gauge", sample{
			labels: lbl("certificate", strings.TrimSuffix(filepath.Base(path), ".crt"), "path", rel),
			value:  days,
		})
		found++
		return nil
	})
	r.add("lab_certificate_expiring_within_30d",
		"Number of certificates that expire within 30 days.",
		"gauge", sample{value: float64(countBelow(r, name, 30))})
	r.add("lab_certificate_expiring_within_7d",
		"Number of certificates that expire within 7 days.",
		"gauge", sample{value: float64(countBelow(r, name, 7))})
	r.add("lab_certificates_tracked", "Number of certificates discovered under the PKI directory.",
		"gauge", sample{value: float64(found)})
}

func countBelow(r *registry, name string, limit float64) int {
	m, ok := r.metrics[name]
	if !ok {
		return 0
	}
	n := 0
	for _, s := range m.samples {
		if s.value < limit {
			n++
		}
	}
	return n
}

// -----------------------------------------------------------------------------
// collector 2: etcd backup freshness
// -----------------------------------------------------------------------------

func collectEtcdBackups(r *registry) {
	var (
		newest   time.Time
		count    int
		totalB   int64
		newestSz int64
		newestNm string
	)
	entries, err := os.ReadDir(backupDir)
	if err == nil {
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			name := e.Name()
			if !strings.HasSuffix(name, ".db") && !strings.HasSuffix(name, ".snapshot") {
				continue
			}
			info, err := e.Info()
			if err != nil {
				continue
			}
			count++
			totalB += info.Size()
			if info.ModTime().After(newest) {
				newest = info.ModTime()
				newestSz = info.Size()
				newestNm = name
			}
		}
	}

	age := math.NaN()
	if !newest.IsZero() {
		age = time.Since(newest).Seconds()
	}
	r.add("lab_etcd_backup_age_seconds",
		"Age in seconds of the most recent etcd snapshot. THIS is the metric to alert on.",
		"gauge", sample{value: age})
	r.add("lab_etcd_backup_count",
		"Number of etcd snapshots currently retained on the control-plane node.",
		"gauge", sample{value: float64(count)})
	r.add("lab_etcd_backup_total_bytes",
		"Combined size of all retained etcd snapshots.",
		"gauge", sample{value: float64(totalB)})
	r.add("lab_etcd_backup_newest_size_bytes",
		"Size of the most recent etcd snapshot.",
		"gauge", sample{labels: lbl("snapshot", newestNm), value: float64(newestSz)})
	r.add("lab_etcd_backup_configured",
		"1 when at least one etcd snapshot exists, 0 when the cluster has no recoverable backup.",
		"gauge", sample{value: boolToFloat(count > 0)})
}

func boolToFloat(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

// -----------------------------------------------------------------------------
// collector 3: cluster health through the Kubernetes API
// -----------------------------------------------------------------------------

func init() {
	ca, err := os.ReadFile(caPath)
	if err != nil {
		log.Printf("warning: cannot read %s: %v", caPath, err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(ca)
	httpClient = &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
		},
	}
}

func apiGet(path string, out interface{}) error {
	if k8sHost == "" {
		return fmt.Errorf("KUBERNETES_SERVICE_HOST not set (not running in-cluster?)")
	}
	tok, err := os.ReadFile(tokenPath)
	if err != nil {
		return fmt.Errorf("read token: %w", err)
	}
	req, err := http.NewRequest(http.MethodGet, "https://"+k8sHost+":"+k8sPort+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(tok)))
	req.Header.Set("Accept", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("api %s returned %s", path, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

type objectMeta struct {
	Name      string            `json:"name"`
	Namespace string            `json:"namespace"`
	Labels    map[string]string `json:"labels"`
}

type nodeList struct {
	Items []struct {
		Metadata objectMeta `json:"metadata"`
		Status   struct {
			Conditions []struct {
				Type   string `json:"type"`
				Status string `json:"status"`
			} `json:"conditions"`
		} `json:"status"`
	} `json:"items"`
}

type podList struct {
	Items []struct {
		Metadata objectMeta `json:"metadata"`
		Status   struct {
			Phase             string `json:"phase"`
			ContainerStatuses []struct {
				RestartCount int32 `json:"restartCount"`
				Ready        bool  `json:"ready"`
			} `json:"containerStatuses"`
		} `json:"status"`
	} `json:"items"`
}

type deployList struct {
	Items []struct {
		Metadata objectMeta `json:"metadata"`
		Spec     struct {
			Replicas *int32 `json:"replicas"`
		} `json:"spec"`
		Status struct {
			AvailableReplicas int32 `json:"availableReplicas"`
			ReadyReplicas     int32 `json:"readyReplicas"`
		} `json:"status"`
	} `json:"items"`
}

type pdbList struct {
	Items []struct {
		Metadata objectMeta `json:"metadata"`
		Status   struct {
			DisruptionsAllowed int32 `json:"disruptionsAllowed"`
			CurrentHealthy     int32 `json:"currentHealthy"`
			DesiredHealthy     int32 `json:"desiredHealthy"`
		} `json:"status"`
	} `json:"items"`
}

type pvList struct {
	Items []struct {
		Metadata objectMeta `json:"metadata"`
		Status   struct {
			Phase string `json:"phase"`
		} `json:"status"`
	} `json:"items"`
}

func collectCluster(r *registry) error {
	// --- nodes -------------------------------------------------------------
	var nodes nodeList
	if err := apiGet("/api/v1/nodes", &nodes); err != nil {
		return fmt.Errorf("nodes: %w", err)
	}
	ready := 0
	for _, n := range nodes.Items {
		isReady := 0.0
		for _, c := range n.Status.Conditions {
			if c.Type == "Ready" {
				if c.Status == "True" {
					isReady = 1
					ready++
				}
			}
		}
		r.add("lab_node_ready", "1 when the node Ready condition is True.",
			"gauge", sample{labels: lbl("node", n.Metadata.Name), value: isReady})
	}
	r.add("lab_cluster_nodes_ready", "Number of nodes whose Ready condition is True.",
		"gauge", sample{value: float64(ready)})
	r.add("lab_cluster_nodes_total", "Total number of registered nodes.",
		"gauge", sample{value: float64(len(nodes.Items))})

	// --- pods --------------------------------------------------------------
	var pods podList
	if err := apiGet("/api/v1/pods", &pods); err != nil {
		return fmt.Errorf("pods: %w", err)
	}
	notRunning := map[string]int{}
	restarts := 0.0
	for _, p := range pods.Items {
		if p.Status.Phase != "Running" && p.Status.Phase != "Succeeded" {
			notRunning[p.Metadata.Namespace]++
		}
		for _, cs := range p.Status.ContainerStatuses {
			if cs.RestartCount > 0 {
				restarts += float64(cs.RestartCount)
			}
		}
	}
	r.add("lab_cluster_pods_total", "Total number of pods across all namespaces.",
		"gauge", sample{value: float64(len(pods.Items))})
	nsNames := make([]string, 0, len(notRunning))
	for ns := range notRunning {
		nsNames = append(nsNames, ns)
	}
	sort.Strings(nsNames)
	for _, ns := range nsNames {
		r.add("lab_namespace_pods_not_running",
			"Pods that are neither Running nor Succeeded, grouped by namespace.",
			"gauge", sample{labels: lbl("namespace", ns), value: float64(notRunning[ns])})
	}
	r.add("lab_cluster_pods_not_running",
		"Total pods that are neither Running nor Succeeded. Alert on this before a user does.",
		"gauge", sample{value: float64(sumInts(notRunning))})
	r.add("lab_cluster_container_restarts_total",
		"Sum of container restart counts observed in the current pod specs.",
		"gauge", sample{value: restarts})

	// --- deployments -------------------------------------------------------
	var deps deployList
	if err := apiGet("/apis/apps/v1/deployments", &deps); err != nil {
		return fmt.Errorf("deployments: %w", err)
	}
	mismatch := 0
	for _, d := range deps.Items {
		want := int32(1)
		if d.Spec.Replicas != nil {
			want = *d.Spec.Replicas
		}
		if d.Status.AvailableReplicas != want {
			mismatch++
			r.add("lab_deployment_replicas_mismatch",
				"1 when a deployment's available replicas differ from its desired replicas.",
				"gauge", sample{
					labels: lbl("namespace", d.Metadata.Namespace, "deployment", d.Metadata.Name),
					value:  1,
				})
		}
	}
	r.add("lab_deployments_total", "Total number of deployments.",
		"gauge", sample{value: float64(len(deps.Items))})
	r.add("lab_deployments_replicas_mismatch_total",
		"Deployments that cannot reach their desired replica count.",
		"gauge", sample{value: float64(mismatch)})

	// --- pod disruption budgets -------------------------------------------
	var pdbs pdbList
	if err := apiGet("/apis/policy/v1/poddisruptionbudgets", &pdbs); err != nil {
		return fmt.Errorf("pdbs: %w", err)
	}
	for _, p := range pdbs.Items {
		r.add("lab_pdb_allowed_disruptions",
			"Allowed voluntary disruptions for a PDB. 0 means a node drain will be REFUSED.",
			"gauge", sample{
				labels: lbl("namespace", p.Metadata.Namespace, "pdb", p.Metadata.Name),
				value:  float64(p.Status.DisruptionsAllowed),
			})
		r.add("lab_pdb_blocked",
			"1 when the PDB currently allows zero voluntary disruptions (maintenance deadlock).",
			"gauge", sample{
				labels: lbl("namespace", p.Metadata.Namespace, "pdb", p.Metadata.Name),
				value:  boolToFloat(p.Status.DisruptionsAllowed == 0),
			})
	}

	// --- persistent volumes -------------------------------------------------
	var pvs pvList
	if err := apiGet("/api/v1/persistentvolumes", &pvs); err != nil {
		return fmt.Errorf("persistentvolumes: %w", err)
	}
	released := 0
	for _, pv := range pvs.Items {
		if pv.Status.Phase == "Released" {
			released++
			r.add("lab_pv_released",
				"1 when a PV is Released, i.e. its PVC is gone but the data still exists under the Retain policy.",
				"gauge", sample{labels: lbl("persistentvolume", pv.Metadata.Name), value: 1})
		}
	}
	r.add("lab_pv_total", "Total persistent volumes.", "gauge", sample{value: float64(len(pvs.Items))})
	r.add("lab_pv_released_total", "Persistent volumes stuck in the Released phase.",
		"gauge", sample{value: float64(released)})

	// --- one aggregated health boolean for a wall display / SMS test -------
	// A Released PV is INFORMATIONAL, not unhealthy: under the Retain reclaim
	// policy it is the expected state after a PVC is deleted, and the data is
	// still safe on disk. Only stuck pods and replica mismatches make the
	// cluster unhealthy.
	// (Learned by actually running this on the lab: the P1-06 Retain demo left a
	//  Released PV behind and the first version of this metric therefore reported
	//  the whole cluster as unhealthy. A monitoring system that cries wolf on an
	//  expected state is worse than no monitoring.)
	unhealthy := sumInts(notRunning) + mismatch
	r.add("lab_cluster_healthy",
		"1 when no pod is stuck and no deployment is short of its desired replicas.",
		"gauge", sample{value: boolToFloat(unhealthy == 0)})
	return nil
}

func sumInts(m map[string]int) int {
	n := 0
	for _, v := range m {
		n += v
	}
	return n
}

// -----------------------------------------------------------------------------
// http plumbing
// -----------------------------------------------------------------------------

func metricsHandler(w http.ResponseWriter, req *http.Request) {
	start := time.Now()
	r := newRegistry()

	r.add("lab_exporter_build_info", "Build information for the lab-exporter.",
		"gauge", sample{labels: lbl("version", version, "exporter", exporterName), value: 1})

	collectCertificates(r)
	collectEtcdBackups(r)

	apiErr := 0.0
	if err := collectCluster(r); err != nil {
		apiErr = 1
		log.Printf("cluster collector failed: %v", err)
		r.add("lab_exporter_collector_error",
			"1 when a collector failed on this scrape. 1 on lab_exporter_cluster means the exporter is blind.",
			"gauge", sample{labels: lbl("collector", "cluster"), value: 1})
	} else {
		r.add("lab_exporter_collector_error",
			"1 when a collector failed on this scrape.",
			"gauge", sample{labels: lbl("collector", "cluster"), value: 0})
	}
	r.add("lab_exporter_up", "1 when the exporter itself is alive.", "gauge", sample{value: 1})
	r.add("lab_exporter_scrape_duration_seconds", "Time this scrape took.",
		"gauge", sample{value: time.Since(start).Seconds()})

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = w.Write([]byte(r.render()))
	_ = apiErr
}

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}

func rootHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<html><head><title>%s</title></head><body>
<h1>%s v%s</h1>
<p>Zero-dependency Prometheus exporter for the k8s HA lab.</p>
<ul>
<li><a href="/metrics">/metrics</a> &mdash; Prometheus exposition</li>
<li><a href="/healthz">/healthz</a> &mdash; health probe</li>
</ul>
<p>Watching: PKI dir <code>%s</code>, etcd backups <code>%s</code>, kube-apiserver <code>%s:%s</code></p>
</body></html>`, exporterName, exporterName, version, pkiDir, backupDir, k8sHost, k8sPort)
}

func main() {
	log.Printf("%s v%s starting on %s (pki=%s backups=%s)", exporterName, version, listenAddr, pkiDir, backupDir)
	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", metricsHandler)
	mux.HandleFunc("/healthz", healthHandler)
	mux.HandleFunc("/", rootHandler)
	srv := &http.Server{
		Addr:              listenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("server stopped: %v", err)
	}
}
