# vcluster POC: Replacing konk for API Aggregation

## Overview

This POC demonstrates how **vcluster** can replace **konk** for Kubernetes API aggregation use cases, using the `tagging-v2` service as a reference implementation.

---

## Part 1: How tagging-v2 Uses konk Today

### What is tagging-aggregate-api?

The `tagging-aggregate-api` is an **Extension API Server** that provides a Kubernetes-style API for managing tags in Infoblox's platform. Instead of using CRDs, it implements a full aggregated API.

**API Group**: `tagging.bulk.infoblox.com`  
**Version**: `v1alpha1`  
**Resources**: tags, tagvalues, and other tagging-related resources

### Why Use konk Instead of Registering Directly with EKS?

| Risk | Without konk | With konk |
|------|--------------|-----------|
| **Cluster stability** | Buggy Extension API can crash EKS apiserver | Only konk's isolated apiserver is affected |
| **etcd pollution** | Custom data stored in EKS's etcd | Stored in konk's dedicated etcd |
| **Blast radius** | Cluster-wide impact | Only tagging functionality affected |
| **API conflicts** | Could conflict with other EKS extensions | Isolated namespace |

### Architecture with konk

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          HOST CLUSTER (EKS)                                 │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  aggregate namespace                                                │   │
│   │                                                                     │   │
│   │   ┌─────────────────────────────────────────────────────────────┐   │   │
│   │   │  bulk-konk (kube-apiserver)                                 │   │   │
│   │   │  - Isolated K8s apiserver                                   │   │   │
│   │   │  - Has APIService: v1alpha1.tagging.bulk.infoblox.com       │   │   │
│   │   └───────────────────────────┬─────────────────────────────────┘   │   │
│   │                               │                                     │   │
│   │   ┌───────────────────────────┼─────────────────────────────────┐   │   │
│   │   │  bulk-konk-etcd           │                                 │   │   │
│   │   │  (stores konk data)       │                                 │   │   │
│   │   └───────────────────────────┘                                 │   │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                   │                                         │
│                                   │ APIService proxies to                   │
│                                   ▼                                         │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  tagging-v2 namespace                                               │   │
│   │                                                                     │   │
│   │   ┌─────────────────────────────────────────────────────────────┐   │   │
│   │   │  tagging-aggregate-api-apiservice (Service)                 │   │   │
│   │   │  ClusterIP: 10.100.187.71:443                               │   │   │
│   │   └───────────────────────────┬─────────────────────────────────┘   │   │
│   │                               │                                     │   │
│   │   ┌───────────────────────────▼─────────────────────────────────┐   │   │
│   │   │  tagging-aggregate-api pod                                  │   │   │
│   │   │  - Handles /apis/tagging.bulk.infoblox.com/v1alpha1/...     │   │   │
│   │   │  - Business logic for tag management                        │   │   │
│   │   └─────────────────────────────────────────────────────────────┘   │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### KonkService Configuration (actual from us-dev-5)

```yaml
apiVersion: konk.infoblox.com/v1alpha1
kind: KonkService
metadata:
  name: tagging-aggregate-api-apiservice
  namespace: tagging-v2
spec:
  group:
    name: tagging.bulk.infoblox.com
  konk:
    name: bulk-konk
    namespace: aggregate
    scope: cluster
  service:
    name: tagging-aggregate-api-apiservice
  version: v1alpha1
```

### What KonkService Automatically Creates

When you create a KonkService, the konk-operator deploys:

| Pod | Purpose |
|-----|---------|
| `tagging-aggregate-api-apiservice-konk-service-kubeconfig-*` | Generates and maintains kubeconfig secret for Extension API Server to talk to konk |
| `tagging-aggregate-api-apiservice-konk-service-kubectl-apis*` | Registers APIService inside konk's apiserver |

**Inside konk, it creates:**

