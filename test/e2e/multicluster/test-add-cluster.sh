#!/usr/bin/env bash
# Test Adding a New Cluster Dynamically
#
# This script tests the scenario where:
# 1. KRO is already running with an RGD defined
# 2. A new consumer cluster is added dynamically
# 3. KRO discovers the new cluster and propagates the RGD
# 4. An instance can be created on the new cluster
#
# Prerequisites:
# - Run setup.sh first to create the base clusters
# - KRO controller should be running with --enable-multicluster
# - Run test-multicluster.sh --skip-cleanup first to have an active RGD

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
            echo "This script tests adding a new cluster dynamically while KRO is running."
            echo ""
            echo "Prerequisites:"
            echo "  1. Run setup.sh first"
            echo "  2. Start KRO controller with --enable-multicluster"
            echo "  3. Run test-multicluster.sh --skip-cleanup to create an RGD"
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
NEW_CLUSTER="kro-consumer-4"
NEW_CLUSTER_LABEL="ap-southeast"
KRO_NAMESPACE="kro-system"
TEST_NAMESPACE="multicluster-test"

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
echo "  KRO Dynamic Cluster Addition Test    "
echo "========================================"
echo ""
echo "Testing adding a new cluster (${NEW_CLUSTER_LABEL}) while KRO is running"
echo ""

# Verify prerequisites
section "Test 1: Verify Prerequisites"

# Check host cluster is accessible
kubectl --context="${HOST_CONTEXT}" get nodes >/dev/null 2>&1 || fail "Cannot connect to host cluster"
pass "Host cluster is accessible"

# Check RGD exists
kubectl --context="${HOST_CONTEXT}" get rgd multicluster-webapp >/dev/null 2>&1 || \
    fail "RGD 'multicluster-webapp' not found. Run test-multicluster.sh --skip-cleanup first"
pass "RGD 'multicluster-webapp' exists"

# Check RGD is Active
RGD_STATE=$(kubectl --context="${HOST_CONTEXT}" get rgd multicluster-webapp -o jsonpath='{.status.state}' 2>/dev/null || echo "Unknown")
if [ "$RGD_STATE" != "Active" ]; then
    fail "RGD is not Active (current state: ${RGD_STATE}). Is KRO controller running?"
fi
pass "RGD is Active"

# Create the new cluster
section "Test 2: Create New Cluster"

if kind get clusters 2>/dev/null | grep -q "^${NEW_CLUSTER}$"; then
    info "Cluster ${NEW_CLUSTER} already exists, deleting first..."
    kind delete cluster --name "${NEW_CLUSTER}"
fi

info "Creating new cluster: ${NEW_CLUSTER} (${NEW_CLUSTER_LABEL})..."
kind create cluster --name "${NEW_CLUSTER}" --wait 60s
pass "Cluster ${NEW_CLUSTER} created"

# Export kubeconfig for easy access
KUBECONFIG_FILE="${ROOT_DIR}/consumer4.kubeconfig"
kind get kubeconfig --name="${NEW_CLUSTER}" > "${KUBECONFIG_FILE}"
NEW_CLUSTER_CONTAINER="${NEW_CLUSTER}-control-plane"
NEW_CLUSTER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${NEW_CLUSTER_CONTAINER}")
sed -i.bak "s|server: https://127.0.0.1:[0-9]*|server: https://${NEW_CLUSTER_IP}:6443|g" "${KUBECONFIG_FILE}"
rm -f "${KUBECONFIG_FILE}.bak"
info "Exported: consumer4.kubeconfig (${NEW_CLUSTER_LABEL})"

# Register the new cluster with KRO
section "Test 3: Register New Cluster with KRO"

info "Getting kubeconfig for new cluster..."
NEW_CLUSTER_KUBECONFIG=$(mktemp)
kind get kubeconfig --name="${NEW_CLUSTER}" > "${NEW_CLUSTER_KUBECONFIG}"

# Update server URL to use Docker network IP
NEW_CLUSTER_CONTAINER="${NEW_CLUSTER}-control-plane"
NEW_CLUSTER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${NEW_CLUSTER_CONTAINER}")
sed -i.bak "s|server: https://127.0.0.1:[0-9]*|server: https://${NEW_CLUSTER_IP}:6443|g" "${NEW_CLUSTER_KUBECONFIG}"

info "Creating cluster secret on host..."
SECRET_NAME="cluster-${NEW_CLUSTER_LABEL}"
kubectl --context="${HOST_CONTEXT}" create secret generic "${SECRET_NAME}" \
    --namespace="${KRO_NAMESPACE}" \
    --from-file=kubeconfig="${NEW_CLUSTER_KUBECONFIG}" \
    --dry-run=client -o yaml | kubectl --context="${HOST_CONTEXT}" apply -f -

kubectl --context="${HOST_CONTEXT}" label secret "${SECRET_NAME}" \
    --namespace="${KRO_NAMESPACE}" \
    kro.run/cluster=true \
    kro.run/region="${NEW_CLUSTER_LABEL}" \
    --overwrite

rm -f "${NEW_CLUSTER_KUBECONFIG}" "${NEW_CLUSTER_KUBECONFIG}.bak"
pass "Cluster secret '${SECRET_NAME}' created"

# Wait for KRO to discover the new cluster
section "Test 4: Wait for Cluster Discovery"

info "Waiting for KRO to discover the new cluster..."
info "(Check KRO controller logs for 'Engaging cluster' message)"
sleep 5  # Give KRO time to notice the new secret
pass "Cluster registration complete"

