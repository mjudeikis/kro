# Multicluster Examples

This directory contains example configurations for setting up KRO in multicluster mode.

## Contents

- `cluster-secret.yaml` - Example secret for registering a remote cluster
- `rbac-remote-cluster.yaml` - RBAC configuration for remote clusters
- `simple-webapp-rgd.yaml` - Simple webapp ResourceGraphDefinition
- `simple-webapp-instance.yaml` - Instance to deploy on remote clusters

## Quick Start

1. Enable multicluster mode on KRO (on host cluster):
   ```bash
   # If running locally
   go run ./cmd/controller --enable-multicluster

   # If using Helm, add to values:
   # controller:
   #   args:
   #     - --enable-multicluster
   ```

2. Create RBAC on the remote cluster:
   ```bash
   kubectl --context=remote-cluster apply -f rbac-remote-cluster.yaml
   ```

3. Register the remote cluster (on host cluster):
   ```bash
   # Get the kubeconfig for the remote cluster
   kubectl --context=remote-cluster config view --minify --raw > /tmp/remote-kubeconfig

   # Create the secret
   kubectl create secret generic my-remote-cluster \
     --namespace=kro-system \
     --from-file=kubeconfig=/tmp/remote-kubeconfig

   # Label it for discovery
   kubectl label secret my-remote-cluster \
     --namespace=kro-system \
     kro.run/cluster=true
   ```

4. Apply the ResourceGraphDefinition (on host cluster):
   ```bash
   kubectl apply -f simple-webapp-rgd.yaml
   ```

5. Create an instance on the remote cluster:
   ```bash
   kubectl --context=remote-cluster apply -f simple-webapp-instance.yaml
   ```

6. Verify the resources were created:
   ```bash
   kubectl --context=remote-cluster get all -n default
   ```

## Using kind for Testing

Create a two-cluster setup with kind:

```bash
# Create host cluster
kind create cluster --name host

# Create remote cluster
kind create cluster --name remote

# Switch to host cluster context
kubectl config use-context kind-host

# Install KRO on host cluster
make install
go run ./cmd/controller --enable-multicluster &

# Get remote cluster kubeconfig
kind get kubeconfig --name=remote > /tmp/remote-kubeconfig

# Create cluster secret on host
kubectl create namespace kro-system
kubectl create secret generic remote-cluster \
  --namespace=kro-system \
  --from-file=kubeconfig=/tmp/remote-kubeconfig
kubectl label secret remote-cluster \
  --namespace=kro-system \
  kro.run/cluster=true

# Apply RGD
kubectl apply -f simple-webapp-rgd.yaml

# Create instance on remote cluster
kubectl --context=kind-remote apply -f simple-webapp-instance.yaml
```
