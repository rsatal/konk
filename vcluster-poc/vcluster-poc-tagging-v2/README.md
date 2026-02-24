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

---

## Part 4: Changes Required to Replace konk with vcluster for tagging-v2

### Current State

- **konk** is deployed via `konk-operator` (namespace: `konk`) and `bulk` app (namespace: `aggregate`)
- **vcluster** is now deployed in `vcluster` namespace via the company workflow (defined in `deployment-configurations/apps.yaml`)
- **tagging-aggregate-api** helm chart creates a `KonkService` CR that auto-provisions APIService registration, TLS certs, kubeconfig, and RBAC

### What KonkService Does Today (and what must be replaced)

| What KonkService creates | Where | Replacement needed |
|---|---|---|
| `APIService` registration | Inside konk's apiserver | Create inside vcluster |
| `ExternalName Service` | Inside konk | Create inside vcluster |
| `Namespace` for service ref | Inside konk | Create inside vcluster |
| `ClusterRole` for RBAC | Inside konk | Create inside vcluster |
| TLS server cert secret (`tagging-aggregate-api-apiservice-konk-service-server`) | `tagging-v2` namespace on host | New cert via cert-manager or vcluster PKI |
| Kubeconfig secret (`tagging-aggregate-api-apiservice-konk-service-kubeconfig`) | `tagging-v2` namespace on host | New kubeconfig pointing to vcluster |

### Target Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                          HOST CLUSTER (EKS)                                │
│                                                                            │
│   ┌────────────────────────────────────────────────────────────────────┐   │
│   │  vcluster namespace                                                │   │
│   │                                                                    │   │
│   │   ┌────────────────────────────────────────────────────────────┐   │   │
│   │   │  vcluster-0 (vcluster — k3s apiserver)                     │   │   │
│   │   │  - APIService: v1alpha1.tagging.bulk.infoblox.com          │   │   │
│   │   │  - REPLACES bulk-konk                                      │   │   │
│   │   └───────────────────────────┬────────────────────────────────┘   │   │
│   └───────────────────────────────┼────────────────────────────────────┘   │
│                                   │                                        │
│                                   │ APIService proxies to                  │
│                                   ▼                                        │
│   ┌────────────────────────────────────────────────────────────────────┐   │
│   │  tagging-v2 namespace                                              │   │
│   │                                                                    │   │
│   │   ┌────────────────────────────────────────────────────────────┐   │   │
│   │   │  tagging-aggregate-api pod (UNCHANGED)                     │   │   │
│   │   │  - Same Go binary, same business logic                     │   │   │
│   │   │  - --authentication-kubeconfig now → vcluster               │   │   │
│   │   │  - --authorization-kubeconfig now → vcluster                │   │   │
│   │   └────────────────────────────────────────────────────────────┘   │   │
│   └────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────┘
```

### Change 1: Register APIService + ExternalName inside vcluster

Create these resources **inside vcluster** (equivalent of what KonkService auto-created inside konk):

```yaml
# Namespace inside vcluster for the service reference
apiVersion: v1
kind: Namespace
metadata:
  name: tagging-v2
---
# ExternalName Service inside vcluster → points to host cluster service
apiVersion: v1
kind: Service
metadata:
  name: tagging-aggregate-api-apiservice
  namespace: tagging-v2
spec:
  type: ExternalName
  externalName: tagging-aggregate-api-apiservice.tagging-v2.svc.cluster.local
  ports:
  - port: 443
---
# APIService registration inside vcluster
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: v1alpha1.tagging.bulk.infoblox.com
spec:
  group: tagging.bulk.infoblox.com
  version: v1alpha1
  groupPriorityMinimum: 1000
  versionPriority: 100
  insecureSkipTLSVerify: true          # for dev; use caBundle in prod
  service:
    name: tagging-aggregate-api-apiservice
    namespace: tagging-v2
    port: 443
