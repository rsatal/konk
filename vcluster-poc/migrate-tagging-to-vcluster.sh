#!/bin/bash
# migrate-tagging-to-vcluster.sh
#
# Migrates tagging-aggregate-api from konk to vcluster on us-dev-5.
# Each step is a separate function — run them one at a time and verify.
#
# Usage:
#   ./migrate-tagging-to-vcluster.sh preflight
#   ./migrate-tagging-to-vcluster.sh backup
#   ./migrate-tagging-to-vcluster.sh step1   # Generate self-signed TLS cert
#   ./migrate-tagging-to-vcluster.sh step2   # Generate vcluster kubeconfig secret
#   ./migrate-tagging-to-vcluster.sh step3   # Register APIService inside vcluster
#   ./migrate-tagging-to-vcluster.sh step4   # Patch tagging-aggregate-api deployment
#   ./migrate-tagging-to-vcluster.sh step5   # Migrate bulk deployment to vcluster
#   ./migrate-tagging-to-vcluster.sh verify  # Verify tagging + bulk APIs work
#   ./migrate-tagging-to-vcluster.sh rollback

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
TAGGING_NS="tagging-v2"
VCLUSTER_NS="vcluster"
VCLUSTER_NAME="vcluster"
DEPLOYMENT_NAME="tagging-aggregate-api"
SERVICE_NAME="tagging-aggregate-api-apiservice"
API_GROUP="tagging.bulk.infoblox.com"
API_VERSION="v1alpha1"

# Current konk secrets (what we're replacing)
KONK_TLS_SECRET="tagging-aggregate-api-apiservice-konk-service-server"
KONK_KUBECONFIG_SECRET="tagging-aggregate-api-apiservice-konk-service-kubeconfig"

# New vcluster secrets (what we're creating)
VCLUSTER_TLS_SECRET="tagging-aggregate-api-vcluster-server"
VCLUSTER_KUBECONFIG_SECRET="tagging-aggregate-api-vcluster-kubeconfig"

# Bulk deployment configuration (in aggregate namespace)
BULK_NS="aggregate"
BULK_DEPLOYMENT="bulk"
BULK_KONK_KUBECONFIG_SECRET="bulk-konk-kubeconfig"
BULK_KONK_PROXY_CLIENT_SECRET="bulk-konk-proxy-client"
BULK_VCLUSTER_KUBECONFIG_SECRET="bulk-vcluster-kubeconfig"
BULK_VCLUSTER_PROXY_CLIENT_SECRET="bulk-vcluster-proxy-client"
VCLUSTER_HOST="vcluster.vcluster:443"

# Backup directory
BACKUP_DIR="./backup-tagging-konk-$(date +%Y%m%d-%H%M%S)"

# Temp directory for cert generation
TMPDIR_CERTS=$(mktemp -d)

# ============================================================================
# Colors for output
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $1"; }

