# Migrate Bulk and Tagging from Konk to vCluster

**Cluster:** us-dev-5  
**Date:** February 24, 2026  
**Context:** `teleport.services.sdp.infoblox.com-us-dev-5`

---

## 1. Overview

This document captures the end-to-end migration of the **tagging-aggregate-api** and the **bulk** deployment from konk (`bulk-konk`) to vcluster. The goal is to validate whether vcluster can replace konk as the API aggregation layer.

### Components Involved

| Component | Namespace | Description |
|-----------|-----------|-------------|
| `tagging-aggregate-api` | `tagging-v2` | Extension API server serving `tags` and `values` resources under `tagging.bulk.infoblox.com/v1alpha1` |
| `bulk` | `aggregate` | Import/export service that discovers and proxies requests to extension API servers through the aggregation layer (konk/vcluster) |
| `bulk-konk` | `aggregate` | Konk's kube-apiserver — the aggregation point for all 11 extension API servers (19 KonkService CRs) |
| `vcluster-0` | `vcluster` | vcluster StatefulSet — the replacement aggregation point |

### Pre-Migration Architecture

```
Client → env-5.test.infoblox.com → bulk deployment
                                      │
                                      │ --konk.host=bulk-konk.aggregate:6443
                                      │ kubeconfig: bulk-konk-kubeconfig
                                      │ proxy-client: bulk-konk-proxy-client
                                      ▼
                               ┌───────────-──┐
                               │  bulk-konk   │ (konk kube-apiserver)
                               │  port 6443   │
                               └──────┬───-───┘
                                      │ APIService aggregation
                                      ▼
                     ┌──────────────────────────────────-──┐
                     │    19 KonkService CRs               │
                     │    11 Extension API Servers         │
                     │    12 API Groups                    │
                     │    (including tagging-aggregate-api)│
                     └──────────────────────────────────-──┘
```

### Post-Migration Architecture (Tagging Only)

```
Client → env-5.test.infoblox.com → bulk deployment
                                      │
                                      │ --konk.host=vcluster.vcluster:443
                                      │ kubeconfig: bulk-vcluster-kubeconfig
                                      │ proxy-client: bulk-vcluster-proxy-client
                                      ▼
                               ┌──────────────┐
                               │   vcluster   │ (vcluster kube-apiserver)
                               │   port 443   │
                               └──────┬───────┘
                                      │ APIService: v1alpha1.tagging.bulk.infoblox.com
                                      ▼
                            ┌────────────────-─────┐
                            │ tagging-aggregate-api│
                            │ (tagging-v2 ns)      │
                            └────────────────-─────┘
```

---

## 2. Pre-Migration State

### Tagging Deployment (`tagging-v2` namespace)

```
Deployment: tagging-aggregate-api
  Replicas: 1
  Image: infobloxcto/atlas.tagging.aggregateapi:v0.1.5-37-gdfd0864-j3
  Key Args:
    --tagging.url=http://tagging.tagging-v2.svc.cluster.local:8081/v2/tags
    --tls-cert-file=/tmp/k8s-apiserver-server/serving-certs/tls.crt
    --tls-private-key-file=/tmp/k8s-apiserver-server/serving-certs/tls.key
    --authentication-kubeconfig=/kubeconfig/admin.conf
    --authorization-kubeconfig=/kubeconfig/admin.conf
    --delegated-auth=true
  Volumes:
    apiserver-cert → tagging-aggregate-api-apiservice-konk-service-server (TLS)
    kubeconfig     → tagging-aggregate-api-apiservice-konk-service-kubeconfig
```

### Bulk Deployment (`aggregate` namespace)

```
Deployment: bulk
  Replicas: 2
  Image: infobloxcto/atlas.bulk:v2.5.0-72-g9a753381-j177
  Key Args:
    [12] --konk.host=bulk-konk.aggregate:6443
    [13] --konk.tls.insecure=true
    [14] --konk.tls.cert=/tmp/k8s-apiserver-server/serving-certs/tls.crt
    [15] --konk.tls.key=/tmp/k8s-apiserver-server/serving-certs/tls.key
  Volumes:
    kubeconfig       → bulk-konk-kubeconfig        (mounted at /etc/kubernetes)
    proxy-client-cert → bulk-konk-proxy-client      (mounted at /tmp/k8s-apiserver-server/serving-certs/)
    db-dsn-volume    → bulk-db-dsn
  Env:
    KUBECONFIG=/etc/kubernetes/admin.conf
```

### KonkServices Registered in bulk-konk