1. **Namespace** for the service reference
2. **ExternalName Service** pointing to the Extension API Server in host cluster
3. **APIService** registration:
   ```yaml
   apiVersion: apiregistration.k8s.io/v1
   kind: APIService
   metadata:
     name: v1alpha1.tagging.bulk.infoblox.com
   spec:
     group: tagging.bulk.infoblox.com
     version: v1alpha1
     service:
       name: tagging-aggregate-api-apiservice
       namespace: tagging-v2
   ```
4. **ClusterRole** for RBAC

### Request Flow

```
Client Request: GET /apis/tagging.bulk.infoblox.com/v1alpha1/namespaces/default/tags
         │
         ▼
┌─────────────────┐
│  bulk-konk      │  (konk apiserver)
│  apiserver      │  "I have an APIService for tagging.bulk.infoblox.com"
└────────┬────────┘
         │
         │  Proxies via ExternalName Service
         ▼
┌────────────────────────────┐
│ tagging-aggregate-api      │  (Extension API Server)
│ (tagging-v2 namespace)     │  Handles request, returns tags
└────────────────────────────┘
```

---

## Part 2: POC - Replacing konk with vcluster

### Goal

Demonstrate that vcluster can provide the same **isolated API aggregation** capability as konk, using a mock tagging API server.

### POC Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          HOST CLUSTER (us-dev-5)                            │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  vcluster-poc namespace                                             │   │
│   │                                                                     │   │
│   │   ┌─────────────────────────────────────────────────────────────┐   │   │
│   │   │  poc-vcluster-0 (vcluster)                                  │   │   │
│   │   │  - k3s apiserver + etcd in single pod                       │   │   │
│   │   │  - Has APIService: v1alpha1.tagging.poc.infoblox.com        │   │   │
│   │   │  - REPLACEMENT FOR bulk-konk                                │   │   │
│   │   └───────────────────────────┬─────────────────────────────────┘   │   │
│   │                               │                                     │   │
│   │                               │ APIService proxies to               │   │
│   │                               ▼                                     │   │
│   │   ┌─────────────────────────────────────────────────────────────┐   │   │
│   │   │  mock-tagging-apiserver (Service + Deployment)              │   │   │
│   │   │  - Python-based mock Extension API Server                   │   │   │
│   │   │  - Serves: tagging.poc.infoblox.com/v1alpha1                │   │   │
│   │   │  - SIMULATES tagging-aggregate-api                          │   │   │
│   │   └─────────────────────────────────────────────────────────────┘   │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### POC Components

#### 1. vcluster (poc-vcluster)

Created with:
```bash
vcluster create poc-vcluster --namespace vcluster-poc --connect=false
```

**What it provides:**
- Isolated Kubernetes API server (k3s-based)
- Own etcd storage (SQLite by default, can use external etcd)
- Virtual nodes (synced from host)
- Full Kubernetes API compatibility

#### 2. Mock Extension API Server

File: `vcluster-poc/mock-apiserver.yaml`

A Python-based service that mimics tagging-aggregate-api:

| Endpoint | Response |
|----------|----------|
| `/healthz` | `ok` |
| `/apis/tagging.poc.infoblox.com/v1alpha1` | APIResourceList (tags, tagvalues) |
| `/apis/tagging.poc.infoblox.com/v1alpha1/namespaces/{ns}/tags` | List of mock tags |

**API Group**: `tagging.poc.infoblox.com` (different from prod to avoid conflicts)

#### 3. APIService Registration

File: `vcluster-poc/apiservice-registration.yaml`

Registers the mock API with vcluster:

```yaml
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: v1alpha1.tagging.poc.infoblox.com
spec:
  insecureSkipTLSVerify: true  # For POC only
  group: tagging.poc.infoblox.com
  groupPriorityMinimum: 1000
  service:
    name: mock-tagging-apiserver
    namespace: extension-apis
    port: 443
  version: v1alpha1
  versionPriority: 100
```

### Comparison: konk vs vcluster POC

