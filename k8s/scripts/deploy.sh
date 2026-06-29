#!/usr/bin/env bash
## Deploy the full Day-23 K8s observability stack.
## Layered: A1 (raw manifests) → A2 (Helm chart) → A3 (Prometheus Operator) →
##         A4 (OTel Operator + Alloy) → B (vLLM + HPA) → C (agents).
## Each layer depends on the previous. Run in order.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-day23-obs}"

log() { printf "\033[1;36m>> %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m!! %s\033[0m\n" "$*"; }
err() { printf "\033[1;31mxx %s\033[0m\n" "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: deploy.sh [layer|all]
  all       — deploy every layer in order (default)
  cluster   — only create the kind cluster
  a1        — raw manifests (app, prometheus, loki, jaeger, otel, grafana, alertmanager)
  a2        — Helm chart wrapping A1
  a3        — Prometheus Operator + kube-prometheus-stack + ServiceMonitor + PrometheusRule
  a4        — OTel Operator + OpenTelemetryCollector + Grafana Alloy DaemonSet
  b         — vLLM deployment + HPA on custom p95 latency metric
  c         — research-agent Job + CronJob
  teardown  — delete everything in this stack (cluster too)
EOF
}

ensure_cluster() {
  if ! kubectl cluster-info --context "${KUBE_CONTEXT}" > /dev/null 2>&1; then
    log "kind cluster missing; creating..."
    bash "${SCRIPT_DIR}/cluster.sh" up
  fi
}

build_images() {
  log "Building local images (inference-api + research-agent)"
  docker build -t day23-inference-api:local "${ROOT}/01-instrument-fastapi/app/" > /dev/null
  docker build -t day23-research-agent:local "${ROOT}/agents/research-agent/" > /dev/null
  bash "${SCRIPT_DIR}/cluster.sh" load day23-inference-api:local > /dev/null
  bash "${SCRIPT_DIR}/cluster.sh" load day23-research-agent:local > /dev/null
}

layer_cluster() {
  bash "${SCRIPT_DIR}/cluster.sh" up
}

layer_a1() {
  ensure_cluster
  build_images
  log "A1: applying raw manifests (raw mode — no operator)"
  kubectl apply -f "${ROOT}/manifests/monitoring/" --context "${KUBE_CONTEXT}"
  log "Waiting for pods..."
  kubectl wait --for=condition=ready pod -l app=inference-api -n monitoring --timeout=120s
  kubectl wait --for=condition=ready pod -l app=prometheus -n monitoring --timeout=120s
  kubectl wait --for=condition=ready pod -l app=otel-collector -n monitoring --timeout=120s
  kubectl wait --for=condition=ready pod -l app=loki -n monitoring --timeout=120s
  kubectl wait --for=condition=ready pod -l app=jaeger -n monitoring --timeout=120s
  kubectl wait --for=condition=ready pod -l app=grafana -n monitoring --timeout=120s
  kubectl wait --for=condition=ready pod -l app=alertmanager -n monitoring --timeout=120s
}

layer_a2() {
  ensure_cluster
  log "A2: install Helm chart (replaces A1 raw manifests)"
  helm uninstall obs -n monitoring --ignore-not-found
  helm install obs "${ROOT}/helm/day23-obs" -n monitoring --create-namespace
  kubectl wait --for=condition=ready pod -l app=inference-api -n monitoring --timeout=120s
  kubectl wait --for=condition=ready pod -l app=prometheus -n monitoring --timeout=120s
  kubectl wait --for=condition=ready pod -l app=otel-collector -n monitoring --timeout=120s
  kubectl wait --for=condition=ready pod -l app=loki -n monitoring --timeout=120s
  kubectl wait --for=condition=ready pod -l app=jaeger -n monitoring --timeout=120s
  kubectl wait --for=condition=ready pod -l app=grafana -n monitoring --timeout=120s
  kubectl wait --for=condition=ready pod -l app=alertmanager -n monitoring --timeout=120s
}

layer_a3() {
  ensure_cluster
  log "A3: installing kube-prometheus-stack (Prometheus Operator pattern)"
  if ! helm list -n monitoring | grep -q kube-prom-stack; then
    helm install kube-prom-stack prometheus-community/kube-prometheus-stack \
      -n monitoring --create-namespace \
      -f "${ROOT}/operators/kube-prom-stack.values.yaml" \
      --wait --timeout 600s
  fi
  log "A3: applying ServiceMonitor + PrometheusRule for inference-api"
  kubectl apply -f "${ROOT}/operators/servicemonitor/inference-api.yaml"
  kubectl apply -f "${ROOT}/operators/prometheusrule/inference-api.yaml"
  log "Waiting for operator-managed Prometheus..."
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n monitoring --timeout=240s
}