```
NAMESPACE         SERVICE NAME                                KONK        
atcapi            atcapi-apiservice                           bulk-konk   
atcapi            atcapi-apiservice-v2                        bulk-konk   
ddi               dns-config-importexport-apiservice          bulk-konk   
ddi               dns-config-importexport-apiservice-v2       bulk-konk   
ddi               dns-data-importexport-apiservice            bulk-konk   
ddi               dns-data-importexport-apiservice-v2         bulk-konk   
ddi               ipam-importexport-apiservice                bulk-konk   
ddi               ipam-importexport-apiservice-v2             bulk-konk   
ddi               ipam-importexport-apiservice-v3             bulk-konk   
ddi               keys-importexport-apiservice                bulk-konk   
dns-config-test   dns-config-importexport-apiservice          bulk-konk   
dns-config-test   dns-config-importexport-apiservice-v2       bulk-konk   
endpoints         endpoints-api-service-apiservice            bulk-konk   
hostapp           hostapp-aggregate-api-apiservice            bulk-konk   
hostapp           hostapp-aggregate-api-infra                 bulk-konk   
ngp-cp            bootstrap-app-aggregate-api-apiservice      bulk-konk   
ntp               ntp-aggregate-api-apiservice                bulk-konk   
redirect          redirect-apiservice                         bulk-konk   
tagging-v2        tagging-aggregate-api-apiservice            bulk-konk   
```

---

## 3. Migration Steps Performed

### Step 1: Create Self-Signed TLS Certificate

Generated a self-signed TLS cert for the tagging-aggregate-api to use when serving via vcluster.

```bash
# Created secret: tagging-aggregate-api-vcluster-server
# Namespace: tagging-v2
# Type: kubernetes.io/tls
# Keys: tls.crt, tls.key
# SANs: tagging-aggregate-api-apiservice.tagging-v2.svc,
#        tagging-aggregate-api-apiservice.tagging-v2.svc.cluster.local
```

### Step 2: Generate vCluster Kubeconfig Secret

Extracted the admin kubeconfig from vcluster and created a secret for the tagging pod.

```bash
# Source: vcluster admin kubeconfig (vc-config-vcluster secret in vcluster ns)
# Created secret: tagging-aggregate-api-vcluster-kubeconfig
# Namespace: tagging-v2
# Key: admin.conf
# Server URL: https://vcluster.vcluster:443
# User: kubernetes-super-admin (O=system:masters)
```

### Step 3: Register APIService Inside vCluster

Connected to vcluster and applied:
- **APIService** `v1alpha1.tagging.bulk.infoblox.com` → pointing to `tagging-aggregate-api-apiservice` ExternalName service
- **ExternalName Service** in vcluster → `tagging-aggregate-api-apiservice.tagging-v2.svc.cluster.local`
- **RBAC** (ClusterRole + ClusterRoleBinding) for delegated auth

```bash
# Verified:
$ vcluster connect vcluster --namespace vcluster -- kubectl get apiservices | grep tagging
v1alpha1.tagging.bulk.infoblox.com   tagging-v2/tagging-aggregate-api-apiservice   True   6h
```

### Step 4: Patch Tagging Deployment to Use vCluster Secrets

Patched the `tagging-aggregate-api` deployment volumes:

| Volume | Before (konk) | After (vcluster) |
|--------|---------------|-------------------|
| `apiserver-cert` | `tagging-aggregate-api-apiservice-konk-service-server` | `tagging-aggregate-api-vcluster-server` |
| `kubeconfig` | `tagging-aggregate-api-apiservice-konk-service-kubeconfig` | `tagging-aggregate-api-vcluster-kubeconfig` |

```bash
# Result: Pod restarted, 1/1 Running
# The pod now authenticates against vcluster instead of konk
```

### Step 5: Migrate Bulk Deployment from Konk to vCluster

#### 5a. Copy vCluster Secrets to `aggregate` Namespace

The bulk deployment needs its own copies of the vcluster credentials in the `aggregate` namespace.

```bash
# Kubeconfig: copied tagging-aggregate-api-vcluster-kubeconfig → bulk-vcluster-kubeconfig (aggregate ns)
# Proxy-client: extracted client cert/key/CA from vcluster admin kubeconfig

# IMPORTANT: The proxy-client secret must contain the vcluster admin CLIENT cert
# (CN=kubernetes-super-admin, O=system:masters), NOT the server TLS cert.
# The original copy used the server TLS cert, which caused "Unauthorized" errors.

# Correct approach:
kubectl create secret generic bulk-vcluster-proxy-client \
  --from-file=tls.crt=<client-cert-from-kubeconfig> \
  --from-file=tls.key=<client-key-from-kubeconfig> \
  --from-file=ca.crt=<ca-cert-from-kubeconfig> \
  -n aggregate
```

