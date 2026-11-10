#!/usr/bin/env bash
# Phase 6 – initialise/unseal Vault, configure KV v2 + Kubernetes auth for ESO and seed credentials.
# Idempotent: existing secrets are never overwritten. Unseal key + root token: .secrets/vault-init.json
# (POC only – a production setup would use auto-unseal and no long-lived root token).
#   scripts/06-vault-bootstrap.sh            full bootstrap
#   scripts/06-vault-bootstrap.sh --unseal   only unseal (e.g. after a Vault pod restart)
set -euo pipefail
cd "$(dirname "$0")/.."
source ./00-env.sh
INIT=.secrets/vault-init.json
kubectl -n "$NS_VAULT" wait pod/vault-0 --for=jsonpath='{.status.phase}'=Running --timeout=10m >/dev/null
vexec() { kubectl -n "$NS_VAULT" exec -i vault-0 -- env VAULT_TOKEN="${ROOT_TOKEN:-}" "$@"; }

if [[ $(vexec vault status -format=json | jq -r .initialized) == false ]]; then
  vexec vault operator init -key-shares=1 -key-threshold=1 -format=json > "$INIT"
  chmod 600 "$INIT"
fi
if [[ $(vexec vault status -format=json | jq -r .sealed) == true ]]; then
  vexec vault operator unseal "$(jq -r '.unseal_keys_b64[0]' "$INIT")" >/dev/null
fi
echo "vault unsealed"
[[ "${1:-}" == "--unseal" ]] && exit 0
ROOT_TOKEN=$(jq -r .root_token "$INIT")

vexec vault secrets list -format=json | jq -e '."kv/"' >/dev/null || vexec vault secrets enable -path=kv kv-v2
vexec vault auth list -format=json | jq -e '."kubernetes/"' >/dev/null || vexec vault auth enable kubernetes
vexec vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc >/dev/null

policy() { vexec vault policy write "$1" - >/dev/null; }
policy confluent <<'P'
path "kv/data/kafka/*"          { capabilities = ["read"] }
path "kv/data/postgres/connect" { capabilities = ["read"] }
path "kv/data/mq/app"           { capabilities = ["read"] }
P
policy postgres <<'P'
path "kv/data/postgres/*" { capabilities = ["read"] }
P
policy mq <<'P'
path "kv/data/mq/*" { capabilities = ["read"] }
P
for ns in $NS_CP $NS_PG $NS_MQ; do
  vexec vault write "auth/kubernetes/role/$ns" bound_service_account_names=vault-reader \
    bound_service_account_namespaces="$ns" policies="$ns" audience=vault ttl=1h >/dev/null
done

set -a; source .secrets/platform.env; set +a
seed() { # path json – only if the secret does not exist yet
  if vexec vault kv get "kv/$1" >/dev/null 2>&1; then echo "kv/$1 exists – kept"; return; fi
  vexec sh -c "cat > /tmp/seed.json && vault kv put kv/$1 @/tmp/seed.json >/dev/null; rc=\$?; rm -f /tmp/seed.json; exit \$rc" <<< "$2"
  echo "kv/$1 seeded"
}
seed kafka/system-users "$(jq -n --arg k "$KAFKA_BROKER_PASSWORD" --arg a "$KAFKA_ADMIN_PASSWORD" --arg c "$KAFKA_CONNECT_PASSWORD" '{kafka:$k, admin:$a, connect:$c}')"
seed kafka/rest "$(jq -n --arg r "$REST_ADMIN_PASSWORD" --arg c "$CONNECT_REST_PASSWORD" '{"rest-admin":$r, "connect-admin":$c}')"
seed postgres/admin "$(jq -n --arg p "$PG_ADMIN_PASSWORD" '{password:$p}')"
seed postgres/connect "$(jq -n --arg p "$PG_CONNECT_PASSWORD" '{username:"connect", password:$p}')"
seed mq/admin "$(jq -n --arg p "$MQ_ADMIN_PASSWORD" '{password:$p}')"
seed mq/app "$(jq -n --arg p "$MQ_APP_PASSWORD" '{username:"app", password:$p}')"

# One Kafka credential per registered connector.
for name in $(yq '.connectors | keys | .[]' platform/kafka-admin/connector-registry.yaml); do
  scripts/onboard-connector.sh "$name"
done