layer_a4() {
  ensure_cluster
  log "A4: installing cert-manager + OTel Operator"
  if ! kubectl get namespace cert-manager > /dev/null 2>&1; then
    helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
      --set crds.enabled=true --wait --timeout 300s
  fi
  if ! helm list -n monitoring | grep -q opentelemetry-operator; then
    helm repo add opentelemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
    helm repo update > /dev/null 2>&1
    helm install opentelemetry-operator opentelemetry/opentelemetry-operator \
      -n monitoring --wait --timeout 300s
  fi
  log "A4: deploying OpenTelemetryCollector gateway (operator-managed)"
  kubectl apply -f "${ROOT}/operators/otelcollector/gateway.yaml"
  log "A4: deploying Grafana Alloy DaemonSet for log shipping"
  kubectl apply -f "${ROOT}/manifests/monitoring/08-grafana-alloy.yaml"
  log "Waiting for gateway + alloy..."
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=otel-gateway -n monitoring --timeout=180s
  kubectl wait --for=condition=ready pod -l app=grafana-alloy -n monitoring --timeout=180s
}

layer_b() {
  ensure_cluster
  log "B: deploying vLLM-mock + ServiceMonitor + Ingress"
  kubectl apply -f "${ROOT}/manifests/serving/01-vllm-mock.yaml"
  log "B: deploying prometheus-adapter for custom metrics API"
  kubectl apply -f "${ROOT}/manifests/serving/02-prometheus-adapter.yaml"
  kubectl apply -f "${ROOT}/manifests/serving/02b-pod-rbac.yaml"
  log "B: deploying HPA on p95 latency"
  kubectl apply -f "${ROOT}/manifests/serving/03-hpa.yaml"
  kubectl wait --for=condition=ready pod -l app=vllm -n serving --timeout=120s
  kubectl wait --for=condition=ready pod -l app=prometheus-adapter -n monitoring --timeout=120s
}

layer_c() {
  ensure_cluster
  build_images
  log "C: deploying research-agent Job + CronJob"
  kubectl apply -f "${ROOT}/manifests/agents/01-research-agent-job.yaml"
  log "C: deploying agent PrometheusRule"
  kubectl apply -f "${ROOT}/operators/prometheusrule/agents.yaml"
}

layer_teardown() {
  log "Removing research-agent job + cronjob"
  kubectl delete job research-agent-run-001 -n agents --ignore-not-found
  kubectl delete cronjob research-agent-cron -n agents --ignore-not-found
  log "Removing HPA + adapter + vllm"
  kubectl delete -f "${ROOT}/manifests/serving/" --ignore-not-found
  log "Removing operators (ServiceMonitors, PrometheusRules, OpenTelemetryCollector)"
  kubectl delete -f "${ROOT}/operators/" --ignore-not-found
  log "Removing helm releases"
  helm uninstall opentelemetry-operator -n monitoring --ignore-not-found
  helm uninstall kube-prom-stack -n monitoring --ignore-not-found
  helm uninstall cert-manager -n cert-manager --ignore-not-found
  helm uninstall obs -n monitoring --ignore-not-found
  log "Removing namespaces"
  kubectl delete namespace monitoring --ignore-not-found
  kubectl delete namespace serving --ignore-not-found
  kubectl delete namespace agents --ignore-not-found
  kubectl delete namespace cert-manager --ignore-not-found
  log "Deleting kind cluster"
  bash "${SCRIPT_DIR}/cluster.sh" down
}

case "${1:-all}" in
  cluster) layer_cluster ;;
  a1) layer_a1 ;;
  a2) layer_a2 ;;
  a3) layer_a3 ;;
  a4) layer_a4 ;;
  b) layer_b ;;
  c) layer_c ;;
  teardown) layer_teardown ;;
  all)
    layer_cluster
    layer_a1
    layer_a2
    layer_a3
    layer_a4
    layer_b
    layer_c
    log "✅ All layers deployed. Cluster summary:"
    kubectl get pods -A --context "${KUBE_CONTEXT}"
    ;;
  *) usage ;;
esac