# Copy CRD to the new cluster (until automatic CRD sync is implemented)
section "Test 5: Sync CRD to New Cluster"

NEW_CONTEXT="kind-${NEW_CLUSTER}"
info "Copying MCWebApp CRD to new cluster..."
kubectl --context="${HOST_CONTEXT}" get crd mcwebapps.kro.run -o yaml | \
    kubectl --context="${NEW_CONTEXT}" apply -f -
pass "CRD synced to ${NEW_CLUSTER_LABEL}"

# Create test namespace on new cluster
section "Test 6: Create Test Namespace"

info "Creating test namespace on ${NEW_CLUSTER_LABEL}..."
kubectl --context="${NEW_CONTEXT}" create namespace "${TEST_NAMESPACE}" --dry-run=client -o yaml | \
    kubectl --context="${NEW_CONTEXT}" apply -f -
pass "Test namespace created"

# Create instance on the new cluster
section "Test 7: Create Instance on New Cluster"

info "Creating MCWebApp instance on ${NEW_CLUSTER_LABEL}..."
cat <<EOF | kubectl --context="${NEW_CONTEXT}" apply -f -
apiVersion: kro.run/v1alpha1
kind: MCWebApp
metadata:
  name: webapp-${NEW_CLUSTER_LABEL}
  namespace: ${TEST_NAMESPACE}
spec:
  name: webapp-${NEW_CLUSTER_LABEL}
  replicas: 2
  region: ${NEW_CLUSTER_LABEL}
EOF
pass "Instance created on ${NEW_CLUSTER_LABEL}"

# Verify deployment is created
section "Test 8: Verify Child Resources"

wait_for "Deployment on ${NEW_CLUSTER_LABEL}" 60 \
    "kubectl --context=${NEW_CONTEXT} get deployment webapp-${NEW_CLUSTER_LABEL} -n ${TEST_NAMESPACE}"

# Wait for deployment to be available
section "Test 9: Verify Deployment Availability"

wait_for "Deployment available on ${NEW_CLUSTER_LABEL}" 120 \
    "kubectl --context=${NEW_CONTEXT} get deployment webapp-${NEW_CLUSTER_LABEL} -n ${TEST_NAMESPACE} -o jsonpath='{.status.availableReplicas}' | grep -qE '^[1-9]'"

# Verify instance status
section "Test 10: Verify Instance Status"

wait_for "Instance status on ${NEW_CLUSTER_LABEL}" 30 \
    "kubectl --context=${NEW_CONTEXT} get mcwebapp webapp-${NEW_CLUSTER_LABEL} -n ${TEST_NAMESPACE} -o jsonpath='{.status.availableReplicas}' | grep -qE '^[1-9]'"

# Display summary
section "Test Summary"
echo ""
echo "New cluster deployment:"
echo ""
printf "%-15s %-25s %-10s %-10s\n" "REGION" "DEPLOYMENT" "REPLICAS" "AVAILABLE"
printf "%-15s %-25s %-10s %-10s\n" "------" "----------" "--------" "---------"
DEPLOYMENT="webapp-${NEW_CLUSTER_LABEL}"
REPLICAS=$(kubectl --context="${NEW_CONTEXT}" get deployment "${DEPLOYMENT}" -n "${TEST_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "N/A")
AVAILABLE=$(kubectl --context="${NEW_CONTEXT}" get deployment "${DEPLOYMENT}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "N/A")
printf "%-15s %-25s %-10s %-10s\n" "${NEW_CLUSTER_LABEL}" "${DEPLOYMENT}" "${REPLICAS}" "${AVAILABLE}"
echo ""

# Cleanup
section "Cleanup"
if [ "$SKIP_CLEANUP" = true ]; then
    info "Skipping cleanup (--skip-cleanup flag set)"
    info "To clean up manually, run:"
    echo "  kubectl --context=${NEW_CONTEXT} delete mcwebapp webapp-${NEW_CLUSTER_LABEL} -n ${TEST_NAMESPACE}"
    echo "  kubectl --context=${HOST_CONTEXT} delete secret cluster-${NEW_CLUSTER_LABEL} -n ${KRO_NAMESPACE}"
    echo "  kind delete cluster --name ${NEW_CLUSTER}"
    echo "  rm -f ${ROOT_DIR}/consumer4.kubeconfig"
else
    info "Cleaning up test resources..."

    # Delete instance from new cluster
    kubectl --context="${NEW_CONTEXT}" delete mcwebapp "webapp-${NEW_CLUSTER_LABEL}" -n "${TEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1

    # Delete CRD from new cluster
    kubectl --context="${NEW_CONTEXT}" delete crd mcwebapps.kro.run --ignore-not-found >/dev/null 2>&1

    # Delete test namespace from new cluster
    kubectl --context="${NEW_CONTEXT}" delete namespace "${TEST_NAMESPACE}" --ignore-not-found >/dev/null 2>&1

    # Delete cluster secret from host
    kubectl --context="${HOST_CONTEXT}" delete secret "cluster-${NEW_CLUSTER_LABEL}" -n "${KRO_NAMESPACE}" --ignore-not-found >/dev/null 2>&1

    # Delete the new cluster
    kind delete cluster --name "${NEW_CLUSTER}"

    # Remove kubeconfig file
    rm -f "${ROOT_DIR}/consumer4.kubeconfig"

    pass "Cleanup complete"
fi

echo ""
echo "========================================"
echo "        All Tests Passed!              "
echo "========================================"
echo ""
echo "KRO successfully discovered and managed resources on a"
echo "dynamically added cluster (${NEW_CLUSTER_LABEL})."
echo ""