# ============================================================================
# PREFLIGHT: Check if tagging APIs are currently working via konk
# ============================================================================
preflight() {
    echo ""
    echo "============================================"
    echo "  PREFLIGHT CHECK"
    echo "============================================"
    echo ""

    # 1. Check we're on the right cluster context
    info "Checking cluster context..."
    CURRENT_CTX=$(kubectl config current-context)
    echo "  Current context: ${CURRENT_CTX}"
    if [[ "${CURRENT_CTX}" != *"us-dev-5"* && "${CURRENT_CTX}" != *"env-5"* ]]; then
        warn "Context doesn't look like us-dev-5. Proceed with caution."
    else
        ok "Context looks correct"
    fi

    # 2. Check tagging-aggregate-api deployment exists and is running
    info "Checking tagging-aggregate-api deployment..."
    READY=$(kubectl get deployment ${DEPLOYMENT_NAME} -n ${TAGGING_NS} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl get deployment ${DEPLOYMENT_NAME} -n ${TAGGING_NS} -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
    if [[ "${READY}" -ge 1 ]]; then
        ok "Deployment ${DEPLOYMENT_NAME} is running (${READY}/${DESIRED} ready)"
    else
        fail "Deployment ${DEPLOYMENT_NAME} is NOT ready (${READY}/${DESIRED})"
        return 1
    fi

    # 3. Check current konk secrets exist
    info "Checking konk secrets..."
    if kubectl get secret ${KONK_TLS_SECRET} -n ${TAGGING_NS} &>/dev/null; then
        ok "TLS secret exists: ${KONK_TLS_SECRET}"
    else
        warn "TLS secret NOT found: ${KONK_TLS_SECRET}"
    fi

    if kubectl get secret ${KONK_KUBECONFIG_SECRET} -n ${TAGGING_NS} &>/dev/null; then
        ok "Kubeconfig secret exists: ${KONK_KUBECONFIG_SECRET}"
    else
        warn "Kubeconfig secret NOT found: ${KONK_KUBECONFIG_SECRET}"
    fi

    # 4. Check KonkService CR exists
    info "Checking KonkService CR..."
    if kubectl get konkservice ${SERVICE_NAME} -n ${TAGGING_NS} &>/dev/null; then
        ok "KonkService CR exists: ${SERVICE_NAME}"
    else
        warn "KonkService CR NOT found (may be normal if konk CRDs aren't installed)"
    fi

    # 5. Check vcluster is running
    info "Checking vcluster in ${VCLUSTER_NS} namespace..."
    VCLUSTER_POD=$(kubectl get pods -n ${VCLUSTER_NS} -l app=vcluster -o name 2>/dev/null | head -1)
    if [[ -z "${VCLUSTER_POD}" ]]; then
        # Try alternate label
        VCLUSTER_POD=$(kubectl get pods -n ${VCLUSTER_NS} --field-selector=status.phase=Running -o name 2>/dev/null | grep vcluster | head -1)
    fi
    if [[ -n "${VCLUSTER_POD}" ]]; then
        ok "vcluster pod found: ${VCLUSTER_POD}"
    else
        fail "No vcluster pod found in ${VCLUSTER_NS} namespace"
        warn "List of pods in ${VCLUSTER_NS}:"
        kubectl get pods -n ${VCLUSTER_NS} 2>/dev/null || true
        return 1
    fi

    # 6. Check vcluster kubeconfig secret exists
    info "Checking vcluster kubeconfig secret..."
    VC_SECRET_NAME="vc-config-${VCLUSTER_NAME}"
    if kubectl get secret ${VC_SECRET_NAME} -n ${VCLUSTER_NS} &>/dev/null; then
        ok "vcluster config secret exists: ${VC_SECRET_NAME}"
    else
        # Try alternate name
        VC_SECRET_NAME="vc-${VCLUSTER_NAME}"
        if kubectl get secret ${VC_SECRET_NAME} -n ${VCLUSTER_NS} &>/dev/null; then
            ok "vcluster kubeconfig secret exists: ${VC_SECRET_NAME}"
        else
            warn "vcluster kubeconfig secret not found. Checking all secrets in ${VCLUSTER_NS}:"
            kubectl get secrets -n ${VCLUSTER_NS} 2>/dev/null | grep -i "vc-\|vcluster" || true
        fi
    fi

    # 7. Test tagging API via konk (current state)
    info "Testing tagging API via konk (current working state)..."
    info "  Checking if bulk-konk apiserver is reachable..."
    KONK_POD=$(kubectl get pods -n ${BULK_NS} -l app.kubernetes.io/name=konk -o name 2>/dev/null | head -1)
    if [[ -n "${KONK_POD}" ]]; then
        ok "bulk-konk pod found: ${KONK_POD}"
    else
        # Try alternate
        KONK_POD=$(kubectl get pods -n ${BULK_NS} -o name 2>/dev/null | grep "bulk-konk" | grep -v "etcd\|init" | head -1)
        if [[ -n "${KONK_POD}" ]]; then
            ok "bulk-konk pod found: ${KONK_POD}"
        else
            warn "bulk-konk pod not found in ${BULK_NS} namespace"
        fi
    fi

    # 8. Check bulk deployment
    info "Checking bulk deployment in ${BULK_NS} namespace..."
    BULK_READY=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    BULK_DESIRED=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
    if [[ "${BULK_READY}" -ge 1 ]]; then
        ok "Bulk deployment ${BULK_DEPLOYMENT} is running (${BULK_READY}/${BULK_DESIRED} ready)"
    else
        fail "Bulk deployment ${BULK_DEPLOYMENT} is NOT ready (${BULK_READY}/${BULK_DESIRED})"
    fi

    # 9. Check bulk konk secrets
    info "Checking bulk konk secrets in ${BULK_NS}..."
    if kubectl get secret ${BULK_KONK_KUBECONFIG_SECRET} -n ${BULK_NS} &>/dev/null; then
        ok "Bulk konk kubeconfig secret exists: ${BULK_KONK_KUBECONFIG_SECRET}"
    else
        warn "Bulk konk kubeconfig secret NOT found: ${BULK_KONK_KUBECONFIG_SECRET}"
    fi
    if kubectl get secret ${BULK_KONK_PROXY_CLIENT_SECRET} -n ${BULK_NS} &>/dev/null; then
        ok "Bulk konk proxy-client secret exists: ${BULK_KONK_PROXY_CLIENT_SECRET}"
    else
        warn "Bulk konk proxy-client secret NOT found: ${BULK_KONK_PROXY_CLIENT_SECRET}"
    fi

    echo ""
    echo "============================================"
    ok "Preflight complete. Review results above."
    echo "============================================"
}

# ============================================================================
# BACKUP: Save current state of everything we'll modify
# ============================================================================
backup() {
    echo ""
    echo "============================================"
    echo "  BACKUP"
    echo "============================================"
    echo ""

    mkdir -p "${BACKUP_DIR}"
    info "Backup directory: ${BACKUP_DIR}"

    # 1. Backup deployment
    info "Backing up deployment ${DEPLOYMENT_NAME}..."
    kubectl get deployment ${DEPLOYMENT_NAME} -n ${TAGGING_NS} -o yaml > "${BACKUP_DIR}/deployment.yaml"
    ok "Saved: ${BACKUP_DIR}/deployment.yaml"

    # 2. Backup konk TLS secret
    info "Backing up TLS secret..."
    if kubectl get secret ${KONK_TLS_SECRET} -n ${TAGGING_NS} -o yaml > "${BACKUP_DIR}/konk-tls-secret.yaml" 2>/dev/null; then
        ok "Saved: ${BACKUP_DIR}/konk-tls-secret.yaml"
    else
        warn "TLS secret ${KONK_TLS_SECRET} not found, skipping"
    fi

    # 3. Backup konk kubeconfig secret
    info "Backing up kubeconfig secret..."
    if kubectl get secret ${KONK_KUBECONFIG_SECRET} -n ${TAGGING_NS} -o yaml > "${BACKUP_DIR}/konk-kubeconfig-secret.yaml" 2>/dev/null; then
        ok "Saved: ${BACKUP_DIR}/konk-kubeconfig-secret.yaml"
    else
        warn "Kubeconfig secret ${KONK_KUBECONFIG_SECRET} not found, skipping"
    fi

    # 4. Backup KonkService CR
    info "Backing up KonkService CR..."
    if kubectl get konkservice ${SERVICE_NAME} -n ${TAGGING_NS} -o yaml > "${BACKUP_DIR}/konkservice.yaml" 2>/dev/null; then
        ok "Saved: ${BACKUP_DIR}/konkservice.yaml"
    else
        warn "KonkService CR not found, skipping"
    fi

    # 5. Backup service
    info "Backing up service ${SERVICE_NAME}..."
    if kubectl get service ${SERVICE_NAME} -n ${TAGGING_NS} -o yaml > "${BACKUP_DIR}/service.yaml" 2>/dev/null; then
        ok "Saved: ${BACKUP_DIR}/service.yaml"
    else
        warn "Service ${SERVICE_NAME} not found, skipping"
    fi

    # 6. Backup bulk deployment (in aggregate namespace)
    info "Backing up bulk deployment in ${BULK_NS} namespace..."
    if kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} -o yaml > "${BACKUP_DIR}/bulk-deployment.yaml" 2>/dev/null; then
        ok "Saved: ${BACKUP_DIR}/bulk-deployment.yaml"
    else
        warn "Bulk deployment ${BULK_DEPLOYMENT} not found in ${BULK_NS}, skipping"
    fi

    # 7. Backup bulk-konk-kubeconfig secret
    info "Backing up bulk konk kubeconfig secret..."
    if kubectl get secret ${BULK_KONK_KUBECONFIG_SECRET} -n ${BULK_NS} -o yaml > "${BACKUP_DIR}/bulk-konk-kubeconfig-secret.yaml" 2>/dev/null; then
        ok "Saved: ${BACKUP_DIR}/bulk-konk-kubeconfig-secret.yaml"
    else
        warn "Secret ${BULK_KONK_KUBECONFIG_SECRET} not found in ${BULK_NS}, skipping"
    fi

    # 8. Backup bulk-konk-proxy-client secret
    info "Backing up bulk konk proxy-client secret..."
    if kubectl get secret ${BULK_KONK_PROXY_CLIENT_SECRET} -n ${BULK_NS} -o yaml > "${BACKUP_DIR}/bulk-konk-proxy-client-secret.yaml" 2>/dev/null; then
        ok "Saved: ${BACKUP_DIR}/bulk-konk-proxy-client-secret.yaml"
    else
        warn "Secret ${BULK_KONK_PROXY_CLIENT_SECRET} not found in ${BULK_NS}, skipping"
    fi

    # 9. Save current pod status for reference
    info "Saving current pod status..."
    kubectl get pods -n ${TAGGING_NS} -o wide > "${BACKUP_DIR}/pods-before.txt" 2>/dev/null
    ok "Saved: ${BACKUP_DIR}/pods-before.txt"

    info "Saving bulk pod status..."
    kubectl get pods -n ${BULK_NS} -l app.kubernetes.io/name=${BULK_DEPLOYMENT} -o wide > "${BACKUP_DIR}/bulk-pods-before.txt" 2>/dev/null
    ok "Saved: ${BACKUP_DIR}/bulk-pods-before.txt"

    echo ""
    echo "============================================"
    ok "Backup complete: ${BACKUP_DIR}"
    echo "  Files:"
    ls -la "${BACKUP_DIR}/"
    echo "============================================"
    echo ""
    echo "  IMPORTANT: Note this backup directory path."
    echo "  You'll need it for rollback: ${BACKUP_DIR}"
}

