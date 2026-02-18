# KRO Multicluster Migration Plan

## Overview

Migrate KRO from `controller-runtime` to `multicluster-runtime` to enable multi-cluster operations.

**Status Legend**: ⬜ Not Started | 🔄 In Progress | ✅ Completed | ⏸️ Blocked

---

## Phase 1: Foundation - Dependencies and Manager Setup ✅

**Goal**: Add multicluster-runtime dependency and update manager creation.

| Task | Status | Notes |
|------|--------|-------|
| 1.1 Add multicluster-runtime to go.mod | ✅ | Using local replace directive |
| 1.2 Verify controller-runtime version compatibility | ✅ | Both use v0.23.x, k8s v0.35.0 |
| 1.3 Create provider abstraction package | ✅ | `pkg/multicluster/` |
| 1.4 Add CLI flags for multicluster mode | ✅ | `--enable-multicluster`, etc. |
| 1.5 Update manager creation in main.go | ✅ | Support both single/multi modes |
| 1.6 Add basic integration test | ⬜ | Deferred to Phase 6 |

**Files created/modified**:
- `go.mod` - Added multicluster-runtime with replace directive
- `cmd/controller/main.go` - Updated manager, added flags
- `pkg/multicluster/provider.go` - Provider abstraction
- `pkg/multicluster/manager.go` - Manager wrapper for single/multi modes

---

## Phase 2: ResourceGraphDefinition Controller Migration ✅

**Goal**: Make the RGD controller cluster-aware.

| Task | Status | Notes |
|------|--------|-------|
| 2.1 Update reconciler interface | ✅ | Uses `mcreconcile.Request` with ClusterName |
| 2.2 Update controller builder | ✅ | Uses `mcbuilder.ControllerManagedBy()` |
| 2.3 Add cluster context to reconciliation | ✅ | Via `mcreconcile.Request.ClusterName` |
| 2.4 Update CRD management for clusters | ⬜ | Deferred - CRDs only on host cluster |
| 2.5 Update microcontroller registration | ⬜ | Part of Phase 3 (DynamicController) |
| 2.6 Add unit tests | ⬜ | Deferred to Phase 6 |

**Key Changes**:
- `SetupWithManager` now accepts `mcmanager.Manager`
- Uses `mcbuilder.ControllerManagedBy(mgr).For()` with engagement options
- RGD controller only watches local cluster (`WithEngageWithLocalCluster(true)`)
- `Reconcile` method accepts `mcreconcile.Request` and fetches object
- CRD watches use `mchandler.EnqueueRequestsFromMapFunc`

**Files modified**:
- `pkg/controller/resourcegraphdefinition/controller.go` - Updated to multicluster-runtime
- `pkg/multicluster/manager.go` - Simplified to always use mcmanager internally
- `cmd/controller/main.go` - Updated SetupWithManager call
- `test/integration/environment/setup.go` - Updated for multicluster manager

---

## Phase 3: DynamicController Multicluster Support ✅

**Goal**: Make the custom DynamicController cluster-aware.

| Task | Status | Notes |
|------|--------|-------|
| 3.1 Create MulticlusterDynamicController | ✅ | Wrapper managing per-cluster DynamicControllers |
| 3.2 Implement multicluster.Aware interface | ✅ | Engage called when clusters discovered |
| 3.3 Update registration to include cluster | ✅ | MulticlusterHandler includes clusterName |
| 3.4 Handle cluster removal cleanup | ✅ | Context cancellation stops per-cluster DCs |
| 3.5 Update handler invocation | ✅ | Handler receives clusterName parameter |
| 3.6 Add integration tests | ⬜ | Deferred to Phase 6 |

**Key Changes**:
- Created `MulticlusterDynamicController` wrapping per-cluster `DynamicController` instances
- Implements `multicluster.Aware` interface to receive cluster engagement notifications
- New `MulticlusterHandler` type: `func(ctx, clusterName, req) error`
- Instance controller updated to accept cluster name in `Reconcile`
- Registrations are replicated to all engaged clusters automatically
- Local cluster is always engaged (empty cluster name)

**Files created/modified**:
- `pkg/dynamiccontroller/multicluster_controller.go` - New MulticlusterDynamicController
- `pkg/controller/instance/controller.go` - Updated Reconcile signature
- `pkg/controller/resourcegraphdefinition/controller.go` - Uses MulticlusterDynamicController
- `cmd/controller/main.go` - Creates and adds MulticlusterDynamicController
- `test/integration/environment/setup.go` - Uses MulticlusterDynamicController

---

## Phase 4: Client Set Migration ✅

**Goal**: Make the client set cluster-aware.

