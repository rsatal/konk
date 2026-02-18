# POC of konk replacement with vcluster

---

## 1. What is konk?

**konk** (Kubernetes ON Kubernetes) is a tool for deploying an independent Kubernetes API server within an existing Kubernetes cluster. It provides the Kubernetes API machinery (etcd + kube-apiserver) without the compute layer (no kubelet or nodes).

---

## 2. Why konk Exists - The Problem It Solves

In standard Kubernetes, when building an **Extension API Server** (an aggregated API), you register it with the main cluster's API server. This approach has several risks:

- A buggy extension API can crash or destabilize the parent cluster
- If your API doesn't fully comply with Kubernetes API conventions, it can break things
- Your custom resources compete for space in the main cluster's etcd

**konk provides an isolated Kubernetes API server where:**
- Extension APIs are registered in konk (not the parent cluster)
- If something goes wrong, only konk is affected, not the parent cluster
- Custom resources are stored in konk's own etcd

---

## 3. konk Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Parent Kubernetes Cluster                │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    konk-operator                     │   │
│  │  (watches for Konk and KonkService CRs)             │   │
│  └─────────────────────────────────────────────────────┘   │
│                            │                                │
│                            ▼                                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   Konk Instance                      │   │
│  │  ┌──────────────┐    ┌──────────────────────────┐   │   │
│  │  │     etcd     │◄───│   kube-apiserver         │   │   │
│  │  │  (3 replicas)│    │   (standalone, no nodes) │   │   │
│  │  └──────────────┘    └──────────────────────────┘   │   │
│  │                              ▲                       │   │
│  │                              │                       │   │
│  │         ┌────────────────────┼────────────────┐     │   │
│  │         │                    │                │     │   │
│  │  ┌──────┴───────┐    ┌───────┴──────┐  ┌──────┴───┐│   │
│  │  │ APIService 1 │    │ APIService 2 │  │   ...    ││   │
│  │  │ (your app)   │    │ (another app)│  │          ││   │
│  │  └──────────────┘    └──────────────┘  └──────────┘│   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Components

| Component | Description |
|-----------|-------------|
| **konk-operator** | Watches for Konk, KonkService, and Etcd Custom Resources and deploys the corresponding Helm charts |
| **etcd** | Distributed key-value store (typically 3 replicas) for storing konk's data |
| **kube-apiserver** | Standalone Kubernetes API server without nodes - handles API requests |
| **KonkService** | Registers extension API servers with an existing konk instance |

### Front-Proxy Ingress

**Front-proxy ingress** is a feature of `KonkService` that allows external clients to access your extension APIs through an Ingress, with automatic mTLS (mutual TLS) authentication.

