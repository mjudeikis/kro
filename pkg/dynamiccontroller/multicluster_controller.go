// Copyright 2025 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package dynamiccontroller

import (
	"context"
	"fmt"
	"sync"

	"github.com/go-logr/logr"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/runtime/schema"
	k8smetadata "k8s.io/client-go/metadata"
	"sigs.k8s.io/controller-runtime/pkg/cluster"
	ctrl "sigs.k8s.io/controller-runtime"

	mcmulticluster "sigs.k8s.io/multicluster-runtime/pkg/multicluster"
)

// LocalClusterName is the name used to identify the local/host cluster.
// In multicluster-runtime, the local cluster has an empty name.
const LocalClusterName = ""

// MulticlusterHandler is the handler function signature for multicluster reconciliation.
// It includes the cluster name to allow handlers to know which cluster the resource is from.
type MulticlusterHandler func(ctx context.Context, clusterName string, req ctrl.Request) error

// registeredGVR tracks a registered GVR and its handler for propagation to new clusters.
type registeredGVR struct {
	gvk              schema.GroupVersionKind
	handler          MulticlusterHandler
	childGVRsToWatch []schema.GroupVersionResource
}

// MulticlusterDynamicController wraps DynamicController instances for multiple clusters.
// It implements the multicluster.Aware interface to receive cluster engagement notifications.
//
// Architecture:
//   - Maintains one DynamicController per engaged cluster
//   - The local cluster is always engaged (empty cluster name)
//   - When a new cluster is engaged, it creates a new DynamicController for it
//   - All registered GVRs are propagated to newly engaged clusters
//   - When a cluster is disengaged (context cancelled), its DynamicController is stopped
type MulticlusterDynamicController struct {
	log    logr.Logger
	config Config

	// mu protects clusters and registeredGVRs
	mu sync.RWMutex

	// clusters maps cluster name to its DynamicController and metadata client
	clusters map[string]*clusterEntry

	// registeredGVRs tracks all registered parent GVRs and their configurations
	// so they can be replicated to newly engaged clusters
	registeredGVRs map[schema.GroupVersionResource]*registeredGVR

	// localClient and localMapper are used for the local cluster
	localClient k8smetadata.Interface
	localMapper meta.RESTMapper

	// localReady is closed when the local cluster has been engaged.
	// Register waits for this before proceeding.
	localReady chan struct{}
}

// clusterEntry holds the DynamicController and client for a single cluster
type clusterEntry struct {
	dc       *DynamicController
	client   k8smetadata.Interface
	mapper   meta.RESTMapper
	cancelFn context.CancelFunc
}

// NewMulticlusterDynamicController creates a new MulticlusterDynamicController.
// The local cluster's metadata client and REST mapper are required for the host cluster.
func NewMulticlusterDynamicController(
	log logr.Logger,
	config Config,
	localClient k8smetadata.Interface,
	localMapper meta.RESTMapper,
) *MulticlusterDynamicController {
	mdc := &MulticlusterDynamicController{
		log:            log.WithName("multicluster-dynamic-controller"),
		config:         config,
		clusters:       make(map[string]*clusterEntry),
		registeredGVRs: make(map[schema.GroupVersionResource]*registeredGVR),
		localClient:    localClient,
		localMapper:    localMapper,
		localReady:     make(chan struct{}),
	}
	return mdc
}

