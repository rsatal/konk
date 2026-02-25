#!/bin/bash
# rollback-bulk.sh
#
# Rolls back the bulk deployment from vcluster to konk.
# Reverts the 3 changes made in step5 of the migration:
#   1. --konk.host → bulk-konk.aggregate:6443
#   2. kubeconfig volume → bulk-konk-kubeconfig
#   3. proxy-client-cert volume → bulk-konk-proxy-client
#
# Usage:
#   ./rollback-bulk.sh            # Rollback and verify
#   ./rollback-bulk.sh --verify   # Verify only (no rollback) + test exports
#   ./rollback-bulk.sh --dry-run  # Show what would change without applying

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
BULK_NS="aggregate"
BULK_DEPLOYMENT="bulk"

# Konk originals (what we revert TO)
KONK_HOST="bulk-konk.aggregate:6443"
KONK_KUBECONFIG_SECRET="bulk-konk-kubeconfig"
KONK_PROXY_CLIENT_SECRET="bulk-konk-proxy-client"

# vcluster values (what we revert FROM)
VCLUSTER_HOST="vcluster.vcluster:443"
VCLUSTER_KUBECONFIG_SECRET="bulk-vcluster-kubeconfig"
VCLUSTER_PROXY_CLIENT_SECRET="bulk-vcluster-proxy-client"

# Bulk API for export tests
BULK_API_URL="https://env-5.test.infoblox.com"
# Paste your Bearer token here (or set BULK_API_TOKEN env var)
BULK_API_TOKEN="eyJhbGciOiJSUzUxMiIsInR5cCI6IkpXVCJ9.eyJ1c2VyX2lkIjoiNzciLCJpZGVudGl0eV91c2VyX2lkIjoiODdmOWQyN2MtMjNiZS00MTA5LTgwZWMtM2QzYTkyZjM5ZDljIiwidXNlcm5hbWUiOiJha3VtYXJAaW5mb2Jsb3guY29tIiwiYWNjb3VudF9pZCI6IjI1NCIsImFjY291bnRfdHlwZSI6InN0YW5kYXJkIiwiY3NwX2FjY291bnRfaWQiOjI1NCwiaWRlbnRpdHlfYWNjb3VudF9pZCI6ImU3YjliYzUyLTk2YmItNGY5OC05NGIzLTAwMDAwMDAwMDI1NCIsImFjY291bnRfbmFtZSI6Ik1OUiIsImFjY291bnRfZG9tYWluIjoiaW5mb2Jsb3guY29tIiwiYWNjb3VudF9udW1iZXIiOiIyNTQiLCJhY2NvdW50X3N0b3JhZ2VfaWQiOjMwMDI1NCwic2ZkY19hY2NvdW50X2lkIjoiNDIzIiwiZ3JvdXBzIjpbImFjdF9hZG1pbiIsInVzZXIiLCJmb28tYmFyIiwidGVzdC1zcnQiLCJncm91cDEyMyIsInRlc3QtY29tcGEiLCJpYi10ZC1hZG1pbiIsImliLWRkaS1hZG1pbiIsInRlc3QiLCJpYi1hY2Nlc3MtY29udHJvbC1hZG1pbiIsInRlc3QtMTIzIiwidGVtcDEiLCJibHItYWRtaW4tdWciLCJ0ZXN0LWR2ayIsImN1c3RvbWFkbWluIiwibXNwLWdycDEiLCJpYi1kZGktdXNlciIsImFzc2V0cy1pbnZlbnRvcnktcmVhZCIsImliLXNvYy1pbnNpZ2h0LWFkbWluIiwidGVzdDEiLCJpYi1ibG94b25lLW5pb3MtdXNlciIsImliLWludGVyYWN0aXZlLXVzZXIiXSwic3ViamVjdCI6eyJpZCI6ImFrdW1hckBpbmZvYmxveC5jb20iLCJzdWJqZWN0X3R5cGUiOiJ1c2VyIiwiYXV0aGVudGljYXRpb25fdHlwZSI6ImJlYXJlciJ9LCJhdWQiOiJpYi1jdGsiLCJleHAiOjE3NzIwMjQ0NzIsImp0aSI6ImYzNzhlZDkwLTExN2MtNGFhNy05YWE3LWU3ODc5MmU0NGIyMCIsImlhdCI6MTc3MTkzNzk4MiwiaXNzIjoiaWRlbnRpdHkiLCJuYmYiOjE3NzE5Mzc5ODJ9.UeZcZFXfiZ6AT9oizPgIR69UiyDstvf-r6bDQoe66cqK-p2nq-proNSYgDdYZHrjBjC-CUh4JSaujgBdDl_cKnHTD0t4mcrvmpjHDNfufkFkkcvGb2lYHFii6DJGxS8upF6rrdxhFpWeEiXcZ4EO1B4Bd3Jl08RWlypYs9vdlBtqDTtvvXUn_8YVEln62tXU5aUK_PsmqFCr4FCl3_FKWAdfJOQ3SVxn6hU104TUpx6JxweCnecSYyZQtYevsbYMsa7N215RsGsJ8yEGfUdFky8UEiFaFwIWBLXjKsGlsi3fwX94c_qSPJ1c_9vsUDDoaZqntn14sCyJUWzmO07NIw"

