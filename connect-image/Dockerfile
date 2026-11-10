# Kafka Connect worker image with all connector plugins baked in (no runtime downloads).
# Build via scripts/03-build-connect-image.sh – it downloads and checksum-verifies the artefacts into build/.
ARG CP_VERSION
FROM confluentinc/cp-server-connect:${CP_VERSION}
ARG JDBC_CONNECTOR_VERSION
ARG PG_DRIVER_VERSION
ARG MQ_SOURCE_VERSION
# Confluent JDBC connector (source + sink); the PostgreSQL driver must sit in the plugin's lib dir.
COPY build/plugins/confluentinc-kafka-connect-jdbc-${JDBC_CONNECTOR_VERSION}/ /usr/share/confluent-hub-components/confluentinc-kafka-connect-jdbc/
COPY build/plugins/postgresql-${PG_DRIVER_VERSION}.jar /usr/share/confluent-hub-components/confluentinc-kafka-connect-jdbc/lib/
# IBM MQ source connector – the jar-with-dependencies already contains com.ibm.mq.allclient.
COPY build/plugins/kafka-connect-mq-source-${MQ_SOURCE_VERSION}-jar-with-dependencies.jar /usr/share/confluent-hub-components/kafka-connect-mq-source/
