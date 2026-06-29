#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-day23-obs}"
CONFIG="${SCRIPT_DIR}/kind-config.yaml"

case "${1:-up}" in
  up)
    echo ">> Creating kind cluster '${CLUSTER_NAME}' (1 control-plane + 2 workers)"
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
      echo "   cluster already exists; reusing"
    else
      kind create cluster --name "${CLUSTER_NAME}" --config "${CONFIG}" --wait 120s
    fi
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"
    echo ""
    echo ">> Nodes:"
    kubectl get nodes -o wide
    ;;
  down)
    echo ">> Deleting kind cluster '${CLUSTER_NAME}'"
    kind delete cluster --name "${CLUSTER_NAME}"
    ;;
  load)
    if [[ -z "${2:-}" ]]; then
      echo "usage: $0 load <image>"
      exit 1
    fi
    echo ">> Loading image ${2} into cluster"
    kind load docker-image "${2}" --name "${CLUSTER_NAME}"
    ;;
  *)
    echo "usage: $0 {up|down|load <image>}"
    exit 1
    ;;
esac