# Data types routed via KONK (bulk-konk aggregator)
KONK_DATA_TYPES=(
    "Infrastructure (hosts)|infrastructure.bulk.infoblox.com/v1alpha1/hosts.v1alpha1.infrastructure.bulk.infoblox.com"
    "DNS (records)|dnsdata.bulk.infoblox.com/v2/recordv2s"
)

# Data types routed via VCLUSTER (tagging migrated to vcluster)
VCLUSTER_DATA_TYPES=(
    "Tagging (tags)|tagging.bulk.infoblox.com/v1alpha1/tags"
    "Tagging (values)|tagging.bulk.infoblox.com/v1alpha1/values"
)

# ============================================================================
# Colors
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $1"; }

# ============================================================================
# Check current state
# ============================================================================
check_current_state() {
    echo ""
    echo "============================================"
    echo "  Current Bulk Deployment State"
    echo "============================================"
    echo ""

    CURRENT_HOST=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} \
        -o jsonpath='{.spec.template.spec.containers[0].args}' | \
        python3 -c "
import sys, json
args = json.load(sys.stdin)
for a in args:
    if a.startswith('--konk.host='):
        print(a.split('=',1)[1])
        break
" 2>/dev/null || echo "unknown")

    CURRENT_KC=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} \
        -o jsonpath='{.spec.template.spec.volumes}' | \
        python3 -c "
import sys, json
for v in json.load(sys.stdin):
    if v['name'] == 'kubeconfig':
        print(v.get('secret',{}).get('secretName','unknown'))
        break
" 2>/dev/null || echo "unknown")

    CURRENT_PC=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} \
        -o jsonpath='{.spec.template.spec.volumes}' | \
        python3 -c "
import sys, json
for v in json.load(sys.stdin):
    if v['name'] == 'proxy-client-cert':
        print(v.get('secret',{}).get('secretName','unknown'))
        break
" 2>/dev/null || echo "unknown")

    echo "  --konk.host      : ${CURRENT_HOST}"
    echo "  kubeconfig secret: ${CURRENT_KC}"
    echo "  proxy-client     : ${CURRENT_PC}"
    echo ""

    if [[ "${CURRENT_HOST}" == "${KONK_HOST}" && \
          "${CURRENT_KC}" == "${KONK_KUBECONFIG_SECRET}" && \
          "${CURRENT_PC}" == "${KONK_PROXY_CLIENT_SECRET}" ]]; then
        ok "Bulk is already on konk. No rollback needed."
        return 1
    fi

    if [[ "${CURRENT_HOST}" == "${VCLUSTER_HOST}" ]]; then
        warn "Bulk is currently on vcluster. Will revert to konk."
    else
        warn "Bulk host is '${CURRENT_HOST}' (unexpected). Will patch to konk."
    fi
    return 0
}

# ============================================================================
# Rollback
# ============================================================================
rollback() {
    echo ""
    echo "============================================"
    echo "  Rollback: Bulk → Konk"
    echo "============================================"
    echo ""

    # Patch 1: --konk.host
    KONK_HOST_INDEX=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} \
        -o jsonpath='{.spec.template.spec.containers[0].args}' | \
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

    info "Patching --konk.host (args[${KONK_HOST_INDEX}]) → ${KONK_HOST}"
    kubectl patch deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} --type='json' \
        -p="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/args/${KONK_HOST_INDEX}\", \"value\": \"--konk.host=${KONK_HOST}\"}]" 2>&1
    ok "  --konk.host reverted"

    # Patch 2: kubeconfig volume
    info "Patching kubeconfig volume → ${KONK_KUBECONFIG_SECRET}"
    kubectl patch deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} --type='json' \
        -p='[{"op": "replace", "path": "/spec/template/spec/volumes/0/secret/secretName", "value": "'"${KONK_KUBECONFIG_SECRET}"'"}]' 2>&1
    ok "  kubeconfig reverted"

    # Patch 3: proxy-client-cert volume
    info "Patching proxy-client-cert volume → ${KONK_PROXY_CLIENT_SECRET}"
    kubectl patch deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} --type='json' \
        -p='[{"op": "replace", "path": "/spec/template/spec/volumes/1/secret/secretName", "value": "'"${KONK_PROXY_CLIENT_SECRET}"'"}]' 2>&1
    ok "  proxy-client-cert reverted"

    echo ""

    # Wait for rollout
    info "Waiting for rollout (timeout: 180s)..."
    kubectl rollout status deployment/${BULK_DEPLOYMENT} -n ${BULK_NS} --timeout=180s 2>&1 || {
        warn "Rollout may not have completed. Check pods:"
        kubectl get pods -n ${BULK_NS} -l app.kubernetes.io/name=${BULK_DEPLOYMENT}
        return 1
    }
    ok "Rollout complete"
}