# ============================================================================
# STEP 1: Generate self-signed TLS cert and create secret
# ============================================================================
step1_create_tls_cert() {
    echo ""
    echo "============================================"
    echo "  STEP 1: Create TLS certificate secret"
    echo "============================================"
    echo ""

    # Check if secret already exists
    if kubectl get secret ${VCLUSTER_TLS_SECRET} -n ${TAGGING_NS} &>/dev/null; then
        warn "Secret ${VCLUSTER_TLS_SECRET} already exists in ${TAGGING_NS}."
        read -p "  Overwrite? (y/N): " CONFIRM
        if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
            info "Skipping step 1."
            return 0
        fi
        kubectl delete secret ${VCLUSTER_TLS_SECRET} -n ${TAGGING_NS}
    fi

    info "Generating self-signed TLS certificate..."

    # Generate cert with SANs matching the service DNS names
    openssl req -x509 -newkey rsa:2048 \
        -keyout "${TMPDIR_CERTS}/tls.key" \
        -out "${TMPDIR_CERTS}/tls.crt" \
        -days 365 -nodes \
        -subj "/CN=${SERVICE_NAME}.${TAGGING_NS}" \
        -addext "subjectAltName=DNS:${SERVICE_NAME},DNS:${SERVICE_NAME}.${TAGGING_NS},DNS:${SERVICE_NAME}.${TAGGING_NS}.svc,DNS:${SERVICE_NAME}.${TAGGING_NS}.svc.cluster.local" \
        2>/dev/null

    ok "Certificate generated"
    echo "  CN: ${SERVICE_NAME}.${TAGGING_NS}"
    echo "  SANs: ${SERVICE_NAME}, ${SERVICE_NAME}.${TAGGING_NS}.svc.cluster.local"

    info "Creating secret ${VCLUSTER_TLS_SECRET} in ${TAGGING_NS}..."
    kubectl create secret tls ${VCLUSTER_TLS_SECRET} \
        -n ${TAGGING_NS} \
        --cert="${TMPDIR_CERTS}/tls.crt" \
        --key="${TMPDIR_CERTS}/tls.key"

    ok "Secret created: ${VCLUSTER_TLS_SECRET}"

    # Save the CA cert — we'll need it for the APIService caBundle (optional, for non-insecure mode)
    cp "${TMPDIR_CERTS}/tls.crt" "${TMPDIR_CERTS}/ca.crt"
    info "CA cert saved to ${TMPDIR_CERTS}/ca.crt (for APIService caBundle if needed)"

    # Verify
    info "Verifying secret..."
    kubectl get secret ${VCLUSTER_TLS_SECRET} -n ${TAGGING_NS}
    ok "Step 1 complete"
}

