#!/usr/bin/env bash
# Phase 4 – the only secrets that are NOT sourced from Vault (they are needed before/for Vault):
#   * ca-pair-sslcerts (confluent): demo CA key pair, CFK signs the Kafka/KRaft/Connect certificates with it
#   * demo-ca (confluent, postgres, mq): CA certificate – trust anchor for ESO→Vault and CFK→REST APIs
#   * vault-tls (vault): Vault server certificate
set -euo pipefail
cd "$(dirname "$0")/.."
source ./00-env.sh
for ns in $NS_CP $NS_VAULT $NS_PG $NS_MQ; do
  kubectl create ns "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
k() { local ns=$1; shift; kubectl -n "$ns" create secret "$@" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }
k "$NS_CP" tls ca-pair-sslcerts --cert=pki/ca.pem --key=pki/ca-key.pem
for ns in $NS_CP $NS_PG $NS_MQ; do
  k "$ns" generic demo-ca --from-file=ca.crt=pki/ca.pem --from-file=cacerts.pem=pki/ca.pem
done
k "$NS_VAULT" generic vault-tls --from-file=tls.crt=pki/vault.pem --from-file=tls.key=pki/vault-key.pem \
  --from-file=ca.crt=pki/ca.pem
echo "bootstrap secrets created"