#### How it works:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              External Traffic                                │
│                                                                              │
│     Client Request                                                           │
│     https://my-api.example.com/apis/atcapi.bulk.infoblox.com/v1alpha1/...   │
│           │                                                                  │
│           ▼                                                                  │
│     ┌───────────────┐                                                        │
│     │   Ingress     │  (NGINX with mTLS)                                     │
│     │   Controller  │                                                        │
│     └───────┬───────┘                                                        │
│             │  Uses client certificate from:                                 │
│             │  <konk-name>-ingress-client secret                             │
│             │                                                                │
│             ▼                                                                │
│     ┌───────────────┐                                                        │
│     │  bulk-konk    │  (konk's kube-apiserver)                               │
│     │  apiserver    │                                                        │
│     └───────┬───────┘                                                        │
│             │                                                                │
│             ▼                                                                │
│     ┌───────────────┐                                                        │
│     │  Extension    │  (your API server pod)                                 │
│     │  API Server   │                                                        │
│     └───────────────┘                                                        │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### Example KonkService with Ingress:

```yaml
kind: KonkService
metadata:
  name: atcapi-apiservice
spec:
  group:
    name: atcapi.bulk.infoblox.com
  konk:
    name: bulk-konk
  service:
    name: atcapi-apiservice
  ingress:
    enabled: true
    hosts:
    - host: my-api.example.com
    tls:
    - hosts:
      - my-api.example.com
      secretName: my-api.example.com-tls
```

#### What KonkService automatically provisions for ingress:

| Resource | Purpose |
|----------|--------|
| **Ingress** | Routes external traffic to konk's apiserver |
| **Client Certificate** | mTLS cert for Ingress → konk authentication |
| **NGINX annotations** | Configures backend-protocol as HTTPS, proxy-ssl settings |

---

## 4. konk Custom Resources (CRDs)

konk-operator manages three types of Custom Resources:

| CRD | Purpose |
|-----|---------|
| **Konk** | Creates a new konk instance (kube-apiserver + etcd) |
| **KonkService** | Registers an extension API server with an existing konk |
| **Etcd** | Manages etcd clusters for konk |

---

## 5. API Terminology: Extension API Server vs API Group

### What is an Extension API Server?

An **Extension API Server** is a **single running service/pod** that can handle **multiple APIs** (resources).

For example, the `atcapi-apiservice` pod might handle:
- `/apis/atcapi.bulk.infoblox.com/v1alpha1/threats`
- `/apis/atcapi.bulk.infoblox.com/v1alpha1/policies`
- `/apis/atcapi.bulk.infoblox.com/v1alpha1/blocklists`

**One Extension API Server = One pod/service that can serve many resource types**

### What is an API Group?

An **API Group** is a logical grouping of related APIs (resources) under a common URL prefix.

In Kubernetes, APIs are organized like:
```
/apis/<group>/<version>/<resource>
```

Examples:

| API Group | Example Full Path | What it serves |
|-----------|-------------------|----------------|
| `atcapi.bulk.infoblox.com` | `/apis/atcapi.bulk.infoblox.com/v1alpha1/threats` | Threat Defense resources |
| `dnsconfig.bulk.infoblox.com` | `/apis/dnsconfig.bulk.infoblox.com/v1/zones` | DNS configuration resources |
| `ipamdhcp.bulk.infoblox.com` | `/apis/ipamdhcp.bulk.infoblox.com/v1/subnets` | IPAM/DHCP resources |

### Relationship Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│           Extension API Server (1 pod/service)                  │
│           e.g., ipam-importexport-apiservice                    │
│                                                                 │
│   ┌──────────────────────────────────────────────────────────┐ │
│   │              API Group: ipamdhcp.bulk.infoblox.com        │ │
│   │                                                          │ │
│   │   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐ │ │
│   │   │ subnets  │  │ networks │  │ ranges   │  │  leases │ │ │
│   │   │ (API)    │  │ (API)    │  │ (API)    │  │  (API)  │ │ │
│   │   └──────────┘  └──────────┘  └──────────┘  └─────────┘ │ │
│   └──────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### Why 11 Services but 12 API Groups?

One Extension API Server can serve **multiple API Groups**. For example:
```
hostapp-aggregate-api-apiservice → serves TWO API groups:
  - onprem.bulk.infoblox.com
  - infrastructure.bulk.infoblox.com
```

### Summary Table

| Term | What it is | Count in cluster |
|------|-----------|------------------|
| **Extension API Server** | A running pod/service that handles API requests | 11 services |
| **API Group** | A namespace/prefix for organizing related APIs | 12 groups |
| **API (Resource)** | Individual resource types (like `subnets`, `zones`) | Many per group |
| **KonkService CR** | Kubernetes object that registers an API group with konk | 16 CRs |

Why 16 KonkService CRs for 11 services?
- Some services have multiple KonkService CRs (e.g., `v1` and `v2` versions)
- Some services register multiple API groups

---

## 6. Example Usage

### Creating a Konk instance:

```yaml
apiVersion: konk.infoblox.com/v1alpha1
kind: Konk
metadata:
  name: my-konk
spec:
  scope: cluster
```

### Creating a KonkService to register an API:

```yaml
apiVersion: konk.infoblox.com/v1alpha1
kind: KonkService
metadata:
  name: my-service
spec:
  group:
    name: example.infoblox.com
    kinds:
    - MyResource
  konk:
    name: my-konk
  service:
    name: my-api-service
  version: v1alpha1
```

---

## 7. Key Characteristics of konk

| Aspect | Detail |
|--------|--------|
| **What it IS** | An isolated kube-apiserver + etcd running as pods |
| **What it ISN'T** | A full Kubernetes cluster (no nodes, no workloads) |
| **Disabled APIs** | apps, autoscaling, batch, networking, storage (because no nodes) |
| **Primary Use Case** | Safely run extension/aggregated API servers in isolation |
| **Storage Backend** | Dedicated etcd (3 replicas by default) |
| **Certificate Management** | Integrates with cert-manager |

---

## 8. What is vcluster?

**vcluster** (virtual cluster) is an open-source tool by Loft Labs that creates fully functional virtual Kubernetes clusters running inside a host cluster's namespace. Unlike konk, vcluster creates a **full Kubernetes experience** including virtual nodes.

---

## 9. Feature Comparison: konk vs vcluster

| Feature | konk | vcluster |
|---------|------|----------|
| **What it provides** | kube-apiserver + etcd only | Full virtual K8s cluster (apiserver + controller-manager + scheduler + etcd + virtual nodes) |
| **Node support** | ❌ No (no kubelet) | ✅ Yes (syncs to host nodes or creates virtual nodes) |
| **Workload support** | ❌ Cannot run Pods, Deployments, etc. | ✅ Full workload support |
| **Primary use case** | Extension API servers / API aggregation | Multi-tenancy, dev environments, CI/CD isolation |
| **Resource isolation** | API-level only | Full namespace isolation with optional resource syncing |
| **Maintenance** | In-house/Infoblox maintained | Open-source with commercial support (Loft Labs) |
| **Community/Updates** | Limited (internal) | Active community, frequent releases |

---

## 10. Current konk Setup (bulk-konk)

### kube-apiserver Instances

| Component | Count | Pod Name | Namespace |
|-----------|-------|----------|-----------|
| **konk kube-apiserver** | **1** | `bulk-konk-6b799fbb8c-j9jcm` | aggregate |
| konk init (helper) | 1 | `bulk-konk-init-b5dbf4896-hkpms` | aggregate |
| konk etcd | 1 | `bulk-konk-etcd-0` | aggregate |

### Extension API Servers Summary

| Count | Description |
|-------|-------------|
| **16** | Total KonkService CRs |
| **11** | Unique Extension API Server services |
| **12** | Unique API Groups |

### Extension API Server Mappings

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

### Architecture Diagram

```
                    ┌─────────────────────────────────────────┐
                    │         bulk-konk (1 apiserver)         │
                    │         aggregate namespace             │
                    └─────────────────┬───────────────────────┘
                                      │
         ┌────────────────────────────┼────────────────────────────┐
         │                            │                            │
         ▼                            ▼                            ▼
   ┌───────────┐              ┌───────────────┐            ┌──────────────┐
   │  atcapi   │              │     ddi       │            │   hostapp    │
   │  (1 svc)  │              │   (4 svcs)    │            │   (1 svc)    │
   └───────────┘              └───────────────┘            └──────────────┘
         │                            │                            │
         ▼                            ▼                            ▼
  ┌─────────────┐           ┌─────────────────┐          ┌───────────────┐
  │endpoints(1)│           │ ntp, ngp-cp,    │          │ redirect,     │
  │             │           │ tagging (3 svcs)│          │ tagging (2)   │
  └─────────────┘           └─────────────────┘          └───────────────┘
```

**Summary: 1 konk apiserver → 11 Extension API Servers → 12 API Groups**

### Configuration Details

- **Scope**: cluster
- **etcd**: 1 replica with 4Gi memory limit

### Detailed Architecture: Where Components Run

**Important: Extension API Servers are NOT "inside" konk.** They are:
- Regular pods running in the **host cluster** (various namespaces)
- They **REGISTER** their APIs with konk's apiserver via `APIService` objects

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          HOST KUBERNETES CLUSTER                            │
│                     (has its own kube-apiserver)                            │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ konk namespace                                                         │ │
│  │   └── konk-operator (watches for Konk/KonkService CRs)                │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ aggregate namespace                                                    │ │
│  │   ├── bulk-konk (kube-apiserver) ◄── THIS IS KONK's API SERVER        │ │
│  │   ├── bulk-konk-etcd-0                                                 │ │
│  │   └── bulk-konk-init                                                   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │ Extension API Servers (11 separate services in various namespaces)    │ │
│  │                                                                        │ │
│  │   atcapi namespace:     atcapi-apiservice (pod)                       │ │
│  │   ddi namespace:        dns-config-importexport (pod)                 │ │
│  │                         dns-data-importexport (pod)                   │ │
│  │                         ipam-importexport (pod)                       │ │
│  │                         keys-importexport (pod)                       │ │
│  │   endpoints namespace:  endpoints-api-service (pod)                   │ │
│  │   hostapp namespace:    hostapp-aggregate-api (pod)                   │ │
│  │   ngp-cp namespace:     bootstrap-app-aggregate-api (pod)             │ │
│  │   ntp namespace:        ntp-aggregate-api (pod)                       │ │
│  │   redirect namespace:   redirect-apiservice (pod)                     │ │
│  │   tagging-v2 namespace: tagging-aggregate-api (pod)                   │ │
│  │                                                                        │ │
│  │   These are PODS running in the HOST cluster, NOT inside konk!        │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Request Flow: How API Aggregation Works

```
Client Request (e.g., GET /apis/atcapi.bulk.infoblox.com/v1alpha1/...)
     │
     ▼
┌─────────────────┐
│ bulk-konk       │  (konk's kube-apiserver)
│ apiserver       │
└────────┬────────┘
         │
         │  "I don't handle atcapi.bulk.infoblox.com myself,
         │   but I know atcapi-apiservice pod can handle it"
         │   (via registered APIService object)
         │
         ▼
┌─────────────────┐
│ atcapi-apiservice│  (Extension API Server - a regular pod in host cluster)
│ (atcapi ns)      │
└────────┬────────┘
         │
         ▼
    Response returned to client
```

### Layer Summary

| Layer | What | Count | Notes |
|-------|------|-------|-------|
| **Host cluster API server** | Main K8s cluster apiserver | 1 | Managed by cloud provider (EKS) |
| **konk API server** | Isolated kube-apiserver for API aggregation | 1 | `bulk-konk` in aggregate namespace |
| **Extension API Servers** | Services that handle custom APIs | 11 | Regular pods, APIs registered WITH konk |

The extension API servers run as **regular pods in the host cluster** but their APIs are **registered in konk's apiserver** (not the host cluster's apiserver). This is the isolation benefit - if an extension API misbehaves, it doesn't affect the host cluster's API server.

