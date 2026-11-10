#!/usr/bin/env bash
# Admin helper: creates (or removes) the Kafka credential of a connector in Vault
# (kv/kafka/connector-users, key = connector name). ESO propagates it within ~1 minute to
#   * the broker user database (secret kafka-plain-users) and
#   * the Connect workers (secret connector-kafka-credentials, mounted as a file).
# Onboarding a connector = this script + registry entry (connector-registry.yaml) + KafkaTopic CR.
#   scripts/onboard-connector.sh <name>            create credential (no-op if it exists)
#   scripts/onboard-connector.sh <name> --remove   delete credential (after the connector was removed)
set -euo pipefail
cd "$(dirname "$0")/.."
source ./00-env.sh
name=${1:?usage: $0 <connector-name> [--remove]}
[[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "invalid connector name" >&2; exit 1; }
ROOT_TOKEN=$(jq -r .root_token .secrets/vault-init.json)
vexec() { kubectl -n "$NS_VAULT" exec -i vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" "$@"; }
P=kv/kafka/connector-users
current=$(vexec vault kv get -format=json "$P" 2>/dev/null | jq -c '.data.data // {}' || echo '{}')

if [[ "${2:-}" == "--remove" ]]; then
  new=$(jq -c --arg n "$name" 'del(.[$n])' <<< "$current")
elif jq -e --arg n "$name" 'has($n)' <<< "$current" >/dev/null; then
  echo "credential for $name exists – kept"; exit 0
else
  new=$(jq -c --arg n "$name" --arg p "$(openssl rand -hex 20)" '. + {($n): $p}' <<< "$current")
fi
vexec sh -c "cat > /tmp/u.json && vault kv put $P @/tmp/u.json >/dev/null; rc=\$?; rm -f /tmp/u.json; exit \$rc" <<< "$new"
echo "kv/kafka/connector-users updated ($name ${2:-added})"
