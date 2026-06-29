# Day-23 Observability Stack on Kubernetes

Production-shaped port of the Day-23 Track-2 observability stack from
`docker-compose.yml` to a real Kubernetes cluster, plus AI/LLM serving
and agent workloads on top.

This is the **bonus / ungraded** assignment (`ADVANCED-K8S.md`). I
worked through Track A (port stack to k8s), Track B (LLM serving),
and Track C (agent workloads) end-to-end.

> **AI-assisted / vibe-coded**: manifests are mostly handwritten for
> legibility, but the iteration loop (edit → apply → wait → kubectl
> describe → fix) was tight and many of the operator-yaml specifics
> came from `kubectl explain <resource>.<field>` rather than hallucinating.
> See [`POSTMORTEM.md`](POSTMORTEM.md) for the actual bumps I hit.

---

## What's deployed

```
                         ┌─────────────────────────────────────┐
                         │       kind cluster (3 nodes)       │
                         │  control-plane + 2x workers        │
                         └────────────────┬────────────────────┘
                                          │
              ┌───────────────────────────┼───────────────────────────┐
              │                           │                           │
       namespace: monitoring        namespace: serving         namespace: agents
              │                           │                           │
   ┌──────────┴──────────────┐   ┌────────┴─────────┐       ┌────────┴─────────┐
   │  inference-api (D, 2r)  │   │  vllm-mock (D)   │       │ research-agent   │
   │                         │   │  + ServiceMon    │       │  Job / CronJob   │
   │  Prometheus  (SS, 1r)   │   │  + Ingress       │       └──────────────────┘
   │  + Grafana              │   │  + HPA on p95 ───┐
   │  + Loki (SS)            │   │                  │
   │  + Jaeger               │   │  prometheus-     │
   │  + OTel Collector (D)   │   │  adapter (D)     │
   │  + Alertmanager (SS)    │   └──────────────────┘
   │                         │
   │  kube-prometheus-stack  │
   │  (Prometheus Operator   │
   │   pattern)              │
   │  + Prometheus           │
   │  + Alertmanager         │
   │  + Grafana              │
   │  + kube-state-metrics   │
   │  + node-exporter        │
   │  + ServiceMonitors      │
   │  + PrometheusRule CRs   │
   │                         │
   │  opentelemetry-operator │
   │  + OpenTelemetryCollector gateway (D, 2r)
   │                         │
   │  Grafana Alloy (DS, 3p) │
   │  → ships pod logs to Loki
   │                         │
   │  cert-manager (n/a for ops, but OTel Operator needs it)
   └─────────────────────────┘
```

## Layers (matches `ADVANCED-K8S.md`)

| Layer | Path                                  | Description |
|-------|---------------------------------------|-------------|
| **A1** | `manifests/monitoring/`                | Raw manifests for 7-service Compose stack, ported to k8s Deployments / StatefulSets / DaemonSet equivalents. |
| **A2** | `helm/day23-obs/`                      | Custom Helm chart wrapping A1 — `values.yaml`, `_helpers.tpl`, per-service templates. Replaces A1 with one command. |
| **A3** | `operators/kube-prom-stack.values.yaml`<br>`operators/servicemonitor/`<br>`operators/prometheusrule/` | Production idiom: Prometheus Operator + `kube-prometheus-stack` + `ServiceMonitor` + `PrometheusRule` CRDs. |
| **A4** | `operators/otelcollector/gateway.yaml`<br>`manifests/monitoring/08-grafana-alloy.yaml` | OpenTelemetry Operator + `OpenTelemetryCollector` gateway, plus Grafana Alloy **DaemonSet** that ships pod logs to Loki (replaces Promtail, EOL 2026). |
| **B**  | `manifests/serving/`                   | vLLM-mock Deployment + `Ingress` + `ServiceMonitor`. Then **prometheus-adapter** + **HPA on p95 latency** (custom metric, not CPU). |
| **C**  | `manifests/agents/`<br>`agents/research-agent/` | Single-shot research agent as `Job` (with `CronJob` variant), OTel-instrumented, calling inference-api as a tool. Traces visible in Jaeger. |
| **C2.3** | `operators/prometheusrule/agents.yaml` | Agent-specific `PrometheusRule`: tool-call p95, iterations/task, stuck-in-loop detector. |

## Quick start

```bash
# Single command — full stack from zero:
k8s/scripts/deploy.sh all

# Or layer by layer:
k8s/scripts/deploy.sh cluster      # create the kind cluster
k8s/scripts/deploy.sh a1           # raw manifests
k8s/scripts/deploy.sh a2           # helm chart (replaces a1)
k8s/scripts/deploy.sh a3           # Prometheus Operator
k8s/scripts/deploy.sh a4           # OTel Operator + Alloy
k8s/scripts/deploy.sh b            # vLLM + HPA
k8s/scripts/deploy.sh c            # agent

# Tear everything down (cluster too):
k8s/scripts/deploy.sh teardown
```

