# Multicluster Setup Guide

This guide explains how to configure KRO to operate in multicluster mode, allowing you to manage resources across multiple Kubernetes clusters from a single control plane.

## Overview

KRO supports two operational modes:

1. **Single-cluster mode** (default): KRO manages resources only on the cluster where it runs.
2. **Multicluster mode**: KRO discovers additional clusters via kubeconfig secrets and manages instances across all discovered clusters.

In multicluster mode:
- **ResourceGraphDefinitions (RGDs)** are defined on the host/control plane cluster only
- **Instances** of RGDs can be created on any discovered cluster
- CRDs generated from RGDs are installed on the host cluster
- Child resources are created on the same cluster as their parent instance

## Prerequisites

- KRO installed on the host cluster
- Network connectivity between the host cluster and remote clusters
- Kubeconfig credentials with appropriate permissions for remote clusters

## Enabling Multicluster Mode

### Controller Flags

To enable multicluster mode, start the KRO controller with the following flags:

```bash
go run ./cmd/controller \
  --enable-multicluster \
  --cluster-secrets-namespace=kro-system \
  --cluster-secrets-label=kro.run/cluster \
  --cluster-secrets-key=kubeconfig
```

| Flag | Default | Description |
|------|---------|-------------|
| `--enable-multicluster` | `false` | Enable multicluster mode |
| `--cluster-secrets-namespace` | `kro-system` | Namespace where cluster kubeconfig secrets are stored |
| `--cluster-secrets-label` | `kro.run/cluster` | Label used to identify secrets containing kubeconfig data |
| `--cluster-secrets-key` | `kubeconfig` | Key in the secret data that contains the kubeconfig |

### Helm Values

If using Helm to deploy KRO, add these values:

```yaml
controller:
  args:
    - --enable-multicluster
    - --cluster-secrets-namespace=kro-system
    - --cluster-secrets-label=kro.run/cluster
    - --cluster-secrets-key=kubeconfig
```

## Registering Clusters

Remote clusters are registered by creating Kubernetes secrets containing kubeconfig data. KRO watches for secrets with the configured label and automatically discovers new clusters.

### Creating a Cluster Secret

1. Generate or obtain the kubeconfig for the remote cluster:

```bash
# Example: Get kubeconfig for a kind cluster
kind get kubeconfig --name=remote-cluster > /tmp/remote-kubeconfig
```

2. Create the secret in the configured namespace:

```bash
kubectl create secret generic remote-cluster \
  --namespace=kro-system \
  --from-file=kubeconfig=/tmp/remote-kubeconfig

kubectl label secret remote-cluster \
  --namespace=kro-system \
  kro.run/cluster=true
```

Or using a YAML manifest:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: remote-cluster
  namespace: kro-system
  labels:
    kro.run/cluster: "true"
type: Opaque
data:
  kubeconfig: <base64-encoded-kubeconfig>
```

### Kubeconfig Requirements

The kubeconfig in the secret must:
- Be a complete, self-contained kubeconfig (not referencing external files)
- Have the `current-context` set to the target cluster
- Use credentials that can reach the cluster from the host cluster's network

Example kubeconfig structure:

```yaml
apiVersion: v1
kind: Config
current-context: remote-cluster
clusters:
- name: remote-cluster
  cluster:
    server: https://remote-cluster-api.example.com:6443
    certificate-authority-data: <base64-ca-cert>
contexts:
- name: remote-cluster
  context:
    cluster: remote-cluster
    user: kro-admin
users:
- name: kro-admin
  user:
    client-certificate-data: <base64-client-cert>
    client-key-data: <base64-client-key>
```

### Required RBAC Permissions

KRO needs sufficient permissions on remote clusters to manage resources. Create appropriate RBAC on each remote cluster:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kro
  namespace: kro-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kro-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin  # Or a more restrictive custom role
subjects:
- kind: ServiceAccount
  name: kro
  namespace: kro-system
```

