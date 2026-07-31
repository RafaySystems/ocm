# gRPC Registration: When CSR Is Not Approved / Not Issued (Signed)

When using **gRPC** registration, the hub runs **GRPCHubDriver** with two controllers: one that **approves** CSRs and one that **signs** (issues) them. This doc explains when the CSR stays **not approved** or **approved but not issued**.

---

## 1. Flow overview

| Step | Component | What happens |
|------|------------|--------------|
| 1 | Spoke agent | Sends CSR request over gRPC (token auth). CSR has **SignerName** `open-cluster-management.io/grpc`. |
| 2 | gRPC server (hub) | Creates the CSR on the hub API and sets **annotation** `open-cluster-management.io/csr-user` = token user from context (`HandleStatusUpdate` in `pkg/server/services/csr/csr.go`). |
| 3 | **csrApprovingController** | Same reconcilers as CSR path but with **SignerName** `operatorv1.GRPCAuthSigner` and **Username** from that **annotation** (not `Spec.Username`). If a reconciler allows, it calls **UpdateApproval** (adds Approved condition). |
| 4 | **csrSignController** | For CSRs that are **Approved** and have **Status.Certificate** empty and **SignerName** `open-cluster-management.io/grpc`, **signs** the CSR using **--grpc-ca-file** and **--grpc-key-file** and updates **CSR.Status.Certificate**. |
| 5 | Spoke | Sees approved + certificate, builds hub-kubeconfig secret. |

So in gRPC mode the hub both **approves** and **issues** (signs) the CSR; no kube-controller-manager signer is involved.

---

## 2. When the CSR is **not approved**

The **csrApprovingController** uses the same reconcilers as the CSR path (`csr.NewCSRRenewalReconciler` and `csr.NewCSRBootstrapReconciler`) with **SignerName** `open-cluster-management.io/grpc`. **Username** for those reconcilers comes from **`getCSRInfo`** in `hub_driver.go`, which uses **`Annotations[operatorv1.CSRUsernameAnnotation]`** (i.e. the token user set by the gRPC server when it creates the CSR).

### 2.1 validateCSR fails

Same as CSR path; the CSR is **not** approved if:

- **SignerName** is not `open-cluster-management.io/grpc`.
- Missing label **`open-cluster-management.io/cluster-name`**.
- Invalid PEM / org / commonName in the CSR request (e.g. org must match `system:open-cluster-management:managedcluster:<clusterName>`, commonName must have the expected prefix).

### 2.2 Renewal reconciler (CSRRenewalReconciler)

- **csr.Username != commonName**  
  For gRPC, **Username** is from the **annotation** (e.g. token identity string), and **commonName** is from the CSR subject (e.g. `system:open-cluster-management:managedcluster:cluster-534:...`). They are **usually different**, so the renewal reconciler often **skips** (`reconcileContinue`) and the bootstrap reconciler runs next.
- **authorize()** returns false  
  SubjectAccessReview for **renew** on `managedclusters/clientcertificates` fails (e.g. cluster not accepted, or no RBAC for the annotated user). Then the reconciler returns **reconcileStop** and logs *"Managed cluster csr cannot be auto approved due to subject access review not approved"* → **not approved**.

So for **first-time (bootstrap)** gRPC registration, renewal typically does **not** approve; **bootstrap reconciler** is what approves.

### 2.3 Bootstrap reconciler (CSRBootstrapReconciler)

- Only registered when feature gate **ManagedClusterAutoApproval** is enabled.
- Approves only if **`csr.Username`** (from annotation) is in **approvalUsers**, or **approvalUsers** contains **`"*"`** (wildcard: approve any user). See `approve_reconciler.go`: `Has("*") || Has(csr.Username)`.
- **approvalUsers** for gRPC comes from hub’s **--auto-approved-grpc-users** (see `hub/manager.go`: `m.AutoApprovedGRPCUsers` passed to `grpc.NewGRPCHubDriver`).

So if:

- **ManagedClusterAutoApproval** is disabled, or  
- **--auto-approved-grpc-users** is empty or does not include **`"*"`** or the token user (e.g. `admin`),

