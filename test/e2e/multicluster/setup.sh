#!/usr/bin/env bash
# Multicluster E2E Test Setup Script
#
# Creates a multi-cluster environment for testing KRO's multicluster functionality:
# - kro-host: The central control plane cluster running KRO controller
# - kro-consumer-1: Consumer cluster for workloads (e.g., US-East)
# - kro-consumer-2: Consumer cluster for workloads (e.g., US-West)
# - kro-consumer-3: Consumer cluster for workloads (e.g., EU)
#
# This demonstrates KRO's ability to manage resources across multiple clusters
# from a single control plane.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

HOST_CLUSTER="kro-host"
CONSUMER_CLUSTERS=("kro-consumer-1" "kro-consumer-2" "kro-consumer-3")
KRO_NAMESPACE="kro-system"

# Friendly names for display (simulating different regions/environments)
declare -A CLUSTER_LABELS
CLUSTER_LABELS["kro-consumer-1"]="us-east"
CLUSTER_LABELS["kro-consumer-2"]="us-west"
CLUSTER_LABELS["kro-consumer-3"]="eu-central"

echo "=== KRO Multicluster E2E Test Setup ==="
echo ""
echo "This will create a multi-cluster environment:"
echo "  - 1 central KRO control plane cluster"
echo "  - 3 consumer clusters for workloads"
echo ""

# Check prerequisites
echo "Checking prerequisites..."
command -v kind >/dev/null 2>&1 || { echo "Error: kind is required but not installed."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl is required but not installed."; exit 1; }
command -v go >/dev/null 2>&1 || { echo "Error: go is required but not installed."; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "Error: docker is required but not installed."; exit 1; }
echo "All prerequisites met."
echo ""

# Create host cluster
echo "=== Creating Host Cluster ==="
echo "Creating central KRO control plane cluster: ${HOST_CLUSTER}..."
if kind get clusters 2>/dev/null | grep -q "^${HOST_CLUSTER}$"; then
    echo "Host cluster already exists, skipping creation"
else
    kind create cluster --name "${HOST_CLUSTER}" --wait 60s
fi

# Create consumer clusters
echo ""
echo "=== Creating Consumer Clusters ==="
for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    echo "Creating consumer cluster: ${CONSUMER} (${LABEL})..."
    if kind get clusters 2>/dev/null | grep -q "^${CONSUMER}$"; then
        echo "Consumer cluster ${CONSUMER} already exists, skipping creation"
    else
        kind create cluster --name "${CONSUMER}" --wait 60s
    fi
done

# Switch to host cluster context
kubectl config use-context "kind-${HOST_CLUSTER}"

# Install CRDs on host cluster
echo ""
echo "=== Configuring Host Cluster ==="
echo "Installing KRO CRDs on host cluster..."
kubectl apply -f "${ROOT_DIR}/helm/crds/"

# Create kro-system namespace on host
echo "Creating ${KRO_NAMESPACE} namespace on host..."
kubectl create namespace "${KRO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Register each consumer cluster with the host
echo ""
echo "=== Registering Consumer Clusters ==="
for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    echo ""
    echo "Registering ${CONSUMER} (${LABEL}) with host cluster..."

    # Get consumer cluster kubeconfig
    CONSUMER_KUBECONFIG=$(mktemp)
    kind get kubeconfig --name="${CONSUMER}" > "${CONSUMER_KUBECONFIG}"

    # The kubeconfig from kind uses localhost, which won't work from host cluster.
    # For kind clusters, we need to use the docker network address.
    CONSUMER_CONTAINER="${CONSUMER}-control-plane"
    CONSUMER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONSUMER_CONTAINER}")

    # Update the server URL in the kubeconfig to use the docker IP
    sed -i.bak "s|server: https://127.0.0.1:[0-9]*|server: https://${CONSUMER_IP}:6443|g" "${CONSUMER_KUBECONFIG}"

    # Create cluster secret on host (use the label as the secret name for clarity)
    SECRET_NAME="cluster-${LABEL}"
    kubectl --context="kind-${HOST_CLUSTER}" create secret generic "${SECRET_NAME}" \
        --namespace="${KRO_NAMESPACE}" \
        --from-file=kubeconfig="${CONSUMER_KUBECONFIG}" \
        --dry-run=client -o yaml | kubectl --context="kind-${HOST_CLUSTER}" apply -f -

    kubectl --context="kind-${HOST_CLUSTER}" label secret "${SECRET_NAME}" \
        --namespace="${KRO_NAMESPACE}" \
        kro.run/cluster=true \
        kro.run/region="${LABEL}" \
        --overwrite

    rm -f "${CONSUMER_KUBECONFIG}" "${CONSUMER_KUBECONFIG}.bak"
    echo "Registered ${CONSUMER} as '${SECRET_NAME}'"
done

# Export kubeconfigs for easy access
echo ""
echo "=== Exporting Kubeconfigs ==="

# Export local/host kubeconfig
LOCAL_KUBECONFIG="${ROOT_DIR}/local.kubeconfig"
kind get kubeconfig --name="${HOST_CLUSTER}" > "${LOCAL_KUBECONFIG}"
echo "Exported: local.kubeconfig (host cluster)"

# Export consumer kubeconfigs with Docker network IPs (for cross-cluster access)
COUNTER=1
for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    KUBECONFIG_FILE="${ROOT_DIR}/consumer${COUNTER}.kubeconfig"

    kind get kubeconfig --name="${CONSUMER}" > "${KUBECONFIG_FILE}"

    # Update server URL to Docker network IP for cross-cluster access
    CONSUMER_CONTAINER="${CONSUMER}-control-plane"
    CONSUMER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONSUMER_CONTAINER}")
    sed -i.bak "s|server: https://127.0.0.1:[0-9]*|server: https://${CONSUMER_IP}:6443|g" "${KUBECONFIG_FILE}"
    rm -f "${KUBECONFIG_FILE}.bak"

    echo "Exported: consumer${COUNTER}.kubeconfig (${LABEL})"
    COUNTER=$((COUNTER + 1))
done

echo ""
echo "========================================"
echo "=== Setup Complete ==="
echo "========================================"
echo ""
echo "Clusters created:"
echo "  - kind-${HOST_CLUSTER} (central control plane - runs KRO)"
for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    echo "  - kind-${CONSUMER} (consumer cluster - ${LABEL})"
done
echo ""
echo "Cluster secrets registered in kro-system namespace:"
kubectl --context="kind-${HOST_CLUSTER}" get secrets -n "${KRO_NAMESPACE}" -l kro.run/cluster=true
echo ""
echo "Kubeconfig files exported to ${ROOT_DIR}:"
echo "  - local.kubeconfig (host cluster)"
echo "  - consumer1.kubeconfig (us-east)"
echo "  - consumer2.kubeconfig (us-west)"
echo "  - consumer3.kubeconfig (eu-central)"
echo ""
echo "Usage: kubectl --kubeconfig=local.kubeconfig get pods -A"
echo ""
echo "========================================"
echo "Next steps:"
echo "========================================"
echo ""
echo "1. Start the KRO controller with multicluster mode:"
echo "   cd ${ROOT_DIR}"
echo "   go run ./cmd/controller --enable-multicluster"
echo ""
echo "2. Run the multicluster test:"
echo "   ${SCRIPT_DIR}/test-multicluster.sh"
echo ""
echo "3. Cleanup when done:"
echo "   ${SCRIPT_DIR}/cleanup.sh"
echo ""
