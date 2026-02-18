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

package multicluster

import (
	"context"

	"k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cluster"
	"sigs.k8s.io/controller-runtime/pkg/manager"

	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	"sigs.k8s.io/multicluster-runtime/pkg/multicluster"
)

// LocalClusterName is the name used to identify the local/host cluster.
const LocalClusterName = ""

// Manager provides cluster access functionality for both single and multi-cluster modes.
// It always wraps a multicluster-runtime manager internally, which works with or without
// a provider configured. When no provider is set, it behaves like a standard single-cluster
// controller-runtime manager.
type Manager interface {
	mcmanager.Manager

	// IsMulticluster returns true if a multicluster provider is configured.
	IsMulticluster() bool

	// GetKROProvider returns the KRO provider wrapper, or nil if not configured.
	GetKROProvider() *Provider

	// Start starts the manager.
	Start(ctx context.Context) error
}

// kroManager wraps a multicluster-runtime manager with KRO-specific functionality.
type kroManager struct {
	mcmanager.Manager
	provider *Provider
}

// NewManager creates a new manager that wraps multicluster-runtime.
// If provider is nil, the manager operates in single-cluster mode.
// Otherwise, it operates in multi-cluster mode with the given provider.
func NewManager(cfg *rest.Config, provider *Provider, opts ctrl.Options) (Manager, error) {
	var mcProvider multicluster.Provider
	if provider != nil && provider.IsMulticluster() {
		mcProvider = provider.GetProvider()
	}

	mgr, err := mcmanager.New(cfg, mcProvider, opts)
	if err != nil {
		return nil, err
	}

	return &kroManager{
		Manager:  mgr,
		provider: provider,
	}, nil
}

func (m *kroManager) IsMulticluster() bool {
	return m.provider != nil && m.provider.IsMulticluster()
}

func (m *kroManager) GetCluster(ctx context.Context, clusterName string) (cluster.Cluster, error) {
	return m.Manager.GetCluster(ctx, clusterName)
}

func (m *kroManager) GetLocalManager() manager.Manager {
	return m.Manager.GetLocalManager()
}

func (m *kroManager) GetKROProvider() *Provider {
	return m.provider
}

func (m *kroManager) GetProvider() multicluster.Provider {
	if m.provider != nil {
		return m.provider.GetProvider()
	}
	return m.Manager.GetProvider()
}

func (m *kroManager) Start(ctx context.Context) error {
	// Setup the provider with the manager so it can start watching for clusters
	if m.provider != nil {
		if err := m.provider.SetupWithManager(ctx, m.Manager); err != nil {
			return err
		}
	}
	return m.Manager.Start(ctx)
}