// Engage implements multicluster.Aware.
// It is called when a new cluster should be watched.
// The context is tied to the cluster's lifecycle and will be cancelled when the cluster is removed.
func (mdc *MulticlusterDynamicController) Engage(ctx context.Context, clusterName string, cl cluster.Cluster) error {
	mdc.mu.Lock()
	defer mdc.mu.Unlock()

	// Check if already engaged
	if _, exists := mdc.clusters[clusterName]; exists {
		mdc.log.V(1).Info("Cluster already engaged", "cluster", clusterName)
		return nil
	}

	mdc.log.Info("Engaging cluster", "cluster", clusterName)

	// Get metadata client from the cluster
	metadataClient, err := k8smetadata.NewForConfig(cl.GetConfig())
	if err != nil {
		return fmt.Errorf("failed to create metadata client for cluster %s: %w", clusterName, err)
	}

	// Create config for this cluster.
	// For remote clusters (non-local), we don't wait for cache sync because
	// CRDs might not exist yet (they may need to be propagated from the central cluster).
	// The informer will keep retrying in the background until the CRD becomes available.
	clusterConfig := mdc.config
	if clusterName != LocalClusterName {
		waitForSync := false
		clusterConfig.WaitForSync = &waitForSync
	}

	// Create a new DynamicController for this cluster
	dc := NewDynamicController(
		mdc.log.WithValues("cluster", clusterName),
		clusterConfig,
		metadataClient,
		cl.GetRESTMapper(),
	)

	// Create a cancellable context for this cluster's controller
	dcCtx, cancelFn := context.WithCancel(ctx)

	entry := &clusterEntry{
		dc:       dc,
		client:   metadataClient,
		mapper:   cl.GetRESTMapper(),
		cancelFn: cancelFn,
	}
	mdc.clusters[clusterName] = entry

	// Start the DynamicController in a goroutine
	go func() {
		if err := dc.Start(dcCtx); err != nil {
			mdc.log.Error(err, "DynamicController stopped with error", "cluster", clusterName)
		}
		mdc.log.Info("DynamicController stopped", "cluster", clusterName)

		// Clean up when the controller stops
		mdc.mu.Lock()
		delete(mdc.clusters, clusterName)
		mdc.mu.Unlock()
	}()

	// Wait for the DynamicController to be ready before registering GVRs
	if err := dc.WaitUntilStarted(ctx); err != nil {
		return fmt.Errorf("waiting for dynamic controller to start: %w", err)
	}

	// Register all existing GVRs with this new cluster's DynamicController
	for gvr, reg := range mdc.registeredGVRs {
		// Wrap the handler to provide the cluster name
		clusterHandler := mdc.wrapHandler(clusterName, reg.handler)
		// Use RegisterWithGVK to pass the GVK explicitly - this is important because
		// in multicluster scenarios the CRD might not exist on the remote cluster yet,
		// so the mapper can't look up the GVK.
		if err := dc.RegisterWithGVK(dcCtx, gvr, reg.gvk, clusterHandler, reg.childGVRsToWatch...); err != nil {
			mdc.log.Error(err, "Failed to register GVR with new cluster",
				"cluster", clusterName, "gvr", gvr)
			// Continue with other registrations even if one fails
		}
	}

	return nil
}

// wrapHandler wraps a MulticlusterHandler to a Handler by providing the cluster name
func (mdc *MulticlusterDynamicController) wrapHandler(clusterName string, handler MulticlusterHandler) Handler {
	return func(ctx context.Context, req ctrl.Request) error {
		return handler(ctx, clusterName, req)
	}
}

// Start starts the local cluster's DynamicController.
// This is called by the manager when it starts.
func (mdc *MulticlusterDynamicController) Start(ctx context.Context) error {
	// Engage the local cluster first
	// Create a minimal cluster wrapper for the local cluster
	if err := mdc.engageLocal(ctx); err != nil {
		return fmt.Errorf("failed to engage local cluster: %w", err)
	}

	// Wait for context to be done
	<-ctx.Done()

	// Clean up all clusters
	mdc.mu.Lock()
	for name, entry := range mdc.clusters {
		mdc.log.Info("Stopping cluster", "cluster", name)
		entry.cancelFn()
	}
	mdc.mu.Unlock()

	return nil
}

// engageLocal sets up the local cluster's DynamicController
func (mdc *MulticlusterDynamicController) engageLocal(ctx context.Context) error {
	mdc.mu.Lock()
	defer mdc.mu.Unlock()

	// Check if local cluster is already engaged
	if _, exists := mdc.clusters[LocalClusterName]; exists {
		return nil
	}

	mdc.log.Info("Engaging local cluster")

	// Create DynamicController for the local cluster
	dc := NewDynamicController(
		mdc.log.WithValues("cluster", "local"),
		mdc.config,
		mdc.localClient,
		mdc.localMapper,
	)

	dcCtx, cancelFn := context.WithCancel(ctx)

	entry := &clusterEntry{
		dc:       dc,
		client:   mdc.localClient,
		mapper:   mdc.localMapper,
		cancelFn: cancelFn,
	}
	mdc.clusters[LocalClusterName] = entry

	// Start the local DynamicController
	go func() {
		if err := dc.Start(dcCtx); err != nil {
			mdc.log.Error(err, "Local DynamicController stopped with error")
		}
	}()

	// Wait for the local DynamicController to be ready
	if err := dc.WaitUntilStarted(ctx); err != nil {
		return fmt.Errorf("waiting for local dynamic controller to start: %w", err)
	}

	// Register all existing GVRs with the local cluster's DynamicController
	// This handles the case where Register was called before Start
	for gvr, reg := range mdc.registeredGVRs {
		// Wrap the handler to provide the cluster name
		clusterHandler := mdc.wrapHandler(LocalClusterName, reg.handler)
		if err := dc.RegisterWithGVK(dcCtx, gvr, reg.gvk, clusterHandler, reg.childGVRsToWatch...); err != nil {
			mdc.log.Error(err, "Failed to register GVR with local cluster", "gvr", gvr)
			// Continue with other registrations even if one fails
		}
	}

	// Signal that the local cluster is ready
	close(mdc.localReady)

	return nil
}

