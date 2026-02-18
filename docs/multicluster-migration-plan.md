# KRO Multicluster Migration Plan

## Executive Summary

This document outlines the plan to migrate KRO from standard `controller-runtime` to `multicluster-runtime` to enable multi-cluster operations. The migration enables KRO to manage ResourceGraphDefinitions and their instances across multiple Kubernetes clusters from a single control plane.

## Current Architecture

### Components Using controller-runtime

1. **Manager** ([cmd/controller/main.go:143-172](cmd/controller/main.go#L143-L172))
   - Standard `ctrl.NewManager()` with leader election, metrics, health probes
   - Custom HTTP client with QPS/Burst settings

2. **ResourceGraphDefinitionReconciler** ([pkg/controller/resourcegraphdefinition/controller.go](pkg/controller/resourcegraphdefinition/controller.go))
   - Standard controller-runtime reconciler
   - Uses `ctrl.NewControllerManagedBy(mgr)` builder pattern
   - Watches ResourceGraphDefinitions and CRDs

3. **DynamicController** ([pkg/dynamiccontroller/dynamic_controller.go](pkg/dynamiccontroller/dynamic_controller.go))
   - **Custom implementation** - NOT using controller-runtime controllers
   - Manages runtime-created watches for user-defined resources
   - Uses lazy informers and custom workqueue
   - Registered via `mgr.Add()` as a runnable

4. **Client Set** ([pkg/client/set.go](pkg/client/set.go))
   - Custom unified client wrapper
   - Shared HTTP client across Kubernetes, Dynamic, APIExtensions clients

### Key Integration Points

```
main.go
├── ctrl.NewManager()           → mcmanager.New()
├── RGD Reconciler             → Cluster-aware reconciler
├── DynamicController          → Multicluster DynamicController
└── client.Set                 → Cluster-aware client factory
```

---

## Migration Strategy

### Phase 1: Foundation - Manager and Provider Setup

**Goal**: Replace the standard manager with multicluster manager without changing reconciler behavior.

#### 1.1 Create Cluster Provider Interface

Create a flexible provider that supports multiple cluster discovery mechanisms:

**File**: `pkg/multicluster/provider/provider.go`

```go
// Provider wraps multicluster-runtime providers with KRO-specific configuration
type Provider interface {
    multicluster.Provider
    multicluster.ProviderRunnable
}

// Options for creating providers
type Options struct {
    // Type of provider: "kubeconfig", "cluster-api", "kind", "static"
    Type string

    // For kubeconfig provider
    KubeconfigNamespace string
    KubeconfigLabel     string

    // For static provider
    StaticClusters []StaticClusterConfig
}
```

**Recommended Provider**: `kubeconfig` provider (secret-based) for production, with `kind` for development.

#### 1.2 Update Manager Creation

**File**: `cmd/controller/main.go`

```go
// Before
mgr, err := ctrl.NewManager(restConfig, ctrl.Options{...})

// After
import (
    mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
    "sigs.k8s.io/multicluster-runtime/providers/kubeconfig"
)

// Create provider
provider := kubeconfig.New(kubeconfig.Options{
    Namespace:             clusterSecretsNamespace,
    KubeconfigSecretLabel: "kro.run/cluster",
    KubeconfigSecretKey:   "kubeconfig",
})

// Create multicluster manager
mgr, err := mcmanager.New(restConfig, provider, mcmanager.Options{
    Options: ctrl.Options{
        Scheme:                  scheme,
        Metrics:                 metricsserver.Options{BindAddress: metricsAddr},
        HealthProbeBindAddress:  probeAddr,
        LeaderElection:          enableLeaderElection,
        LeaderElectionID:        "controller.kro.run",
        LeaderElectionNamespace: leaderElectionNamespace,
        GracefulShutdownTimeout: &gracefulShutdownTimeout,
    },
})
```

#### 1.3 Add CLI Flags for Multicluster Mode

**File**: `cmd/controller/main.go`

```go
var (
    enableMulticluster       bool
    clusterSecretsNamespace  string
    clusterSecretsLabel      string
)

flag.BoolVar(&enableMulticluster, "enable-multicluster", false, "Enable multicluster mode")
flag.StringVar(&clusterSecretsNamespace, "cluster-secrets-namespace", "kro-system",
    "Namespace containing cluster kubeconfig secrets")
flag.StringVar(&clusterSecretsLabel, "cluster-secrets-label", "kro.run/cluster",
    "Label selector for cluster kubeconfig secrets")
```

---

### Phase 2: ResourceGraphDefinition Controller Migration

**Goal**: Make the RGD controller cluster-aware.

#### 2.1 Update Reconciler Signature

**File**: `pkg/controller/resourcegraphdefinition/controller.go`

```go
// Before
func (r *ResourceGraphDefinitionReconciler) Reconcile(
    ctx context.Context,
    o *v1alpha1.ResourceGraphDefinition,
) (ctrl.Result, error)

// After
import mcreconcile "sigs.k8s.io/multicluster-runtime/pkg/reconcile"

func (r *ResourceGraphDefinitionReconciler) Reconcile(
    ctx context.Context,
    req mcreconcile.Request,
) (ctrl.Result, error) {
    // Get cluster for this request
    cl, err := r.manager.GetCluster(ctx, req.ClusterName)
    if err != nil {
        return ctrl.Result{}, err
    }

    // Fetch RGD from specific cluster
    rgd := &v1alpha1.ResourceGraphDefinition{}
    if err := cl.GetClient().Get(ctx, req.NamespacedName, rgd); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // Include cluster context in all operations
    return r.reconcileWithCluster(ctx, req.ClusterName, cl, rgd)
}
```

#### 2.2 Update Controller Builder

**File**: `pkg/controller/resourcegraphdefinition/controller.go`

```go
import mcbuilder "sigs.k8s.io/multicluster-runtime/pkg/builder"

func (r *ResourceGraphDefinitionReconciler) SetupWithManager(mgr mcmanager.Manager) error {
    r.manager = mgr

    return mcbuilder.ControllerManagedBy(mgr).
        Named("ResourceGraphDefinition").
        For(&v1alpha1.ResourceGraphDefinition{}).
        WithEventFilter(predicate.GenerationChangedPredicate{}).
        WatchesMetadata(
            &extv1.CustomResourceDefinition{},
            handler.EnqueueRequestsFromMapFunc(r.findRGDsForCRD),
        ).
        Complete(r)
}
```

#### 2.3 Add Cluster Context to CRD Management

The RGD controller creates CRDs on clusters. This needs cluster-specific handling:

```go
func (r *ResourceGraphDefinitionReconciler) ensureCRD(
    ctx context.Context,
    clusterName string,
    cl cluster.Cluster,
    rgd *v1alpha1.ResourceGraphDefinition,
) error {
    // Use cluster-specific client for CRD operations
    apiextClient := cl.GetClient()

    // Create/update CRD on the specific cluster
    // ...
}
```

---

### Phase 3: DynamicController Multicluster Support

**Goal**: Make the custom DynamicController cluster-aware.

This is the most complex part because DynamicController is a custom implementation.

#### 3.1 Create Multicluster DynamicController

**File**: `pkg/dynamiccontroller/multicluster_controller.go`

```go
// MulticlusterDynamicController wraps DynamicController for multicluster support
type MulticlusterDynamicController struct {
    mu sync.RWMutex

    // Per-cluster dynamic controllers
    controllers map[string]*DynamicController

    // Manager reference for cluster access
    manager mcmanager.Manager

    // Shared configuration
    config DynamicControllerConfig
}

// Implements multicluster.Aware
func (c *MulticlusterDynamicController) Engage(
    ctx context.Context,
    clusterName string,
    cl cluster.Cluster,
) error {
    c.mu.Lock()
    defer c.mu.Unlock()

    // Create a DynamicController for this cluster
    dc := NewDynamicController(
        cl.GetConfig(),
        c.config,
    )

    c.controllers[clusterName] = dc

    // Start the controller
    go dc.Run(ctx, c.config.Workers)

    return nil
}

// Register adds a handler for a specific cluster
func (c *MulticlusterDynamicController) Register(
    ctx context.Context,
    clusterName string,
    gvr schema.GroupVersionResource,
    handler Handler,
    children ...schema.GroupVersionResource,
) error {
    c.mu.RLock()
    dc, ok := c.controllers[clusterName]
    c.mu.RUnlock()

    if !ok {
        return fmt.Errorf("cluster %s not engaged", clusterName)
    }

    return dc.Register(ctx, gvr, handler, children...)
}
```

#### 3.2 Update Registration Pattern

The RGD controller registers instances with the DynamicController. This needs cluster context:

**File**: `pkg/controller/resourcegraphdefinition/controller.go`

```go
// Before
err := r.dynamicController.Register(ctx, gvr, controller.Reconcile, resourceGVRs...)

// After
err := r.dynamicController.Register(ctx, req.ClusterName, gvr, controller.Reconcile, resourceGVRs...)
```

---

### Phase 4: Client Set Migration

**Goal**: Make the client set cluster-aware.

#### 4.1 Create ClusterClientFactory

**File**: `pkg/client/cluster_factory.go`

```go
// ClusterClientFactory creates clients for specific clusters
type ClusterClientFactory struct {
    manager     mcmanager.Manager
    baseOptions SetOptions

    mu      sync.RWMutex
    clients map[string]SetInterface
}

// GetClient returns a client set for a specific cluster
func (f *ClusterClientFactory) GetClient(
    ctx context.Context,
    clusterName string,
) (SetInterface, error) {
    f.mu.RLock()
    if c, ok := f.clients[clusterName]; ok {
        f.mu.RUnlock()
        return c, nil
    }
    f.mu.RUnlock()

    // Get cluster
    cl, err := f.manager.GetCluster(ctx, clusterName)
    if err != nil {
        return nil, err
    }

    // Create client set for this cluster
    clientSet, err := NewSet(cl.GetConfig(), f.baseOptions)
    if err != nil {
        return nil, err
    }

    f.mu.Lock()
    f.clients[clusterName] = clientSet
    f.mu.Unlock()

    return clientSet, nil
}
```

#### 4.2 Update Instance Controller to Use Factory

**File**: `pkg/controller/instance/controller.go`

```go
type Controller struct {
    gvr           schema.GroupVersionResource
    clusterName   string  // NEW: cluster context
    clientFactory *ClusterClientFactory
    // ...
}

func (c *Controller) Reconcile(ctx context.Context, req ctrl.Request) error {
    // Get cluster-specific client
    clientSet, err := c.clientFactory.GetClient(ctx, c.clusterName)
    if err != nil {
        return err
    }

    // Use cluster-specific dynamic client
    client := clientSet.Dynamic()
    // ...
}
```

---

### Phase 5: Cross-Cluster Resource References (Future)

**Goal**: Support resources that reference resources in other clusters.

This is an advanced feature for future implementation:

```yaml
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: cross-cluster-app
spec:
  resources:
    # Resource in cluster-a
    - id: configMap
      cluster: cluster-a  # NEW: cluster targeting
      resource:
        apiVersion: v1
        kind: ConfigMap

    # Resource in cluster-b referencing cluster-a
    - id: deployment
      cluster: cluster-b
      resource:
        apiVersion: apps/v1
        kind: Deployment
        spec:
          template:
            spec:
              containers:
                - env:
                    - valueFrom:
                        crossClusterRef:
                          cluster: cluster-a
                          resource: configMap
                          path: .data.value
```

---

## Implementation Tasks

### Task 1: Add multicluster-runtime Dependency
- [ ] Add `sigs.k8s.io/multicluster-runtime` to go.mod
- [ ] Verify compatibility with current controller-runtime version

### Task 2: Create Provider Abstraction
- [ ] Create `pkg/multicluster/provider/` package
- [ ] Implement kubeconfig provider wrapper
- [ ] Add provider configuration options
- [ ] Add integration tests for provider

### Task 3: Update Manager Initialization
- [ ] Modify `cmd/controller/main.go` to use `mcmanager.New()`
- [ ] Add multicluster CLI flags
- [ ] Support both single-cluster and multi-cluster modes
- [ ] Update leader election configuration

### Task 4: Migrate ResourceGraphDefinitionReconciler
- [ ] Update reconciler signature to use `mcreconcile.Request`
- [ ] Update controller builder to use `mcbuilder`
- [ ] Add cluster context to CRD management
- [ ] Update RGD status with cluster information
- [ ] Add unit tests for cluster-aware reconciliation

### Task 5: Create Multicluster DynamicController
- [ ] Create `MulticlusterDynamicController` wrapper
- [ ] Implement `multicluster.Aware` interface
- [ ] Update registration to include cluster context
- [ ] Ensure proper cleanup on cluster removal
- [ ] Add integration tests

### Task 6: Create ClusterClientFactory
- [ ] Create `pkg/client/cluster_factory.go`
- [ ] Implement cluster-aware client caching
- [ ] Update instance controller to use factory
- [ ] Handle cluster disconnection/reconnection

### Task 7: Update Instance Controller
- [ ] Add cluster context to ReconcileContext
- [ ] Update all client operations to use cluster-specific clients
- [ ] Add cluster name to logging
- [ ] Update status with cluster information

### Task 8: Documentation and Testing
- [ ] Create multicluster setup documentation
- [ ] Add e2e tests for multicluster scenarios
- [ ] Document provider configuration options
- [ ] Add troubleshooting guide

---

## File Changes Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `go.mod` | Modify | Add multicluster-runtime dependency |
| `cmd/controller/main.go` | Modify | Update manager creation, add CLI flags |
| `pkg/multicluster/provider/provider.go` | Create | Provider abstraction |
| `pkg/controller/resourcegraphdefinition/controller.go` | Modify | Cluster-aware reconciler |
| `pkg/dynamiccontroller/multicluster_controller.go` | Create | Multicluster wrapper |
| `pkg/client/cluster_factory.go` | Create | Cluster client factory |
| `pkg/controller/instance/controller.go` | Modify | Use cluster factory |
| `pkg/controller/instance/context.go` | Modify | Add cluster context |

---

## Backward Compatibility

The migration maintains backward compatibility:

1. **Single-cluster mode**: When `--enable-multicluster=false`, use nil provider
2. **API unchanged**: ResourceGraphDefinition API remains the same
3. **Gradual rollout**: Clusters can be added incrementally via secrets

```go
var provider multicluster.Provider
if enableMulticluster {
    provider = kubeconfig.New(...)
} else {
    provider = nil // Single-cluster mode
}
mgr, err := mcmanager.New(cfg, provider, opts)
```

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Breaking changes in multicluster-runtime | High | Pin to specific version, test thoroughly |
| Performance degradation with many clusters | Medium | Implement cluster sharding, lazy loading |
| Cluster connectivity issues | Medium | Implement retry logic, circuit breakers |
| Resource conflicts across clusters | Medium | Add cluster-specific naming/labeling |
| Leader election complexity | High | Use single leader for all clusters initially |

---

## Testing Strategy

1. **Unit Tests**: Mock cluster interface for reconciler testing
2. **Integration Tests**: Use kind provider with multiple local clusters
3. **E2E Tests**: Full multicluster deployment scenarios
4. **Performance Tests**: Measure overhead with N clusters

---

## Future Enhancements

1. **Cluster Sharding**: Distribute clusters across multiple KRO instances
2. **Cross-cluster References**: Resources referencing other clusters
3. **Cluster Groups**: Logical grouping of clusters for bulk operations
4. **Cluster Policies**: Per-cluster resource policies and quotas
5. **Cluster Federation**: Support for KubeFed and similar projects
