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

package resourcegraphdefinition

import (
	"context"
	"errors"

	"github.com/go-logr/logr"
	extv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrlrtcontroller "sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	mcbuilder "sigs.k8s.io/multicluster-runtime/pkg/builder"
	mchandler "sigs.k8s.io/multicluster-runtime/pkg/handler"
	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"
	mcreconcile "sigs.k8s.io/multicluster-runtime/pkg/reconcile"

	"github.com/kubernetes-sigs/kro/api/v1alpha1"
	kroclient "github.com/kubernetes-sigs/kro/pkg/client"
	"github.com/kubernetes-sigs/kro/pkg/dynamiccontroller"
	"github.com/kubernetes-sigs/kro/pkg/graph"
	"github.com/kubernetes-sigs/kro/pkg/metadata"
)

// ResourceGraphDefinitionReconciler reconciles a ResourceGraphDefinition object
type ResourceGraphDefinitionReconciler struct {
	allowCRDDeletion bool

	// Client and instanceLogger are set with SetupWithManager

	client.Client

	instanceLogger logr.Logger

	clientSet            kroclient.SetInterface
	crdManager           kroclient.CRDClient
	clusterClientFactory *kroclient.ClusterClientFactory

	metadataLabeler         metadata.Labeler
	rgBuilder               *graph.Builder
	dynamicController       *dynamiccontroller.MulticlusterDynamicController
	maxConcurrentReconciles int
}

func NewResourceGraphDefinitionReconciler(
	clientSet kroclient.SetInterface,
	clusterClientFactory *kroclient.ClusterClientFactory,
	allowCRDDeletion bool,
	dynamicController *dynamiccontroller.MulticlusterDynamicController,
	builder *graph.Builder,
	maxConcurrentReconciles int,
) *ResourceGraphDefinitionReconciler {
	crdWrapper := clientSet.CRD(kroclient.CRDWrapperConfig{})

	return &ResourceGraphDefinitionReconciler{
		clientSet:               clientSet,
		clusterClientFactory:    clusterClientFactory,
		allowCRDDeletion:        allowCRDDeletion,
		crdManager:              crdWrapper,
		dynamicController:       dynamicController,
		metadataLabeler:         metadata.NewKROMetaLabeler(),
		rgBuilder:               builder,
		maxConcurrentReconciles: maxConcurrentReconciles,
	}
}

// SetupWithManager sets up the controller with the multicluster Manager.
// The RGD controller only watches resources on the local/host cluster since
// ResourceGraphDefinitions are cluster-scoped control plane resources.
func (r *ResourceGraphDefinitionReconciler) SetupWithManager(mgr mcmanager.Manager) error {
	localMgr := mgr.GetLocalManager()
	r.Client = localMgr.GetClient()
	r.clientSet.SetRESTMapper(localMgr.GetRESTMapper())
	r.instanceLogger = localMgr.GetLogger()

	logConstructor := func(req *mcreconcile.Request) logr.Logger {
		log := localMgr.GetLogger().WithName("rgd-controller").WithValues(
			"controller", "ResourceGraphDefinition",
			"controllerGroup", v1alpha1.GroupVersion.Group,
			"controllerKind", "ResourceGraphDefinition",
		)
		if req != nil {
			log = log.WithValues("name", req.Name, "cluster", req.ClusterName)
		}
		return log
	}

	return mcbuilder.ControllerManagedBy(mgr).
		Named("ResourceGraphDefinition").
		// RGDs only exist on the local/host cluster
		For(&v1alpha1.ResourceGraphDefinition{},
			mcbuilder.WithEngageWithLocalCluster(true),
			mcbuilder.WithEngageWithProviderClusters(false),
		).
		WithEventFilter(predicate.GenerationChangedPredicate{}).
		WithOptions(
			ctrlrtcontroller.TypedOptions[mcreconcile.Request]{
				LogConstructor:          logConstructor,
				MaxConcurrentReconciles: r.maxConcurrentReconciles,
			},
		).
		WatchesMetadata(
			&extv1.CustomResourceDefinition{},
			mchandler.EnqueueRequestsFromMapFunc(r.findRGDsForCRD),
			mcbuilder.WithEngageWithLocalCluster(true),
			mcbuilder.WithEngageWithProviderClusters(false),
			mcbuilder.WithPredicates(predicate.Funcs{
				UpdateFunc: func(e event.UpdateEvent) bool {
					return true
				},
				CreateFunc: func(e event.CreateEvent) bool {
					return false
				},
				DeleteFunc: func(e event.DeleteEvent) bool {
					return true
				},
			}),
		).
		Complete(reconcile.TypedFunc[mcreconcile.Request](r.Reconcile))
}

// findRGDsForCRD returns a list of reconcile requests for the ResourceGraphDefinition
// that owns the given CRD. It is used to trigger reconciliation when a CRD is updated.
func (r *ResourceGraphDefinitionReconciler) findRGDsForCRD(ctx context.Context, obj client.Object) []reconcile.Request {
	mobj, err := meta.Accessor(obj)
	if err != nil {
		return nil
	}

	// Check if the CRD is owned by a ResourceGraphDefinition
	if !metadata.IsKROOwned(mobj) {
		return nil
	}

	rgdName, ok := mobj.GetLabels()[metadata.ResourceGraphDefinitionNameLabel]
	if !ok {
		return nil
	}

	// Return a reconcile request for the corresponding RGD
	return []reconcile.Request{
		{
			NamespacedName: types.NamespacedName{
				Name: rgdName,
			},
		},
	}
}

// Reconcile handles the reconciliation of a ResourceGraphDefinition.
// It accepts a multicluster Request which includes the cluster name,
// though for RGDs the cluster will always be the local cluster.
func (r *ResourceGraphDefinitionReconciler) Reconcile(
	ctx context.Context,
	req mcreconcile.Request,
) (ctrl.Result, error) {
	// Fetch the ResourceGraphDefinition from the local cluster
	o := &v1alpha1.ResourceGraphDefinition{}
	if err := r.Client.Get(ctx, req.NamespacedName, o); err != nil {
		if apierrors.IsNotFound(err) {
			// Object not found, likely deleted
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	if !o.DeletionTimestamp.IsZero() {
		if err := r.cleanupResourceGraphDefinition(ctx, o); err != nil {
			return ctrl.Result{}, err
		}
		if err := r.setUnmanaged(ctx, o); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}

	if err := r.setManaged(ctx, o); err != nil {
		return ctrl.Result{}, err
	}

	topologicalOrder, resourcesInformation, reconcileErr := r.reconcileResourceGraphDefinition(ctx, o)

	if err := r.updateStatus(ctx, o, topologicalOrder, resourcesInformation); err != nil {
		reconcileErr = errors.Join(reconcileErr, err)
	}

	return ctrl.Result{}, reconcileErr
}
