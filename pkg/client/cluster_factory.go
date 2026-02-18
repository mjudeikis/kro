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

package client

import (
	"context"
	"fmt"
	"sync"

	"github.com/go-logr/logr"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/client-go/dynamic"
	"sigs.k8s.io/controller-runtime/pkg/cluster"

	mcmulticluster "sigs.k8s.io/multicluster-runtime/pkg/multicluster"
)

// LocalClusterName is the name used to identify the local/host cluster.
// In multicluster-runtime, the local cluster has an empty name.
const LocalClusterName = ""

// ClusterClients holds the clients for a single cluster.
type ClusterClients struct {
	Dynamic    dynamic.Interface
	RESTMapper meta.RESTMapper
}

// ClusterClientFactory provides cluster-specific clients for multicluster operations.
// It implements the multicluster.Aware interface to receive cluster engagement notifications.
//
// Usage:
//   - In single-cluster mode, use GetClients("") or GetClients(LocalClusterName)
//   - In multi-cluster mode, use GetClients(clusterName) with the cluster name
//     received from the reconciliation request
//
// The factory caches clients per cluster for efficiency and automatically
// cleans up clients when clusters are disengaged.
type ClusterClientFactory struct {
	log logr.Logger

	// mu protects clusters map
	mu sync.RWMutex

	// clusters maps cluster name to its clients
	clusters map[string]*clusterEntry

	// localClients holds the pre-configured local cluster clients
	localClients *ClusterClients
}

// clusterEntry holds the clients and lifecycle context for a single cluster
type clusterEntry struct {
	clients  *ClusterClients
	cancelFn context.CancelFunc
}

// NewClusterClientFactory creates a new ClusterClientFactory.
// The localDynamic and localMapper are used for the local cluster (empty cluster name).
func NewClusterClientFactory(
	log logr.Logger,
	localDynamic dynamic.Interface,
	localMapper meta.RESTMapper,
) *ClusterClientFactory {
	return &ClusterClientFactory{
		log:      log.WithName("cluster-client-factory"),
		clusters: make(map[string]*clusterEntry),
		localClients: &ClusterClients{
			Dynamic:    localDynamic,
			RESTMapper: localMapper,
		},
	}
}

// GetClients returns the clients for the specified cluster.
// For the local cluster, use empty string or LocalClusterName.
// Returns an error if the cluster is not engaged.
func (f *ClusterClientFactory) GetClients(clusterName string) (*ClusterClients, error) {
	// Local cluster is always available
	if clusterName == LocalClusterName {
		return f.localClients, nil
	}

	f.mu.RLock()
	entry, exists := f.clusters[clusterName]
	f.mu.RUnlock()

	if !exists {
		return nil, fmt.Errorf("cluster %q is not engaged", clusterName)
	}

	return entry.clients, nil
}

// GetDynamic returns the dynamic client for the specified cluster.
// This is a convenience method that wraps GetClients.
func (f *ClusterClientFactory) GetDynamic(clusterName string) (dynamic.Interface, error) {
	clients, err := f.GetClients(clusterName)
	if err != nil {
		return nil, err
	}
	return clients.Dynamic, nil
}

// GetRESTMapper returns the REST mapper for the specified cluster.
// This is a convenience method that wraps GetClients.
func (f *ClusterClientFactory) GetRESTMapper(clusterName string) (meta.RESTMapper, error) {
	clients, err := f.GetClients(clusterName)
	if err != nil {
		return nil, err
	}
	return clients.RESTMapper, nil
}

// Engage implements multicluster.Aware.
// It is called when a new cluster should be watched.
// The context is tied to the cluster's lifecycle and will be cancelled when the cluster is removed.
func (f *ClusterClientFactory) Engage(ctx context.Context, clusterName string, cl cluster.Cluster) error {
	f.mu.Lock()
	defer f.mu.Unlock()

	// Check if already engaged
	if _, exists := f.clusters[clusterName]; exists {
		f.log.V(1).Info("Cluster already engaged", "cluster", clusterName)
		return nil
	}

	f.log.Info("Engaging cluster", "cluster", clusterName)

	// Create dynamic client from the cluster's config
	dynamicClient, err := dynamic.NewForConfig(cl.GetConfig())
	if err != nil {
		return fmt.Errorf("failed to create dynamic client for cluster %s: %w", clusterName, err)
	}

	// Create a cancellable context for tracking this cluster's lifecycle
	_, cancelFn := context.WithCancel(ctx)

	entry := &clusterEntry{
		clients: &ClusterClients{
			Dynamic:    dynamicClient,
			RESTMapper: cl.GetRESTMapper(),
		},
		cancelFn: cancelFn,
	}
	f.clusters[clusterName] = entry

	// Start a goroutine to clean up when the cluster context is cancelled
	go func() {
		<-ctx.Done()
		f.mu.Lock()
		delete(f.clusters, clusterName)
		f.mu.Unlock()
		f.log.Info("Cluster disengaged", "cluster", clusterName)
	}()

	return nil
}

// GetEngagedClusters returns the names of all currently engaged clusters.
// This includes the local cluster (empty string).
func (f *ClusterClientFactory) GetEngagedClusters() []string {
	f.mu.RLock()
	defer f.mu.RUnlock()

	// Local cluster is always engaged
	clusters := make([]string, 0, len(f.clusters)+1)
	clusters = append(clusters, LocalClusterName)

	for name := range f.clusters {
		clusters = append(clusters, name)
	}
	return clusters
}

// IsEngaged returns true if the specified cluster is currently engaged.
// The local cluster (empty string) is always engaged.
func (f *ClusterClientFactory) IsEngaged(clusterName string) bool {
	if clusterName == LocalClusterName {
		return true
	}

	f.mu.RLock()
	defer f.mu.RUnlock()
	_, exists := f.clusters[clusterName]
	return exists
}

// Start implements manager.Runnable.
// The factory doesn't need to run any background tasks, but implements
// this interface to be added to the manager for lifecycle management.
func (f *ClusterClientFactory) Start(ctx context.Context) error {
	// Wait for context to be done
	<-ctx.Done()
	return nil
}

// Verify that ClusterClientFactory implements multicluster.Aware
var _ mcmulticluster.Aware = &ClusterClientFactory{}