```

**How to apply these automatically — options:**

| Approach | Pros | Cons |
|----------|------|------|
| Kubernetes Job (runs post-deploy) | Simple, scriptable | One-shot, no reconciliation |
| Init container on tagging-aggregate-api | Tied to pod lifecycle | Adds startup latency |
| Custom operator (VclusterService) | Full automation like KonkService | Significant development effort |
| Manual via `vcluster connect` | Quick for dev/testing | Not sustainable for prod |

### Change 2: tagging-aggregate-api Helm Chart

The pod currently mounts **two konk-generated secrets**:

```yaml
# CURRENT — these secret names are created by KonkService
volumes:
- name: apiserver-cert
  secret:
    secretName: tagging-aggregate-api-apiservice-konk-service-server      # ← TLS cert
- name: kubeconfig
  secret:
    secretName: tagging-aggregate-api-apiservice-konk-service-kubeconfig  # ← kubeconfig to konk
```

**Changes needed in the helm chart:**

1. **Remove the `KonkService` CR template entirely** — this is the CR at the bottom of the rendered manifest:
   ```yaml
   # DELETE THIS from the chart
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

2. **Update volume secret references** to point to new vcluster-generated secrets:
   ```yaml
   # NEW — secret names for vcluster
   volumes:
   - name: apiserver-cert
     secret:
       secretName: tagging-aggregate-api-vcluster-server      # ← new TLS cert
   - name: kubeconfig
     secret:
       secretName: tagging-aggregate-api-vcluster-kubeconfig  # ← kubeconfig to vcluster
   ```

3. **Container args stay the same** — still use `--authentication-kubeconfig` and `--authorization-kubeconfig`, just now the secret content points to vcluster's apiserver instead of konk.

### Change 3: Kubeconfig Generation (most critical)

This is the **hardest part** — replacing what KonkService automated.

**What's needed:** A kubeconfig secret in the `tagging-v2` namespace that lets the tagging-aggregate-api pod authenticate against vcluster for delegated auth.

**Steps:**

1. Extract vcluster's admin kubeconfig from secret `vc-vcluster` in the `vcluster` namespace:
   ```bash
   kubectl get secret vc-vcluster -n vcluster -o jsonpath='{.data.config}' | base64 -d
   ```

2. Modify the server URL to use **internal cluster DNS** (not localhost/port-forward):
   ```yaml
   # Change server from:
   server: https://localhost:8443
   # To:
   server: https://vcluster.vcluster.svc.cluster.local:443
   ```

3. Create the kubeconfig secret in `tagging-v2` namespace:
   ```bash
   kubectl create secret generic tagging-aggregate-api-vcluster-kubeconfig \
     -n tagging-v2 \
     --from-file=admin.conf=./vcluster-kubeconfig.yaml
   ```

**For automation**, this should become a Job or script that:
- Reads the vcluster kubeconfig secret
- Rewrites the server URL to internal DNS
- Creates/updates the secret in the target namespace

### Change 4: TLS Certificate Provisioning

| Option | How | Dev | Prod |
|--------|-----|-----|------|
| `insecureSkipTLSVerify: true` in APIService | Set in vcluster-internal APIService spec | ✅ Good enough | ❌ Not recommended |
| cert-manager with vcluster CA | Extract vcluster CA → create Issuer → issue cert | ✅ | ✅ Recommended |
| Self-signed cert + caBundle | Generate cert, put CA in APIService `.spec.caBundle` | ✅ | ✅ Acceptable |

### Change 5: deployment-configurations

**`apps.yaml`** — update tagging-aggregate-api dependency:
```yaml
# Current:
tagging-aggregate-api:
  inherit-shared-values:
    - legacy
    - ingress
  namespace: tagging-v2
  # ... (no explicit konk dependency, but implicitly needs bulk app)

# Add vcluster dependency:
tagging-aggregate-api:
  dependencies:
    - name: vcluster
  inherit-shared-values:
    - legacy
    - ingress
  namespace: tagging-v2
```