# ============================================================================
# STEP 2: Generate vcluster kubeconfig and create secret
# ============================================================================
step2_create_kubeconfig() {
    echo ""
    echo "============================================"
    echo "  STEP 2: Create vcluster kubeconfig secret"
    echo "============================================"
    echo ""

    # Check if secret already exists
    if kubectl get secret ${VCLUSTER_KUBECONFIG_SECRET} -n ${TAGGING_NS} &>/dev/null; then
        warn "Secret ${VCLUSTER_KUBECONFIG_SECRET} already exists in ${TAGGING_NS}."
        read -p "  Overwrite? (y/N): " CONFIRM
        if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
            info "Skipping step 2."
            return 0
        fi
        kubectl delete secret ${VCLUSTER_KUBECONFIG_SECRET} -n ${TAGGING_NS}
    fi

    # Try to find the vcluster kubeconfig secret
    info "Extracting vcluster kubeconfig..."

    KUBECONFIG_RAW=""
    # Method 1: vc-<name> secret (vcluster stores admin kubeconfig here)
    if kubectl get secret "vc-${VCLUSTER_NAME}" -n ${VCLUSTER_NS} &>/dev/null; then
        info "  Found secret: vc-${VCLUSTER_NAME}"
        KUBECONFIG_RAW=$(kubectl get secret "vc-${VCLUSTER_NAME}" -n ${VCLUSTER_NS} \
            -o jsonpath='{.data.config}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi

    # Method 2: Check for config in different key
    if [[ -z "${KUBECONFIG_RAW}" ]]; then
        KUBECONFIG_RAW=$(kubectl get secret "vc-${VCLUSTER_NAME}" -n ${VCLUSTER_NS} \
            -o jsonpath='{.data.config\.yaml}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi

    # Method 3: vc-config-<name>
    if [[ -z "${KUBECONFIG_RAW}" ]]; then
        if kubectl get secret "vc-config-${VCLUSTER_NAME}" -n ${VCLUSTER_NS} &>/dev/null; then
            info "  Trying secret: vc-config-${VCLUSTER_NAME}"
            KUBECONFIG_RAW=$(kubectl get secret "vc-config-${VCLUSTER_NAME}" -n ${VCLUSTER_NS} \
                -o jsonpath='{.data.config}' 2>/dev/null | base64 -d 2>/dev/null || true)
        fi
    fi

    # Method 4: Try vcluster CLI
    if [[ -z "${KUBECONFIG_RAW}" ]] && command -v vcluster &>/dev/null; then
        info "  Trying vcluster CLI..."
        KUBECONFIG_RAW=$(vcluster connect ${VCLUSTER_NAME} --namespace ${VCLUSTER_NS} --print 2>/dev/null || true)
    fi

    if [[ -z "${KUBECONFIG_RAW}" ]]; then
        fail "Could not extract vcluster kubeconfig!"
        echo ""
        echo "  Debug: List all secrets in ${VCLUSTER_NS}:"
        kubectl get secrets -n ${VCLUSTER_NS} | grep -i "vc\|vcluster\|config" || true
        echo ""
        echo "  You can manually extract and provide the kubeconfig:"
        echo "    kubectl get secret <secret-name> -n ${VCLUSTER_NS} -o jsonpath='{.data.config}' | base64 -d > /tmp/vcluster-kc.yaml"
        echo "    # Edit server URL to: https://${VCLUSTER_NAME}.${VCLUSTER_NS}:443"
        echo "    kubectl create secret generic ${VCLUSTER_KUBECONFIG_SECRET} -n ${TAGGING_NS} --from-file=admin.conf=/tmp/vcluster-kc.yaml"
        return 1
    fi

    ok "Extracted vcluster kubeconfig"

    # Rewrite server URL to internal cluster DNS
    info "Rewriting server URL to internal DNS..."
    # NOTE: Use short DNS name (not .svc.cluster.local) because vcluster's TLS cert
    # only includes 'vcluster.vcluster' as a SAN, not the FQDN.
    INTERNAL_URL="https://${VCLUSTER_NAME}.${VCLUSTER_NS}:443"

    KUBECONFIG_FIXED=$(echo "${KUBECONFIG_RAW}" | \
        sed -E "s|server: https?://[^[:space:]]+|server: ${INTERNAL_URL}|g")

    echo "${KUBECONFIG_FIXED}" > "${TMPDIR_CERTS}/admin.conf"
    ok "Server URL rewritten to: ${INTERNAL_URL}"

    # Show what we're creating (redact sensitive data)
    info "Kubeconfig preview (server only):"
    echo "${KUBECONFIG_FIXED}" | grep "server:" | head -1

    # Create the secret
    info "Creating secret ${VCLUSTER_KUBECONFIG_SECRET} in ${TAGGING_NS}..."
    kubectl create secret generic ${VCLUSTER_KUBECONFIG_SECRET} \
        -n ${TAGGING_NS} \
        --from-file=admin.conf="${TMPDIR_CERTS}/admin.conf"

    ok "Secret created: ${VCLUSTER_KUBECONFIG_SECRET}"

    # Verify
    info "Verifying secret has admin.conf key..."
    kubectl get secret ${VCLUSTER_KUBECONFIG_SECRET} -n ${TAGGING_NS} -o jsonpath='{.data}' | python3 -c "
import sys, json
data = json.load(sys.stdin)
for k in data:
    print(f'  Key: {k} ({len(data[k])} chars base64)')
" 2>/dev/null || kubectl get secret ${VCLUSTER_KUBECONFIG_SECRET} -n ${TAGGING_NS}

    ok "Step 2 complete"
}

# ============================================================================
# STEP 3: Register APIService + ExternalName + RBAC inside vcluster
# ============================================================================
step3_register_in_vcluster() {
    echo ""
    echo "============================================"
    echo "  STEP 3: Register APIService inside vcluster"
    echo "============================================"
    echo ""

    # Create the manifest to apply inside vcluster
    VCLUSTER_MANIFEST="${TMPDIR_CERTS}/vcluster-apiservice.yaml"

    cat > "${VCLUSTER_MANIFEST}" <<VCLUSTER_EOF
---
# Namespace inside vcluster for the service reference
apiVersion: v1
kind: Namespace
metadata:
  name: ${TAGGING_NS}
---
# ExternalName Service inside vcluster → points to host cluster service
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
  namespace: ${TAGGING_NS}
spec:
  type: ExternalName
  externalName: ${SERVICE_NAME}.${TAGGING_NS}.svc.cluster.local
  ports:
  - port: 443
    targetPort: 443
    protocol: TCP
---
# APIService registration inside vcluster
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  name: ${API_VERSION}.${API_GROUP}
spec:
  group: ${API_GROUP}
  version: ${API_VERSION}
  groupPriorityMinimum: 1000
  versionPriority: 100
  insecureSkipTLSVerify: true
  service:
    name: ${SERVICE_NAME}
    namespace: ${TAGGING_NS}
    port: 443
---
# RBAC: Allow delegated auth (TokenReview + SubjectAccessReview)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${DEPLOYMENT_NAME}-delegated-auth
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
  name: ${DEPLOYMENT_NAME}-delegated-auth
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${DEPLOYMENT_NAME}-delegated-auth
subjects:
- kind: User
  name: ${DEPLOYMENT_NAME}
  apiGroup: rbac.authorization.k8s.io
# Also allow the kubeconfig user (may use a different identity)
- kind: Group
  name: system:masters
  apiGroup: rbac.authorization.k8s.io
VCLUSTER_EOF

    info "Manifest to apply inside vcluster:"
    echo "  ${VCLUSTER_MANIFEST}"
    echo ""
    cat "${VCLUSTER_MANIFEST}"
    echo ""

    # Connect to vcluster and apply
    info "Connecting to vcluster and applying manifest..."

    if command -v vcluster &>/dev/null; then
        info "Using vcluster CLI to connect..."

        # Save current context so we can switch back
        ORIGINAL_CTX=$(kubectl config current-context)

        # Connect and apply
        vcluster connect ${VCLUSTER_NAME} --namespace ${VCLUSTER_NS} -- kubectl apply -f "${VCLUSTER_MANIFEST}" 2>&1 || {
            # If the above fails, try connecting first then applying
            warn "Direct apply failed. Trying connect + apply..."
            vcluster connect ${VCLUSTER_NAME} --namespace ${VCLUSTER_NS} &
            VCLUSTER_PID=$!
            sleep 5

            kubectl apply -f "${VCLUSTER_MANIFEST}" 2>&1 || {
                fail "Failed to apply manifest inside vcluster"
                kill ${VCLUSTER_PID} 2>/dev/null || true
                return 1
            }

            kill ${VCLUSTER_PID} 2>/dev/null || true
        }

        # Switch back to original context
        kubectl config use-context "${ORIGINAL_CTX}" 2>/dev/null || true
    else
        warn "vcluster CLI not found. Trying kubectl with vcluster context..."
        echo ""
        echo "  Available contexts with 'vcluster' in name:"
        kubectl config get-contexts -o name 2>/dev/null | grep -i vcluster || echo "  (none found)"
        echo ""
        echo "  Manual steps:"
        echo "    1. vcluster connect ${VCLUSTER_NAME} --namespace ${VCLUSTER_NS}"
        echo "    2. kubectl apply -f ${VCLUSTER_MANIFEST}"
        echo "    3. Switch back to host context"
        echo ""
        echo "  Or install vcluster CLI: brew install loft-sh/tap/vcluster"
        return 1
    fi

    # Verify (connect to vcluster again briefly)
    info "Verifying APIService registration inside vcluster..."
    vcluster connect ${VCLUSTER_NAME} --namespace ${VCLUSTER_NS} -- \
        kubectl get apiservices 2>&1 | grep "${API_GROUP}" || {
        warn "Could not verify APIService. You can check manually:"
        echo "  vcluster connect ${VCLUSTER_NAME} --namespace ${VCLUSTER_NS}"
        echo "  kubectl get apiservices | grep ${API_GROUP}"
    }

    ok "Step 3 complete"
}

# ============================================================================
# STEP 4: Patch tagging-aggregate-api deployment to use vcluster secrets
# ============================================================================
step4_patch_deployment() {
    echo ""
    echo "============================================"
    echo "  STEP 4: Patch deployment to use vcluster"
    echo "============================================"
    echo ""

    # Verify new secrets exist before patching
    info "Verifying new secrets exist..."
    if ! kubectl get secret ${VCLUSTER_TLS_SECRET} -n ${TAGGING_NS} &>/dev/null; then
        fail "TLS secret ${VCLUSTER_TLS_SECRET} not found. Run step 1 first."
        return 1
    fi
    ok "TLS secret found: ${VCLUSTER_TLS_SECRET}"

    if ! kubectl get secret ${VCLUSTER_KUBECONFIG_SECRET} -n ${TAGGING_NS} &>/dev/null; then
        fail "Kubeconfig secret ${VCLUSTER_KUBECONFIG_SECRET} not found. Run step 2 first."
        return 1
    fi
    ok "Kubeconfig secret found: ${VCLUSTER_KUBECONFIG_SECRET}"

    # Show current state
    info "Current deployment volume secrets:"
    kubectl get deployment ${DEPLOYMENT_NAME} -n ${TAGGING_NS} -o jsonpath='{.spec.template.spec.volumes}' | \
        python3 -c "
import sys, json
vols = json.load(sys.stdin)
for v in vols:
    secret = v.get('secret', {}).get('secretName', 'N/A')
    print(f\"  Volume '{v['name']}' → secret '{secret}'\")
" 2>/dev/null || {
        kubectl get deployment ${DEPLOYMENT_NAME} -n ${TAGGING_NS} -o yaml | grep secretName
    }

    echo ""
    warn "This will patch the deployment to use:"
    echo "  apiserver-cert → ${VCLUSTER_TLS_SECRET}"
    echo "  kubeconfig     → ${VCLUSTER_KUBECONFIG_SECRET}"
    echo ""
    echo "  The pod will restart with the new secrets."
    echo ""
    read -p "  Continue? (y/N): " CONFIRM
    if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
        info "Aborted."
        return 0
    fi

    # Patch the deployment using strategic merge patch
    # We need to update the secret names in the volumes
    info "Patching deployment..."

    # The TLS secret key names differ: konk uses 'apiserver.crt'/'apiserver.key', our new TLS secret uses 'tls.crt'/'tls.key'
    # The mount path is /tmp/k8s-apiserver-server/serving-certs/ and the args reference tls.crt and tls.key
    # So we need to project the keys correctly

    kubectl get deployment ${DEPLOYMENT_NAME} -n ${TAGGING_NS} -o json | \
        python3 -c "
import sys, json

deploy = json.load(sys.stdin)
volumes = deploy['spec']['template']['spec']['volumes']

for vol in volumes:
    if vol['name'] == 'apiserver-cert':
        old_secret = vol.get('secret', {}).get('secretName', 'unknown')
        vol['secret']['secretName'] = '${VCLUSTER_TLS_SECRET}'
        # The tagging binary expects files named tls.crt and tls.key
        # kubectl create secret tls creates keys 'tls.crt' and 'tls.key' by default
        # which matches the --tls-cert-file and --tls-private-key-file args
        print(f'  Patched apiserver-cert: {old_secret} → ${VCLUSTER_TLS_SECRET}', file=sys.stderr)
    elif vol['name'] == 'kubeconfig':
        old_secret = vol.get('secret', {}).get('secretName', 'unknown')
        vol['secret']['secretName'] = '${VCLUSTER_KUBECONFIG_SECRET}'
        print(f'  Patched kubeconfig: {old_secret} → ${VCLUSTER_KUBECONFIG_SECRET}', file=sys.stderr)

# Clean metadata for replace
deploy['metadata'].pop('resourceVersion', None)
deploy['metadata'].pop('uid', None)
deploy['metadata'].pop('creationTimestamp', None)
deploy['metadata'].pop('generation', None)
deploy['metadata'].get('annotations', {}).pop('kubectl.kubernetes.io/last-applied-configuration', None)
deploy['metadata'].get('annotations', {}).pop('deployment.kubernetes.io/revision', None)
deploy.pop('status', None)

json.dump(deploy, sys.stdout)
" | kubectl apply -f - 2>&1

    ok "Deployment patched"

    # Wait for rollout
    info "Waiting for rollout (timeout: 120s)..."
    kubectl rollout status deployment/${DEPLOYMENT_NAME} -n ${TAGGING_NS} --timeout=120s 2>&1 || {
        warn "Rollout may not have completed. Check pod status:"
        kubectl get pods -n ${TAGGING_NS} -l app.kubernetes.io/name=${DEPLOYMENT_NAME}
    }

    # Show new pod status
    info "New pod status:"
    kubectl get pods -n ${TAGGING_NS} -l app.kubernetes.io/name=${DEPLOYMENT_NAME} -o wide

    # Show pod logs (last 10 lines)
    info "Pod logs (last 10 lines):"
    POD_NAME=$(kubectl get pods -n ${TAGGING_NS} -l app.kubernetes.io/name=${DEPLOYMENT_NAME} -o name | head -1)
    if [[ -n "${POD_NAME}" ]]; then
        kubectl logs ${POD_NAME} -n ${TAGGING_NS} --tail=10 2>/dev/null || warn "Could not get logs"
    fi

    ok "Step 4 complete"
}

# ============================================================================
# STEP 5: Migrate bulk deployment from konk to vcluster
# ============================================================================
step5_migrate_bulk() {
    echo ""
    echo "============================================"
    echo "  STEP 5: Migrate bulk deployment to vcluster"
    echo "============================================"
    echo ""

    # The bulk deployment in the aggregate namespace uses konk to proxy
    # requests to the tagging-aggregate-api. After migrating tagging to
    # vcluster (steps 1-4), we must also point bulk at vcluster.
    #
    # What we change:
    #   1. Copy vcluster kubeconfig and proxy-client secrets from tagging-v2 to aggregate
    #   2. Patch bulk deployment:
    #      - --konk.host arg: bulk-konk.aggregate:6443 → vcluster.vcluster:443
    #      - kubeconfig volume: bulk-konk-kubeconfig → bulk-vcluster-kubeconfig
    #      - proxy-client-cert volume: bulk-konk-proxy-client → bulk-vcluster-proxy-client

    # --- Part A: Copy vcluster secrets to aggregate namespace ---
    info "Copying vcluster secrets from ${TAGGING_NS} to ${BULK_NS} namespace..."

    # Check source secrets exist
    if ! kubectl get secret ${VCLUSTER_KUBECONFIG_SECRET} -n ${TAGGING_NS} &>/dev/null; then
        fail "Source secret ${VCLUSTER_KUBECONFIG_SECRET} not found in ${TAGGING_NS}. Run step 2 first."
        return 1
    fi
    if ! kubectl get secret ${VCLUSTER_TLS_SECRET} -n ${TAGGING_NS} &>/dev/null; then
        fail "Source secret ${VCLUSTER_TLS_SECRET} not found in ${TAGGING_NS}. Run step 1 first."
        return 1
    fi

    # Copy kubeconfig secret → bulk-vcluster-kubeconfig in aggregate
    if kubectl get secret ${BULK_VCLUSTER_KUBECONFIG_SECRET} -n ${BULK_NS} &>/dev/null; then
        info "Secret ${BULK_VCLUSTER_KUBECONFIG_SECRET} already exists in ${BULK_NS}, updating..."
        kubectl get secret ${VCLUSTER_KUBECONFIG_SECRET} -n ${TAGGING_NS} -o json | \
            python3 -c "
import sys, json
s = json.load(sys.stdin)
s['metadata'] = {'name': '${BULK_VCLUSTER_KUBECONFIG_SECRET}', 'namespace': '${BULK_NS}'}
json.dump(s, sys.stdout)
" | kubectl apply -f - 2>&1
    else
        kubectl get secret ${VCLUSTER_KUBECONFIG_SECRET} -n ${TAGGING_NS} -o json | \
            python3 -c "
import sys, json
s = json.load(sys.stdin)
s['metadata'] = {'name': '${BULK_VCLUSTER_KUBECONFIG_SECRET}', 'namespace': '${BULK_NS}'}
json.dump(s, sys.stdout)
" | kubectl create -f - 2>&1
    fi
    ok "Copied kubeconfig → ${BULK_VCLUSTER_KUBECONFIG_SECRET} in ${BULK_NS}"

    # Create proxy-client secret from vcluster admin kubeconfig client cert
    # NOTE: The proxy-client secret must contain the CLIENT cert/key/CA from the
    # vcluster admin kubeconfig, NOT the server TLS cert. Using the server cert
    # causes "Unauthorized" errors because bulk uses this cert to authenticate
    # as a client to the vcluster API server (requestheader proxy auth).
    info "Extracting client cert/key/CA from vcluster kubeconfig for proxy-client secret..."

    # Extract client-certificate-data, client-key-data, certificate-authority-data
    # from the admin.conf in the vcluster kubeconfig secret
    PROXY_CLIENT_JSON=$(kubectl get secret ${VCLUSTER_KUBECONFIG_SECRET} -n ${TAGGING_NS} -o jsonpath='{.data.admin\.conf}' | \
        base64 -d | python3 -c "
import sys, yaml, base64, json

kc = yaml.safe_load(sys.stdin)
user = kc['users'][0]['user']
cluster = kc['clusters'][0]['cluster']

# These are already base64-encoded inside the kubeconfig YAML,
# but yaml.safe_load decodes them to raw bytes via base64 decoding.
# We need to re-encode for the K8s secret.
client_cert = base64.b64encode(base64.b64decode(user['client-certificate-data'])).decode()
client_key = base64.b64encode(base64.b64decode(user['client-key-data'])).decode()
ca_cert = base64.b64encode(base64.b64decode(cluster['certificate-authority-data'])).decode()

secret = {
    'apiVersion': 'v1',
    'kind': 'Secret',
    'metadata': {
        'name': '${BULK_VCLUSTER_PROXY_CLIENT_SECRET}',
        'namespace': '${BULK_NS}'
    },
    'type': 'Opaque',
    'data': {
        'tls.crt': client_cert,
        'tls.key': client_key,
        'ca.crt': ca_cert
    }
}
json.dump(secret, sys.stdout)
" 2>&1)

    if [[ -z "${PROXY_CLIENT_JSON}" || "${PROXY_CLIENT_JSON}" == *"error"* ]]; then
        fail "Failed to extract client cert from vcluster kubeconfig"
        echo "${PROXY_CLIENT_JSON}"
        return 1
    fi

    if kubectl get secret ${BULK_VCLUSTER_PROXY_CLIENT_SECRET} -n ${BULK_NS} &>/dev/null; then
        info "Secret ${BULK_VCLUSTER_PROXY_CLIENT_SECRET} already exists, deleting and recreating..."
        kubectl delete secret ${BULK_VCLUSTER_PROXY_CLIENT_SECRET} -n ${BULK_NS} 2>&1
    fi
    echo "${PROXY_CLIENT_JSON}" | kubectl create -f - 2>&1
    ok "Created proxy-client secret ${BULK_VCLUSTER_PROXY_CLIENT_SECRET} in ${BULK_NS} (from vcluster admin client cert)"

    echo ""

    # --- Part B: Patch bulk deployment ---
    info "Current bulk deployment konk settings:"
    kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} -o jsonpath='{.spec.template.spec.containers[0].args}' | \
        python3 -c "
import sys, json
args = json.load(sys.stdin)
for i, a in enumerate(args):
    if 'konk.host' in a:
        print(f'  arg[{i}]: {a}')
" 2>/dev/null || true
    kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} -o jsonpath='{.spec.template.spec.volumes}' | \
        python3 -c "
import sys, json
vols = json.load(sys.stdin)
for v in vols:
    secret = v.get('secret', {}).get('secretName', 'N/A')
    print(f\"  Volume '{v['name']}' → secret '{secret}'\")
" 2>/dev/null || true

    echo ""
    warn "This will patch the bulk deployment to use:"
    echo "  --konk.host         → ${VCLUSTER_HOST}"
    echo "  kubeconfig volume   → ${BULK_VCLUSTER_KUBECONFIG_SECRET}"
    echo "  proxy-client volume → ${BULK_VCLUSTER_PROXY_CLIENT_SECRET}"
    echo ""
    echo "  The bulk pods will restart with vcluster connectivity."
    echo ""
    read -p "  Continue? (y/N): " CONFIRM
    if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
        info "Aborted."
        return 0
    fi

    info "Patching bulk deployment..."

    # Patch 1: Update --konk.host arg (find the arg index dynamically)
    KONK_HOST_INDEX=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} -o jsonpath='{.spec.template.spec.containers[0].args}' | \
        python3 -c "
import sys, json
args = json.load(sys.stdin)
for i, a in enumerate(args):
    if a.startswith('--konk.host='):
        print(i)
        break
else:
    print(-1)
" 2>/dev/null)

    if [[ "${KONK_HOST_INDEX}" == "-1" || -z "${KONK_HOST_INDEX}" ]]; then
        fail "Could not find --konk.host arg in bulk deployment"
        return 1
    fi
    info "  Found --konk.host at args index ${KONK_HOST_INDEX}"

    kubectl patch deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} --type='json' \
        -p="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/args/${KONK_HOST_INDEX}\", \"value\": \"--konk.host=${VCLUSTER_HOST}\"}]" 2>&1
    ok "  Patched --konk.host → ${VCLUSTER_HOST}"

    # Patch 2: Update kubeconfig volume (find the volume index dynamically)
    KUBECONFIG_VOL_INDEX=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} -o jsonpath='{.spec.template.spec.volumes}' | \
        python3 -c "
