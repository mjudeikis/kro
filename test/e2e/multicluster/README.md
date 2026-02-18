# Multicluster E2E Tests

This directory contains end-to-end tests for KRO's multicluster functionality.

## Overview

The test suite demonstrates KRO's ability to manage resources across multiple Kubernetes clusters from a single control plane. It creates:

- **1 Central Control Plane** (`kro-host`) - Runs the KRO controller
- **3 Consumer Clusters** - Simulate different regions/environments:
  - `kro-consumer-1` (us-east)
  - `kro-consumer-2` (us-west)
  - `kro-consumer-3` (eu-central)

```
                    ┌─────────────────────────────────────┐
                    │         kro-host (Control Plane)    │
                    │                                     │
                    │  ┌─────────────────────────────┐    │
                    │  │      KRO Controller         │    │
                    │  │  - ResourceGraphDefinitions │    │
                    │  │  - Cluster Discovery        │    │
                    │  └─────────────────────────────┘    │
                    └──────────────┬──────────────────────┘
                                   │
           ┌───────────────────────┼───────────────────────┐
           │                       │                       │
           ▼                       ▼                       ▼
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│  kro-consumer-1  │    │  kro-consumer-2  │    │  kro-consumer-3  │
│    (us-east)     │    │    (us-west)     │    │   (eu-central)   │
│                  │    │                  │    │                  │
│  ┌────────────┐  │    │  ┌────────────┐  │    │  ┌────────────┐  │
│  │ MCWebApp   │  │    │  │ MCWebApp   │  │    │  │ MCWebApp   │  │
│  │ Instance   │  │    │  │ Instance   │  │    │  │ Instance   │  │
│  └────────────┘  │    │  └────────────┘  │    │  └────────────┘  │
│        │         │    │        │         │    │        │         │
│        ▼         │    │        ▼         │    │        ▼         │
│  ┌────────────┐  │    │  ┌────────────┐  │    │  ┌────────────┐  │
│  │ Deployment │  │    │  │ Deployment │  │    │  │ Deployment │  │
│  │ (2 pods)   │  │    │  │ (2 pods)   │  │    │  │ (2 pods)   │  │
│  └────────────┘  │    │  └────────────┘  │    │  └────────────┘  │
└──────────────────┘    └──────────────────┘    └──────────────────┘
```

## Prerequisites

- `kind` (Kubernetes in Docker)
- `kubectl`
- `go` (for running the controller)
- `docker`

## Quick Start

```bash
# 1. Create the clusters and register them
./setup.sh

# 2. In a separate terminal, start KRO with multicluster mode
cd /path/to/kro
go run ./cmd/controller --enable-multicluster

# 3. Run the tests
./test-multicluster.sh

# 4. Cleanup when done
./cleanup.sh
```

## What the Test Does

1. **Cluster Connectivity** - Verifies all 4 clusters are accessible
2. **Namespace Setup** - Creates test namespace on all consumer clusters
3. **Cluster Discovery** - Verifies KRO discovered all consumer clusters via secrets
4. **RGD Creation** - Creates a ResourceGraphDefinition on the host cluster
5. **CRD Sync** - Copies the generated CRD to all consumer clusters
6. **Instance Creation** - Creates MCWebApp instances on all 3 consumer clusters
7. **Child Resources** - Verifies Deployments are created on each cluster
8. **Availability** - Waits for all Deployments to become available
9. **Status Propagation** - Verifies instance status is updated

## Test Output Example

```
========================================
    KRO Multicluster E2E Test Suite
========================================

Testing deployment across:
  - 1 central control plane (kind-kro-host)
  - 3 consumer clusters (us-east, us-west, eu-central)

=== Test 1: Cluster Connectivity ===
PASS: Host cluster (kind-kro-host) is accessible
PASS: Consumer cluster us-east (kind-kro-consumer-1) is accessible
PASS: Consumer cluster us-west (kind-kro-consumer-2) is accessible
PASS: Consumer cluster eu-central (kind-kro-consumer-3) is accessible

...

=== Test Summary ===

Deployments across all clusters:

REGION          DEPLOYMENT                REPLICAS   AVAILABLE
------          ----------                --------   ---------
us-east         webapp-us-east            2          2
us-west         webapp-us-west            2          2
eu-central      webapp-eu-central         2          2

========================================
        All Tests Passed!
========================================

KRO successfully managed resources across 3 consumer clusters
from a single central control plane.
```

## Manual Testing

For manual testing without the scripts:

```bash
# 1. Create clusters
kind create cluster --name kro-host
kind create cluster --name kro-consumer-1
kind create cluster --name kro-consumer-2
kind create cluster --name kro-consumer-3

# 2. Install KRO CRDs on host
kubectl --context=kind-kro-host apply -f helm/crds/

# 3. Create kro-system namespace
kubectl --context=kind-kro-host create ns kro-system

# 4. Register consumer clusters (repeat for each)
# Get the Docker IP for inter-cluster communication
CONSUMER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kro-consumer-1-control-plane)
kind get kubeconfig --name=kro-consumer-1 > /tmp/consumer-1.kubeconfig
sed -i "s|server: https://127.0.0.1:[0-9]*|server: https://${CONSUMER_IP}:6443|g" /tmp/consumer-1.kubeconfig

kubectl --context=kind-kro-host create secret generic cluster-us-east \
  -n kro-system \
  --from-file=kubeconfig=/tmp/consumer-1.kubeconfig
kubectl --context=kind-kro-host label secret cluster-us-east \
  -n kro-system \
  kro.run/cluster=true

# 5. Run controller with multicluster mode
go run ./cmd/controller --enable-multicluster

# 6. Create RGD on host
kubectl --context=kind-kro-host apply -f examples/multicluster/simple-webapp-rgd.yaml

# 7. Copy CRD to consumer clusters
kubectl --context=kind-kro-host get crd simplewebapps.kro.run -o yaml | \
  kubectl --context=kind-kro-consumer-1 apply -f -

# 8. Create instance on consumer cluster
kubectl --context=kind-kro-consumer-1 apply -f examples/multicluster/simple-webapp-instance.yaml

# 9. Verify resources
kubectl --context=kind-kro-consumer-1 get all -n default
```

## Troubleshooting

### Clusters not being discovered

Check that:
1. Secrets have the `kro.run/cluster=true` label
2. Secrets are in the `kro-system` namespace
3. KRO controller is running with `--enable-multicluster` flag

```bash
# List cluster secrets
kubectl --context=kind-kro-host get secrets -n kro-system -l kro.run/cluster=true
```

### Controller logs

```bash
# Check KRO controller logs for cluster engagement
go run ./cmd/controller --enable-multicluster 2>&1 | grep -E "(Engaging|cluster)"
```

### Network issues between clusters

When using kind, clusters communicate via Docker network IPs, not localhost:

```bash
# Verify the kubeconfig in the secret uses the Docker IP
kubectl --context=kind-kro-host get secret cluster-us-east -n kro-system -o jsonpath='{.data.kubeconfig}' | base64 -d | grep server
```