**`build/*/tagging-aggregate-api.yaml`** — replace konk values:
```yaml
# Current (in every environment's values file):
konk:
  enabled: true
  name: bulk-konk
  namespace: aggregate
  scope: cluster

# Replace with:
konk:
  enabled: false    # disable KonkService creation

vcluster:
  enabled: true
  name: vcluster
  namespace: vcluster
```

### Change 6: RBAC inside vcluster

KonkService created a `ClusterRole` inside konk. Create the equivalent inside vcluster:

```yaml
# Apply inside vcluster
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tagging-aggregate-api-delegated-auth
rules:
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
- apiGroups: ["authorization.k8s.io"]
  resources: ["subjectaccessreviews"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tagging-aggregate-api-delegated-auth
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tagging-aggregate-api-delegated-auth
subjects:
- kind: User
  name: tagging-aggregate-api
  apiGroup: rbac.authorization.k8s.io
```
<!-- 
### Change 7: k8s.manifests Changes

The `k8s.manifests` repository contains the rendered Kubernetes manifests that get applied to each cluster. These are **auto-generated** from the helm chart + values files by the deployment pipeline.

**What changes automatically** (once helm chart is updated):
- The `KonkService` CR will disappear from `dev/env-5/tagging-aggregate-api/manifest.yaml`
- Secret volume references will change from `*-konk-service-*` to `*-vcluster-*`

**What needs manual attention:**
- If there is a new manifest directory needed for the vcluster-internal resources (APIService + ExternalName + RBAC), it depends on how you choose to apply them (Job, init container, or separate helm chart)
- If a separate helm chart or Job is used to apply resources inside vcluster, a new manifest directory (e.g., `dev/env-5/vcluster-apiservice-registration/`) may be needed in each cluster folder

**Current manifest structure** (per cluster):
```
k8s.manifests/
  dev/env-5/
    konk-operator/manifest.yaml        ← stays (still needed for other services during transition)
    bulk/manifest.yaml                  ← stays (still needed for other services during transition)
    tagging-aggregate-api/manifest.yaml ← changes (KonkService removed, new secret refs)
    tagging-v2/manifest.yaml            ← unchanged (the tagging app itself)
```

**Note:** `konk-operator` and `bulk` manifests can only be removed once **all 11** extension API servers are migrated to vcluster, not just tagging-v2. -->

### Change 7: Ingress (if applicable)

KonkService supports a **front-proxy ingress** feature that allows external clients to reach extension APIs through an NGINX Ingress with mTLS. This needs to be checked for tagging-v2.

**Check if tagging-v2 uses konk ingress:**
```bash
# Look for ingress spec in the KonkService CR
kubectl get konkservice tagging-aggregate-api-apiservice -n tagging-v2 -o yaml | grep -A10 "ingress:"
```