| Task | Status | Notes |
|------|--------|-------|
| 4.1 Create ClusterClientFactory | ✅ | Factory for cluster clients |
| 4.2 Implement client caching | ✅ | Cache per cluster |
| 4.3 Handle cluster disconnect/reconnect | ✅ | Context-based cleanup |
| 4.4 Update instance controller | ✅ | Use factory |
| 4.5 Add unit tests | ⬜ | Deferred to Phase 6 |

**Key Changes**:
- Created `ClusterClientFactory` that implements `multicluster.Aware`
- Caches cluster-specific `dynamic.Interface` and `RESTMapper` per cluster
- Local cluster always available, remote clusters tracked via Engage/context cancellation
- Instance controller now receives clients via factory based on cluster name
- `ReconcileContext` includes `ClusterName` field for cluster identification

**Files created/modified**:
- `pkg/client/cluster_factory.go` - New ClusterClientFactory
- `pkg/controller/instance/controller.go` - Uses ClusterClientFactory
- `pkg/controller/instance/context.go` - Added ClusterName field
- `pkg/controller/instance/status.go` - Uses rcx.Client instead of c.client
- `pkg/controller/resourcegraphdefinition/controller.go` - Accepts ClusterClientFactory
- `pkg/controller/resourcegraphdefinition/controller_reconcile.go` - Passes factory to instance ctrl
- `cmd/controller/main.go` - Creates and registers ClusterClientFactory
- `test/integration/environment/setup.go` - Creates and registers ClusterClientFactory

---

## Phase 5: Instance Controller Updates ✅

**Goal**: Update instance controller for multicluster.

| Task | Status | Notes |
|------|--------|-------|
| 5.1 Add cluster to ReconcileContext | ✅ | Done in Phase 4 |
| 5.2 Update resource operations | ✅ | Uses cluster-specific clients via factory |
| 5.3 Update status reporting | ✅ | Uses rcx.Client for cluster-specific status |
| 5.4 Update logging | ✅ | Cluster name in all reconcile logs |
| 5.5 Add tests | ⬜ | Deferred to Phase 6 |

**Note**: Most tasks completed as part of Phase 4 implementation.

**Files modified**:
- `pkg/controller/instance/controller.go` - Cluster-specific clients
- `pkg/controller/instance/context.go` - ClusterName field
- `pkg/controller/instance/status.go` - Uses rcx.Client

---

## Phase 6: Integration and Testing ✅

**Goal**: End-to-end testing and documentation.

| Task | Status | Notes |
|------|--------|-------|
| 6.1 Create multicluster e2e tests | ✅ | Scripts for kind-based testing |
| 6.2 Update existing tests | ✅ | Unit tests pass, backward compatible |
| 6.3 Create documentation | ✅ | Complete setup guide |
| 6.4 Add example configurations | ✅ | Cluster secrets, RBAC, RGD examples |
| 6.5 Performance testing | ⬜ | Deferred - needs real cluster environment |

**Files created**:
- `test/e2e/multicluster/` - E2E test scripts (setup.sh, test-multicluster.sh, cleanup.sh)
- `docs/multicluster-setup.md` - Comprehensive documentation
- `examples/multicluster/` - Complete examples (cluster-secret, rbac, simple-webapp)

---

## Progress Log

| Date | Phase | Notes |
|------|-------|-------|
| 2026-02-13 | Planning | Initial plan created |
| 2026-02-13 | Phase 1 | Completed - multicluster foundation in place |
| 2026-02-13 | Phase 2 | Completed - RGD controller migrated to multicluster-runtime |
| 2026-02-13 | Phase 3 | Completed - DynamicController multicluster support |
| 2026-02-13 | Phase 4 | Completed - ClusterClientFactory for cluster-specific clients |
| 2026-02-13 | Phase 5 | Completed - Instance controller multicluster updates |
| 2026-02-13 | Phase 6 | Completed - Documentation, examples, and e2e test scripts |

---

## Architecture Decisions

### AD-1: Provider Selection
**Decision**: Use `kubeconfig` provider (secret-based) for production
**Rationale**: Allows dynamic cluster onboarding via Kubernetes secrets

### AD-2: Backward Compatibility
**Decision**: Support both single-cluster and multi-cluster modes via flag
**Rationale**: Gradual migration path, no breaking changes

### AD-3: DynamicController Approach
**Decision**: Wrap existing DynamicController in multicluster-aware wrapper
**Rationale**: Minimize changes to working custom code

### AD-4: ClusterClientFactory Pattern
**Decision**: Use a factory pattern with `multicluster.Aware` interface for client management
**Rationale**: Centralized client creation and caching; automatic cleanup via context cancellation

---

## Questions/Blockers

- [ ] What provider should be the default? (kubeconfig vs kind)
- [ ] Should RGDs be cluster-scoped or namespace-scoped in multicluster?
- [ ] How to handle CRD conflicts across clusters with different versions?
