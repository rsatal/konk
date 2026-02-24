# Connecting to the Konk (bulk-konk) APIServer

## Problem

The `bulk-konk` apiserver container is **distroless** — it has no shell (`sh`, `bash`), no `ls`, no `kubectl`, and no standard utilities. You cannot exec into it directly.

```bash
# These all fail:
kubectl exec bulk-konk-<pod> -n aggregate -c apiserver -- sh
kubectl exec bulk-konk-<pod> -n aggregate -c apiserver -- bash
kubectl exec bulk-konk-<pod> -n aggregate -c apiserver -- ls /bin/
# Error: executable file not found in $PATH
```

## Solution: Access Konk from Local Machine via Port-Forward

### Step 1: Extract the Konk Admin Kubeconfig

The konk admin kubeconfig is stored in a secret in the `aggregate` namespace:

```bash
# List konk-related secrets
kubectl get secrets -n aggregate | grep -i "bulk-konk\|kubeconfig\|admin"

# The kubeconfig secret is: bulk-konk-kubeconfig (key: admin.conf)
kubectl get secret bulk-konk-kubeconfig -n aggregate \
  -o jsonpath='{.data.admin\.conf}' | base64 -d > /tmp/konk-kubeconfig.yaml
```

The kubeconfig points to `https://bulk-konk.aggregate.svc:6443` which is only resolvable inside the cluster.

### Step 2: Port-Forward the Konk Service

```bash
kubectl port-forward -n aggregate svc/bulk-konk 6443:6443 &
```

### Step 3: Create a Local-Adjusted Kubeconfig

Rewrite the server URL to point to localhost:

```bash
sed 's|https://bulk-konk.aggregate.svc:6443|https://localhost:6443|' \
  /tmp/konk-kubeconfig.yaml > /tmp/konk-kubeconfig-local.yaml
```

### Step 4: Query the Konk APIServer

```bash
# List API resources registered in konk
kubectl --kubeconfig=/tmp/konk-kubeconfig-local.yaml \
  --insecure-skip-tls-verify api-resources

# Get tags
kubectl --kubeconfig=/tmp/konk-kubeconfig-local.yaml \
  --insecure-skip-tls-verify get tags --all-namespaces

# Get values
kubectl --kubeconfig=/tmp/konk-kubeconfig-local.yaml \
  --insecure-skip-tls-verify get values --all-namespaces
```

> **Note:** `--insecure-skip-tls-verify` is needed because the TLS cert is issued for `bulk-konk.aggregate.svc`, not `localhost`.

## Alternative: Ephemeral Debug Container (for in-cluster access)

If you need a shell inside the pod (e.g., to inspect the filesystem or network):

```bash
# Use bitnami/kubectl image (includes kubectl + bash)
kubectl debug -it bulk-konk-<pod> -n aggregate \
  --target=apiserver --image=bitnami/kubectl:latest -- bash

# Or use busybox (shell only, no kubectl)
kubectl debug -it bulk-konk-<pod> -n aggregate \
  --target=apiserver --image=busybox -- sh
```

Once inside a debug container:
- The apiserver's filesystem is at `/proc/1/root/`
- View processes with `ps aux`
- The apiserver listens on port 6443

To reattach to an existing debug container:

```bash
kubectl attach bulk-konk-<pod> -c <debugger-container-name> -n aggregate -i -t
```

## Konk Secrets Reference

| Secret Name | Namespace | Type | Description |
|---|---|---|---|
| `bulk-konk-kubeconfig` | aggregate | Opaque | Admin kubeconfig (`admin.conf` key) |
| `bulk-konk-apiserver-cert` | aggregate | Opaque | APIServer TLS cert |
| `bulk-konk-ca` | aggregate | kubernetes.io/tls | Cluster CA |
| `bulk-konk-etcd-ca` | aggregate | kubernetes.io/tls | etcd CA |
| `bulk-konk-etcd-cert` | aggregate | Opaque | etcd client cert |
| `bulk-konk-ingress-client` | aggregate | kubernetes.io/tls | Ingress client cert |
| `bulk-konk-proxy-client` | aggregate | kubernetes.io/tls | Proxy client cert |

## API Resources in Konk

As of 2026-02-24, these tagging resources are registered:

| Name | API Group | Version | Namespaced | Kind |
|---|---|---|---|---|
| `tags` | `tagging.bulk.infoblox.com` | `v1alpha1` | true | Tag |
| `values` | `tagging.bulk.infoblox.com` | `v1alpha1` | true | Value |

## Known Issues

- **`atcapi.bulk.infoblox.com/v2`** — This APIService is unhealthy and produces warning logs. It's unrelated to tagging and can be ignored.
- **`Unable to get token from context`** — This error comes from the tagging-aggregate-api backend service itself (not from konk auth). It means the tagging app needs a bearer token to reach downstream services.
