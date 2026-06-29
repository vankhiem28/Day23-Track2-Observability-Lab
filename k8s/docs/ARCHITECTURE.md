# Architecture — Day-23 K8s Observability + AI/Agent Stack

## Cluster topology

```mermaid
flowchart TB
  subgraph KCP[Control-plane node]
    ETCD[etcd]
    API[apiserver]
    SCH[scheduler]
    CM[controller-manager]
    PD[prometheus-discovery]
  end

  subgraph W1[Worker 1]
    INFER1[inference-api-7c5...]
    PROM_SS[prometheus-0]
    LOKI_SS[loki-0]
    OP_OLD[otel-collector-x]
    GATEWAY1[gateway-collector-a]
    ALLOY1[grafana-alloy-a]
    VLLM[vllm-mock-b]
  end

  subgraph W2[Worker 2]
    INFER2[inference-api-p4...]
    GRAFANA[grafana]
    AM[alertmanager-0]
    KSM[kube-state-metrics]
    NE[node-exporter]
    OP_SVC[jaeger]
    GATEWAY2[gateway-collector-b]
    ALLOY2[grafana-alloy-b]
    ALLOY3[grafana-alloy-c]
  end

  API --> INFER1 & INFER2
  API --> PROM_SS
  API --> GATEWAY1 & GATEWAY2
  API --> VLLM
```

## Telemetry flow — three signals, three paths

```mermaid
flowchart LR
  subgraph APP[Application]
    PY[FastAPI / uvicorn]
  end

  subgraph METRICS_PATH[Metrics pipeline]
    PYC[prometheus_client]
    PROMSCRAPE[Prometheus scrape /metrics]
    PROM[Prometheus TSDB]
    PROMQL[PromQL]
    GRAF[Grafana]
  end

  subgraph TRACE_PATH[Trace pipeline]
    OTELSDK[OTel SDK]
    OTLP[OTLP gRPC :4317]
    GW[OTel Collector Gateway]
    SAMP[tail_sampling]
    JAEGER_EXPORTER[otlp/jaeger exporter]
    JAEGER[Jaeger]
  end

  subgraph LOG_PATH[Log pipeline]
    STDOUT[pod stdout/stderr]
    KUBELET[kubelet writes /var/log/pods/]
    ALLOY[Grafana Alloy DaemonSet]
    LOKI[Loki TSDB]
    LOGQL[LogQL]
  end

  PY --> PYC --> PROMSCRAPE --> PROM --> PROMQL --> GRAF
  PY --> OTELSDK --> OTLP --> GW --> SAMP --> JAEGER_EXPORTER --> JAEGER
  PY --> STDOUT --> KUBELET --> ALLOY --> LOKI --> LOGQL --> GRAF
```

## Autoscaling — custom metric path

```mermaid
flowchart LR
  VLLM[vllm-mock Pod]
  PROM[Prometheus]
  ADAPT[prometheus-adapter]
  API[custom.metrics.k8s.io API]
  HPA[HPA controller]

  VLLM -->|exposes /metrics| PROM
  PROM -->|PromQL query p95| ADAPT
  ADAPT -->|exposes pods metric| API
  API -->|HPA polls every 15s| HPA
  HPA -->|scales| VLLM
```

## Sampling policy in OTel Gateway

The gateway's `tail_sampling` keeps:
1. ALL traces with status ERROR (`keep-errors`)
2. ALL traces with latency > 2s (`keep-slow`)
3. ALL traces from `research-agent` / `research-agent-cron` (`keep-agents`)
4. 1% of everything else (`probabilistic-1pct`)

For an agent run that succeeds in ~3 seconds with no errors, only
the explicit `keep-agents` policy saves it from the 1% cull. This
is intentional — agent traces are usually short and uneventful, but
still expensive to drop when investigating.

## Request flow — a single agent run

```mermaid
sequenceDiagram
  participant U as User
  participant Job as research-agent Job
  participant API as inference-api
  participant GW as OTel Gateway
  participant J as Jaeger
  participant P as Prometheus
  participant L as Loki

  U->>Job: kubectl apply
  Job->>Job: emit "agent.start" log
  Job->>API: POST /predict (iter 1)
  API-->>Job: 200 OK + tokens
  Job->>API: POST /predict (iter 2)
  API-->>Job: 200 OK + tokens
  Job->>API: POST /predict (iter 3)
  API-->>Job: 200 OK + tokens
  Job->>API: POST /predict (synthesize)
  API-->>Job: 200 OK + final text
  Job->>Job: force_flush() → shutdown()

  par Telemetry out
    Job->>GW: OTLP gRPC (12 spans)
    GW->>GW: tail_sampling (keep-agents → kept)
    GW->>J: OTLP gRPC export
  and
    API->>P: prom client increments counters
    P->>P: scrape /metrics every 15s
  and
    Job->>L: stdout JSON log (via kubelet → Alloy)
    L->>L: parse, label, store
  end

  Job->>U: log "agent.complete" → exit 0
```