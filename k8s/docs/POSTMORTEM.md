# POSTMORTEM — Day-23 K8s Lab

A running log of the things that broke while porting the Day-23
observability stack from Compose to k8s. **What I changed → what
the cluster did → root cause → how I fixed it → lesson.** This is
the part of the lab that actually teaches you k8s.

---

## PM-1 — kind cluster can't bind port 3000

**What I did**: `kind create cluster` with `extraPortMappings` mapping
container 30080 → host 3000 for Grafana.

**What happened**: `Bind for 0.0.0.0:3000 failed: port is already
allocated`.

**Root cause**: another Docker container (`c2-app-058-frontend`) was
already on host port 3000 on the same Docker daemon. Kind doesn't
know about other containers — only that the port is in use.

**Fix**: changed host ports to 31300 / 31800 / 31668 (avoiding
obvious conflicts), kept the container ports the same. The kind
config in `scripts/kind-config.yaml` documents this.

**Lesson**: never assume host ports are free on a shared Docker
daemon. Always check `docker ps` for host-port collisions first,
or just use port-forwards instead of nodePort mappings.

---

## PM-2 — Prometheus `runAsNonRoot: true` blocked StatefulSet

**What I did**: copied my "production-shape" Prometheus manifest
with `runAsNonRoot: true, runAsUser: 65534, fsGroup: 65534`.

**What happened**: pod stuck in `CreateContainerConfigError` /
`Pending`.

**Root cause**: I had set `fsGroup: 65534` *and* referenced a
ConfigMap for `prometheus.yml`. The Prometheus image's user (65534)
needs read access to the mounted volume, but the ConfigMap volume
defaults to root-owned; the security context made this fail.

**Fix**: dropped `runAsUser` constraint, kept `runAsNonRoot: true` +
`fsGroup: 65534`. Worked.

**Lesson**: the security context triad (`runAsUser` / `runAsGroup` /
`fsGroup`) needs to be consistent with the volume's ownership.
ConfigMaps don't allow GID setting — for production, use a
projection from a Secret or a dedicated PV with the right ownership.

---

## PM-3 — OTel Collector: `cannot unmarshal map into Go struct`

**What I did**: deployed `otel-collector` Deployment with a
ConfigMap whose `data.otel-config.yaml` had receivers defined as
inline map syntax: `otlp: { protocols: { grpc: ... } }`.

**What happened**: collector crashed with:
```
yaml: line 10: cannot unmarshal !!map into string
```

**Root cause**: I had used a single ConfigMap key (`otel-config.yaml`)
and mounted the directory; the key got mounted as `config.yaml`
(empty) and the collector looked for its config at the wrong path.

**Fix**: split into two steps — (a) mount the ConfigMap using
`subPath: otel-config.yaml` so the file ends up at the right path;
(b) verify probes hit `/metrics` (the OTLP self-metrics port), not
`/` which returns 404.

**Lesson**: ConfigMap mounting has TWO ways to go wrong — the path
inside the container, and the readiness probe path. Always verify
both with `kubectl exec` + `wget/curl`.

---

## PM-4 — Loki: same ConfigMap-mount issue, plus a config-file path mismatch

**What I did**: mounted Loki config ConfigMap at `/etc/loki` (dir).

**What happened**: Loki logs showed `loki-config.yaml does not
exist, set config.file for custom config path`.

**Root cause**: I mounted a directory, but the ConfigMap keys
become files inside that directory. Then I asked Loki to read
`/etc/loki/loki-config.yaml` (the literal name) but the actual file
ended up at `/etc/loki/local-config.yaml` (because the dir mount
exposes every key as a file).

**Fix**: used `subPath` mount to control the file name explicitly,
then aligned Loki's `-config.file=/etc/loki/local-config.yaml` arg
to match.

**Lesson**: with ConfigMaps, pick ONE of:
- mount the whole directory (then `subPath` per-file to control names),
- or mount each key as a file (then they land at the literal key name).

Don't mix patterns across the same ConfigMap.

---

## PM-5 — Helm chart: alertmanager config unmarshal error