then the bootstrap reconciler **never** approves → CSR stays **not approved**.

**Practical fix:** Enable **ManagedClusterAutoApproval** and set **--auto-approved-grpc-users** to `"*"` (or a pattern that matches your bootstrap token user). In OcmHubCluster / cluster-manager config this is often exposed as **grpcAutoApprovedUsers: "*"**.

---

## 3. When the CSR is approved but **not issued** (not signed)

**csrSignController** (`hub_driver.go`) is responsible for **writing the signed certificate** into **CSR.Status.Certificate**. It only runs when:

1. CSR exists and has label **`open-cluster-management.io/cluster-name`**.
2. **Approved** condition is set.
3. **Status.Certificate** is **empty**.
4. **SignerName** is **`open-cluster-management.io/grpc`**.

Then it signs with **caKey** and **caData** (from **--grpc-key-file** and **--grpc-ca-file**) and calls **UpdateStatus**.

So the CSR stays **approved but not issued** if:

| Cause | What to check |
|-------|----------------|
| **CA/key files missing or unreadable** | **NewGRPCHubDriver** reads `caFile` and `caKeyFile` at startup; if either fails, the driver is not created. Ensure the registration controller (cluster-manager) is started with **--grpc-ca-file** and **--grpc-key-file** pointing to the gRPC signer CA cert and key (e.g. from **grpcSignerSecretRef** or default signer-secret). |
| **UpdateStatus fails** | Controller may not have RBAC to update **certificatesigningrequests/status**. Or API/network errors. Check hub registration controller logs. |
| **SignerName not gRPC** | csrSignController ignores CSRs whose **SignerName** is not `open-cluster-management.io/grpc`. |
| **Certificate already set** | If **Status.Certificate** is already non-empty, the controller does nothing (no re-sign). |

---

## 4. Summary: gRPC “CSR not approving and issuing”

| Symptom | Likely cause | Fix |
|--------|----------------|-----|
| CSR never gets **Approved** | validateCSR fails (wrong signer, labels, or request format). | Ensure CSR is created by the gRPC server with SignerName `open-cluster-management.io/grpc` and correct labels/request. |
| CSR never gets **Approved** | Renewal skips (Username != commonName); bootstrap not approving. | Enable **ManagedClusterAutoApproval** and set **--auto-approved-grpc-users** (e.g. `"*"`) so bootstrap reconciler approves the annotated user. |
| CSR never gets **Approved** | Bootstrap: annotated user not in approvalUsers. | Set **grpcAutoApprovedUsers: "*"** (or matching pattern) on the hub. |
| CSR **Approved** but **Status.Certificate** empty | Sign controller not running or CA/key not available. | Ensure **--grpc-ca-file** and **--grpc-key-file** are set and the registration controller can read them (e.g. from **grpcSignerSecretRef**). |
| CSR **Approved** but **Status.Certificate** empty | UpdateStatus RBAC or API error. | Check controller logs for **"controller failed to sync"** with key **\<csr-name\>** (e.g. `cluster-3567-bwjcn`); grant update on **certificatesigningrequests/status** if needed. |
| CSR **manually approved** (reason: KubectlApprove), certificate still empty | Sign controller runs only when CSR is approved; it does not log per-CSR. | Confirm **status.certificate** on the CSR; if still empty, check registration controller logs for sync errors and that the controller uses the same hub API as where the CSR exists. |

---

## 5. Relation to CSR path

- The **approval** logic lives in **`ocm/pkg/registration/register/csr`** (approve_reconciler, hub_driver). The gRPC hub driver reuses it with **SignerName** `open-cluster-management.io/grpc` and **Username** from **CSRUsernameAnnotation**.
- The **issuance** (signing) for gRPC is in **`ocm/pkg/registration/register/grpc/hub_driver.go`** (**csrSignController**). The normal CSR path has **no** signer in OCM; the cluster’s kube-controller-manager (or external signer) issues the cert. So for gRPC, the hub **must** have valid **--grpc-ca-file** and **--grpc-key-file** for the sign controller to issue the certificate.