## Verification — what to actually look at

Once `deploy.sh all` finishes, the system is end-to-end working. Here
are the things that prove it:

```bash
# 1. All pods healthy across 3 namespaces
kubectl get pods -A

# 2. App emits metrics and the kube-prom Prometheus scrapes them
kubectl port-forward -n monitoring svc/kube-prom-stack-kube-prome-prometheus 9091:9090 &
curl -s http://localhost:9091/api/v1/targets | jq '.data.activeTargets[].labels.job' | sort -u
# expect: alertmanager, apiserver, coredns, inference-api, kubelet,
#         kube-state-metrics, node-exporter, otel-collector, prometheus,
#         vllm-mock

# 3. SLO alert is loaded (recording rules + alerting rules)
curl -s http://localhost:9091/api/v1/rules | jq '.data.groups[].name' | grep -i inference
# expect: inference-api.quality, inference-api.slo, inference-api.tokens

# 4. End-to-end telemetry from the app:
kubectl port-forward -n monitoring svc/inference-api 8000:8000 &
curl -X POST http://localhost:8000/predict -H 'content-type: application/json' \
     -d '{"prompt":"hi","model":"llama3-mock"}'
# expect: a JSON response with a trace_id

# 5. That trace is in Jaeger (UI + JSON API)
kubectl port-forward -n monitoring svc/jaeger 16686:16686 &
curl -s "http://localhost:16686/api/services" | jq '.data'
# expect: inference-api, research-agent, jaeger-all-in-one

# 6. Logs reach Loki via Grafana Alloy DaemonSet
kubectl port-forward -n monitoring svc/loki 3100:3100 &
START=$(date -v-5M +%s); END=$(date +%s)
curl -s -G "http://localhost:3100/loki/api/v1/query_range" \
     --data-urlencode 'query={pod=~"inference-api.*"}' \
     --data-urlencode "start=${START}" --data-urlencode "end=${END}" \
  | jq '.data.result | length'
# expect: > 0

# 7. HPA reads p95 latency from the prometheus-adapter custom metrics API
kubectl get hpa -n serving
# expect: vllm-mock with non-<unknown> TARGETS

# 8. The agent Job ran end-to-end with traces in Jaeger
kubectl logs -n agents -l job-name=research-agent-run-001
# expect: {"event":"agent.complete","total_tokens":288,...}
```

## Architecture decisions (and the alternatives I rejected)

### Prometheus Operator vs. raw StatefulSet Prometheus
- **Chose**: kube-prometheus-stack (Helm) at A3.
- **Why**: `ServiceMonitor` + `PrometheusRule` CRDs make scrape configs
  and alert rules **first-class k8s objects**. No more editing a
  shared `prometheus.yml`. The "raw" Prometheus at A2 stays for
  comparison; in production you'd cut it.
- **Anti-pattern avoided**: hand-editing `ConfigMap` and `kubectl
  rollout restart` every time you add a scrape target.

### OTel Collector: gateway (operator) vs. head collector (Deployment)
- **Chose**: OpenTelemetry Operator + `OpenTelemetryCollector` CRD
  for the gateway, while keeping a head collector (Deployment) for
  the "ingress" path.
- **Why**: The Operator lets you declare pipeline config in YAML
  and reconcile state. Updating the gateway config is a single
  `kubectl apply`, and the operator handles rolling restart, config
  validation, and status reporting.
- **Cost**: cert-manager is a hard dependency. ~30MB of CRDs.

### Grafana Alloy vs. Promtail
- **Chose**: Grafana Alloy (DaemonSet).
- **Why**: Promtail is EOL in March 2026 per the deck. Alloy is the
  Grafana-replaced log agent, with stronger relabel rules for k8s
  pod discovery. Note the gotcha: `discovery.kubernetes` →
  `discovery.relabel` → `loki.source.file` pattern, not the legacy
  `loki.source.kubernetes`. The path reconstruction
  (`namespace_podname_uid/container/0.log`) is non-trivial — see
  POSTMORTEM for what broke.

### Custom-metric HPA via prometheus-adapter
- **Chose**: `prometheus-adapter` exposing p95 latency as a Pods
  metric on `custom.metrics.k8s.io`, HPA consuming it.
- **Why**: CPU-based HPA is wrong for LLM workloads — CPU doesn't
  track inference latency, and cold-start (60s model load) blows
  past HPA's reactive scale-up window. p95 latency is the SLO we
  actually care about.
- **Trade-off**: more YAML (Adapter + ConfigMap + RBAC + APIService).
  The kind cluster has no GPU so I can only demo the metric in
  the "no scaling" regime, but the wiring is in place.

### Agent as `Job` (not StatefulSet)
- **Chose**: `Job` + `CronJob` for the research agent.
- **Why**: Each agent run is independent — no shared state needed
  for the lab demo. `CronJob` proves the pattern is extensible to
  recurring runs (daily summaries, etc.). For the StatefulSet
  pattern (Level 2 in §C), you'd want persistent memory across
  conversations, which is beyond a single-shot "Research: top 5
  vector DBs in 2026" task.

