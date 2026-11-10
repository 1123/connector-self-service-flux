#!/usr/bin/env bash
# Phase 2 – local demo CA + Vault server certificate + generated platform credentials.
# Everything lands in pki/ and .secrets/ (git-ignored). Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./00-env.sh
mkdir -p pki .secrets

if [[ ! -f pki/ca.pem ]]; then
  openssl req -x509 -newkey rsa:4096 -nodes -days 365 -keyout pki/ca-key.pem -out pki/ca.pem \
    -subj "/O=Connector Self-Service POC/CN=POC Root CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
fi

# Vault listens with TLS (ESO -> Vault traffic is encrypted).
if [[ ! -f pki/vault.pem ]]; then
  openssl req -newkey rsa:2048 -nodes -keyout pki/vault-key.pem -out pki/vault.csr \
    -subj "/O=Connector Self-Service POC/CN=vault.${NS_VAULT}.svc"
  openssl x509 -req -in pki/vault.csr -CA pki/ca.pem -CAkey pki/ca-key.pem -CAcreateserial \
    -days 365 -sha256 -out pki/vault.pem -extfile <(printf '%s\n' \
      "basicConstraints=CA:FALSE" "keyUsage=digitalSignature,keyEncipherment" "extendedKeyUsage=serverAuth" \
      "subjectAltName=DNS:vault,DNS:vault.${NS_VAULT},DNS:vault.${NS_VAULT}.svc,DNS:vault.${NS_VAULT}.svc.cluster.local,DNS:vault-0.vault-internal,DNS:localhost,IP:127.0.0.1")
  rm -f pki/vault.csr
fi

# Platform credentials (seeded into Vault by 06-vault-bootstrap.sh; never committed).
if [[ ! -f .secrets/platform.env ]]; then
  gen() { openssl rand -hex 20; }
  cat > .secrets/platform.env <<EOT
KAFKA_BROKER_PASSWORD=$(gen)
KAFKA_ADMIN_PASSWORD=$(gen)
KAFKA_CONNECT_PASSWORD=$(gen)
REST_ADMIN_PASSWORD=$(gen)
CONNECT_REST_PASSWORD=$(gen)
PG_ADMIN_PASSWORD=$(gen)
PG_CONNECT_PASSWORD=$(gen)
MQ_ADMIN_PASSWORD=$(gen)
MQ_APP_PASSWORD=$(gen)
EOT
  chmod 600 .secrets/platform.env
fi
openssl verify -CAfile pki/ca.pem pki/vault.pem
echo "PKI and credentials ready."