**If ingress is NOT configured** (likely for tagging-v2 — it's an internal API):
- No ingress changes needed
- Skip this step

**If ingress IS configured**, you need to:

1. **Create a new Ingress** that routes to vcluster's apiserver instead of bulk-konk:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: tagging-aggregate-api-ingress
     namespace: vcluster
     annotations:
       nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
       nginx.ingress.kubernetes.io/proxy-ssl-verify: "true"
       # mTLS client cert for vcluster (replaces konk ingress client cert)
       nginx.ingress.kubernetes.io/proxy-ssl-secret: "vcluster/vcluster-ingress-client"
   spec:
     ingressClassName: nginx
     tls:
     - hosts:
       - tagging-api.example.com
       secretName: tagging-api-tls
     rules:
     - host: tagging-api.example.com
       http:
         paths:
         - path: /apis/tagging.bulk.infoblox.com
           pathType: Prefix
           backend:
             service:
               name: vcluster
               port:
                 number: 443
   ```

2. **Update DNS** if the hostname changes

3. **Provision mTLS client certificate** for NGINX → vcluster authentication (replaces `<konk-name>-ingress-client` secret that KonkService created)

**For the tagging-v2 pilot**, confirm with the team whether external ingress access is required. Most extension APIs are accessed internally via konk/vcluster only, making this step unnecessary.

### Summary: Ordered Change List

| # | Where | Change | Complexity |
|---|---|---|---|
| 1 | `tagging-aggregate-api` helm chart | Remove `KonkService` CR template | Low |
| 2 | `tagging-aggregate-api` helm chart | Update volume mount secret names (TLS cert + kubeconfig) | Low |
| 3 | `deployment-configurations/apps.yaml` | Add `vcluster` as dependency for `tagging-aggregate-api` | Low |
| 4 | `deployment-configurations/build/*/tagging-aggregate-api.yaml` | Replace `konk.*` values with vcluster config, set `konk.enabled: false` | Medium |
| 5 | Inside vcluster | Create Namespace + ExternalName Service + APIService (automation TBD) | Medium |
| 6 | Inside vcluster | Create RBAC (ClusterRole + ClusterRoleBinding) for delegated auth | Low |
| 7 | Host cluster (`tagging-v2` ns) | Generate kubeconfig secret pointing to vcluster apiserver | High |
| 8 | Host cluster or vcluster PKI | Provision TLS serving cert for the Extension API Server | Medium |
| 9 | `k8s.manifests` repo | Manifests auto-update; optionally add new dir for vcluster-internal resources | Low |
| 10 | Ingress (if used) | Re-route external ingress from konk to vcluster; new mTLS client cert | Medium (skip if not used) |

### Recommended Approach: Start in Dev

1. **Manually** create kubeconfig secret in `tagging-v2` namespace (extracted from vcluster)
2. **Manually** apply APIService + ExternalName + RBAC inside vcluster (via `vcluster connect`)
3. Modify tagging-aggregate-api helm values to set `konk.enabled: false` and reference new secrets
4. Verify tagging API works through vcluster
5. Once verified, automate steps 1-2 with a Job or init-container before rolling to other environments

### Full Migration Scope (all 11 Extension API Servers)

Once tagging-v2 works, repeat for all services currently using konk:

| Namespace | Service Name | API Group |
|-----------|-------------|-----------|
| atcapi | atcapi-apiservice | atcapi.bulk.infoblox.com |
| ddi | dns-config-importexport-apiservice | dnsconfig.bulk.infoblox.com |
| ddi | dns-data-importexport-apiservice | dnsdata.bulk.infoblox.com |
| ddi | ipam-importexport-apiservice | ipamdhcp.bulk.infoblox.com |
| ddi | keys-importexport-apiservice | keys.bulk.infoblox.com |
| endpoints | endpoints-api-service-apiservice | endpoints.bulk.infoblox.com |
| hostapp | hostapp-aggregate-api-apiservice | onprem.bulk.infoblox.com, infrastructure.bulk.infoblox.com |
| ngp-cp | bootstrap-app-aggregate-api-apiservice | bootstrap.bulk.infoblox.com |
| ntp | ntp-aggregate-api-apiservice | ntp.bulk.infoblox.com |
| redirect | redirect-apiservice | redirect.bulk.infoblox.com |
| tagging-v2 | tagging-aggregate-api-apiservice | tagging.bulk.infoblox.com |

**Summary: 1 konk apiserver → 11 Extension API Servers → 12 API Groups → all need migration**

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
| **Automation** | KonkService CR handles everything | Manual APIService + Service creation (needs tooling) |
| **Overhead** | Lighter (apiserver + etcd only) | Heavier (full k3s control plane) |
| **Maintenance** | Internal tooling, limited updates | Active open-source community |
| **Flexibility** | API aggregation only | Full K8s workload support |

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