## Verifying Cluster Discovery

When a cluster secret is created with the correct label, KRO will:

1. Detect the new secret
2. Parse the kubeconfig
3. Establish connection to the remote cluster
4. Call `Engage` on all multicluster-aware components

Check the controller logs for cluster discovery:

```bash
kubectl logs -n kro-system deployment/kro-controller | grep -i cluster
```

Expected log messages:
```
INFO    Multicluster mode enabled    {"namespace": "kro-system", "label": "kro.run/cluster", "key": "kubeconfig"}
INFO    Engaging with cluster        {"cluster": "remote-cluster"}
```

## Creating Instances on Remote Clusters

Once a cluster is discovered, you can create instances on it by applying the instance manifest to the remote cluster:

```bash
# Create instance on remote cluster
kubectl --context=remote-cluster apply -f - <<EOF
apiVersion: kro.run/v1alpha1
kind: MyApp
metadata:
  name: my-instance
  namespace: default
spec:
  # ... your instance spec
EOF
```

KRO will automatically:
1. Detect the new instance on the remote cluster
2. Create child resources on the same remote cluster
3. Update the instance status based on child resource states

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Host Cluster                                │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────────┐  │
│  │      RGDs       │  │   KRO Controller │  │ Cluster Secrets│  │
│  │ (definitions)   │──│  (multicluster)  │──│  (kubeconfigs) │  │
│  └─────────────────┘  └────────┬─────────┘  └────────────────┘  │
│                                │                                 │
└────────────────────────────────│─────────────────────────────────┘
                                 │
         ┌───────────────────────┼───────────────────────┐
         │                       │                       │
         ▼                       ▼                       ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│ Remote Cluster A│    │ Remote Cluster B│    │ Remote Cluster C│
│  ┌───────────┐  │    │  ┌───────────┐  │    │  ┌───────────┐  │
│  │ Instances │  │    │  │ Instances │  │    │  │ Instances │  │
│  │  + Child  │  │    │  │  + Child  │  │    │  │  + Child  │  │
│  │ Resources │  │    │  │ Resources │  │    │  │ Resources │  │
│  └───────────┘  │    │  └───────────┘  │    │  └───────────┘  │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## Removing a Cluster

To remove a cluster from KRO management:

1. Delete all instances on the remote cluster first (optional but recommended)
2. Delete the cluster secret:

```bash
kubectl delete secret remote-cluster -n kro-system
```

KRO will detect the secret deletion and stop watching the cluster. Existing resources on the remote cluster will remain but will no longer be managed.

## Troubleshooting

### Cluster Not Discovered

1. Verify the secret has the correct label:
   ```bash
   kubectl get secret -n kro-system -l kro.run/cluster=true
   ```

2. Verify the kubeconfig key exists:
   ```bash
   kubectl get secret remote-cluster -n kro-system -o jsonpath='{.data.kubeconfig}' | base64 -d
   ```

3. Check controller logs for errors:
   ```bash
   kubectl logs -n kro-system deployment/kro-controller
   ```

### Connection Failures

1. Verify network connectivity from host cluster to remote API server
2. Check that the kubeconfig server URL is reachable
3. Verify certificates are valid and not expired
4. Ensure service account tokens (if used) are not expired

### Instance Not Being Reconciled

1. Verify the instance CRD exists on the host cluster
2. Check that the instance is being watched on the correct cluster
3. Look for errors in controller logs related to the specific instance

## Limitations

- RGDs can only be defined on the host cluster
- CRDs are only installed on the host cluster
- Cross-cluster resource dependencies are not supported (all child resources must be on the same cluster as the instance)
- Cluster discovery is based on secret labels only (no cluster API support yet)

## Security Considerations

- Store kubeconfig secrets securely; consider using external secret management
- Use least-privilege RBAC on remote clusters
- Rotate credentials periodically
- Consider network policies to restrict access between clusters
- Enable audit logging on all clusters
