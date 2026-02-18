#!/usr/bin/env bash
# Multicluster E2E Test Script
#
# Tests KRO's multicluster functionality by:
# 1. Creating an RGD on the central host cluster
# 2. Creating instances on all 3 consumer clusters
# 3. Verifying child resources are created on each consumer cluster
#
# This demonstrates deploying the same application definition across
# multiple clusters (regions) from a single control plane.

set -euo pipefail

# Parse command line arguments
SKIP_CLEANUP=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-cleanup)
            SKIP_CLEANUP=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--skip-cleanup]"
            echo ""
            echo "Options:"
            echo "  --skip-cleanup  Skip cleanup of test resources (useful for debugging)"
            echo "  -h, --help      Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

HOST_CONTEXT="kind-kro-host"
CONSUMER_CLUSTERS=("kro-consumer-1" "kro-consumer-2" "kro-consumer-3")
TEST_NAMESPACE="multicluster-test"

# Friendly names for display
declare -A CLUSTER_LABELS
CLUSTER_LABELS["kro-consumer-1"]="us-east"
CLUSTER_LABELS["kro-consumer-2"]="us-west"
CLUSTER_LABELS["kro-consumer-3"]="eu-central"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; exit 1; }
info() { echo -e "${YELLOW}INFO${NC}: $1"; }
section() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# Wait for a condition with timeout
wait_for() {
    local desc="$1"
    local timeout="$2"
    shift 2
    local cmd="$@"

    info "Waiting for ${desc} (timeout: ${timeout}s)..."
    local count=0
    while ! eval "${cmd}" >/dev/null 2>&1; do
        if [ $count -ge $timeout ]; then
            fail "Timeout waiting for ${desc}"
        fi
        sleep 1
        count=$((count + 1))
    done
    pass "${desc}"
}

echo ""
echo "========================================"
echo "    KRO Multicluster E2E Test Suite    "
echo "========================================"
echo ""
echo "Testing deployment across:"
echo "  - 1 central control plane (${HOST_CONTEXT})"
echo "  - 3 consumer clusters (us-east, us-west, eu-central)"
echo ""

# Verify all clusters are accessible
section "Test 1: Cluster Connectivity"
info "Verifying cluster connectivity..."
kubectl --context="${HOST_CONTEXT}" get nodes >/dev/null 2>&1 || fail "Cannot connect to host cluster"
pass "Host cluster (${HOST_CONTEXT}) is accessible"

for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    CONTEXT="kind-${CONSUMER}"
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    kubectl --context="${CONTEXT}" get nodes >/dev/null 2>&1 || fail "Cannot connect to ${CONSUMER}"
    pass "Consumer cluster ${LABEL} (${CONTEXT}) is accessible"
done

# Create test namespace on all consumer clusters
section "Test 2: Namespace Setup"
for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    CONTEXT="kind-${CONSUMER}"
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    info "Creating test namespace on ${LABEL}..."
    kubectl --context="${CONTEXT}" create namespace "${TEST_NAMESPACE}" --dry-run=client -o yaml | \
        kubectl --context="${CONTEXT}" apply -f -
done
pass "Test namespace created on all consumer clusters"

# Verify cluster secrets exist
section "Test 3: Cluster Discovery"
info "Checking if all consumer cluster secrets exist on host..."
for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    SECRET_NAME="cluster-${LABEL}"
    kubectl --context="${HOST_CONTEXT}" get secret "${SECRET_NAME}" -n kro-system >/dev/null 2>&1 || \
        fail "Cluster secret ${SECRET_NAME} not found"
    pass "Cluster secret '${SECRET_NAME}' exists"
done

# Create RGD on host cluster
section "Test 4: Create ResourceGraphDefinition"
info "Applying RGD to host cluster..."
cat <<EOF | kubectl --context="${HOST_CONTEXT}" apply -f -
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: multicluster-webapp
spec:
  schema:
    apiVersion: v1alpha1
    kind: MCWebApp
    spec:
      name: string
      replicas: integer | default=1
      region: string | default="unknown"
    status:
      availableReplicas: \${deployment.status.availableReplicas}
  resources:
    - id: deployment
      template:
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: \${schema.spec.name}
          labels:
            app: \${schema.spec.name}
            region: \${schema.spec.region}
        spec:
          replicas: \${schema.spec.replicas}
          selector:
            matchLabels:
              app: \${schema.spec.name}
          template:
            metadata:
              labels:
                app: \${schema.spec.name}
                region: \${schema.spec.region}
            spec:
              containers:
                - name: nginx
                  image: nginx:1.25
                  ports:
                    - containerPort: 80
                  env:
                    - name: REGION
                      value: \${schema.spec.region}
EOF

wait_for "RGD to be Active" 60 \
    "kubectl --context=${HOST_CONTEXT} get rgd multicluster-webapp -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"