# ============================================================================
# Verify
# ============================================================================
verify() {
    echo ""
    echo "============================================"
    echo "  Verify: Bulk on Konk"
    echo "============================================"
    echo ""

    # Check deployment config
    FINAL_HOST=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} \
        -o jsonpath='{.spec.template.spec.containers[0].args}' | \
        python3 -c "
import sys, json
for a in json.load(sys.stdin):
    if a.startswith('--konk.host='):
        print(a.split('=',1)[1])
        break
" 2>/dev/null || echo "unknown")

    FINAL_KC=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} \
        -o jsonpath='{.spec.template.spec.volumes}' | \
        python3 -c "
import sys, json
for v in json.load(sys.stdin):
    if v['name'] == 'kubeconfig':
        print(v.get('secret',{}).get('secretName','unknown'))
        break
" 2>/dev/null || echo "unknown")

    FINAL_PC=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} \
        -o jsonpath='{.spec.template.spec.volumes}' | \
        python3 -c "
import sys, json
for v in json.load(sys.stdin):
    if v['name'] == 'proxy-client-cert':
        print(v.get('secret',{}).get('secretName','unknown'))
        break
" 2>/dev/null || echo "unknown")

    PASS=true

    if [[ "${FINAL_HOST}" == "${KONK_HOST}" ]]; then
        ok "--konk.host = ${KONK_HOST}"
    else
        fail "--konk.host = ${FINAL_HOST} (expected ${KONK_HOST})"
        PASS=false
    fi

    if [[ "${FINAL_KC}" == "${KONK_KUBECONFIG_SECRET}" ]]; then
        ok "kubeconfig  = ${KONK_KUBECONFIG_SECRET}"
    else
        fail "kubeconfig  = ${FINAL_KC} (expected ${KONK_KUBECONFIG_SECRET})"
        PASS=false
    fi

    if [[ "${FINAL_PC}" == "${KONK_PROXY_CLIENT_SECRET}" ]]; then
        ok "proxy-client = ${KONK_PROXY_CLIENT_SECRET}"
    else
        fail "proxy-client = ${FINAL_PC} (expected ${KONK_PROXY_CLIENT_SECRET})"
        PASS=false
    fi

    echo ""

    # Check pods
    info "Pod status:"
    kubectl get pods -n ${BULK_NS} -l app.kubernetes.io/name=${BULK_DEPLOYMENT} -o wide
    echo ""

    READY=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl get deployment ${BULK_DEPLOYMENT} -n ${BULK_NS} \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")

    if [[ "${READY}" -ge 1 ]]; then
        ok "Pods ready: ${READY}/${DESIRED}"
    else
        fail "Pods not ready: ${READY}/${DESIRED}"
        PASS=false
    fi

    # Check logs for errors
    info "Checking logs for errors..."
    ERRORS=$(kubectl logs -n ${BULK_NS} -l app.kubernetes.io/name=${BULK_DEPLOYMENT} \
        --tail=30 2>/dev/null | grep -ic "x509\|unauthorized\|connection refused" 2>/dev/null || true)
    ERRORS=${ERRORS:-0}
    # Multi-pod output can produce multiple lines of counts; sum them
    ERRORS=$(echo "${ERRORS}" | awk '{s+=$1} END {print s+0}')
    if [[ "${ERRORS}" -eq 0 ]]; then
        ok "No connection errors in recent logs"
    else
        warn "Found ${ERRORS} potential error lines in logs"
        kubectl logs -n ${BULK_NS} -l app.kubernetes.io/name=${BULK_DEPLOYMENT} \
            --tail=30 2>/dev/null | grep -i "x509\|unauthorized\|connection refused" | head -3 || true
    fi

    echo ""
    echo "============================================"
    if [[ "${PASS}" == "true" ]]; then
        ok "Bulk rollback verified — all 3 patches on konk"
    else
        fail "Verification had failures — review above"
    fi
    echo "============================================"
}

