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

// Package multicluster provides abstractions for multi-cluster operations in KRO.
package multicluster

import (
	"context"
	"fmt"

	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/cluster"

	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	"sigs.k8s.io/multicluster-runtime/pkg/multicluster"
	"sigs.k8s.io/multicluster-runtime/providers/kubeconfig"
)

// ProviderType represents the type of cluster provider to use.
type ProviderType string

const (
	// ProviderTypeNone indicates no provider (single-cluster mode).
	ProviderTypeNone ProviderType = "none"

	// ProviderTypeKubeconfig uses secrets containing kubeconfig data.
	ProviderTypeKubeconfig ProviderType = "kubeconfig"
)

// Options configures the multicluster provider.
type Options struct {
	// Type specifies the provider type to use.
	Type ProviderType

	// Kubeconfig provider options
	// Namespace is the namespace where cluster kubeconfig secrets are stored.
	KubeconfigNamespace string
	// KubeconfigSecretLabel is the label used to identify secrets containing kubeconfig data.
	KubeconfigSecretLabel string
	// KubeconfigSecretKey is the key in the secret data that contains the kubeconfig.
	KubeconfigSecretKey string

	// ClusterOptions are options to pass to each cluster.
	ClusterOptions []cluster.Option
	// RESTOptions are options to apply to each cluster's REST config.
	RESTOptions []func(cfg *rest.Config) error
}

// DefaultOptions returns the default multicluster options.
func DefaultOptions() Options {
	return Options{
		Type:                  ProviderTypeNone,
		KubeconfigNamespace:   "kro-system",
		KubeconfigSecretLabel: "kro.run/cluster",
		KubeconfigSecretKey:   "kubeconfig",
	}
}

// Provider wraps multicluster-runtime providers for KRO.
// It provides a unified interface for creating and managing providers.
type Provider struct {
	opts     Options
	provider multicluster.Provider
}

// NewProvider creates a new multicluster provider based on the options.
// Returns nil if Type is ProviderTypeNone (single-cluster mode).
func NewProvider(opts Options) (*Provider, error) {
	if opts.Type == ProviderTypeNone {
		return nil, nil
	}

	var provider multicluster.Provider
	switch opts.Type {
	case ProviderTypeKubeconfig:
		provider = kubeconfig.New(kubeconfig.Options{
			Namespace:             opts.KubeconfigNamespace,
			KubeconfigSecretLabel: opts.KubeconfigSecretLabel,
			KubeconfigSecretKey:   opts.KubeconfigSecretKey,
			ClusterOptions:        opts.ClusterOptions,
			RESTOptions:           opts.RESTOptions,
		})
	default:
		return nil, fmt.Errorf("unknown provider type: %s", opts.Type)
	}

	return &Provider{
		opts:     opts,
		provider: provider,
	}, nil
}

// GetProvider returns the underlying multicluster.Provider.
// Returns nil if in single-cluster mode.
func (p *Provider) GetProvider() multicluster.Provider {
	if p == nil {
		return nil
	}
	return p.provider
}

// SetupWithManager sets up the provider with the multicluster manager.
// This should be called before starting the manager.
func (p *Provider) SetupWithManager(ctx context.Context, mgr mcmanager.Manager) error {
	if p == nil || p.provider == nil {
		return nil
	}

	// If the provider implements SetupWithManager, call it
	type setupper interface {
		SetupWithManager(context.Context, mcmanager.Manager) error
	}
	if s, ok := p.provider.(setupper); ok {
		return s.SetupWithManager(ctx, mgr)
	}

	return nil
}

// IsMulticluster returns true if multicluster mode is enabled.
func (p *Provider) IsMulticluster() bool {
	return p != nil && p.provider != nil
}

// Get returns a cluster by name.
func (p *Provider) Get(ctx context.Context, clusterName string) (cluster.Cluster, error) {
	if p == nil || p.provider == nil {
		return nil, multicluster.ErrClusterNotFound
	}
	return p.provider.Get(ctx, clusterName)
}
