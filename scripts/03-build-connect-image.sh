#!/usr/bin/env bash
# Phase 3 – build the custom Connect image (linux/amd64) and push it to Artifact Registry.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./00-env.sh
P=build/plugins
mkdir -p "$P"

fetch() { # url file algo checksum
  [[ -f "$P/$2" ]] || curl -fsSL -o "$P/$2" "$1"
  echo "$4  $P/$2" | shasum -a "$3" -c -
}
fetch "https://hub-downloads.confluent.io/api/plugins/confluentinc/kafka-connect-jdbc/versions/${JDBC_CONNECTOR_VERSION}/confluentinc-kafka-connect-jdbc-${JDBC_CONNECTOR_VERSION}.zip" \
  "confluentinc-kafka-connect-jdbc-${JDBC_CONNECTOR_VERSION}.zip" 1 c13897039bf652f512c14ce4ecc10ece58d7b703
fetch "https://repo1.maven.org/maven2/org/postgresql/postgresql/${PG_DRIVER_VERSION}/postgresql-${PG_DRIVER_VERSION}.jar" \
  "postgresql-${PG_DRIVER_VERSION}.jar" 1 0e7c94ce80cb1dd9875ff44ffe6a40a8aaa3eefd
fetch "https://github.com/ibm-messaging/kafka-connect-mq-source/releases/download/v${MQ_SOURCE_VERSION}/kafka-connect-mq-source-${MQ_SOURCE_VERSION}-jar-with-dependencies.jar" \
  "kafka-connect-mq-source-${MQ_SOURCE_VERSION}-jar-with-dependencies.jar" 256 9bfcf0963b59fe8523ef866837e69b01abf60a10bf52c12a68eff639afd7f27f
[[ -d "$P/confluentinc-kafka-connect-jdbc-${JDBC_CONNECTOR_VERSION}" ]] ||
  unzip -q "$P/confluentinc-kafka-connect-jdbc-${JDBC_CONNECTOR_VERSION}.zip" -d "$P"

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet >/dev/null
docker buildx build --platform linux/amd64 --push -t "$CONNECT_IMAGE" -f connect-image/Dockerfile \
  --build-arg CP_VERSION="$CP_VERSION" --build-arg JDBC_CONNECTOR_VERSION="$JDBC_CONNECTOR_VERSION" \
  --build-arg PG_DRIVER_VERSION="$PG_DRIVER_VERSION" --build-arg MQ_SOURCE_VERSION="$MQ_SOURCE_VERSION" .
echo "pushed $CONNECT_IMAGE"