## File map

```
k8s/
├── scripts/
│   ├── cluster.sh          # kind up/down/load
│   ├── deploy.sh           # layer-by-layer deploy
│   └── kind-config.yaml    # 3-node cluster with port mappings
├── manifests/              # raw k8s manifests (A1)
│   ├── monitoring/
│   │   ├── 00-namespaces.yaml
│   │   ├── 01-app.yaml
│   │   ├── 02-prometheus.yaml
│   │   ├── 03-alertmanager.yaml
│   │   ├── 04-grafana.yaml
│   │   ├── 05-loki.yaml
│   │   ├── 06-jaeger.yaml
│   │   ├── 07-otel-collector.yaml
│   │   └── 08-grafana-alloy.yaml     # A4 — DaemonSet log shipper
│   ├── serving/                       # Track B
│   │   ├── 01-vllm-mock.yaml
│   │   ├── 02-prometheus-adapter.yaml
│   │   ├── 02b-pod-rbac.yaml
│   │   └── 03-hpa.yaml                # HPA on p95 latency
│   └── agents/                        # Track C
│       └── 01-research-agent-job.yaml
├── helm/
│   └── day23-obs/                     # A2 — Helm chart wrapping A1
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── app.yaml
│           ├── prometheus.yaml
│           ├── alertmanager.yaml
│           ├── grafana.yaml
│           ├── loki.yaml
│           ├── jaeger.yaml
│           └── otel-collector.yaml
├── operators/                         # A3/A4
│   ├── kube-prom-stack.values.yaml    # helm values override
│   ├── servicemonitor/
│   │   └── inference-api.yaml         # ServiceMonitor CRD
│   ├── prometheusrule/
│   │   ├── inference-api.yaml         # SLO rules (A3)
│   │   └── agents.yaml                # agent rules (C2.3)
│   └── otelcollector/
│       └── gateway.yaml               # OpenTelemetryCollector CRD
└── docs/
    ├── ARCHITECTURE.md                # mermaid diagram + flows
    └── POSTMORTEM.md                  # things that broke + why
```

## What I deliberately did NOT do

- **§A5 (real cloud cluster)**: GKE/EKS cost money and the lab
  exercises the same patterns on kind. The deploy script would work
  unchanged on a real cluster with the right context.
- **§B.4.3 (Argo Rollouts canary)**: a real Deployment → Rollout swap
  is straightforward but is YAML-only, no observable behavior in lab.
- **§C.2.2 (StatefulSet for agents)**: out of scope for the
  single-shot demo; explained above.
- **§C.2.4 (KEDA worker pool + queue)**: requires NATS/Redis + an
  external queue, which is a separate stack.
- **Triton / KServe**: GPU-bound; this lab has no GPU nodes.

## Metrics / SLOs this lab exercises

| Metric                              | Source             | Where           |
|-------------------------------------|--------------------|-----------------|
| `inference_requests_total{status}`  | app prom client    | Prometheus      |
| `inference_latency_seconds_bucket`  | app prom client    | Prometheus      |
| `inference_tokens_total`            | app prom client    | Prometheus      |
| `inference_quality_score`           | app prom client    | Prometheus      |
| `otelcol_*`                         | OTel self-metrics  | Prometheus      |
| `kube_state_metrics_*`              | kube-state-metrics | Prometheus      |
| `node_cpu_seconds_total`            | node-exporter      | Prometheus      |
| `agent_tool_call_duration_seconds_*`| agent OTel metric  | PrometheusRule  |
| Traces                              | OTLP gRPC → Gateway → Jaeger | Jaeger |
| Logs                                | pod stdout → kubelet → Alloy → Loki | Loki |

## Self-check (§G of ADVANCED-K8S.md)

1. **Pod CrashLoopBackOff** → `kubectl describe pod`, then `kubectl logs --previous`, then check probe paths, then ConfigMap mounts.
2. **ServiceMonitor not scraping** → check (a) selector matchLabels, (b) namespaceSelector matchNames, (c) prometheus `serviceMonitorSelector` is open, (d) port name matches, (e) Service has the matching label, (f) `kubectl exec` into prometheus pod and curl the target IP.
3. **HPA not scaling** → `kubectl describe hpa`, check `ScalingActive=True`, check the custom metrics API via `kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1/...`.
4. **Lost worker** → pods get `node.kubernetes.io/unreachable:NoExecute` after ~5min, kube-controller-manager reschedules. StatefulSets need `volumeClaimTemplates` to survive.
5. **Rollback vLLM** → `kubectl rollout undo deployment/vllm-mock` for Deployment; for StatefulSet, harder — depends on PersistentVolume and model weight strategy.
6. **"Why not Compose?"** → single-host, single-user, no rolling updates, no probes, no CRDs, no operators, no GitOps. Compose is for prototypes; k8s is for multi-tenant production with humans on call.