# ============================================================================
# Export Test
# ============================================================================
test_export() {
    local label="$1"
    local data_type="$2"

    # Build auth header if token is set
    local AUTH_HEADER=""
    if [[ -n "${BULK_API_TOKEN}" ]]; then
        AUTH_HEADER="Authorization: Bearer ${BULK_API_TOKEN}"
    fi

    info "Testing export: ${label}"
    local TMPFILE
    TMPFILE=$(mktemp)
    local EXPORT_NAME="rollback-verify-$(echo "${label}" | tr ' ()' '---' | tr '[:upper:]' '[:lower:]')-$(date +%s)"
    HTTP_CODE=$(curl -sk -o "${TMPFILE}" -w "%{http_code}" -X POST "${BULK_API_URL}/bulk/v1/export" \
        -H "Content-Type: application/json" \
        ${AUTH_HEADER:+-H "${AUTH_HEADER}"} \
        -d '{"name": "'"${EXPORT_NAME}"'", "error_handling_id": 2, "data_types": ["'"${data_type}"'"]}' 2>&1)
    RESPONSE=$(cat "${TMPFILE}")
    rm -f "${TMPFILE}"

    if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "202" ]]; then
        ok "  ${label}: HTTP ${HTTP_CODE} — ${RESPONSE}"
        return 0
    else
        fail "  ${label}: HTTP ${HTTP_CODE} — ${RESPONSE}"
        return 1
    fi
}

test_exports() {
    echo ""
    echo "============================================"
    echo "  Export Tests (via ${BULK_API_URL})"
    echo "============================================"
    echo ""

    if [[ -z "${BULK_API_TOKEN}" ]]; then
        warn "No BULK_API_TOKEN set. Exports will likely return 401."
        warn "Set it with: export BULK_API_TOKEN=\"<token>\""
        echo ""
    fi

    KONK_PASS=true
    VCLUSTER_PASS=true

    # --- Konk data types (should all work after rollback) ---
    echo -e "${BLUE}--- Konk data types (via bulk-konk) ---${NC}"
    echo ""
    for entry in "${KONK_DATA_TYPES[@]}"; do
        local label="${entry%%|*}"
        local dtype="${entry##*|}"
        test_export "${label}" "${dtype}" || KONK_PASS=false
        echo ""
    done

    # --- vcluster data types (tagging, migrated to vcluster) ---
    echo -e "${YELLOW}--- vcluster data types (via vcluster — tagging) ---${NC}"
    warn "Tagging exports may 500 due to pre-existing 'Unable to get token from context' issue"
    echo ""
    for entry in "${VCLUSTER_DATA_TYPES[@]}"; do
        local label="${entry%%|*}"
        local dtype="${entry##*|}"
        test_export "${label}" "${dtype}" || VCLUSTER_PASS=false
        echo ""
    done

    # Build auth header for operations check
    local AUTH_HEADER=""
    if [[ -n "${BULK_API_TOKEN}" ]]; then
        AUTH_HEADER="Authorization: Bearer ${BULK_API_TOKEN}"
    fi

    # Check recent operations
    info "Recent operations:"
    curl -sk ${AUTH_HEADER:+-H "${AUTH_HEADER}"} "${BULK_API_URL}/bulk/v1/operation" 2>/dev/null | \
        python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    ops = data if isinstance(data, list) else data.get('results', data.get('operations', []))
    for op in ops[:5]:
        status = op.get('status', 'unknown')
        dtypes = op.get('data_types', [])
        if dtypes and isinstance(dtypes[0], dict):
            dtype = ', '.join(d.get('name', str(d)) for d in dtypes)
        elif dtypes:
            dtype = ', '.join(str(d) for d in dtypes)
        else:
            dtype = 'N/A'
        op_type = op.get('operation_type', 'unknown')
        name = op.get('name', '')
        print(f'  {op_type}: {status} — {name} [{dtype[:60]}]')
except Exception as e:
    print(f'  Could not parse operations: {e}')
" 2>/dev/null || warn "Could not fetch operations"

    echo ""
    echo "============================================"
    if [[ "${KONK_PASS}" == "true" ]]; then
        ok "Konk exports: ALL PASSED (infrastructure, dns, etc.)"
    else
        fail "Konk exports: SOME FAILED — review above"
    fi
    if [[ "${VCLUSTER_PASS}" == "true" ]]; then
        ok "vcluster exports: ALL PASSED (tagging)"
    else
        warn "vcluster exports: EXPECTED FAILURES (tagging — pre-existing token issue)"
    fi
    echo "============================================"
}

# ============================================================================
# Main
# ============================================================================
ACTION="${1:-rollback}"

case "${ACTION}" in
    --verify)
        check_current_state || true  # show state, don't exit
        verify
        test_exports
        ;;
    --dry-run)
        check_current_state || exit 0
        echo ""
        info "DRY RUN — would apply these patches:"
        echo "  1. --konk.host → ${KONK_HOST}"
        echo "  2. kubeconfig  → ${KONK_KUBECONFIG_SECRET}"
        echo "  3. proxy-client → ${KONK_PROXY_CLIENT_SECRET}"
        echo ""
        info "Run without --dry-run to apply."
        ;;
    *)
        check_current_state || exit 0
        rollback
        verify
        test_exports
        ;;
esac