import sys, json
vols = json.load(sys.stdin)
for i, v in enumerate(vols):
    if v['name'] == 'kubeconfig':
        print(i)
        break
else:
    print(-1)
" 2>/dev/null)

    if [[ "${KUBECONFIG_VOL_INDEX}" != "-1" && -n "${KUBECONFIG_VOL_INDEX}" ]]; then
        kubectl patch deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} --type='json' \
            -p="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/volumes/${KUBECONFIG_VOL_INDEX}/secret/secretName\", \"value\": \"${BULK_VCLUSTER_KUBECONFIG_SECRET}\"}]" 2>&1
        ok "  Patched kubeconfig volume → ${BULK_VCLUSTER_KUBECONFIG_SECRET}"
    else
        warn "  Could not find 'kubeconfig' volume, skipping"
    fi

    # Patch 3: Update proxy-client-cert volume (find the volume index dynamically)
    PROXY_VOL_INDEX=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} -o jsonpath='{.spec.template.spec.volumes}' | \
        python3 -c "
import sys, json
vols = json.load(sys.stdin)
for i, v in enumerate(vols):
    if v['name'] == 'proxy-client-cert':
        print(i)
        break
else:
    print(-1)
" 2>/dev/null)

    if [[ "${PROXY_VOL_INDEX}" != "-1" && -n "${PROXY_VOL_INDEX}" ]]; then
        kubectl patch deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} --type='json' \
            -p="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/volumes/${PROXY_VOL_INDEX}/secret/secretName\", \"value\": \"${BULK_VCLUSTER_PROXY_CLIENT_SECRET}\"}]" 2>&1
        ok "  Patched proxy-client-cert volume → ${BULK_VCLUSTER_PROXY_CLIENT_SECRET}"
    else
        warn "  Could not find 'proxy-client-cert' volume, skipping"
    fi

    # Wait for rollout
    info "Waiting for bulk deployment rollout (timeout: 120s)..."
    kubectl rollout status deployment/${BULK_DEPLOYMENT} -n ${BULK_NS} --timeout=120s 2>&1 || {
        warn "Rollout may not have completed. Check pod status:"
        kubectl get pods -n ${BULK_NS} -l app.kubernetes.io/name=${BULK_DEPLOYMENT}
    }

    # Show new pod status
    info "New bulk pod status:"
    kubectl get pods -n ${BULK_NS} -l app.kubernetes.io/name=${BULK_DEPLOYMENT} -o wide

    # Show pod logs (last 10 lines)
    info "Bulk pod logs (last 10 lines):"
    BULK_POD_NAME=$(kubectl get pods -n ${BULK_NS} -l app.kubernetes.io/name=${BULK_DEPLOYMENT} -o name | head -1)
    if [[ -n "${BULK_POD_NAME}" ]]; then
        kubectl logs ${BULK_POD_NAME} -n ${BULK_NS} --tail=10 2>/dev/null || warn "Could not get bulk pod logs"
    fi

    ok "Step 5 complete"
}

