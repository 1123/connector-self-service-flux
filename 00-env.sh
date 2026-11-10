# shellcheck shell=bash
# Environment-specific values (GCP project, owner label) live in the untracked .env.local – see env.local.example.
source "$(dirname "${BASH_SOURCE[0]}")/.env.local"
: "${PROJECT:?set PROJECT in .env.local}" "${OWNER:?set OWNER in .env.local}"
export REGION=europe-west3
export CLUSTER=connector-self-service
export LABELS=purpose=connector-self-service-poc,owner=${OWNER}
export GH_OWNER=1123
export GH_REPO=connector-self-service-flux
export GH_DEVELOPERS=MartyD24
# Component versions (compatibility: CFK 3.4.x supports CP 8.4.x)
export CP_VERSION=8.4.1
export CFK_INIT_VERSION=3.4.0
export JDBC_CONNECTOR_VERSION=10.9.10
export PG_DRIVER_VERSION=42.7.14
export MQ_SOURCE_VERSION=3.0.0
export CONNECT_IMAGE_TAG=${CP_VERSION}-1
export AR_REPO=${REGION}-docker.pkg.dev/${PROJECT}/connector-self-service
export CONNECT_IMAGE=${AR_REPO}/cp-server-connect-plugins:${CONNECT_IMAGE_TAG}
export NS_CP=confluent NS_VAULT=vault NS_PG=postgres NS_MQ=mq
