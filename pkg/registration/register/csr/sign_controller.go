// Package csr provides an optional sign controller for the CSR registration path.
// When the hub has no kube-controller-manager (e.g. Kubeless), approved CSRs with
// signerName kubernetes.io/kube-apiserver-client are never issued. This controller
// signs those CSRs using the configured CA/key and sets status.certificate.
package csr

import (
	"context"
	"fmt"
	"time"

	certificatesv1 "k8s.io/api/certificates/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	certificatesv1informers "k8s.io/client-go/informers/certificates/v1"
	certificatesv1listers "k8s.io/client-go/listers/certificates/v1"
	"k8s.io/client-go/kubernetes"

	clusterv1 "open-cluster-management.io/api/cluster/v1"
	"open-cluster-management.io/sdk-go/pkg/basecontroller/factory"
	sdkhelpers "open-cluster-management.io/sdk-go/pkg/helpers"
)

// NewCSRSignController creates a controller that signs approved CSRs with
// signerName kubernetes.io/kube-apiserver-client when status.certificate is empty.
// Use this when the hub has no kube-controller-manager (e.g. Kubeless) so the
// registration controller can both approve and issue client certificates.
func NewCSRSignController(
	kubeClient kubernetes.Interface,
	csrInformer certificatesv1informers.CertificateSigningRequestInformer,
	caKey, caData []byte,
	duration time.Duration,
) factory.Controller {
	c := &csrSignController{
		kubeClient: kubeClient,
		csrLister:  csrInformer.Lister(),
		caKey:      caKey,
		caData:     caData,
		duration:   duration,
	}
	return factory.New().
		WithFilteredEventsInformersQueueKeysFunc(
			func(obj runtime.Object) []string {
				accessor, _ := meta.Accessor(obj)
				return []string{accessor.GetName()}
			},
			func(obj interface{}) bool {
				accessor, _ := meta.Accessor(obj)
				if accessor.GetLabels() == nil {
					return false
				}
				if _, ok := accessor.GetLabels()[clusterv1.ClusterNameLabelKey]; !ok {
					return false
				}
				return true
			},
			csrInformer.Informer()).
		WithSync(c.sync).
		ToController("CSRSignController")
}

type csrSignController struct {
	kubeClient kubernetes.Interface
	csrLister  certificatesv1listers.CertificateSigningRequestLister
	caKey      []byte
	caData     []byte
	duration   time.Duration
}

func (c *csrSignController) sync(ctx context.Context, syncCtx factory.SyncContext, csrName string) error {
	csr, err := c.csrLister.Get(csrName)
	if errors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return err
	}

	csr = csr.DeepCopy()

	approved := false
	for _, condition := range csr.Status.Conditions {
		if condition.Type == certificatesv1.CertificateApproved {
			approved = true
			break
		}
	}
	if !approved {
		return nil
	}
	if len(csr.Status.Certificate) > 0 {
		return nil
	}
	if csr.Spec.SignerName != certificatesv1.KubeAPIServerClientSignerName {
		return nil
	}

	signerFunc := sdkhelpers.CSRSignerWithExpiry(c.caKey, c.caData, c.duration)
	csr.Status.Certificate = signerFunc(csr)
	if len(csr.Status.Certificate) == 0 {
		return fmt.Errorf("invalid client certificate generated for csr %q", csr.Name)
	}
	_, err = c.kubeClient.CertificatesV1().CertificateSigningRequests().UpdateStatus(ctx, csr, metav1.UpdateOptions{})
	return err
}