**What I did**: wrote a Helm template for alertmanager.yml using
inline-flow style matchers: `matchers: [{ severity = "critical" }]`.

**What happened**: alertmanager crashed with:
```
yaml: unmarshal errors: line 10: cannot unmarshal !!map into string
```

**Root cause**: Helm's `|` block-scalar preserves whitespace and
newlines, but YAML inline-flow `{ ... }` for an object is fine —
except that the matcher YAML schema expects a list of strings, and
my `{ severity = "critical" }` is a map.

**Fix**: switched to block style:
```yaml
matchers:
  - severity = "critical"
```

**Lesson**: when copying YAML from another tool (alertmanager
docs, Grafana dashboards), verify each block — Helm template
indentation can mask flow-vs-block ambiguities.

---

## PM-6 — Helm chart: Services missing `app: <name>` labels

**What I did**: deployed A2 (Helm chart), then added a
`ServiceMonitor` at A3 with `selector.matchLabels.app: inference-api`.

**What happened**: Prometheus Operator didn't pick up the
inference-api target.

**Root cause**: my Helm `Service` template only had the standard
`app.kubernetes.io/*` labels but not the `app:` label that the
ServiceMonitor selector was matching on.

**Fix**: manually added `app: <service-name>` to every Service in
the chart, ran `helm upgrade`.

**Lesson**: ServiceMonitor / PodMonitor selectors in the Operator
pattern are *label-based contracts*. If your Deployment template
uses `app: foo` but your Service template omits it, you've
inadvertently broken the contract. Either: (a) add `app:` to all
templates, or (b) match on `app.kubernetes.io/name`. Option (a) is
more portable across operators.

---

## PM-7 — OpenTelemetryCollector CRD: config-as-string rejected

**What I did**: wrote the gateway YAML with `spec.config: |` (block
scalar containing a YAML doc).

**What happened**: admission webhook denied:
```
json: cannot unmarshal string into Go struct field OpenTelemetryCollectorSpec.spec.config of type v1beta1.Config
```

**Root cause**: the OTel Operator's CRD schema for `.spec.config`
is a structured object (with `receivers`, `processors`, `exporters`,
`service` typed fields), not a string.

**Fix**: rewrote as YAML structure inline (no `|` block).

**Lesson**: `kubectl explain <resource>.<field>` shows the schema
type. The OTel Operator's `config` field is an Object, not a
String. This is intentional — the operator validates the config
server-side, so you get rejected before the pod starts.

---

## PM-8 — ghcr.io rate-limited anonymous pulls

**What I did**: configured the OTel Collector CRD with
`image: ghcr.io/open-telemetry/opentelemetry-collector-contrib:0.114.0`.

**What happened**: `ErrImagePull: 403 Forbidden` from ghcr.io.

**Root cause**: GitHub Container Registry requires auth for pulls
beyond a small unauthenticated quota. kind clusters don't pull
images through a configured auth helper by default.

**Fix**: switched to `image: otel/opentelemetry-collector-contrib:0.114.0`
(Docker Hub mirror — same image, different registry). Same image,
no rate limit.

**Lesson**: in lab clusters with no `imagePullSecrets`, prefer
Docker Hub over ghcr.io for non-critical images. For production,
use a private registry with proper auth.

---

## PM-9 — Grafana Alloy: `--cluster.join` flag unknown

**What I did**: ran Alloy with `--cluster.enabled=true
--cluster.join=dns:///grafana-alloy:9095`.

**What happened**: `Error: unknown flag: --cluster.join`.

**Root cause**: Alloy 1.4.x removed the CLI-level cluster join flag;
clustering is now done via River config blocks (`cluster {}`).

**Fix**: dropped the flag, left clustering off (single-node cluster
fine for the lab).

**Lesson**: Grafana Alloy v1 has a different config model than
Promtail / Grafana Agent Static. Check the version-specific docs.

---

## PM-10 — Grafana Alloy: `//` comments OK, `#` comments break

**What I did**: wrote Alloy River config with `# comment` style.

**What happened**: `Error: /etc/alloy/config.alloy:55:5: illegal character U+0023 '#'`.

**Root cause**: Alloy uses **River** (HCL-like) syntax, where
single-line comments are `//` only. `#` was a leftover habit.