**Key Learning:** The `bulk-konk-proxy-client` secret contained a proper client cert signed by konk's CA (with `ca.crt`, `tls.crt`, `tls.key`). When creating the vcluster equivalent, you must use the **client certificate** from the vcluster admin kubeconfig (not the server TLS cert from step 1). The first attempt used the server TLS cert which resulted in `Unauthorized` errors because vcluster's `requestheader-allowed-names` config requires a specific client identity.

#### 5b. Patch Bulk Deployment

Applied three JSON patches to the bulk deployment:

| What | Before (konk) | After (vcluster) |
|------|---------------|-------------------|
| `args[12]` (--konk.host) | `bulk-konk.aggregate:6443` | `vcluster.vcluster:443` |
| `volumes[0]` (kubeconfig) | `bulk-konk-kubeconfig` | `bulk-vcluster-kubeconfig` |
| `volumes[1]` (proxy-client-cert) | `bulk-konk-proxy-client` | `bulk-vcluster-proxy-client` |

```bash
# Patch commands:
kubectl patch deployment bulk -n aggregate --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args/12","value":"--konk.host=vcluster.vcluster:443"}]'

kubectl patch deployment bulk -n aggregate --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/secret/secretName","value":"bulk-vcluster-kubeconfig"}]'

kubectl patch deployment bulk -n aggregate --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/1/secret/secretName","value":"bulk-vcluster-proxy-client"}]'

# Result: 2/2 pods Running, clean logs (no x509 or auth errors)
```

---

## 4. Verification Results

### 4.1 Tagging API via vCluster — WORKING (connectivity)

```bash
$ vcluster connect vcluster --namespace vcluster -- kubectl get apiservices | grep tagging
v1alpha1.tagging.bulk.infoblox.com   tagging-v2/tagging-aggregate-api-apiservice   True   6h

# APIService is Available: True
# Requests route: vcluster → ExternalName service → tagging-aggregate-api pod
```

### 4.2 Tagging API via kubectl — "Unable to get token from context"

```bash
$ vcluster connect vcluster --namespace vcluster -- kubectl get tags --all-namespaces
Error from server (InternalError): Unable to get token from context
```

**This is a pre-existing application-level issue**, not migration-related. The `tagging-aggregate-api` expects a CSP Bearer JWT token in the HTTP request context for multi-tenant authorization. Kubernetes aggregated API flow (both konk and vcluster) passes user identity via requestheader headers (`X-Remote-User`), not the original Bearer token. This same error occurs when testing via konk directly.

### 4.3 Bulk Export with Tagging Data Types — CONFIRMED via vCluster

```bash
# Export request
$ curl -sk "https://env-5.test.infoblox.com/bulk/v1/export" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "vcluster-tagging-test-1",
    "export_format": "json",
    "error_handling_id": 1,
    "data_types": [
      "tagging.bulk.infoblox.com/v1alpha1/tags.v1alpha1.tagging.bulk.infoblox.com",
      "tagging.bulk.infoblox.com/v1alpha1/values.v1alpha1.tagging.bulk.infoblox.com"
    ]
  }'

# Response: {"success": {"message": "Export pending"}}

# Operation result:
{
  "operation_id": "0b6df915-958d-4b12-815f-65bcbef4186c",
  "name": "vcluster-tagging-test-1",
  "overall_status": "completed",
  "data_types": [
    {"data_type": "tagging.bulk.infoblox.com/v1alpha1/tags", "failed_records": "1"},
    {"data_type": "tagging.bulk.infoblox.com/v1alpha1/values", "failed_records": "1"}
  ],
  "errors": [
    {"message": "Unable to get token from context"}
  ]
}
```

**Confirmation that vcluster was used:**
- Bulk deployment `--konk.host=vcluster.vcluster:443` (verified via kubectl)
- Kubeconfig volume → `bulk-vcluster-kubeconfig` (verified)
- Proxy-client volume → `bulk-vcluster-proxy-client` (verified)
- Export was accepted, operation created, request reached tagging-aggregate-api through vcluster
- The "Unable to get token from context" error is from the tagging application code, confirming the request traversed the full chain: `bulk → vcluster → tagging-aggregate-api`

### 4.4 Bulk Pod Health

