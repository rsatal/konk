# vcluster POC: Full Technical Deep-Dive — Replacing konk for tagging-v2

## Table of Contents

1. [Kubernetes Aggregation Layer — How It Works](#1-kubernetes-aggregation-layer--how-it-works)
2. [Three API Servers — Host vs konk vs Extension](#2-three-api-servers--host-vs-konk-vs-extension)
3. [What konk Actually Does](#3-what-konk-actually-does)
4. [How tagging-v2 Uses konk Today](#4-how-tagging-v2-uses-konk-today)
5. [Why Not Register Directly on EKS?](#5-why-not-register-directly-on-eks)
6. [What is vcluster?](#6-what-is-vcluster)
7. [POC: Replacing konk with vcluster (mock API)](#7-poc-replacing-konk-with-vcluster-mock-api)
8. [Production Migration: Changes Required](#8-production-migration-changes-required)
9. [Three Approaches Compared](#9-three-approaches-compared)

---

## 1. Kubernetes Aggregation Layer — How It Works

The aggregation layer is **built-in code inside every kube-apiserver binary**. It is not a separate component — it runs in-process with the apiserver.

### How it works

1. By default, the aggregation layer is **dormant** — it does nothing
2. When you create an `APIService` object, it **wakes up** and claims a URL path
3. Any request to that path is **proxied** (reverse-proxied) to the service you specified

```
Register this:
┌──────────────────────────────────────────────────────────────┐
│ APIService: v1alpha1.tagging.bulk.infoblox.com               │
│   group: tagging.bulk.infoblox.com                           │
│   version: v1alpha1                                          │
│   service: tagging-aggregate-api-apiservice (tagging-v2 ns)  │
└──────────────────────────────────────────────────────────────┘

Then this happens automatically:
GET /apis/tagging.bulk.infoblox.com/v1alpha1/namespaces/default/tags
        │
        ▼
  kube-apiserver receives the request
        │
        ▼
  Aggregation layer: "I have a claim for tagging.bulk.infoblox.com/v1alpha1"
        │              "Proxying to the registered service..."
        │
        ▼
  HTTP request → tagging-aggregate-api-apiservice.tagging-v2.svc:443
        │
        ▼
  Extension API server handles it, returns JSON
        │
        ▼
  kube-apiserver returns response to client
```

**Key point:** The aggregation layer is the reason konk works. konk is just a kube-apiserver, and every kube-apiserver has this built-in proxy. konk adds nothing special — it uses a standard Kubernetes feature in an isolated apiserver.

### What's inside a kube-apiserver

```
┌──────────────────────────────────┐
│  kube-apiserver process          │
│                                  │
│  ┌────────────────────────────┐  │
│  │ Core APIs                  │  │  ← /api/v1/pods, /api/v1/services, etc.
│  │ (built-in)                 │  │
│  └────────────────────────────┘  │
│                                  │
│  ┌────────────────────────────┐  │
│  │ Aggregation Layer          │  │  ← dormant until you register an APIService
│  │ (built-in reverse proxy)   │  │     then proxies to your extension API server
│  └────────────────────────────┘  │
└──────────────────────────────────┘
```

---

## 2. Three API Servers — Host vs konk vs Extension

A common source of confusion: there are three different "API servers" in play, and they are fundamentally different things.

### Overview

| | Host API Server | konk API Server | Extension API Server |
|---|---|---|---|
| **What** | EKS cluster's kube-apiserver (managed by AWS) | `bulk-konk` pod — a standalone kube-apiserver running as a regular pod (namespace: `aggregate`) | Your app pod (e.g. `tagging-aggregate-api` in namespace: `tagging-v2`) |
| **Provides** | Standard K8s APIs (pods, deployments, services, etc.) | An **isolated** Kubernetes API surface — only API aggregation, no nodes/workloads | Custom business APIs like `/apis/tagging.bulk.infoblox.com/v1alpha1/tags` |
| **etcd** | EKS-managed etcd | Its own dedicated etcd (`bulk-konk-etcd-0`) | **No etcd** — it's just an HTTP server |
| **Who manages it** | AWS/cloud provider | konk-operator deploys it via the `bulk` app | Your team's helm chart |
| **Count** | 1 per cluster | 1 (`bulk-konk`) serving all 11 extension APIs | 11 separate services across various namespaces |

### What is an Extension API Server, really?

An Extension API Server is **NOT a kube-apiserver**. It is just a **regular HTTPS server** that:
- Speaks HTTPS
- Follows the Kubernetes API response format (returns `APIResourceList`, `TagsList`, etc.)
- Serves paths like `/apis/tagging.bulk.infoblox.com/v1alpha1/...`

It can be written in **any language** — Go, Python, Java, anything. The `tagging-aggregate-api` is a Go binary. The POC mock was Python. It builds JSON responses that *look like* Kubernetes resources.

### Common misconception: "k8s inside k8s inside k8s"

```
WRONG mental model:
┌─────────────────────────┐
│ EKS (real cluster)      │
│  ┌────────────────────┐ │
│  │ konk (virtual k8s) │ │
│  │  ┌───────────────┐ │ │
│  │  │ extension APIs │ │ │  ← running INSIDE konk? NO!
│  │  └───────────────┘ │ │
│  └────────────────────┘ │
└─────────────────────────┘

CORRECT mental model:
┌──────────────────────────────────────────────────────────┐
│ EKS (real cluster) — runs ALL pods on real EC2 nodes     │
│                                                          │
│  [bulk-konk pod]  ← just a process, an apiserver with    │
│       │              an etcd. IT RUNS NO PODS.            │
│       │              IT HAS NO NODES.                     │
│       │                                                   │
│       │  "I know tagging.bulk.infoblox.com                │
│       │   should be handled by the service                │
│       │   at tagging-v2/tagging-aggregate-api-apiservice" │
│       │                                                   │
│       ▼  (HTTP proxy to host cluster service)             │
│  [tagging-aggregate-api pod] ← regular pod on EKS,       │
│       scheduled by EKS, runs on EC2 nodes                 │
└──────────────────────────────────────────────────────────┘
```

**Everything runs as normal pods on the host cluster.** konk doesn't schedule anything. All 11 extension API servers are regular Deployments in the host EKS cluster with real CPU, real memory, on real EC2 nodes.

---

## 3. What konk Actually Does

konk is **only a routing table + auth layer**. Think of it as an **HTTPS reverse proxy with a database (etcd)**.

### What konk stores in its etcd

| Object | Purpose |
|---|---|
| `APIService` objects | "route `tagging.bulk.infoblox.com` → service X" |
| `ClusterRole` / RBAC objects | "who is allowed to call these APIs" |
| `Namespace` + `ExternalName Service` | "how to reach service X on the host cluster" |

That's it. No pods. No nodes. No compute. Just **routing metadata and auth rules**.

### konk components in the host cluster

```
HOST CLUSTER (EKS) — has real nodes, runs real pods
│
├── namespace: konk          → konk-operator pod (regular pod on host)
├── namespace: aggregate     → bulk-konk pod (apiserver process, regular pod)
│                            → bulk-konk-etcd-0 (etcd process, regular pod)
├── namespace: tagging-v2    → tagging-aggregate-api pod (regular pod)
├── namespace: ddi           → dns-config-importexport pod (regular pod)
├── namespace: atcapi        → atcapi-apiservice pod (regular pod)
└── ... 8 more extension API pods, all regular pods on host
```

### konk architecture

| Component | Description |
|-----------|-------------|
| **konk-operator** | Watches for `Konk`, `KonkService`, and `Etcd` CRs and deploys corresponding Helm charts |
| **etcd** | Distributed key-value store (1-3 replicas) for storing konk's routing data |
| **kube-apiserver** (`bulk-konk`) | Standalone Kubernetes API server without nodes — handles API requests via aggregation layer |
| **KonkService** CR | Registers extension API servers with an existing konk instance |

### What KonkService automates

When you create a `KonkService` CR, the konk-operator:

1. **Creates a Namespace** inside konk for the service reference
2. **Creates an ExternalName Service** inside konk pointing to the Extension API Server in the host cluster
3. **Creates an APIService** registration inside konk's apiserver
4. **Generates TLS server certificates** (via cert-manager) — stored as secret `<name>-konk-service-server`
5. **Generates a kubeconfig** for the Extension API Server to talk to konk for delegated auth — stored as secret `<name>-konk-service-kubeconfig`
6. **Sets up ClusterRole/RBAC** inside konk

---

## 4. How tagging-v2 Uses konk Today

### KonkService configuration (actual from us-dev-5)

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

### What this produces

| Resource | Where | Purpose |
|---|---|---|
| `tagging-aggregate-api-apiservice-konk-service-server` secret | `tagging-v2` namespace (host) | TLS cert for the Extension API Server |
| `tagging-aggregate-api-apiservice-konk-service-kubeconfig` secret | `tagging-v2` namespace (host) | Kubeconfig for delegated auth to konk |
| `v1alpha1.tagging.bulk.infoblox.com` APIService | Inside konk | Routes tagging API calls to the extension |
| ExternalName Service | Inside konk | Points to `tagging-aggregate-api-apiservice.tagging-v2.svc.cluster.local` |
| Namespace `tagging-v2` | Inside konk | Required for the ExternalName service reference |
| ClusterRole | Inside konk | RBAC rules |

### tagging-aggregate-api deployment

The tagging-aggregate-api pod mounts both konk-generated secrets:

```yaml
containers:
- args:
  - --tls-cert-file=/tmp/k8s-apiserver-server/serving-certs/tls.crt
  - --tls-private-key-file=/tmp/k8s-apiserver-server/serving-certs/tls.key
  - --authentication-kubeconfig=/kubeconfig/admin.conf    # ← points to konk
  - --authorization-kubeconfig=/kubeconfig/admin.conf      # ← points to konk
  - --delegated-auth=true
  volumeMounts:
  - mountPath: /tmp/k8s-apiserver-server/serving-certs
    name: apiserver-cert          # ← konk-generated TLS cert
  - mountPath: /kubeconfig
    name: kubeconfig              # ← konk-generated kubeconfig

volumes:
- name: apiserver-cert
  secret:
    secretName: tagging-aggregate-api-apiservice-konk-service-server
- name: kubeconfig
  secret:
    secretName: tagging-aggregate-api-apiservice-konk-service-kubeconfig
```

### Request flow

```
Client request:
  GET /apis/tagging.bulk.infoblox.com/v1alpha1/namespaces/default/tags
         │
         ▼
┌─────────────────┐
│  bulk-konk      │  konk's kube-apiserver (aggregate namespace)
│  apiserver      │  "I have an APIService for tagging.bulk.infoblox.com"
└────────┬────────┘
         │  Proxies via ExternalName Service
         ▼
┌────────────────────────────┐
│ tagging-aggregate-api      │  Extension API Server (tagging-v2 namespace)
│ (regular pod on EKS)       │  Queries PostgreSQL, returns tags
└────────────────────────────┘
```

### The actual "compute" for tagging

```
Client → bulk-konk (checks auth, looks up APIService, proxies)
                    │
                    ▼
         tagging-aggregate-api pod (on EKS, real EC2 node)
                    │
                    ├── talks to PostgreSQL (RDS)
                    ├── talks to Kafka
                    └── returns JSON response
```

The tagging-aggregate-api pod does all the real work — DB queries, business logic, etc. — running on a regular EKS node. konk just sits in front as a **proxy** that says "yes, this caller is authorized, forward the request."

---

## 5. Why Not Register Directly on EKS?

You **can** register APIService objects directly with the host EKS apiserver. That is standard Kubernetes:

```yaml
# This would work — no konk, no vcluster needed
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
  groupPriorityMinimum: 1000
  versionPriority: 100
  caBundle: <CA_CERT>
```

Request flow would be: `Client → EKS apiserver → tagging-aggregate-api pod`

### Why we DON'T do this — the risk

When you register an APIService with the host EKS apiserver:

| Scenario | What happens |
|---|---|
| Extension API server is down | **EKS apiserver becomes slow** — it waits/retries on every API discovery call. `kubectl` commands hang for ALL users |
| Extension API server returns bad responses | Can confuse the EKS API aggregation layer, potentially affecting other API calls |
| Extension API server is slow | EKS apiserver threads get tied up proxying, degrading performance for **everything** |
| 12 extension APIs all registered on EKS | 12x the chance of one bad actor degrading the whole cluster |

### Real-world impact

```
# If tagging-aggregate-api is unhealthy and registered on EKS directly:
$ kubectl get pods        ← THIS becomes slow (5-10 second delays)
$ kubectl get nodes       ← THIS becomes slow too
$ kubectl apply -f ...    ← EVERYTHING is slow
# Because EKS apiserver does API discovery on EVERY call,
# and tries to reach ALL registered APIServices including the broken one

# With konk/vcluster as a middle layer:
$ kubectl get pods        ← Works fine (EKS doesn't know about tagging API)
$ kubectl get nodes       ← Works fine
# Only calls going through konk/vcluster are affected
```

This is purely **blast radius protection**.

---

## 6. What is vcluster?

**vcluster** (virtual cluster) is an open-source tool by Loft Labs that creates fully functional virtual Kubernetes clusters inside a host cluster's namespace.

### konk vs vcluster

| Feature | konk | vcluster |
|---------|------|----------|
| **What it provides** | kube-apiserver + etcd only | Full virtual K8s cluster (apiserver + controller-manager + scheduler + etcd + virtual nodes) |
| **Node support** | No (no kubelet) | Yes (syncs to host nodes or creates virtual nodes) |
| **Workload support** | Cannot run Pods, Deployments, etc. | Full workload support |
| **Primary use case** | Extension API servers / API aggregation | Multi-tenancy, dev environments, CI/CD isolation |
| **Maintenance** | In-house/Infoblox maintained | Open source with commercial support (Loft Labs) |
| **Community** | Limited (internal) | Active community, frequent releases |
| **Aggregation layer** | Yes (built into kube-apiserver) | Yes (built into k3s apiserver) |

### Why vcluster works as a konk replacement

vcluster's k3s apiserver has the **same aggregation layer** as konk's kube-apiserver. You can:
1. Register APIService objects inside vcluster
2. vcluster will proxy requests to Extension API Servers in the host cluster
3. Same isolation benefit as konk

vcluster is **overkill** for just API aggregation (it includes controller-manager, scheduler, virtual nodes). But it's actively maintained and provides the same core capability.

---

## 7. POC: Replacing konk with vcluster (mock API)

### POC architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                          HOST CLUSTER (us-dev-5)                           │
│                                                                            │
│   ┌────────────────────────────────────────────────────────────────────┐   │
│   │  vcluster-poc namespace                                            │   │
│   │                                                                    │   │
│   │   ┌────────────────────────────────────────────────────────────┐   │   │
│   │   │  poc-vcluster-0 (vcluster)                                 │   │   │
│   │   │  - k3s apiserver + etcd in single pod                      │   │   │
│   │   │  - Has APIService: v1alpha1.tagging.poc.infoblox.com       │   │   │
│   │   │  - REPLACEMENT FOR bulk-konk                               │   │   │
│   │   └───────────────────────────┬────────────────────────────────┘   │   │
│   │                               │                                    │   │
│   │                               │ APIService proxies to              │   │
│   │                               ▼                                    │   │
│   │   ┌────────────────────────────────────────────────────────────┐   │   │
│   │   │  mock-tagging-apiserver (Service + Deployment)             │   │   │
│   │   │  - Python HTTPS server (mock Extension API Server)         │   │   │
│   │   │  - Serves: tagging.poc.infoblox.com/v1alpha1               │   │   │
│   │   │  - SIMULATES tagging-aggregate-api                         │   │   │
│   │   └────────────────────────────────────────────────────────────┘   │   │
│   └────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────┘
```

### What was registered inside vcluster

```yaml
# Namespace inside vcluster
apiVersion: v1
kind: Namespace
metadata:
  name: extension-apis
---
# ExternalName service inside vcluster → points to host cluster service
apiVersion: v1
kind: Service
metadata:
  name: mock-tagging-apiserver
  namespace: extension-apis
spec:
  type: ExternalName
  externalName: mock-tagging-apiserver.vcluster-poc.svc.cluster.local
  ports:
  - port: 443
---
# APIService registration inside vcluster
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: v1alpha1.tagging.poc.infoblox.com
spec:
  insecureSkipTLSVerify: true  # POC only
  group: tagging.poc.infoblox.com
  groupPriorityMinimum: 1000
  service:
    name: mock-tagging-apiserver
    namespace: extension-apis
    port: 443
  version: v1alpha1
  versionPriority: 100
```

### POC results

| Test | Result |
|------|--------|
| vcluster creation | PASS — `poc-vcluster-0` running in `vcluster-poc` namespace |
| Mock API Server deployment | PASS — HTTPS server with self-signed cert |
| APIService registration | PASS — `v1alpha1.tagging.poc.infoblox.com` shows `Available: True` |
| API discovery | PASS — `/apis/tagging.poc.infoblox.com/v1alpha1` returns APIResourceList |
| Resource listing | PASS — `/apis/.../namespaces/default/tags` returns Tag objects |

### Verified request flow

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
```

**POC Verdict: SUCCESS** — vcluster can provide the same API aggregation isolation as konk.

---

## 8. Production Migration: Changes Required

### Current state

- **konk** is deployed via `konk-operator` (namespace: `konk`) and `bulk` app (namespace: `aggregate`)
- **vcluster** is now deployed in `vcluster` namespace via the company workflow (defined in `apps.yaml`)
- **tagging-aggregate-api** helm chart creates a `KonkService` CR that auto-provisions everything

### What needs to change — layer by layer

### 8.1 Inside vcluster: APIService + ExternalName Service registration

Create the equivalent of what KonkService auto-created inside konk, but now inside vcluster:

```yaml
# Namespace inside vcluster
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

**How to apply:** Options include a Kubernetes Job, init container, `vcluster connect` + kubectl, or a custom operator.

### 8.2 tagging-aggregate-api Helm Chart Changes

The pod currently mounts two konk-provided secrets:

| Current Secret | Purpose | What Changes |
|---|---|---|
| `tagging-aggregate-api-apiservice-konk-service-server` | TLS cert for serving the Extension API | Must be provisioned differently — cert-manager directly, or vcluster PKI, or self-signed |
| `tagging-aggregate-api-apiservice-konk-service-kubeconfig` | Kubeconfig for delegated auth to konk | Must point to **vcluster's apiserver** instead of konk |

Changes to the helm chart:

1. **Remove the `KonkService` CR** from the helm chart templates
2. **Replace kubeconfig secret**: Create a new secret with a kubeconfig pointing to vcluster's API server (using vcluster's CA and client cert)
3. **Replace server cert secret**: Generate a new serving cert (via cert-manager or vcluster's PKI)
4. **Update `--authentication-kubeconfig` and `--authorization-kubeconfig`** args if secret names change

### 8.3 deployment-configurations Changes

**`apps.yaml`:**

```yaml
# Current tagging-aggregate-api config:
tagging-aggregate-api:
  inherit-shared-values:
    - legacy
    - ingress
  job: Infoblox-CTO/job/atlas.tagging.aggregateapi/job/master
  master: jenkins-ci-production
  namespace: tagging-v2
  owner: '@Infoblox-CTO/atlas-app-infra'
  productOwner: platform-infrastructure-team
  properties: build.properties

# Changes needed:
# - Add vcluster as a dependency (replacing the implicit konk dependency)
# - Or make it depend on a new app that sets up APIService inside vcluster
```

**`build/*/tagging-aggregate-api.yaml` values files:**

```yaml
# Current (in every env):
konk:
  enabled: true
  name: bulk-konk
  namespace: aggregate
  scope: cluster

# Replace with vcluster-equivalent:
vcluster:
  enabled: true
  name: vcluster
  namespace: vcluster
```

### 8.4 Kubeconfig Generation (most critical piece)

This is the **KonkService replacement** — the hardest part.

KonkService auto-generated a kubeconfig secret. With vcluster you need to:

1. Extract the vcluster admin kubeconfig (stored in secret `vc-vcluster` in the `vcluster` namespace, or via `vcluster connect --print`)
2. Create a Kubernetes secret in the `tagging-v2` namespace with a kubeconfig that uses vcluster's **internal cluster DNS** address: `https://vcluster.vcluster.svc.cluster.local:443`
3. The tagging-aggregate-api pod uses this kubeconfig for `--authentication-kubeconfig` and `--authorization-kubeconfig`

### 8.5 TLS Certificate Provisioning

Options:

| Option | Dev | Prod |
|--------|-----|------|
| `insecureSkipTLSVerify: true` in APIService | OK | Not recommended |
| cert-manager with Issuer using vcluster's CA | OK | Recommended |
| Self-signed cert + caBundle in APIService | OK | Acceptable |

### 8.6 k8s.manifests

The generated manifests will change automatically once the helm chart is updated. The `KonkService` CR will be gone, replaced by new secret references.

---

## 9. Three Approaches Compared

```
Option 1: Direct on EKS (simplest, riskiest)
  EKS apiserver → tagging-aggregate-api
    Pros: Zero overhead, simplest setup
    Cons: Bad extension API can break the whole cluster for all users

Option 2: konk (current)
  EKS apiserver (unaware) ... konk apiserver → tagging-aggregate-api
    Pros: Isolation — EKS is protected
    Cons: Internal tool, maintenance burden, KonkService complexity

Option 3: vcluster (proposed replacement)
  EKS apiserver (unaware) ... vcluster apiserver → tagging-aggregate-api
    Pros: Isolation (same as konk), open source, actively maintained
    Cons: Heavier (full k3s), need to build KonkService-equivalent tooling
```

### Change summary — ordered by priority

| # | Repo | Change | Complexity |
|---|---|---|---|
| 1 | `tagging-aggregate-api` helm chart | Remove `KonkService` CR template | Low |
| 2 | `tagging-aggregate-api` helm chart | Add new template for vcluster kubeconfig secret | Medium |
| 3 | `tagging-aggregate-api` helm chart | Update volume mount secret names for TLS cert | Low |
| 4 | `deployment-configurations` | Add `vcluster` dependency to `tagging-aggregate-api` in `apps.yaml` | Low |
| 5 | `deployment-configurations` | Update `build/*/tagging-aggregate-api.yaml`: replace `konk.*` with vcluster config | Medium |
| 6 | New: vcluster-internal manifests | Create APIService + ExternalName Service + Namespace inside vcluster | Medium |
| 7 | Kubeconfig generation | Build automation to extract vcluster kubeconfig and create secret in `tagging-v2` | High |
| 8 | TLS/cert strategy | Decide and implement cert provisioning for Extension API Server | Medium |

### Recommended approach for dev (start here)

1. **Manually** create kubeconfig secret in `tagging-v2` namespace (extracted from vcluster)
2. **Manually** apply APIService + ExternalName inside vcluster (via `vcluster connect`)
3. Modify tagging-aggregate-api helm values to skip `KonkService` and use the manual secrets
4. Verify tagging API works through vcluster
5. Once working, automate steps 1-2 with a Job or init-container

### All 11 Extension API Servers (full migration scope)

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

Start with tagging-v2 as the pilot, then repeat for the other 10.

---

*Document created: February 23, 2026*
*Based on POC completed on us-dev-5 cluster, February 18, 2026*
