#!/usr/bin/env bash
# Creates/rotates the least-privilege token external-secrets uses to read
# openbao (store: oracle-cluster-secret-store, mount: oracle/).
# Requires: bao CLI (brew tap openbao/openbao && brew install openbao), kubectl 'oracle' context.
set -euo pipefail
command -v bao >/dev/null || { echo "missing bao CLI: brew tap openbao/openbao && brew install openbao" >&2; exit 1; }

PF_LOG=$(mktemp)
# --address localhost: bind IPv4+IPv6 (bao resolves localhost -> ::1 first)
kubectl --context oracle port-forward --address localhost -n openbao svc/openbao 8200:8200 >"$PF_LOG" 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null; rm -f "$PF_LOG"' EXIT

echo "waiting for port-forward..."
for _ in $(seq 20); do
  curl -fsS -o /dev/null http://127.0.0.1:8200/v1/sys/health 2>/dev/null && break
  kill -0 $PF 2>/dev/null || { echo "port-forward exited:" >&2; cat "$PF_LOG" >&2; exit 1; }
  sleep 0.5
done
curl -fsS -o /dev/null http://127.0.0.1:8200/v1/sys/health 2>/dev/null \
  || { echo "port-forward never came up:" >&2; cat "$PF_LOG" >&2; exit 1; }
echo "port-forward ready (pid $PF)"

export BAO_ADDR=http://localhost:8200
printf "Logging in to OpenBao via OIDC — watch for a browser window...\n"
bao login -method=oidc role=openbao-admin >/dev/null
[[ -n "${BAO_TOKEN:-}" && -n "${BAO_TOKEN_EXPIRATION_TIME:-}" ]] || { echo "OIDC login failed" >&2; exit 1; }

# dedicated read-only policy (idempotent; map payload via stdin JSON)
echo '{"policy":{"oracle/data/*":{"capabilities":["read","list"]}}}' \
  | bao write -f sys/policies/acl/external-secrets - >/dev/null

# service token, renewable, renews itself indefinitely (period 1y)
TOK=$(bao token create -policy=external-secrets -ttl=8760h -period=8760h \
  -renewable=true -no-default-policy=true -type=service -format=json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth"]["client_token"]["token"])')

kubectl --context oracle -n external-secrets create secret generic bao-token \
  --from-literal=token="$TOK" --dry-run=client -o yaml \
  | kubectl --context oracle apply -f -
unset TOK

kubectl --context oracle rollout restart deploy/external-secrets -n external-secrets
echo "done: bao-token replaced with least-privilege token, ESO restarted"