**Fix**: converted all `#` comments to `//`.

**Lesson**: River ≠ Prometheus config ≠ Grafana Agent config. Read
the first page of https://grafana.com/docs/alloy/ before writing
config.

---

## PM-11 — Grafana Alloy: `__path__` empty, `discovery.kubernetes` silent failure

**What I did**: built `__path__` from `__meta_kubernetes_pod_container_log_path`.

**What happened**: alloy `loki.source.file.pods` emitted
`failed to tail file, stat failed ... filename=""` — empty path.

**Root cause**: in kind 1.36 (k8s 1.36.1), the container log path
metadata field is sometimes empty depending on kubelet configuration.
The default fallback is `/var/log/pods/<dir>/<container>/<N>.log`,
and the directory name format is `<namespace>_<pod_name>_<uid>`.

**Fix**: built the path manually with the standard convention:
```river
rule {
  source_labels = ["__meta_kubernetes_namespace", "__meta_kubernetes_pod_name", "__meta_kubernetes_pod_uid"]
  separator     = "_"
  target_label  = "pod_log_dir"
}
rule {
  source_labels = ["pod_log_dir", "__meta_kubernetes_pod_container_name"]
  separator     = "/"
  target_label  = "__path__"
  replacement   = "/var/log/pods/$0/0.log"
}
```

**Lesson**: kind + kubelet versions sometimes don't populate
`__meta_kubernetes_pod_container_log_path` correctly. Hardcoding
the k8s log directory format works around it but is fragile
across k8s versions.

---

## PM-12 — Grafana Alloy → Loki: 19 labels, limit 15

**What I did**: shipped pod logs with full label set
(app, helm chart, controller-revision, pod-template-hash, pod-template-generation,
service_name, tier, plus k8s-discovered labels).

**What happened**: Loki rejected the push:
```
server returned HTTP status 400 Bad Request: entry for stream has 19 label names; limit 15
```

**Root cause**: Loki default `max_label_names_per_series` is 15.

**Fix**: pruned labels in the Alloy config — kept only `namespace`,
`pod`, `container`, `env`. Dropped helm chart labels, controller
hash, etc.

**Lesson**: Loki has hard limits on label cardinality. Decide
**early** which labels you'll query by (max 15) and which labels
you'll drop. Shipping "everything" looks nice in dev, breaks at
production cardinality.

---

## PM-13 — Grafana Alloy: HTTP listener on 127.0.0.1, kubelet probe from pod IP

**What I did**: kubelet readiness probe:
```yaml
httpGet: { path: /-/ready, port: 12345 }
```

**What happened**: probe failed with `connection refused` even
though alloy was running and listening.

**Root cause**: Alloy 1.4.x binds the HTTP listener to `127.0.0.1`
by default. Kubelet probes go to the pod IP, not localhost.

**Fix**: started alloy with `--server.http.listen-addr=0.0.0.0:12345`
flag.

**Lesson**: default-bind addresses are commonly loopback-only. For
k8s probes, always check the listener address — `--listen-addr`,
`--bind-address`, `-addr`, etc.

---

## PM-14 — prometheus-adapter: `--logtostderr` unknown, then `--secure-listen-address` unknown

**What I did**: copied flags from older docs (v0.9.x) to v0.11.

**What happened**: each flag rejected in turn.

**Root cause**: flag names changed between versions. `--secure-listen-address`
was renamed to `--secure-port`, and `--logtostderr` (klog-style) was removed.

**Fix**: minimal flag set: `--secure-port=6443 --cert-dir=/tmp/certs
--prometheus-url=... --config=...`. That's it.

**Lesson**: prometheus-adapter v0.11 has different CLI than v0.9.
The README still shows old flags. Always check `--help` from the
container, not the GitHub README.

---

## PM-15 — prometheus-adapter: APIService `port` defaults to 443, but adapter listens on 6443

**What I did**: registered `APIService` without specifying port.

**What happened**: kube-apiserver → `localhost:443` connection
refused.

**Fix**: added `port: 6443` to APIService spec.