---

## 11. Can vcluster Replace konk?

### Key Considerations:

#### API Aggregation Use Case

**konk approach**: Register `APIService` objects that point to your extension API servers (e.g., `atcapi.bulk.infoblox.com`)

**vcluster approach**: Would need to:
- Run the vcluster's apiserver
- Register your APIServices inside vcluster
- Route requests from parent cluster → vcluster → your extension API

**Verdict**: vcluster **can** do this, but it's **overkill** if you only need API aggregation.

#### Workload Requirements

- If your extension APIs only define custom resources and don't need to schedule pods → **konk is sufficient**
- If you need to run controllers/pods **inside** the virtual cluster → **vcluster is needed**

---

## 12. Advantages of vcluster over konk

| Advantage | Details |
|-----------|---------|
| **Active maintenance** | vcluster is actively developed; konk appears to be internal tooling with limited updates |
| **Full K8s compatibility** | Can run any K8s workload, not just APIs |
| **Better isolation** | Stronger multi-tenancy boundaries |
| **Ecosystem integration** | Works with standard K8s tooling out of the box |
| **Documentation** | Extensive public documentation |
| **Flexibility** | Multiple backends (k3s, k0s, eks, vanilla k8s) |
| **Resource syncing** | Can sync specific resources between vcluster and host |

