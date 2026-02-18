#!/usr/bin/env bash
# Multicluster E2E Test Cleanup Script
#
# Removes all test clusters created by setup.sh:
# - kro-host (central control plane)
# - kro-consumer-1, kro-consumer-2, kro-consumer-3 (consumer clusters)
# Also removes exported kubeconfig files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

HOST_CLUSTER="kro-host"
CONSUMER_CLUSTERS=("kro-consumer-1" "kro-consumer-2" "kro-consumer-3")

# Friendly names for display
declare -A CLUSTER_LABELS
CLUSTER_LABELS["kro-consumer-1"]="us-east"
CLUSTER_LABELS["kro-consumer-2"]="us-west"
CLUSTER_LABELS["kro-consumer-3"]="eu-central"

echo "=== KRO Multicluster E2E Test Cleanup ==="
echo ""

# Delete consumer clusters
echo "Deleting consumer clusters..."
for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    if kind get clusters 2>/dev/null | grep -q "^${CONSUMER}$"; then
        echo "  Deleting ${CONSUMER} (${LABEL})..."
        kind delete cluster --name "${CONSUMER}"
    else
        echo "  ${CONSUMER} does not exist, skipping"
    fi
done

# Delete host cluster
echo ""
echo "Deleting host cluster..."
if kind get clusters 2>/dev/null | grep -q "^${HOST_CLUSTER}$"; then
    echo "  Deleting ${HOST_CLUSTER}..."
    kind delete cluster --name "${HOST_CLUSTER}"
else
    echo "  ${HOST_CLUSTER} does not exist, skipping"
fi

# Clean up kubeconfig files
echo ""
echo "Cleaning up kubeconfig files..."
for KUBECONFIG_FILE in "${ROOT_DIR}/local.kubeconfig" "${ROOT_DIR}/consumer1.kubeconfig" "${ROOT_DIR}/consumer2.kubeconfig" "${ROOT_DIR}/consumer3.kubeconfig"; do
    if [ -f "${KUBECONFIG_FILE}" ]; then
        rm -f "${KUBECONFIG_FILE}"
        echo "  Removed $(basename ${KUBECONFIG_FILE})"
    fi
done

echo ""
echo "=== Cleanup Complete ==="
echo ""
echo "All KRO multicluster test clusters and kubeconfig files have been removed."