| Aspect | konk (prod) | vcluster (POC) |
|--------|-------------|----------------|
| **Isolated apiserver** | bulk-konk | poc-vcluster-0 |
| **Storage** | Dedicated etcd pod | SQLite (embedded in vcluster) |
| **API Group** | `tagging.bulk.infoblox.com` | `tagging.poc.infoblox.com` |
| **Extension API Server** | tagging-aggregate-api | mock-tagging-apiserver |
| **Registration** | Automatic via KonkService CR | Manual APIService creation |
| **Namespace** | Multiple (aggregate, tagging-v2) | Single (vcluster-poc) |
| **Maintenance** | Infoblox internal | Open source (Loft Labs) |

### POC Steps

#### All Steps Completed ✅

1. **Created vcluster** in `vcluster-poc` namespace
2. **Deployed mock-tagging-apiserver** - Python service that responds to K8s API patterns (with HTTPS/TLS)
3. **Verified mock API server** works via curl test
4. **Applied APIService registration** inside vcluster
5. **Tested API aggregation** - successfully called custom API through vcluster's apiserver

---

## Part 3: POC Results

### Test Results

| Test | Result | Details |
|------|--------|---------|
| vcluster creation | ✅ Pass | `poc-vcluster-0` running in `vcluster-poc` namespace |
| Mock API Server deployment | ✅ Pass | HTTPS server with self-signed cert |
| APIService registration | ✅ Pass | `v1alpha1.tagging.poc.infoblox.com` shows `Available: True` |
| API discovery | ✅ Pass | `/apis/tagging.poc.infoblox.com/v1alpha1` returns APIResourceList |
| Resource listing | ✅ Pass | `/apis/.../namespaces/default/tags` returns Tag objects |

### Successful Request Flow (Verified)

```
kubectl get --raw /apis/tagging.poc.infoblox.com/v1alpha1/namespaces/default/tags
         │
         ▼
┌─────────────────────────────────────┐
│  vcluster apiserver (poc-vcluster)  │
│  - Has APIService registered        │
│  - Proxies to extension-apis svc    │
└────────────────┬────────────────────┘
                 │
                 ▼ (via ExternalName → host cluster)
┌─────────────────────────────────────┐
│  mock-tagging-apiserver             │
│  (vcluster-poc namespace in host)   │
│  - Returns mock Tag resources       │
└─────────────────────────────────────┘
         │
         ▼
Response:
{
  "kind": "TagsList",
  "apiVersion": "tagging.poc.infoblox.com/v1alpha1",
  "items": [{
    "kind": "Tag",
    "metadata": {"name": "example-tag", "namespace": "default"},
    "spec": {"key": "environment", "description": "Mock tag from POC..."}
  }]
}
```

### APIService Status (Final)

```
NAME                                SERVICE                                 AVAILABLE   AGE
v1alpha1.tagging.poc.infoblox.com   extension-apis/mock-tagging-apiserver   True        5m
```

### Key Differences to Address for Production

| Challenge | konk Solution | vcluster Equivalent Needed |
|-----------|---------------|---------------------------|
| **Automatic APIService registration** | KonkService CR + operator | Custom operator or manual process |
| **Certificate management** | cert-manager integration | vcluster's built-in PKI or custom |
| **Kubeconfig generation** | KonkService creates secret | Manual or custom tooling |
| **RBAC setup** | Automatic via konk-service chart | Manual or custom tooling |

---

## Files Created

| File | Purpose |
|------|---------|
| `vcluster-poc/mock-apiserver.yaml` | Mock Extension API Server deployment (Python + HTTPS) |
| `vcluster-poc/apiservice-registration.yaml` | APIService + ExternalName Service for vcluster |
| `vcluster-poc/POC_DETAILS.md` | This documentation |

---

## Conclusion

### POC Verdict: ✅ SUCCESS

This POC demonstrates that vcluster **can** provide the same API aggregation isolation as konk. 

**What was proven:**
- vcluster can host APIService registrations
- vcluster can proxy requests to Extension API Servers in the host cluster
- The same API aggregation pattern used by konk works with vcluster
- No impact to existing konk setup (completely isolated)

### Key Trade-offs