---

## 13. Limitations / Concerns with Replacing konk

| Concern | Details |
|---------|---------|
| **Overhead** | vcluster runs more components (controller-manager, scheduler) - higher resource usage |
| **Migration complexity** | All 14+ KonkServices need to be migrated; kubeconfig references change |
| **Different architecture** | konk uses cert-manager integration for certificates; vcluster has its own PKI |
| **APIService registration** | In konk, `KonkService` CR handles this automatically; in vcluster, you'd need custom tooling or manual registration |
| **No direct equivalent to KonkService** | vcluster doesn't have a built-in mechanism to auto-register APIServices - you'd need to build this |
| **Ingress routing** | konk-service handles front-proxy ingress setup (see Section 3); vcluster would require different configuration |
| **Helm operator pattern** | konk-operator is a Helm operator; vcluster uses its own CLI/operator |

---

## 14. Critical Issue: KonkService Equivalent

Current KonkService workflow:
```yaml
kind: KonkService
spec:
  group:
    name: atcapi.bulk.infoblox.com
  konk:
    name: bulk-konk
  service:
    name: atcapi-apiservice
```

This automatically:
1. Generates server certificates (via cert-manager)
2. Creates a kubeconfig for the service to talk to konk
3. Registers an `APIService` inside konk pointing to your service
4. Sets up RBAC

**vcluster does NOT have this built-in.** You would need to:
- Build custom tooling/operator to replicate `KonkService` functionality
- OR manually configure each extension API server

---

## 15. Resource Comparison (Estimated)

| Component | konk | vcluster |
|-----------|------|----------|
| API Server | 1 pod (~160Mi-4Gi) | 1 pod (similar) |
| etcd | 1-3 pods (~64Mi-4Gi each) | 1-3 pods (similar) OR SQLite |
| Controller Manager | ❌ Not needed | 1 pod (~50Mi) |
| Scheduler | ❌ Not needed | 1 pod (~20Mi) or disabled |
| Init/Setup | 1 pod | Built into vcluster |
| **Total** | ~2-4 pods | ~3-5 pods |

---

## 16. Recommendations

### ✅ Keep konk IF:
- You only need API aggregation (no workloads)
- KonkService automation is critical to your workflow
- Migration effort is a concern
- Resource efficiency is important

### ✅ Switch to vcluster IF:
- You need to run actual workloads in the virtual cluster
- konk maintenance is becoming a burden
- You want better upstream support and documentation
- You're willing to build tooling to replace KonkService functionality

### 🔶 Hybrid Approach:
- Use vcluster for new use cases
- Keep konk for existing API aggregation
- Gradually migrate as you build migration tooling

---

## 17. POC Next Steps

*[To be added after hands-on testing]*

---

## 18. Conclusion

*[To be added]*
