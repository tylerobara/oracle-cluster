#!/usr/bin/env bash
# Creates/rotates the token external-secrets uses to read openbao
# (store: oracle-cluster-secret-store, KV mount: oracle/).
# Flow: OIDC login (browser) -> ensure policy + token-store role -> issue
# token via the role (bypasses "child policies must be subset of parent")
# -> update bao-token secret -> restart ESO.
# Note: tokens self-expire 32d after issue (backend max_lease cap); re-run
# this script about monthly, or before a token expires.
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
bao login -method=oidc role=openbao-admin >/dev/null \
  || { echo "OIDC login failed" >&2; exit 1; }
bao token lookup >/dev/null 2>&1 || { echo "no usable session token after login" >&2; exit 1; }

POLICY_FILE=$(mktemp)
printf 'path "oracle/data/*" {\n  capabilities = ["read", "list"]\n}\n' > "$POLICY_FILE"
bao policy write external-secrets "$POLICY_FILE" >/dev/null
rm -f "$POLICY_FILE"

echo '{"token_policies":["external-secrets"],"allowed_policies":["external-secrets"],"disallowed_policies":["admin","root"],"renewable":true,"token_type":"service","token_period":"8760h","no_default_policy":true}' \
  | bao write -f auth/token/roles/external-secrets - >/dev/null

TOK=$(bao token create -role=external-secrets -format=json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth"]["client_token"])')

kubectl --context oracle -n external-secrets create secret generic bao-token \
  --from-literal=token="$TOK" --dry-run=client -o yaml \
  | kubectl --context oracle apply -f -
unset TOK

kubectl --context oracle rollout restart deploy/external-secrets -n external-secrets
echo "done: bao-token rotated via token-store role, ESO restarted"