// Register registers a parent GVR with its handler across all engaged clusters.
// The handler receives the cluster name for each event.
// Register blocks until the local cluster has been engaged to ensure at least
// one cluster can receive the registration.
// The parentGVK is required to support multicluster scenarios where the CRD might
// not exist on remote clusters yet (so the mapper can't look up the GVK).
func (mdc *MulticlusterDynamicController) Register(
	ctx context.Context,
	parent schema.GroupVersionResource,
	parentGVK schema.GroupVersionKind,
	handler MulticlusterHandler,
	resourceGVRsToWatch ...schema.GroupVersionResource,
) error {
	// Wait for the local cluster to be engaged before proceeding.
	// This prevents the race condition where Register is called before Start.
	select {
	case <-mdc.localReady:
		// Local cluster is ready, proceed
	case <-ctx.Done():
		return ctx.Err()
	}

	mdc.mu.Lock()
	defer mdc.mu.Unlock()

	// Store the registration for future clusters
	mdc.registeredGVRs[parent] = &registeredGVR{
		gvk:              parentGVK,
		handler:          handler,
		childGVRsToWatch: resourceGVRsToWatch,
	}

	// Register with all currently engaged clusters
	var errs []error
	for clusterName, entry := range mdc.clusters {
		wrappedHandler := mdc.wrapHandler(clusterName, handler)
		// Use RegisterWithGVK to pass the GVK explicitly
		if err := entry.dc.RegisterWithGVK(ctx, parent, parentGVK, wrappedHandler, resourceGVRsToWatch...); err != nil {
			errs = append(errs, fmt.Errorf("cluster %s: %w", clusterName, err))
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("failed to register with some clusters: %v", errs)
	}

	mdc.log.V(1).Info("Registered GVR across all clusters",
		"gvr", parent, "clusterCount", len(mdc.clusters))
	return nil
}

// Deregister removes a parent GVR from all engaged clusters.
func (mdc *MulticlusterDynamicController) Deregister(ctx context.Context, parent schema.GroupVersionResource) error {
	mdc.mu.Lock()
	defer mdc.mu.Unlock()

	// Remove from stored registrations
	delete(mdc.registeredGVRs, parent)

	// Deregister from all currently engaged clusters
	var errs []error
	for clusterName, entry := range mdc.clusters {
		if err := entry.dc.Deregister(ctx, parent); err != nil {
			errs = append(errs, fmt.Errorf("cluster %s: %w", clusterName, err))
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("failed to deregister from some clusters: %v", errs)
	}

	mdc.log.V(1).Info("Deregistered GVR from all clusters",
		"gvr", parent, "clusterCount", len(mdc.clusters))
	return nil
}

// GetEngagedClusters returns the names of all currently engaged clusters.
func (mdc *MulticlusterDynamicController) GetEngagedClusters() []string {
	mdc.mu.RLock()
	defer mdc.mu.RUnlock()

	clusters := make([]string, 0, len(mdc.clusters))
	for name := range mdc.clusters {
		clusters = append(clusters, name)
	}
	return clusters
}

// GetClusterController returns the DynamicController for a specific cluster.
// Returns nil if the cluster is not engaged.
func (mdc *MulticlusterDynamicController) GetClusterController(clusterName string) *DynamicController {
	mdc.mu.RLock()
	defer mdc.mu.RUnlock()

	if entry, exists := mdc.clusters[clusterName]; exists {
		return entry.dc
	}
	return nil
}

// Verify that MulticlusterDynamicController implements multicluster.Aware
var _ mcmulticluster.Aware = &MulticlusterDynamicController{}
