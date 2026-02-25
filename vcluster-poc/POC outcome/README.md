# vCluster POC: Replacing Konk for API Aggregation

**Date:** February 25, 2026  
**Cluster:** us-dev-5  
**Author:** Rahul Satal

---

## Table of Contents

1. [The Problem: Why Do We Need API Aggregation?](#1-the-problem-why-do-we-need-api-aggregation)
2. [How Konk Solves This (Current Solution)](#2-how-konk-solves-this-current-solution)
3. [How vCluster Could Replace Konk](#3-how-vcluster-could-replace-konk)
4. [What We Did in the POC](#4-what-we-did-in-the-poc)
5. [POC Outcome: What Worked](#5-poc-outcome-what-worked)
6. [The Showstopper: Why We Cannot Continue](#6-the-showstopper-why-we-cannot-continue)
7. [Additional Challenges Discovered](#7-additional-challenges-discovered)
8. [Current State After POC](#8-current-state-after-poc)
9. [Scripts and Artifacts Produced](#9-scripts-and-artifacts-produced)
10. [Conclusion and Recommendation](#10-conclusion-and-recommendation)
- [Appendix A: Konk vs vCluster Architecture Comparison](#appendix-a-konk-vs-vcluster-architecture-comparison)
- [Appendix B: Request Flow Comparison](#appendix-b-request-flow-comparison)
- [Appendix C: What "19 KonkService CRs" Means](#appendix-c-what-19-konkservice-crs-means)
- [Appendix D: TLS Certificate and Kubeconfig — What They Do](#appendix-d-tls-certificate-and-kubeconfig--what-they-do)

---

## 1. The Problem: Why Do We Need API Aggregation?

### What Our Platform Does

The **bulk** service in Infoblox allows customers to import/export data in bulk. It uses multiple Infoblox services to do this — DNS, IPAM/DHCP, Tagging, Infrastructure, Threat Defense, etc. Each of these services exposes its own API (extension API server) for bulk to talk to.

Think of it like a shopping mall: each store (service) has its own entrance. But customers (the bulk service) want **one front door** to access all stores.

### The "One Front Door" Problem

The **bulk** service needs to discover and talk to all 11 extension API servers across 12 API groups. Instead of hardcoding every service endpoint, we use **Kubernetes API Aggregation** — a single API server that knows where every service lives and routes requests to the right place.

```
Without aggregation (messy):                With aggregation (clean):

  bulk ──→ tagging-api                        bulk ──→ ONE API Server ──→ tagging-api
  bulk ──→ dns-api                                                   ──→ dns-api
  bulk ──→ ipam-api                                                  ──→ ipam-api
  bulk ──→ infrastructure-api                                        ──→ infrastructure-api
  bulk ──→ ... (11 more)                                             ──→ ... (11 more)
```

### Why Not Use the Main Cluster's API Server?

Registering custom APIs directly on the main EKS cluster API server is risky:
- A buggy extension API could **crash or destabilize the entire cluster**
- Custom resources compete for space in the main cluster's etcd
- No isolation — one bad actor affects everyone

**We need an isolated, sandboxed API server just for our extension APIs.**

---

## 2. How Konk Solves This (Current Solution)

### What is Konk?

**Konk** (Kubernetes ON Kubernetes) is an **in-house tool** that deploys a standalone Kubernetes API server (+ etcd) inside our cluster. Think of it as a "mini Kubernetes" that only handles API routing — no pods, no nodes, no workloads.

### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                    Our EKS Cluster                          │
│                                                             │
│   ┌─────────────────────────────────────────────────────┐   │
│   │            Konk (bulk-konk)                         │   │
│   │                                                     │   │
│   │   ┌──────────┐     ┌──────────────────────────┐     │   │
│   │   │   etcd   │◄────│  kube-apiserver          │     │   │
│   │   │ (storage)│     │  (the "one front door")  │     │   │
│   │   └──────────┘     └────────────┬─────────────┘     │   │
│   │                                 │                   │   │
│   │     "I know where every service lives"              │   │
│   │     (via 19 KonkService registrations)              │   │
│   └─────────────────────────────────┼───────────────────┘   │
│                                     │                       │
│        ┌──────────┬─────────────────┼──────────┬────────┐   │
│        ▼          ▼                 ▼          ▼        ▼   │
│   ┌────────┐ ┌────────┐      ┌──────────┐ ┌───────┐  ...    │
│   │tagging │ │  dns   │      │   ipam   │ │hostapp│         │
│   │  api   │ │  api   │      │   api    │ │  api  │         │
│   └────────┘ └────────┘      └──────────┘ └───────┘         │
│                                                             │
│   11 extension API servers, 12 API groups                   │
└─────────────────────────────────────────────────────────────┘
```

### The Konk Operator + KonkService

Konk uses **3 CRDs** (Custom Resource Definitions):

| CRD | Purpose | vCluster equivalent? |
|-----|---------|---------------------|
| **Konk** | Deploys a kube-apiserver (the "mini K8s") | **Yes** — `vcluster create` does this |
| **Etcd** | Deploys the backing etcd storage | **Yes** — vcluster embeds etcd in the same pod |
| **KonkService** | Automates registration of each extension API server (certs, kubeconfig, APIService, RBAC, ingress) | **No** — vcluster has no equivalent |

Konk has an **operator** that automates everything. When you create a `KonkService` CR, it automatically:
1. Generates TLS certificates (via cert-manager)
2. Creates a kubeconfig for the service
3. Registers an `APIService` and `ExternalName` inside konk
4. Sets up RBAC permissions
5. Configures front-proxy ingress* (for external access)

**This automation is a big deal** — you just write a small YAML and konk handles the rest. vCluster replaces the infrastructure (Konk + Etcd), but has **no answer for the automation layer** (KonkService).

### Key Concepts Explained

#### What is an Extension API Server?

Kubernetes has a built-in API server that handles standard resources (pods, deployments, services, etc.). But what if you want to add **your own custom APIs** — like a `/tags` endpoint for tagging, or a `/hosts` endpoint for infrastructure?

An **extension API server** is a separate process (pod) that serves these custom APIs. It's like adding a new department to a company — the department has its own staff and handles its own work, but it's accessible through the company's main reception desk (the API server).

**Host API server vs Konk API server vs Extension API server — they are NOT the same thing:**

```
Think of it like Infoblox itself:

  Host API Server  =  INFOBLOX HQ in Santa Clara, USA
  (EKS)                - Manages the whole company (pods, nodes, deployments)
                       - Doesn't handle individual product work (tagging, dns, etc.)
                       - We keep our custom APIs OUT of here for safety

  Konk API Server  =  INDIA OFFICE RECEPTION in Bengaluru, India
  (bulk-konk)          - Doesn't do the product work itself
                       - Knows which team handles which product
                       - Routes your request to the right team

  Extension API    =  The actual ENGINEERING TEAMS (11 of them)
  Servers              - Tagging team, DNS team, IPAM team, Infra team, etc.
                       - Spread across Bengaluru, Thiruvananthapuram, Pune
                       - Each team does the real work
                       - But all requests come through the reception desk
```

The konk API server is a **router/dispatcher** — it doesn't serve tagging data or DNS data itself. It just knows _"tagging requests go to the tagging team, DNS requests go to the DNS team"_ and forwards accordingly. The extension API servers are the teams that actually process the requests and return data.

In our case, we have **11 extension API servers** — each one handles a different domain:

| Extension API Server | What it serves |
|---------------------|----------------|
| tagging-aggregate-api | Tags and values for bulk tagging |
| dns-importexport | DNS record import/export |
| ipam-importexport | IPAM/DHCP import/export |
| infrastructure-importexport | Host/network infrastructure |
| ... | ... (7 more) |

Each extension API server is just a regular pod running in the cluster. It needs to be **registered** with an API server (konk/vcluster) so that requests can be routed to it.

#### What is API Aggregation?

**API Aggregation** is the Kubernetes mechanism that connects everything together. It's the "reception desk" that knows which extension API server handles which API group, and forwards requests accordingly.

```
                          API Aggregation in action:

  Client request: GET /apis/tagging.bulk.infoblox.com/v1alpha1/tags
                    │
                    ▼
            ┌───────────────┐
            │  API Server   │  Checks its APIService list...
            │  (konk)       │  "tagging.bulk.infoblox.com → tagging-aggregate-api"
            └───────┬───────┘
                    │  Forwards request
                    ▼
            ┌───────────────┐
            │  tagging-     │  Handles the request, returns tags
            │  aggregate-api│
            └───────────────┘
```

Without aggregation, the client would need to know the exact address of every extension API server. With aggregation, there's **one endpoint** that routes to all of them — this is the "one front door" concept from Section 1.

The key objects that make aggregation work:
1. **APIService** — tells the API server where to route each API group
2. **ExternalName Service** — provides DNS resolution to the actual pod
3. **RBAC** — authorizes the API server to forward requests
4. **Certificates** — secures communication between the API server and extension pods

#### What is an APIService?

An **APIService** is a built-in Kubernetes object that tells the API server: _"When someone asks for APIs under this group, forward the request to that service."_

Even `kubectl get pods` works because of an APIService! Kubernetes has built-in APIServices for its core resources:

```bash
$ kubectl get apiservice v1.                  # built-in: handles pods, nodes, services, etc.
$ kubectl get apiservice v1beta1.metrics.k8s.io   # added by metrics-server: handles "kubectl top"
```

When you run `kubectl get pods`, the API server checks its APIService list, finds that `v1.` (core group) is handled **locally**, and serves the response. When you run `kubectl top nodes`, it finds `v1beta1.metrics.k8s.io` is handled by the **metrics-server** pod, and forwards the request there.

Custom APIServices work the same way — they tell the API server: _"Forward requests for this API group to that service."_

Think of it like a **redirect rule** in a phone system:
- "If someone calls extension 100 (tagging), transfer them to the tagging pod"
- "If someone calls extension 200 (dns), transfer them to the dns pod"

So when a client makes this API call:
```
GET /apis/tagging.bulk.infoblox.com/v1alpha1/tags
      ├── group: tagging.bulk.infoblox.com
      ├── version: v1alpha1
      └── resource: tags   (handled by the extension pod itself, not the APIService)
```
The API server looks up: _"Who handles `tagging.bulk.infoblox.com/v1alpha1`?"_ → finds the APIService below → forwards to `tagging-aggregate-api-apiservice`.

```yaml
# Inside konk/vcluster: APIService tells konk "tagging requests go to tagging-aggregate-api"
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: v1alpha1.tagging.bulk.infoblox.com    # The API group + version
spec:
  group: tagging.bulk.infoblox.com            # API group name
  version: v1alpha1                            # API version
  service:
    name: tagging-aggregate-api-apiservice     # WHERE to send requests
    namespace: tagging-v2                      # Which namespace the service is in
  caBundle: <base64-encoded-CA-cert>           # How to trust the service's TLS cert
```

Without an `APIService`, the API server would respond with "404 Not Found" for any tagging request. The APIService is the **glue** that connects the API server to the actual backend service.

#### What is an ExternalName Service?

An **ExternalName** service is a Kubernetes service that acts as a **DNS alias**. Instead of pointing to pods, it points to another DNS name.

When konk (or vcluster) needs to route a request to an extension API server, the backend service lives in a **different namespace** (or even a different cluster context). An ExternalName service bridges this gap:

```yaml
# Inside konk/vcluster: "tagging-aggregate-api-apiservice" resolves to the real pod's FQDN
apiVersion: v1
kind: Service
metadata:
  name: tagging-aggregate-api-apiservice
  namespace: tagging-v2         # namespace as seen inside konk/vcluster
spec:
  type: ExternalName
  externalName: tagging-aggregate-api-apiservice.tagging-v2.svc.cluster.local
  #             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  #             The actual DNS name of the pod's service in the host cluster
```

**Who creates these?**
- **In konk:** The `konk-operator` creates both the `APIService` and the backing `ExternalName` service automatically when you create a `KonkService` CR. You never have to touch these yourself.
- **In vcluster:** There is no automation. You must **manually** create both the `APIService` and the `ExternalName` service inside vcluster. This is one of the key gaps.

#### Front-Proxy Ingress (How External Traffic Reaches Konk)

The **front-proxy ingress** is how clients outside the host cluster us-dev-5 (like the bulk API at `env-5.test.infoblox.com`) access the extension APIs through konk.

```
External client (browser / curl / bulk API)
     │
     │  HTTPS request to env-5.test.infoblox.com
     ▼
┌─────────────────┐
│  NGINX Ingress  │  ← has a client certificate (mTLS) to authenticate with konk
│  Controller     │
└────────┬────────┘
         │  Uses client cert from: <konk-name>-ingress-client secret
         │  Backend protocol: HTTPS with proxy-ssl
         ▼
┌─────────────────┐
│  bulk-konk      │  ← konk's kube-apiserver (port 6443)
│  apiserver      │     Validates the ingress client cert against its front-proxy CA
└────────┬────────┘
         │  Looks up APIService for the requested API group
         │  Forwards request to the correct extension API server
         ▼
┌─────────────────┐
│  Extension API  │  ← e.g., tagging-aggregate-api, dns-importexport, etc.
│  Server (pod)   │
└─────────────────┘
```

**How it works in konk:**
- The `KonkService` CR has an `ingress.enabled: true` option
- When enabled, konk-operator automatically creates:
  - An **Ingress** resource with NGINX annotations for HTTPS backend + proxy-ssl
  - A **client certificate** secret (`<konk-name>-ingress-client`) for mTLS between the ingress and konk
  - The proper TLS configuration so the ingress can authenticate with konk's API server
- The ingress uses **mutual TLS (mTLS)**: the client (ingress) presents a certificate to prove its identity to konk, and konk's front-proxy CA validates it

**In vcluster:** There is no built-in front-proxy ingress automation. You would need to manually configure the ingress, create client certificates, and set up the proxy-ssl annotations. However, for internal service-to-service communication (like bulk → vcluster), ingress is not needed — bulk connects directly to `vcluster.vcluster:443` within the cluster.

### Why Replace Konk?

| Issue | Impact |
|-------|--------|
| **In-house maintained** | Small team, limited bandwidth for updates/fixes |
| **No community support** | Bugs and security patches fall entirely on us |
| **Outdated dependencies** | etcd and kube-apiserver versions lag behind upstream |
| **Limited documentation** | Tribal knowledge, hard to onboard new engineers |
| **Heavyweight** | Runs 3 pods (apiserver + etcd + init) per konk instance |

---

## 3. How vCluster Could Replace Konk

### What is vCluster?

**vCluster** is an **open-source tool** (by Loft Labs) that creates a fully functional virtual Kubernetes cluster inside a namespace. It's like Konk but more feature-rich — it provides a complete Kubernetes environment: API server, controller-manager, scheduler, and even virtual nodes.

### Why Consider vCluster?

| Advantage | Details |
|-----------|---------|
| **Actively maintained** | Open-source, frequent releases, large community |
| **Commercial support** | Loft Labs offers enterprise support |
| **Full K8s compatibility** | Can serve as a drop-in API aggregation layer |
| **Lighter deployment** | Single StatefulSet (all-in-one pod) vs konk's 3 pods |
| **Better documentation** | Extensive public docs, examples, and community |
| **Multiple backends** | Supports k3s, k0s, eks, vanilla K8s as backing store |

### Side-by-Side Comparison

```
     Konk (current)                    vCluster (proposed)

  ┌────────────────────┐           ┌────────────────────┐
  │ konk-operator      │           │                    │
  │ (watches CRDs)     │           │  vcluster CLI/     │
  └────────┬───────────┘           │  operator          │
           │                       └────────┬───────────┘
           ▼                                ▼
  ┌────────────────────┐           ┌────────────────────┐
  │ bulk-konk          │           │ vcluster-0         │
  │  - kube-apiserver  │           │  - kube-apiserver  │
  │  - etcd (1 pod)    │           │  - etcd (embedded) │
  │  - init (1 pod)    │           │  (single pod!)     │
  │  (3 pods total)    │           └────────────────────┘
  └────────────────────┘
  Port: 6443                       Port: 443
  KonkService CRs: 19             APIServices: manual setup
```

---

## 4. What We Did in the POC

### Goal

Validate whether vCluster can replace konk as the API aggregation layer by migrating the **tagging** service (one of the 11 extension API servers) from konk to vcluster.

### Steps Performed

#### Step 1: Deploy vCluster
A vcluster instance (`vcluster-0`) was deployed in the `vcluster` namespace on us-dev-5.

#### Step 2: Create TLS Certificate
Generated a self-signed TLS cert for the tagging-aggregate-api to use when serving through vcluster (instead of konk's cert).

#### Step 3: Create Kubeconfig
Extracted the vcluster admin kubeconfig and created a secret so the tagging pod can authenticate against vcluster.

#### Step 4: Register APIService in vCluster
Inside vcluster, registered:
- An `APIService` for `v1alpha1.tagging.bulk.infoblox.com`
- An `ExternalName` service pointing to the tagging pod in the host cluster
- RBAC rules for delegated authentication

#### Step 5: Switch Tagging from Konk to vCluster
Patched the tagging deployment to use vcluster secrets instead of konk secrets:

| Setting | Before (Konk) | After (vCluster) |
|---------|---------------|-------------------|
| TLS cert | konk-generated cert | self-signed cert |
| Kubeconfig | konk admin kubeconfig | vcluster admin kubeconfig |
| Auth target | bulk-konk.aggregate:6443 | vcluster.vcluster:443 |

#### Step 6: Switch Bulk from Konk to vCluster
Patched the bulk deployment to discover APIs through vcluster instead of konk:

| Setting | Before (Konk) | After (vCluster) |
|---------|---------------|-------------------|
| `--konk.host` | `bulk-konk.aggregate:6443` | `vcluster.vcluster:443` |
| Kubeconfig | `bulk-konk-kubeconfig` | `bulk-vcluster-kubeconfig` |
| Proxy-client cert | `bulk-konk-proxy-client` | `bulk-vcluster-proxy-client` |

---

## 5. POC Outcome: What Worked

### API Aggregation via vCluster — WORKS

```
APIService v1alpha1.tagging.bulk.infoblox.com → Available: True

Request chain: bulk → vcluster → tagging-aggregate-api → confirmed working
```

- vCluster's kube-apiserver correctly routes API requests to the tagging pod
- ExternalName service resolution works across namespaces
- Delegated authentication (requestheader) works
- The tagging pod starts and runs healthy with vcluster secrets

### Bulk Export via vCluster — WORKS (for tagging)

```bash
POST /bulk/v1/export
  data_types: ["tagging.bulk.infoblox.com/v1alpha1/tags"]

Response: {"success": {"message": "Export pending"}}
# Operation created, request reached tagging through vcluster
```

### Lighter Footprint

| | Konk | vCluster |
|--|------|----------|
| Pods | 3 (apiserver + etcd + init) | 1 (StatefulSet, all-in-one) |
| Operator | konk-operator required | vcluster CLI/operator |
| CRDs needed | Konk, KonkService, Etcd | None (standard K8s) |

---

## 6. The Showstopper: Why We Cannot Continue

### Critical Finding: Single-Service Migration Breaks Everything Else

The **bulk** deployment uses a single `--konk.host` parameter to discover ALL APIs. It's like having one phone book — you can only look up numbers from ONE directory at a time.

When we pointed bulk to vcluster (which only has tagging registered), **all 10 other services became unreachable**:

```
                    What bulk sees via KONK           What bulk sees via vCLUSTER
                    (current — everything works)      (POC — only tagging works)

  tagging           ✅ Available                       ✅ Available
  infrastructure    ✅ Available                       ❌ NOT FOUND
  dns-config        ✅ Available                       ❌ NOT FOUND
  dns-data          ✅ Available                       ❌ NOT FOUND
  ipam-dhcp         ✅ Available                       ❌ NOT FOUND
  atcapi            ✅ Available                       ❌ NOT FOUND
  hostapp           ✅ Available                       ❌ NOT FOUND
  bootstrap         ✅ Available                       ❌ NOT FOUND
  ntp               ✅ Available                       ❌ NOT FOUND
  redirect          ✅ Available                       ❌ NOT FOUND
  endpoints         ✅ Available                       ❌ NOT FOUND
  keys              ✅ Available                       ❌ NOT FOUND
```

**You CANNOT migrate services one-by-one.** It's all-or-nothing.

### What Would "All-or-Nothing" Require?

To fully switch from konk to vcluster, we would need to:

1. **Register ALL 19 KonkService CRs as APIServices in vcluster** — For each of the 11 extension API servers and 12 API groups, manually create:
   - An `APIService` object inside vcluster
   - An `ExternalName` service inside vcluster
   - RBAC (ClusterRole + ClusterRoleBinding) for delegated auth

2. **Build KonkService-equivalent automation** — Konk's operator handles cert generation, kubeconfig creation, APIService registration, and RBAC automatically. vCluster has **no built-in equivalent**. We'd need to build custom tooling or a custom operator.

3. **Coordinate with ALL 11 service teams** — Each extension API server would need its deployment patched to use vcluster certs/kubeconfig instead of konk.

4. **Big-bang cutover** — All services must be registered and tested in vcluster BEFORE switching bulk's `--konk.host`, since there's no way to do a gradual migration.

---

## 7. Additional Challenges Discovered

### 7.1 Proxy-Client Certificate Gotcha

The bulk deployment needs a **client certificate** to authenticate with the API server's requestheader proxy. We initially copied the server TLS cert, which caused `Unauthorized` errors. The fix required extracting the **admin client cert** from the vcluster kubeconfig — a subtlety not documented anywhere.

**Lesson:** The proxy-client secret is the client's identity certificate (CN=kubernetes-super-admin), not the server's TLS cert. Getting this wrong causes silent authentication failures.

### 7.2 x509 Certificate Log Noise

After migrating tagging to vcluster, konk still tries to probe the tagging pod every ~30 seconds. Since the tagging pod now trusts vcluster's CA (not konk's CA), these probes produce x509 errors in logs:

```
"Unable to authenticate the request"
  err="x509: certificate signed by unknown authority"
```

These are harmless but noisy. They would stop only if we remove the tagging KonkService from konk — but doing so breaks konk-based access to tagging.

### 7.3 Pre-Existing Tagging Token Issue

The tagging-aggregate-api has a pre-existing bug: it expects a CSP JWT Bearer token in the HTTP context, but K8s API aggregation (both konk and vcluster) passes identity via `X-Remote-User` headers, not Bearer tokens. This causes `"Unable to get token from context"` errors. **This is NOT a migration issue — it exists on konk too.**

### 7.4 No KonkService Equivalent in vCluster

Konk's biggest value-add is the `KonkService` CR that automates everything. vCluster does not have:
- Automatic cert generation for extension API servers
- Automatic kubeconfig secret creation
- Automatic APIService registration
- Automatic RBAC setup

All of this would need to be built from scratch.

---

## 8. Current State After POC

| Component | State | Details |
|-----------|-------|---------|
| **Tagging deployment** | On vCluster | Using vcluster certs/kubeconfig (steps 1-4 active) |
| **Bulk deployment** | On Konk (reverted) | Reverted to konk so all data types work |
| **vCluster** | Running | `vcluster-0` in vcluster namespace |
| **Konk** | Running | `bulk-konk` in aggregate namespace, all 19 KonkServices active |
| **vCluster secrets** | Preserved | `bulk-vcluster-kubeconfig` and `bulk-vcluster-proxy-client` kept in aggregate namespace |

---

## 9. Scripts and Artifacts Produced

| Artifact | Location | Purpose |
|----------|----------|---------|
| Migration script | `migrate-tagging-to-vcluster.sh` | Automated steps 1-5, backup, verify, rollback (1200+ lines) |
| Rollback script | `rollback-bulk.sh` | Reverts bulk to konk with verify and export test |
| Detailed migration log | `Migrate bulk and tagging/README.md` | Step-by-step record of what was done |
| Additional test scripts | `additional-scripts/` | Proxy-client fix, konk connectivity tests, bulk deployment parser |
| Backups | `backup-tagging-konk-*` | Pre-migration state of all deployments and secrets |

---

## 10. Conclusion and Recommendation

### Can vCluster Replace Konk?

**Technically, yes.** vCluster's kube-apiserver handles API aggregation correctly — APIService registration, request routing, delegated auth, and ExternalName resolution all work as expected.

**Practically, no — not incrementally.** The fundamental problem is that bulk uses a single aggregation endpoint. You cannot migrate services one at a time; it's a big-bang switchover that requires:
- Building KonkService-equivalent automation for vcluster
- Registering all 11 services (19 CRs) at once
- Coordinating with all service teams
- Significant engineering effort with high risk

### Recommendation

| Option | Effort | Risk | Recommendation |
|--------|--------|------|----------------|
| **Keep konk as-is** | None | Status quo risks (maintenance burden) | Short-term default |
| **Full migration to vcluster** | High (build operator, coordinate teams, big-bang cutover) | High (all-or-nothing) | Not recommended without dedicated project |
| **Build vcluster KonkService operator** | Medium-High (custom operator development) | Medium | Best long-term path if konk retirement is a goal |
| **Hybrid (new services on vcluster)** | Low | Low | Good interim approach — keep konk for existing, use vcluster for new |

### Bottom Line

> **vCluster works as an API aggregation layer, but replacing konk is not a simple swap.** The migration cannot be done incrementally due to bulk's single `--konk.host` design. A full migration requires building automation equivalent to KonkService, which is a separate engineering project. The POC successfully validated the technical feasibility but revealed the operational complexity is the real barrier.

---

## Appendix A: Konk vs vCluster Architecture Comparison

```
                KONK                                    vCLUSTER
  ┌──────────────────────────┐          ┌──────────────────────────┐
  │  konk-operator           │          │  vcluster operator/CLI   │
  │  (watches CRDs)          │          │                          │
  └────────────┬─────────────┘          └────────────┬─────────────┘
               │                                     │
               ▼                                     ▼
  ┌──────────────────────────┐          ┌──────────────────────────┐
  │  bulk-konk-etcd          │          │  vcluster-0 (StatefulSet)│
  │  (dedicated etcd pod)    │          │  ┌─────────────────────┐ │
  └──────────────────────────┘          │  │ kube-apiserver      │ │
  ┌──────────────────────────┐          │  │ etcd (embedded)     │ │
  │  bulk-konk (apiserver)   │          │  │ controller-manager  │ │
  │  (dedicated pod)         │          │  │ scheduler (optional)│ │
  └──────────────────────────┘          │  └─────────────────────┘ │
  ┌──────────────────────────┐          └──────────────────────────┘
  │  bulk-konk-init          │
  │  (init helper pod)       │           Port: 443
  └──────────────────────────┘           Pods: 1 (all-in-one)
                                         CRDs: None required
  Port: 6443
  Pods: 3
  CRDs: Konk, KonkService, Etcd

  API Registration:                     API Registration:
  KonkService CR (automated)            APIService + ExternalName (manual)
  └── cert-manager integration          └── No built-in automation
  └── auto kubeconfig creation          └── Must extract from admin kubeconfig
  └── auto RBAC setup                   └── Must create manually
  └── auto APIService                   └── Must create manually
```

## Appendix B: Request Flow Comparison

```
HOW A BULK EXPORT REQUEST FLOWS:

Via Konk (current):
  Client → env-5.test.infoblox.com → bulk pod
    → --konk.host=bulk-konk.aggregate:6443
    → bulk-konk apiserver (knows ALL 12 API groups)
    → routes to correct extension API server pod
    → response back to client

Via vCluster (POC):
  Client → env-5.test.infoblox.com → bulk pod
    → --konk.host=vcluster.vcluster:443
    → vcluster apiserver (only knows tagging API group)
    → routes to tagging pod ✅
    → routes to dns/infra/ipam? ❌ NOT REGISTERED
```

## Appendix C: What "19 KonkService CRs" Means

```
                         bulk-konk (API server)
                                │
      ┌─────────────────────────┼──────────────────────────┐
      │                         │                          │
  ┌───┴───┐               ┌────┴────┐              ┌──────┴──────┐
  │atcapi │               │  ddi    │              │  hostapp    │
  │2 CRs  │               │ 8 CRs  │              │  2 CRs      │
  │(v1,v2)│               │(dns-cfg │              │(infra,onprem│
  │       │               │ dns-data│              │  )          │
  │       │               │ ipam    │              │             │
  │       │               │ keys)   │              │             │
  └───────┘               └─────────┘              └─────────────┘

  + bootstrap(1) + endpoints(1) + ntp(1) + redirect(1) + tagging(1)
  + dns-config-test(2)

  Total: 19 KonkService CRs → 11 services → 12 API groups
```

## Appendix D: TLS Certificate and Kubeconfig — What They Do

Each extension API server needs **two secrets** to work with konk (or vcluster). Both are created on the **main (host) cluster** as Kubernetes Secrets, but they exist for communication **with konk**, not with the host cluster.

#### TLS Certificate

**Purpose:** Konk connects to extension pods over HTTPS. The TLS cert lets the extension pod serve HTTPS and lets konk verify it's talking to the right pod (not an imposter).

```
  Konk API Server ──── HTTPS ────→ Extension API pod
       │                               │
       │  "Show me your TLS cert"      │  Presents its TLS cert
       │                               │
       │  Validates against caBundle   │
       │  in the APIService object     │
       └───────────────────────────────┘

  TLS cert  = Extension pod's IDENTITY CARD
              Created on: main cluster (K8s Secret)
              Trusted by: konk (via APIService caBundle field)
```

- **Where it's stored:** Main cluster, as a K8s Secret in the extension pod's namespace
- **Where it's trusted:** Inside konk, in the `APIService` object's `caBundle` field
- **Who creates it:** In konk — the konk-operator (via cert-manager). In vcluster — you, manually.

#### Kubeconfig

**Purpose:** The extension API server needs to **call back to konk** for delegated authentication. When a request arrives, the extension pod asks konk: _"Is this user authorized?"_ The kubeconfig gives it the credentials and endpoint to reach konk.

```
  The FULL request flow (kubeconfig is used in step 4):

  Step 1: Client (bulk) sends request
       │
       ▼
  Step 2: Konk API Server receives it FIRST
       │  Looks up APIService → "this goes to tagging pod"
       │  Adds X-Remote-User headers (identity of the caller)
       │  Forwards request to extension pod
       ▼
  Step 3: Extension pod receives the forwarded request
       │  "I got headers saying this is user X... but can I trust them?"
       │  "Let me call back to konk to verify..."
       │
       │  ← THIS is where the kubeconfig is used (callback)
       ▼
  Step 4: Extension pod calls BACK to Konk (using kubeconfig)
       │  "Hey konk, did YOU actually send me this request?"
       │
       ▼
  Step 5: Konk responds: "Yes, I forwarded it, the user is legit"
       │
       ▼
  Step 6: Extension pod processes the request and returns data

  Kubeconfig = Extension pod's PHONE NUMBER FOR KONK (for the callback in step 4)
               Created on: main cluster (K8s Secret)
               Points to: konk (bulk-konk.aggregate:6443)
               NOT the main cluster API server
```

- **Where it's stored:** Main cluster, as a K8s Secret in the extension pod's namespace
- **Where it points to:** Konk's address (`bulk-konk.aggregate:6443`), not the host cluster
- **Who creates it:** In konk — the konk-operator. In vcluster — you, manually (extracted from vcluster admin kubeconfig).

#### Summary

```
  Both secrets live on the MAIN CLUSTER but are for talking to KONK:

  ┌──────────────────┐         ┌──────────────────┐
  │  TLS Certificate │         │    Kubeconfig     │
  ├──────────────────┤         ├──────────────────┤
  │ What: Pod's      │         │ What: Credentials │
  │   identity cert  │         │   to call konk    │
  │                  │         │                   │
  │ Direction:       │         │ Direction:        │
  │ Konk → Pod       │         │ Pod → Konk        │
  │ (konk validates  │         │ (pod calls back   │
  │  the pod)        │         │  to authenticate) │
  │                  │         │                   │
  │ Created by:      │         │ Created by:       │
  │ konk-operator    │         │ konk-operator     │
  │ (cert-manager)   │         │                   │
  └──────────────────┘         └──────────────────┘
```
