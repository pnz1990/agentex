// Package k8s provides a Kubernetes client wrapper for the agentex coordinator.
// It supports both in-cluster and kubeconfig-based authentication, and provides
// typed methods for ConfigMap operations and dynamic client access for kro CRDs.
package k8s

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// DefaultTimeout is the default timeout for Kubernetes API calls.
// The bash coordinator uses 10s timeouts; we use the same.
const DefaultTimeout = 10 * time.Second

// KroGroup is the API group for kro-managed custom resources.
const KroGroup = "kro.run"

// KroVersion is the API version for kro-managed custom resources.
const KroVersion = "v1alpha1"

// CRD GVRs for kro-managed resources.
var (
	AgentGVR = schema.GroupVersionResource{
		Group:    KroGroup,
		Version:  KroVersion,
		Resource: "agents",
	}
	TaskGVR = schema.GroupVersionResource{
		Group:    KroGroup,
		Version:  KroVersion,
		Resource: "tasks",
	}
	ThoughtGVR = schema.GroupVersionResource{
		Group:    KroGroup,
		Version:  KroVersion,
		Resource: "thoughts",
	}
	ReportGVR = schema.GroupVersionResource{
		Group:    KroGroup,
		Version:  KroVersion,
		Resource: "reports",
	}
	MessageGVR = schema.GroupVersionResource{
		Group:    KroGroup,
		Version:  KroVersion,
		Resource: "messages",
	}
	CampaignGVR = schema.GroupVersionResource{
		Group:    KroGroup,
		Version:  KroVersion,
		Resource: "campaigns",
	}
)

// Client wraps Kubernetes clientset and dynamic client with typed convenience methods.
type Client struct {
	Clientset     kubernetes.Interface
	DynamicClient dynamic.Interface
	logger        *slog.Logger
}

// NewClient creates a new Kubernetes client. If kubeconfig is empty, it uses
// in-cluster configuration (for pods running inside Kubernetes). Otherwise,
// it loads the kubeconfig file from the given path.
func NewClient(kubeconfig string, logger *slog.Logger) (*Client, error) {
	var config *rest.Config
	var err error

	if kubeconfig != "" {
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
		if err != nil {
			return nil, fmt.Errorf("building kubeconfig from %s: %w", kubeconfig, err)
		}
		logger.Info("using kubeconfig", "path", kubeconfig)
	} else {
		config, err = rest.InClusterConfig()
		if err != nil {
			return nil, fmt.Errorf("building in-cluster config: %w", err)
		}
		logger.Info("using in-cluster config")
	}

	// Set reasonable timeouts and QPS to match coordinator's needs.
	// The coordinator makes frequent API calls; allow bursting.
	config.QPS = 50
	config.Burst = 100
	config.Timeout = 30 * time.Second

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("creating kubernetes clientset: %w", err)
	}

	dynClient, err := dynamic.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("creating dynamic client: %w", err)
	}

	return &Client{
		Clientset:     clientset,
		DynamicClient: dynClient,
		logger:        logger,
	}, nil
}

// NewClientFromInterfaces creates a Client from pre-existing interfaces.
// This is primarily used in tests with fake clients.
func NewClientFromInterfaces(clientset kubernetes.Interface, dynClient dynamic.Interface, logger *slog.Logger) *Client {
	return &Client{
		Clientset:     clientset,
		DynamicClient: dynClient,
		logger:        logger,
	}
}

// withTimeout returns a context with the given timeout, or DefaultTimeout if
// the provided timeout is zero.
func withTimeout(parent context.Context, timeout time.Duration) (context.Context, context.CancelFunc) {
	if timeout == 0 {
		timeout = DefaultTimeout
	}
	return context.WithTimeout(parent, timeout)
}

// GetConfigMap retrieves a ConfigMap by name from the given namespace.
func (c *Client) GetConfigMap(ctx context.Context, namespace, name string) (*corev1.ConfigMap, error) {
	ctx, cancel := withTimeout(ctx, DefaultTimeout)
	defer cancel()

	cm, err := c.Clientset.CoreV1().ConfigMaps(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("getting configmap %s/%s: %w", namespace, name, err)
	}
	return cm, nil
}

// UpdateConfigMap updates a ConfigMap using optimistic concurrency via ResourceVersion.
// Returns k8serrors.IsConflict(err) == true on version conflict.
func (c *Client) UpdateConfigMap(ctx context.Context, namespace string, cm *corev1.ConfigMap) (*corev1.ConfigMap, error) {
	ctx, cancel := withTimeout(ctx, DefaultTimeout)
	defer cancel()

	updated, err := c.Clientset.CoreV1().ConfigMaps(namespace).Update(ctx, cm, metav1.UpdateOptions{})
	if err != nil {
		return nil, fmt.Errorf("updating configmap %s/%s: %w", namespace, cm.Name, err)
	}
	return updated, nil
}

// PatchConfigMap applies a strategic merge patch to a ConfigMap.
func (c *Client) PatchConfigMap(ctx context.Context, namespace, name string, patchData []byte) (*corev1.ConfigMap, error) {
	ctx, cancel := withTimeout(ctx, DefaultTimeout)
	defer cancel()

	cm, err := c.Clientset.CoreV1().ConfigMaps(namespace).Patch(
		ctx, name, types.MergePatchType, patchData, metav1.PatchOptions{},
	)
	if err != nil {
		return nil, fmt.Errorf("patching configmap %s/%s: %w", namespace, name, err)
	}
	return cm, nil
}