# Copy the generated CRD to all consumer clusters
section "Test 5: Sync CRD to Consumer Clusters"
info "Copying MCWebApp CRD from host to all consumer clusters..."
for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    CONTEXT="kind-${CONSUMER}"
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    kubectl --context="${HOST_CONTEXT}" get crd mcwebapps.kro.run -o yaml | \
        kubectl --context="${CONTEXT}" apply -f -
    pass "CRD synced to ${LABEL}"
done

# Create instances on all consumer clusters
section "Test 6: Create Instances on Consumer Clusters"
for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    CONTEXT="kind-${CONSUMER}"
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    info "Creating MCWebApp instance on ${LABEL}..."
    cat <<EOF | kubectl --context="${CONTEXT}" apply -f -
apiVersion: kro.run/v1alpha1
kind: MCWebApp
metadata:
  name: webapp-${LABEL}
  namespace: ${TEST_NAMESPACE}
spec:
  name: webapp-${LABEL}
  replicas: 2
  region: ${LABEL}
EOF
    pass "Instance created on ${LABEL}"
done

# Verify deployments are created on all consumer clusters
section "Test 7: Verify Child Resources"
for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    CONTEXT="kind-${CONSUMER}"
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    wait_for "Deployment on ${LABEL}" 60 \
        "kubectl --context=${CONTEXT} get deployment webapp-${LABEL} -n ${TEST_NAMESPACE}"
done

# Wait for deployments to be available
section "Test 8: Verify Deployment Availability"
for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    CONTEXT="kind-${CONSUMER}"
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    wait_for "Deployment available on ${LABEL}" 120 \
        "kubectl --context=${CONTEXT} get deployment webapp-${LABEL} -n ${TEST_NAMESPACE} -o jsonpath='{.status.availableReplicas}' | grep -qE '^[1-9]'"
done

# Verify instance status is updated
section "Test 9: Verify Instance Status"
for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    CONTEXT="kind-${CONSUMER}"
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    wait_for "Instance status on ${LABEL}" 30 \
        "kubectl --context=${CONTEXT} get mcwebapp webapp-${LABEL} -n ${TEST_NAMESPACE} -o jsonpath='{.status.availableReplicas}' | grep -qE '^[1-9]'"
done

# Display summary
section "Test Summary"
echo ""
echo "Deployments across all clusters:"
echo ""
printf "%-15s %-25s %-10s %-10s\n" "REGION" "DEPLOYMENT" "REPLICAS" "AVAILABLE"
printf "%-15s %-25s %-10s %-10s\n" "------" "----------" "--------" "---------"
for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
    CONTEXT="kind-${CONSUMER}"
    LABEL="${CLUSTER_LABELS[$CONSUMER]}"
    DEPLOYMENT="webapp-${LABEL}"
    REPLICAS=$(kubectl --context="${CONTEXT}" get deployment "${DEPLOYMENT}" -n "${TEST_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "N/A")
    AVAILABLE=$(kubectl --context="${CONTEXT}" get deployment "${DEPLOYMENT}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "N/A")
    printf "%-15s %-25s %-10s %-10s\n" "${LABEL}" "${DEPLOYMENT}" "${REPLICAS}" "${AVAILABLE}"
done
echo ""

# Cleanup
section "Cleanup"
if [ "$SKIP_CLEANUP" = true ]; then
    info "Skipping cleanup (--skip-cleanup flag set)"
    info "To clean up manually, run:"
    echo "  kubectl --context=${HOST_CONTEXT} delete rgd multicluster-webapp"
    for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
        LABEL="${CLUSTER_LABELS[$CONSUMER]}"
        echo "  kubectl --context=kind-${CONSUMER} delete mcwebapp webapp-${LABEL} -n ${TEST_NAMESPACE}"
    done
else
    info "Cleaning up test resources..."

    # Delete instances from consumer clusters
    for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
        CONTEXT="kind-${CONSUMER}"
        LABEL="${CLUSTER_LABELS[$CONSUMER]}"
        kubectl --context="${CONTEXT}" delete mcwebapp "webapp-${LABEL}" -n "${TEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1
    done

    # Delete RGD from host
    kubectl --context="${HOST_CONTEXT}" delete rgd multicluster-webapp --ignore-not-found >/dev/null 2>&1

    # Delete CRDs from consumer clusters
    for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
        CONTEXT="kind-${CONSUMER}"
        kubectl --context="${CONTEXT}" delete crd mcwebapps.kro.run --ignore-not-found >/dev/null 2>&1
    done

    # Delete test namespaces
    for CONSUMER in "${CONSUMER_CLUSTERS[@]}"; do
        CONTEXT="kind-${CONSUMER}"
        kubectl --context="${CONTEXT}" delete namespace "${TEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1
    done

    pass "Cleanup complete"
fi

echo ""
echo "========================================"
echo "        All Tests Passed!              "
echo "========================================"
echo ""
echo "KRO successfully managed resources across 3 consumer clusters"
echo "from a single central control plane."
echo ""