**Lesson**: APIService default port is 443, but most custom
adapters (including prometheus-adapter) use 6443 or 8443. Always
explicit.

---

## PM-16 — prometheus-adapter: 403 on SAR (subjectaccessreviews)

**What I did**: created a ClusterRole granting `subjectaccessreviews:create`.

**What happened**: still got `cannot create resource subjectaccessreviews
in API group authorization.k8s.io`.

**Root cause**: the ClusterRole existed but the `ClusterRoleBinding`
was missing.

**Fix**: added `ClusterRoleBinding` for the service account.

**Lesson**: prometheus-adapter's RBAC needs 3 things:
1. ClusterRole with `nodes/namespaces/configmaps` read,
2. ClusterRole with `subjectaccessreviews` create,
3. ClusterRoleBinding linking the SA to BOTH clusterroles.

Plus a `Role` + `RoleBinding` for the ConfigMap in its own namespace.

---

## PM-17 — HPA: `FailedGetPodsMetric: no known available metric versions found`

**What I did**: deployed HPA referring to `metric: inference_latency_seconds_p95`.

**What happened**: HPA logged `no known available metric versions
found` for 10+ minutes.

**Root cause**: the prometheus-adapter was running, but it had
two cascading issues: (a) `--config` flag wasn't being read because
the volume mount was on a directory not a file path, (b) once
fixed, the adapter needed `pods:list` RBAC in the serving namespace
to enumerate pods.

**Fix**: two-step — first fixed the volume mount with `subPath:
prometheus-adapter-config.yaml`, then added a separate ClusterRole +
ClusterRoleBinding for `pods:get,list,watch`.

**Lesson**: when prometheus-adapter returns no metric, walk
`kubectl logs prometheus-adapter` first; the error is usually
specific (config not loaded, RBAC denied, prom unreachable).

---

## PM-18 — OTel gateway: agent traces dropped by 1% sampling

**What I did**: agent Job ran successfully, but `research-agent`
service never appeared in Jaeger.

**What happened**: tail_sampling policy dropped 99% of healthy
traces; only 1 of every 100 agent runs survived to Jaeger.

**Fix**: added an explicit `keep-agents` policy to tail_sampling:
```yaml
- name: keep-agents
  type: string_attribute
  string_attribute:
    key: service.name
    values: [research-agent, research-agent-cron]
```

**Lesson**: sampling is good for high-volume services but disastrous
for debugging specific workloads. Either (a) tag services that
must-always-be-traced, or (b) skip sampling for short-lived Jobs.

---

## PM-19 — Agent spans lost because of `force_flush` not being called

**What I did**: agent ran in 4 seconds, called `provider.shutdown()`,
exited.

**What happened**: 0 traces in Jaeger for the agent.

**Root cause**: `BatchSpanProcessor` has a default 5-second
`schedule_delay_millis` between batch exports. The agent exited
before the first batch fired.

**Fix**: (a) reduced `schedule_delay_millis` to 500 in the
BatchSpanProcessor, and (b) added explicit `provider.force_flush(timeout_millis=5000)`
before shutdown.

**Lesson**: short-lived processes that emit telemetry MUST call
`force_flush` before exit, otherwise the BatchSpanProcessor loses
the in-flight spans. This is the single most common OTel
"why aren't my traces appearing" bug.

---

## Summary

| Category | Bumps | Most painful |
|----------|-------|--------------|
| Path/mount issues (ConfigMap) | 4 | OTel collector + Loki |
| Label/selector contracts | 2 | Helm Service labels for ServiceMonitor |
| CRD schema mismatches | 1 | OpenTelemetryCollector config as string |
| Cluster-side infra | 3 | cert-manager for OTel Operator |
| Sampling/flush behavior | 3 | Agent traces dropped + not flushed |
| Flags/CLI versioning | 3 | prometheus-adapter v0.11 |

The big takeaway: **k8s has more failure modes than Compose, and
they're less obvious.** Almost every bump above was a label/path/port
mismatch that doesn't show up until you watch the pod logs for
30 seconds. The fix is always the same — `kubectl describe`,
`kubectl logs --previous`, `kubectl exec`, and reading the
admission webhook error carefully.