// ListConfigMaps lists all ConfigMaps in the given namespace.
func (c *Client) ListConfigMaps(ctx context.Context, namespace string, opts metav1.ListOptions) (*corev1.ConfigMapList, error) {
	ctx, cancel := withTimeout(ctx, 15*time.Second)
	defer cancel()

	cms, err := c.Clientset.CoreV1().ConfigMaps(namespace).List(ctx, opts)
	if err != nil {
		return nil, fmt.Errorf("listing configmaps in %s: %w", namespace, err)
	}
	return cms, nil
}

// ListJobs lists all Jobs in the given namespace.
func (c *Client) ListJobs(ctx context.Context, namespace string, opts metav1.ListOptions) (*batchv1.JobList, error) {
	ctx, cancel := withTimeout(ctx, 15*time.Second)
	defer cancel()

	jobs, err := c.Clientset.BatchV1().Jobs(namespace).List(ctx, opts)
	if err != nil {
		return nil, fmt.Errorf("listing jobs in %s: %w", namespace, err)
	}
	return jobs, nil
}

// GetJob retrieves a single Job by name.
func (c *Client) GetJob(ctx context.Context, namespace, name string) (*batchv1.Job, error) {
	ctx, cancel := withTimeout(ctx, DefaultTimeout)
	defer cancel()

	job, err := c.Clientset.BatchV1().Jobs(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("getting job %s/%s: %w", namespace, name, err)
	}
	return job, nil
}

// DeleteJob deletes a Job by name. If the Job does not exist, the error is
// silently ignored (returns nil). This makes it safe to call even when unsure
// if the Job exists.
func (c *Client) DeleteJob(ctx context.Context, namespace, name string) error {
	ctx, cancel := withTimeout(ctx, DefaultTimeout)
	defer cancel()

	err := c.Clientset.BatchV1().Jobs(namespace).Delete(ctx, name, metav1.DeleteOptions{})
	if err != nil && !k8serrors.IsNotFound(err) {
		return fmt.Errorf("deleting job %s/%s: %w", namespace, name, err)
	}
	return nil
}

// WatchJobs starts a watch on Jobs in the given namespace.
func (c *Client) WatchJobs(ctx context.Context, namespace string, opts metav1.ListOptions) (watch.Interface, error) {
	return c.Clientset.BatchV1().Jobs(namespace).Watch(ctx, opts)
}

// CountActiveJobs counts jobs that are still running (no completionTime, active > 0).
// This matches the bash coordinator's jq filter.
func (c *Client) CountActiveJobs(ctx context.Context, namespace string) (int, error) {
	jobs, err := c.ListJobs(ctx, namespace, metav1.ListOptions{})
	if err != nil {
		return 0, err
	}

	active := 0
	for i := range jobs.Items {
		job := &jobs.Items[i]
		if job.Status.CompletionTime == nil && job.Status.Active > 0 {
			active++
		}
	}
	return active, nil
}

// CreateCR creates a kro custom resource using the dynamic client.
func (c *Client) CreateCR(ctx context.Context, namespace string, gvr schema.GroupVersionResource, obj *unstructured.Unstructured) (*unstructured.Unstructured, error) {
	ctx, cancel := withTimeout(ctx, DefaultTimeout)
	defer cancel()

	result, err := c.DynamicClient.Resource(gvr).Namespace(namespace).Create(ctx, obj, metav1.CreateOptions{})
	if err != nil {
		return nil, fmt.Errorf("creating %s %s/%s: %w", gvr.Resource, namespace, obj.GetName(), err)
	}
	return result, nil
}

// GetCR retrieves a kro custom resource using the dynamic client.
func (c *Client) GetCR(ctx context.Context, namespace string, gvr schema.GroupVersionResource, name string) (*unstructured.Unstructured, error) {
	ctx, cancel := withTimeout(ctx, DefaultTimeout)
	defer cancel()

	result, err := c.DynamicClient.Resource(gvr).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("getting %s %s/%s: %w", gvr.Resource, namespace, name, err)
	}
	return result, nil
}

// ListCRs lists kro custom resources using the dynamic client.
func (c *Client) ListCRs(ctx context.Context, namespace string, gvr schema.GroupVersionResource, opts metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	ctx, cancel := withTimeout(ctx, 15*time.Second)
	defer cancel()

	result, err := c.DynamicClient.Resource(gvr).Namespace(namespace).List(ctx, opts)
	if err != nil {
		return nil, fmt.Errorf("listing %s in %s: %w", gvr.Resource, namespace, err)
	}
	return result, nil
}

// DeleteCR deletes a kro custom resource using the dynamic client.
func (c *Client) DeleteCR(ctx context.Context, namespace string, gvr schema.GroupVersionResource, name string) error {
	ctx, cancel := withTimeout(ctx, DefaultTimeout)
	defer cancel()

	err := c.DynamicClient.Resource(gvr).Namespace(namespace).Delete(ctx, name, metav1.DeleteOptions{})
	if err != nil && !k8serrors.IsNotFound(err) {
		return fmt.Errorf("deleting %s %s/%s: %w", gvr.Resource, namespace, name, err)
	}
	return nil
}

// IsConflict returns true if the error is a Kubernetes conflict (409) error.
func IsConflict(err error) bool {
	return k8serrors.IsConflict(err)
}

// IsNotFound returns true if the error is a Kubernetes not-found (404) error.
func IsNotFound(err error) bool {
	return k8serrors.IsNotFound(err)
}