# ============================================================================
# VERIFY: Test tagging API works through vcluster
# ============================================================================
verify() {
    echo ""
    echo "============================================"
    echo "  VERIFY: Test tagging API via vcluster"
    echo "============================================"
    echo ""

    # 1. Check pod is running
    info "Checking pod status..."
    kubectl get pods -n ${TAGGING_NS} -l app.kubernetes.io/name=${DEPLOYMENT_NAME} -o wide
    echo ""

    READY=$(kubectl get deployment ${DEPLOYMENT_NAME} -n ${TAGGING_NS} \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${READY}" -ge 1 ]]; then
        ok "Pod is running and ready"
    else
        fail "Pod is NOT ready"
        echo ""
        info "Pod events:"
        POD_NAME=$(kubectl get pods -n ${TAGGING_NS} -l app.kubernetes.io/name=${DEPLOYMENT_NAME} -o name | head -1)
        kubectl describe ${POD_NAME} -n ${TAGGING_NS} 2>/dev/null | tail -20 || true
        echo ""
        info "Pod logs:"
        kubectl logs ${POD_NAME} -n ${TAGGING_NS} --tail=20 2>/dev/null || true
        return 1
    fi

    # 2. Test health endpoint directly on the host service
    info "Testing health endpoint on host service..."
    kubectl run -n ${TAGGING_NS} vcluster-verify-health \
        --image=curlimages/curl --rm -it --restart=Never --timeout=30s \
        -- curl -sk "https://${SERVICE_NAME}.${TAGGING_NS}.svc.cluster.local:443/healthz" 2>/dev/null || {
        warn "Health check via curl pod failed (may be network policy). Trying port-forward..."
    }

    # 3. Test APIService via vcluster
    info "Testing APIService inside vcluster..."
    if command -v vcluster &>/dev/null; then
        echo ""
        info "Checking APIService status:"
        vcluster connect ${VCLUSTER_NAME} --namespace ${VCLUSTER_NS} -- \
            kubectl get apiservices 2>&1 | grep "${API_GROUP}" || warn "APIService not found"
        echo ""

        info "Testing API discovery:"
        vcluster connect ${VCLUSTER_NAME} --namespace ${VCLUSTER_NS} -- \
            kubectl get --raw "/apis/${API_GROUP}/${API_VERSION}" 2>&1 | \
            python3 -m json.tool 2>/dev/null || warn "API discovery failed"
        echo ""

        info "Testing resource listing:"
        vcluster connect ${VCLUSTER_NAME} --namespace ${VCLUSTER_NS} -- \
            kubectl get --raw "/apis/${API_GROUP}/${API_VERSION}/namespaces/default/tags" 2>&1 | \
            python3 -m json.tool 2>/dev/null || warn "Resource listing failed"
    else
        warn "vcluster CLI not installed. Test manually:"
        echo "  vcluster connect ${VCLUSTER_NAME} --namespace ${VCLUSTER_NS}"
        echo "  kubectl get apiservices | grep ${API_GROUP}"
        echo "  kubectl get --raw /apis/${API_GROUP}/${API_VERSION}"
    fi

    echo ""
    echo "============================================"
    echo "  Verify: Tagging API checks complete."
    echo "============================================"
    echo ""

    # --- Bulk deployment verification ---
    echo "============================================"
    echo "  Verify: Bulk deployment health"
    echo "============================================"
    echo ""

    # 4. Check bulk pods are running
    info "Checking bulk pod status..."
    kubectl get pods -n ${BULK_NS} -l app.kubernetes.io/name=${BULK_DEPLOYMENT} -o wide
    echo ""

    BULK_READY=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    BULK_DESIRED=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
    if [[ "${BULK_READY}" -ge 1 ]]; then
        ok "Bulk deployment is running (${BULK_READY}/${BULK_DESIRED} ready)"
    else
        fail "Bulk deployment is NOT ready (${BULK_READY}/${BULK_DESIRED})"
        BULK_POD=$(kubectl get pods -n ${BULK_NS} -l app.kubernetes.io/name=${BULK_DEPLOYMENT} -o name | head -1)
        if [[ -n "${BULK_POD}" ]]; then
            info "Bulk pod logs:"
            kubectl logs ${BULK_POD} -n ${BULK_NS} --tail=20 2>/dev/null || true
        fi
    fi

    # 5. Verify bulk deployment is now pointing to vcluster
    info "Verifying bulk deployment points to vcluster..."
    CURRENT_KONK_HOST=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} \
        -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | \
        python3 -c "
import sys, json
args = json.load(sys.stdin)
for a in args:
    if a.startswith('--konk.host='):
        print(a.split('=',1)[1])
        break
" 2>/dev/null || echo "unknown")
    if [[ "${CURRENT_KONK_HOST}" == "${VCLUSTER_HOST}" ]]; then
        ok "Bulk --konk.host is set to ${VCLUSTER_HOST}"
    else
        warn "Bulk --konk.host is '${CURRENT_KONK_HOST}', expected '${VCLUSTER_HOST}'"
    fi

    # 6. Check bulk pod logs for errors
    info "Checking bulk pod logs for errors..."
    BULK_POD=$(kubectl get pods -n ${BULK_NS} -l app.kubernetes.io/name=${BULK_DEPLOYMENT} -o name | head -1)
    if [[ -n "${BULK_POD}" ]]; then
        BULK_ERRORS=$(kubectl logs ${BULK_POD} -n ${BULK_NS} --tail=50 2>/dev/null | \
            grep -ci "error\|x509\|connection refused\|timeout" 2>/dev/null || echo "0")
        if [[ "${BULK_ERRORS}" -eq 0 ]]; then
            ok "No errors in bulk pod logs (last 50 lines)"
        else
            warn "Found ${BULK_ERRORS} potential error lines in bulk pod logs"
            kubectl logs ${BULK_POD} -n ${BULK_NS} --tail=50 2>/dev/null | \
                grep -i "error\|x509\|connection refused\|timeout" | head -5 || true
        fi
    fi

    echo ""
    echo "============================================"
    echo "  All verification checks complete."
    echo "  Review results above."
    echo "============================================"
}