| Aspect | konk | vcluster |
|--------|------|----------|
| **Automation** | KonkService CR handles everything | Manual APIService + Service creation |
| **Overhead** | Lighter (apiserver + etcd only) | Heavier (full k3s control plane) |
| **Maintenance** | Internal tooling | Active open-source community |
| **Flexibility** | API aggregation only | Full K8s workload support |

### Migration Path

For production migration, you would need to either:
1. **Build a `VclusterService` operator** (similar to KonkService) - Recommended
2. **Manually configure** each Extension API Server
3. **Use a hybrid approach** during transition

---

## Commands Used

### 1. Install vcluster CLI

```bash
brew install loft-sh/tap/vcluster
```

### 2. Create Namespace and vcluster

```bash
# Create namespace for POC
kubectl create namespace vcluster-poc

# Create vcluster (k3s-based virtual cluster)
vcluster create poc-vcluster --namespace vcluster-poc --connect=false
```

### 3. Deploy Mock Extension API Server (in host cluster)

```bash
# Switch to host cluster context
kubectl config use-context teleport.services.sdp.infoblox.com-us-dev-5

# Apply mock API server deployment
kubectl apply -f vcluster-poc/mock-apiserver.yaml

# Verify pods are running
kubectl get pods -n vcluster-poc
```

### 4. Test Mock API Server

```bash
# Test health endpoint
kubectl run -n vcluster-poc curl-test --image=curlimages/curl --rm -it --restart=Never \
  -- curl -s http://mock-tagging-apiserver.vcluster-poc.svc:443/healthz

# Test API discovery
kubectl run -n vcluster-poc curl-test --image=curlimages/curl --rm -it --restart=Never \
  -- curl -s http://mock-tagging-apiserver.vcluster-poc.svc:443/apis/tagging.poc.infoblox.com/v1alpha1
```

### 5. Connect to vcluster and Register APIService

```bash
# Option A: Connect to vcluster (opens port-forward)
vcluster connect poc-vcluster --namespace vcluster-poc

# Option B: Switch to vcluster context directly
kubectl config use-context vcluster_poc-vcluster_vcluster-poc_teleport.services.sdp.infoblox.com-us-dev-5

# Apply APIService registration inside vcluster
kubectl apply -f vcluster-poc/apiservice-registration.yaml
```

### 6. Verify APIService Registration

```bash
# Check APIService is available (should show True)
kubectl get apiservices | grep tagging

# Expected output:
# v1alpha1.tagging.poc.infoblox.com   extension-apis/mock-tagging-apiserver   True   5m
```

### 7. Test API Aggregation

```bash
# Test API discovery through vcluster
kubectl get --raw /apis/tagging.poc.infoblox.com/v1alpha1

# Test resource listing (the main POC goal!)
kubectl get --raw /apis/tagging.poc.infoblox.com/v1alpha1/namespaces/default/tags | jq .
```

### 8. Cleanup (Optional)

```bash
# Switch to host cluster
kubectl config use-context teleport.services.sdp.infoblox.com-us-dev-5

# Delete vcluster (this removes everything)
vcluster delete poc-vcluster --namespace vcluster-poc

# Delete namespace
kubectl delete namespace vcluster-poc
```

---

## Appendix: Troubleshooting

### APIService shows "FailedDiscoveryCheck"

**Symptom**: `kubectl get apiservices` shows `Available: False (FailedDiscoveryCheck)`

**Cause**: Usually TLS/network issues between vcluster and the Extension API Server

**Solution**:
1. Ensure Extension API Server uses HTTPS (not HTTP)
2. Check `insecureSkipTLSVerify: true` is set in APIService spec
3. Verify network connectivity from vcluster pod to host service

### Cannot reach Extension API Server

**Check network connectivity**:
```bash
# From vcluster context, test DNS resolution
kubectl run -n default curl-test --image=curlimages/curl --rm -it --restart=Never \
  -- curl -sk https://mock-tagging-apiserver.vcluster-poc.svc.cluster.local:443/healthz
```

---

*POC completed on us-dev-5 cluster, February 18, 2026*
