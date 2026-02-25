#!/bin/sh
JWT="eyJhbGciOiJSUzUxMiIsInR5cCI6IkpXVCJ9.eyJ1c2VyX2lkIjoiNzciLCJpZGVudGl0eV91c2VyX2lkIjoiOTBjZDlmYzItYmQ1ZC00YmU4LWI3ZmYtYWYxNzVlNGVjMDU2IiwidXNlcm5hbWUiOiJha3VtYXJAaW5mb2Jsb3guY29tIiwiYWNjb3VudF9pZCI6IjIwMTAxMTIiLCJhY2NvdW50X3R5cGUiOiJzdGFuZGFyZCIsImNzcF9hY2NvdW50X2lkIjoyMDEwMTEyLCJpZGVudGl0eV9hY2NvdW50X2lkIjoiZDFiMjAwZTItNzU4My00YTJkLWFmODgtMmM0MjBkOWM1NzJmIiwiYWNjb3VudF9uYW1lIjoiYXRsYXNfaG9zdGFwcCIsImFjY291bnRfZG9tYWluIjoiaW5mb2Jsb3guc2l0ZSIsImFjY291bnRfbnVtYmVyIjoiMjAxMDExMiIsImNvbXBhbnlfbnVtYmVyIjoxMDAwMTAxMTIsImFjY291bnRfc3RvcmFnZV9pZCI6MjMxMDExMiwic2ZkY19hY2NvdW50X2lkIjoiQkxPWElOVDc4OTUxMzY5MDAxIiwiZ3JvdXBzIjpbImFjdF9hZG1pbiIsInVzZXIiLCJpYi1hY2Nlc3MtY29udHJvbC1hZG1pbiIsIm5hbmFuYW5hIiwiaWItaW50ZXJhY3RpdmUtdXNlciJdLCJzdWJqZWN0Ijp7ImlkIjoiYWt1bWFyQGluZm9ibG94LmNvbSIsInN1YmplY3RfdHlwZSI6InVzZXIiLCJhdXRoZW50aWNhdGlvbl90eXBlIjoiYmVhcmVyIn0sImF1ZCI6ImliLWN0ayIsImV4cCI6MTc3MjAwNTg2MCwianRpIjoiMjIxMzA0YjAtYjMwZC00NWNmLTllOGItMjY3NjA1NGJhN2E4IiwiaWF0IjoxNzcxOTE5MzgyLCJpc3MiOiJpZGVudGl0eSIsIm5iZiI6MTc3MTkxOTM4Mn0.ZOx1TlV2-CDGhCyOrd7UoZQ_UrKgYgfxejgITuxnqOU8yuI5g5_nVudoqMUjwBMKxTLAdBGknf5_8CKWg2wMnvvvT06lxaqbQGurh3GU0nxnSi83x2_0CGXiEWr5PxvwZidrJ1s8eJLuzpMolQRaz1t_AuA991eo7s8apX6rqcIhfpuh8OYzT4OFhtaUMkk9FHczWj8UsALAk0F2nRLokvf0M5Wz5cLHGKN5m34JKrDKMrDdGNsxkCqwXB4-l5KBsWvW4ikRyFQY7d6BabIGJZhi4G2pDvkNnbAcCHA--gxKyQ-xpSAniLGH9BX8niKmJBQ-KHtrdR4ZHvkTbvJG5A"

echo "=== PATH 2: Direct internal REST (tagging-v2 service) ==="
curl -sk \
  -H "Authorization: Bearer ${JWT}" \
  "http://tagging.tagging-v2.svc.cluster.local:8081/v2/tags?_limit=4000&_offset=0" \
  -o /tmp/rest-internal.json 2>&1
echo "Exit code: $?"
echo "Response size: $(wc -c < /tmp/rest-internal.json) bytes"

echo ""
echo "=== PATH 3: Direct to tagging-aggregate-api (K8s format) ==="
curl -sk \
  -H "Authorization: Bearer ${JWT}" \
  "https://tagging-aggregate-api.tagging-v2.svc.cluster.local:443/apis/tagging.bulk.infoblox.com/v1alpha1/namespaces/default/tags" \
  -o /tmp/aggapi-direct.json 2>&1
echo "Exit code: $?"
echo "Response size: $(wc -c < /tmp/aggapi-direct.json) bytes"
echo "First 300 chars:"
head -c 300 /tmp/aggapi-direct.json
echo ""