# ============================================================================
# ROLLBACK: Restore to konk-based working state
# ============================================================================
rollback() {
    echo ""
    echo "============================================"
    echo "  ROLLBACK: Restore konk-based state"
    echo "============================================"
    echo ""

    # Find the most recent backup directory
    if [[ -n "${2:-}" && -d "${2}" ]]; then
        RESTORE_DIR="${2}"
    else
        RESTORE_DIR=$(ls -dt ./backup-tagging-konk-* 2>/dev/null | head -1)
    fi

    if [[ -z "${RESTORE_DIR}" || ! -d "${RESTORE_DIR}" ]]; then
        fail "No backup directory found!"
        echo "  Usage: $0 rollback [backup-dir]"
        echo "  Example: $0 rollback ./backup-tagging-konk-20260223-143000"
        echo ""
        echo "  Available backups:"
        ls -d ./backup-tagging-konk-* 2>/dev/null || echo "  (none)"
        return 1
    fi

    info "Restoring from: ${RESTORE_DIR}"
    echo ""

    # 1. Restore tagging deployment (this is the main change to roll back)
    if [[ -f "${RESTORE_DIR}/deployment.yaml" ]]; then
        info "Restoring tagging deployment..."
        kubectl apply -f "${RESTORE_DIR}/deployment.yaml" 2>&1
        ok "Tagging deployment restored"
    else
        fail "deployment.yaml not found in backup!"
        return 1
    fi

    # 2. Wait for tagging rollout
    info "Waiting for tagging rollout..."
    kubectl rollout status deployment/${DEPLOYMENT_NAME} -n ${TAGGING_NS} --timeout=120s 2>&1 || {
        warn "Tagging rollout may not have completed"
    }

    # 3. Restore bulk deployment
    if [[ -f "${RESTORE_DIR}/bulk-deployment.yaml" ]]; then
        info "Restoring bulk deployment..."
        kubectl apply -f "${RESTORE_DIR}/bulk-deployment.yaml" 2>&1
        ok "Bulk deployment restored"

        info "Waiting for bulk rollout..."
        kubectl rollout status deployment/${BULK_DEPLOYMENT} -n ${BULK_NS} --timeout=120s 2>&1 || {
            warn "Bulk rollout may not have completed"
        }
    else
        info "No bulk-deployment.yaml in backup, skipping bulk restore"
    fi

    # 4. Clean up vcluster secrets from tagging namespace (optional — they don't hurt anything)
    info "Cleaning up vcluster secrets from ${TAGGING_NS}..."
    kubectl delete secret ${VCLUSTER_TLS_SECRET} -n ${TAGGING_NS} 2>/dev/null && \
        ok "Deleted: ${VCLUSTER_TLS_SECRET}" || \
        info "Secret ${VCLUSTER_TLS_SECRET} not found (already clean)"

    kubectl delete secret ${VCLUSTER_KUBECONFIG_SECRET} -n ${TAGGING_NS} 2>/dev/null && \
        ok "Deleted: ${VCLUSTER_KUBECONFIG_SECRET}" || \
        info "Secret ${VCLUSTER_KUBECONFIG_SECRET} not found (already clean)"

    # 5. Clean up vcluster secrets from aggregate namespace
    info "Cleaning up vcluster secrets from ${BULK_NS}..."
    kubectl delete secret ${BULK_VCLUSTER_KUBECONFIG_SECRET} -n ${BULK_NS} 2>/dev/null && \
        ok "Deleted: ${BULK_VCLUSTER_KUBECONFIG_SECRET} from ${BULK_NS}" || \
        info "Secret ${BULK_VCLUSTER_KUBECONFIG_SECRET} not found in ${BULK_NS} (already clean)"

    kubectl delete secret ${BULK_VCLUSTER_PROXY_CLIENT_SECRET} -n ${BULK_NS} 2>/dev/null && \
        ok "Deleted: ${BULK_VCLUSTER_PROXY_CLIENT_SECRET} from ${BULK_NS}" || \
        info "Secret ${BULK_VCLUSTER_PROXY_CLIENT_SECRET} not found in ${BULK_NS} (already clean)"

    # 6. Clean up APIService inside vcluster (optional)
    if command -v vcluster &>/dev/null; then
        info "Cleaning up APIService inside vcluster..."
        vcluster connect ${VCLUSTER_NAME} --namespace ${VCLUSTER_NS} -- \
            kubectl delete apiservice "${API_VERSION}.${API_GROUP}" 2>/dev/null && \
            ok "Deleted APIService inside vcluster" || \
            info "APIService not found inside vcluster (already clean)"
    fi

    # 7. Verify pods are back to working state
    echo ""
    info "Checking restored tagging pod status..."
    kubectl get pods -n ${TAGGING_NS} -l app.kubernetes.io/name=${DEPLOYMENT_NAME} -o wide

    READY=$(kubectl get deployment ${DEPLOYMENT_NAME} -n ${TAGGING_NS} \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${READY}" -ge 1 ]]; then
        ok "Tagging pod is running and ready"
    else
        warn "Tagging pod not ready yet. Give it a minute and check:"
        echo "  kubectl get pods -n ${TAGGING_NS} -l app.kubernetes.io/name=${DEPLOYMENT_NAME}"
    fi

    info "Checking restored bulk pod status..."
    kubectl get pods -n ${BULK_NS} -l app.kubernetes.io/name=${BULK_DEPLOYMENT} -o wide
    BULK_READY=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${BULK_READY}" -ge 1 ]]; then
        ok "Bulk pod is running and ready"
    else
        warn "Bulk pod not ready yet. Give it a minute and check:"
        echo "  kubectl get pods -n ${BULK_NS} -l app.kubernetes.io/name=${BULK_DEPLOYMENT}"
    fi

    echo ""
    echo "============================================"
    ok "Rollback complete"
    echo "============================================"
}

# ============================================================================
# MAIN: Route to the right function
# ============================================================================
usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands (run in order):"
    echo "  preflight   - Check current state, verify prerequisites"
    echo "  backup      - Backup all resources that will be modified"
    echo "  step1       - Create self-signed TLS certificate secret"
    echo "  step2       - Generate vcluster kubeconfig secret"
    echo "  step3       - Register APIService + RBAC inside vcluster"
    echo "  step4       - Patch tagging deployment to use vcluster secrets"
    echo "  step5       - Migrate bulk deployment from konk to vcluster"
    echo "  verify      - Test tagging + bulk APIs work through vcluster"
    echo "  rollback    - Restore original konk-based state from backup"
    echo ""
    echo "Quick run (all steps):"
    echo "  $0 preflight && $0 backup && $0 step1 && $0 step2 && $0 step3 && $0 step4 && $0 step5 && $0 verify"
}

case "${1:-}" in
    preflight) preflight ;;
    backup)    backup ;;
    step1)     step1_create_tls_cert ;;
    step2)     step2_create_kubeconfig ;;
    step3)     step3_register_in_vcluster ;;
    step4)     step4_patch_deployment ;;
    step5)     step5_migrate_bulk ;;
    verify)    verify ;;
    rollback)  rollback "$@" ;;
    *)         usage ;;
esac