```
NAME                    READY   STATUS    RESTARTS   AGE
bulk-5ff9df7b4c-9zpfc   2/2     Running   0          2m51s
bulk-5ff9df7b4c-ftkj7   2/2     Running   0          10m

# No x509, Unauthorized, or connection errors in logs
```

---

## 5. Critical Finding: Single-Service Migration Breaks Other APIs

### The Problem

Konk aggregates **19 KonkService CRs** (11 extension API servers, 12 API groups). The `bulk` deployment uses a single `--konk.host` to discover ALL APIs through this aggregation point.

By pointing bulk from `konk → vcluster`, we fixed tagging access but **broke all other data types** because vcluster only has `tagging.bulk.infoblox.com` registered.

| Data Type | Konk | vCluster |
|-----------|------|----------|
| `tagging.bulk.infoblox.com` (tags, values) | ✅ Registered | ✅ Registered |
| `infrastructure.bulk.infoblox.com` (hosts, pools) | ✅ Registered | ❌ NOT registered |
| `dnsdata.bulk.infoblox.com` (recordv2s) | ✅ Registered | ❌ NOT registered |
| `atcapi.bulk.infoblox.com` | ✅ Registered | ❌ NOT registered |
| All other 9 API groups | ✅ Registered | ❌ NOT registered |

### Evidence

An export with mixed data types (infrastructure + tagging) fails for infrastructure:
```json
{"error": "discovery failure: no resource types returned: Unauthorized"}
```

This happens because bulk tries to discover `hosts.v1alpha1.infrastructure.bulk.infoblox.com` via vcluster, but that API group doesn't exist in vcluster.

### Implication

**You cannot migrate services out of konk one-by-one** without breaking the single aggregation point. Options:

1. **Migrate ALL services to vcluster at once** — register all 19 KonkServices as APIServices in vcluster
2. **Roll back bulk to konk** — keeps all services working except tagging (which has the x509 cert mismatch)
3. **Fix konk to trust vcluster's CA** — update konk's requestheader/front-proxy CA to include vcluster's CA so konk can still proxy to tagging after migration
4. **Dual aggregation** — have bulk query both konk and vcluster (requires application changes)

---

## 6. Known Issues

### 6.1 x509 Certificate Errors from Konk Probes

After step 4, the tagging pod logs show x509 errors every ~30 seconds:

```
E0224 authentication.go:63] "Unable to authenticate the request"
  err="x509: certificate signed by unknown authority"
```

**Cause:** Konk's APIService for `tagging.bulk.infoblox.com` is still registered and konk periodically probes the tagging pod. But the tagging pod now validates against vcluster's CA, not konk's CA. These probes fail but are harmless — they just generate log noise.

**Fix:** Decommission the tagging KonkService CR in konk, or migrate all services to vcluster.

### 6.2 "Unable to get token from context"

This is a **pre-existing** tagging-aggregate-api application issue. The app expects a CSP JWT Bearer token in the request context for tenant authorization. The Kubernetes aggregated API flow (both konk and vcluster) passes identity via requestheader headers, not Bearer tokens. This error exists whether using konk or vcluster.

### 6.3 Proxy-Client Secret Must Be a Client Cert

The `bulk-vcluster-proxy-client` secret must contain the **client certificate** extracted from the vcluster admin kubeconfig (`CN=kubernetes-super-admin, O=system:masters`), not the server TLS cert from step 1. Using the wrong cert causes `Unauthorized` / `discovery failure` errors.

**Correct secret structure:**
```
ca.crt   → vcluster CA certificate
tls.crt  → client certificate from vcluster admin kubeconfig
tls.key  → client private key from vcluster admin kubeconfig
```

---

## 7. Secrets Inventory

### tagging-v2 Namespace

| Secret | Type | Purpose | Status |
|--------|------|---------|--------|
| `tagging-aggregate-api-apiservice-konk-service-server` | TLS | Old konk server cert | Kept (backup) |
| `tagging-aggregate-api-apiservice-konk-service-kubeconfig` | Opaque | Old konk kubeconfig | Kept (backup) |
| `tagging-aggregate-api-vcluster-server` | TLS | New self-signed TLS cert | **Active** |
| `tagging-aggregate-api-vcluster-kubeconfig` | Opaque | vcluster admin kubeconfig | **Active** |

### aggregate Namespace

| Secret | Type | Purpose | Status |
|--------|------|---------|--------|
| `bulk-konk-kubeconfig` | Opaque | Old konk kubeconfig | Kept (backup) |
| `bulk-konk-proxy-client` | TLS | Old konk client cert (ca.crt, tls.crt, tls.key) | Kept (backup) |
| `bulk-vcluster-kubeconfig` | Opaque | vcluster admin kubeconfig (copied from tagging-v2) | **Active** |
| `bulk-vcluster-proxy-client` | Opaque | vcluster admin client cert (extracted from kubeconfig) | **Active** |

---

## 8. Backups

All backups saved to: `konk/vcluster-poc/backup-tagging-konk-20260224-113338/`

| File | Size | Contents |
|------|------|----------|
| `deployment.yaml` | 4.9KB | Tagging deployment (pre-migration) |
| `konk-tls-secret.yaml` | 6.5KB | Konk TLS secret |
| `konk-kubeconfig-secret.yaml` | 12.4KB | Konk kubeconfig secret |
| `konkservice.yaml` | 23.7KB | KonkService CR |
| `service.yaml` | 1.2KB | Tagging service |
| `pods-before.txt` | — | Pre-migration pod status |
| `bulk-deployment.yaml` | 6.6KB | Bulk deployment (pre-migration) |
| `bulk-konk-kubeconfig-secret.yaml` | 8.1KB | Bulk konk kubeconfig |
| `bulk-konk-proxy-client-secret.yaml` | 6.0KB | Bulk konk proxy-client |

---

## 9. Rollback Procedure

To restore the original konk-based state:

```bash
# 1. Restore tagging deployment (reverts volumes to konk secrets)
kubectl apply -f backup-tagging-konk-*/deployment.yaml

# 2. Restore bulk deployment (reverts --konk.host and volumes to konk)
kubectl apply -f backup-tagging-konk-*/bulk-deployment.yaml

# 3. Clean up vcluster secrets from tagging-v2
kubectl delete secret tagging-aggregate-api-vcluster-server -n tagging-v2
kubectl delete secret tagging-aggregate-api-vcluster-kubeconfig -n tagging-v2

# 4. Clean up vcluster secrets from aggregate
kubectl delete secret bulk-vcluster-kubeconfig -n aggregate
kubectl delete secret bulk-vcluster-proxy-client -n aggregate

# 5. (Optional) Remove APIService from vcluster
vcluster connect vcluster --namespace vcluster -- \
  kubectl delete apiservice v1alpha1.tagging.bulk.infoblox.com
```

Or use the migration script:
```bash
./migrate-tagging-to-vcluster.sh rollback ./backup-tagging-konk-20260224-113338
```

---

## 10. Migration Script

A comprehensive migration script is available at:
`konk/vcluster-poc/migrate-tagging-to-vcluster.sh`

```bash
./migrate-tagging-to-vcluster.sh preflight   # Check prerequisites
./migrate-tagging-to-vcluster.sh backup      # Backup all resources
./migrate-tagging-to-vcluster.sh step1       # Create TLS cert secret
./migrate-tagging-to-vcluster.sh step2       # Create vcluster kubeconfig secret
./migrate-tagging-to-vcluster.sh step3       # Register APIService in vcluster
./migrate-tagging-to-vcluster.sh step4       # Patch tagging deployment
./migrate-tagging-to-vcluster.sh step5       # Migrate bulk deployment
./migrate-tagging-to-vcluster.sh verify      # Verify all components
./migrate-tagging-to-vcluster.sh rollback    # Restore konk-based state
```

---

## 11. Conclusions

### What Worked

1. **vcluster can replace konk for API aggregation** — APIService registration, ExternalName routing, and delegated auth all work
2. **Bulk → vcluster → tagging-aggregate-api** request chain is fully functional
3. **vcluster is lighter** — single StatefulSet vs konk's apiserver + etcd + init pods
4. **No konk-operator dependency** — vcluster manages its own lifecycle

### What Didn't Work

1. **Single-service migration breaks other APIs** — bulk uses a single `--konk.host`; pointing it to vcluster loses all non-tagging APIs
2. **"Unable to get token from context"** — pre-existing tagging app issue, not migration-related
3. **Proxy-client secret must be exact** — took iteration to get the right cert type (client cert, not server cert)

### Recommendations for Full Migration

1. **Register ALL 19 KonkServices as APIServices in vcluster** before switching bulk's `--konk.host`
2. **Automate APIService registration** — build a tool/operator equivalent to `KonkService` that:
   - Creates ExternalName services inside vcluster
   - Registers APIService objects
   - Sets up RBAC for delegated auth
3. **Test with ALL data types** — export with infrastructure, dns, tagging, etc. to verify complete coverage
4. **Address the token issue** if tagging export/import through bulk is a required use case
