#!/usr/bin/env bash
# Reconciles Kafka ACLs to the desired state derived from connector-registry.yaml:
# adds missing ACLs and removes every ACL that is not desired (this Job owns all ACLs in the cluster).
# Input: /work/connectors.txt with lines "<name> <type> <topic1,topic2,...>" (rendered by the yq init container).
set -euo pipefail
export LC_ALL=C
BOOTSTRAP=kafka.confluent.svc.cluster.local:9071
CFG=/tmp/admin.properties
cat > "$CFG" <<EOT
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="${ADMIN_PASSWORD}";
ssl.truststore.type=PEM
ssl.truststore.location=/mnt/ca/cacerts.pem
EOT
acls() { kafka-acls --bootstrap-server "$BOOTSTRAP" --command-config "$CFG" "$@"; }

# ACL key format: principal|RESOURCE_TYPE|PATTERN_TYPE|resource name|OPERATION|host|PERMISSION
desired=/tmp/desired.txt; current=/tmp/current.txt
: > "$desired"
want() { echo "$1|$2|$3|$4|$5|*|ALLOW" >> "$desired"; }

# Connect workers: internal topics (_connect-configs/-offsets/-status) and the worker group.
for op in READ WRITE DESCRIBE DESCRIBE_CONFIGS CREATE; do want User:connect TOPIC PREFIXED _connect- "$op"; done
want User:connect GROUP LITERAL _connect READ

while read -r name type topics; do
  [[ -z "$name" ]] && continue
  p="User:$name"
  for t in ${topics//,/ }; do
    case "$type" in
      mq-source|jdbc-source) want "$p" TOPIC LITERAL "$t" WRITE; want "$p" TOPIC LITERAL "$t" DESCRIBE ;;
      jdbc-sink)             want "$p" TOPIC LITERAL "$t" READ;  want "$p" TOPIC LITERAL "$t" DESCRIBE ;;
      *) echo "unknown connector type '$type' for $name" >&2; exit 1 ;;
    esac
  done
  # Sink tasks consume in group connect-<connector name>.
  [[ "$type" == jdbc-sink ]] && want "$p" GROUP LITERAL "connect-$name" READ
done < /work/connectors.txt
sort -u -o "$desired" "$desired"

acls --list | awk '
  /^Current ACLs for resource/ {
    match($0, /resourceType=[A-Z_]+/); rt = substr($0, RSTART + 13, RLENGTH - 13)
    match($0, /name=[^,]+/);           n  = substr($0, RSTART + 5,  RLENGTH - 5)
    match($0, /patternType=[A-Z]+/);   pt = substr($0, RSTART + 12, RLENGTH - 12)
    next }
  /principal=/ {
    match($0, /principal=[^,]+/);       pr   = substr($0, RSTART + 10, RLENGTH - 10)
    match($0, /host=[^,]+/);            h    = substr($0, RSTART + 5,  RLENGTH - 5)
    match($0, /operation=[A-Z_]+/);     op   = substr($0, RSTART + 10, RLENGTH - 10)
    match($0, /permissionType=[A-Z]+/); perm = substr($0, RSTART + 15, RLENGTH - 15)
    print pr "|" rt "|" pt "|" n "|" op "|" h "|" perm }' | sort -u > "$current"

pascal() { echo "$1" | awk -F_ '{ for (i = 1; i <= NF; i++) printf "%s%s", substr($i,1,1), tolower(substr($i,2)) }'; }
apply() { # add|remove key
  local pr rt pt n op h perm res=()
  IFS='|' read -r pr rt pt n op h perm <<< "$2"
  case "$rt" in
    TOPIC) res=(--topic "$n") ;; GROUP) res=(--group "$n") ;; CLUSTER) res=(--cluster) ;;
    TRANSACTIONAL_ID) res=(--transactional-id "$n") ;; *) echo "skip unsupported resource type $rt" >&2; return 0 ;;
  esac
  local who=(--allow-principal "$pr" --allow-host "$h"); [[ "$perm" == DENY ]] && who=(--deny-principal "$pr" --deny-host "$h")
  echo "$1: $2"
  acls "--$1" "${who[@]}" --operation "$(pascal "$op")" "${res[@]}" \
    --resource-pattern-type "$(echo "$pt" | tr '[:upper:]' '[:lower:]')" ${3:+--force} >/dev/null
}
comm -13 "$current" "$desired" | while read -r k; do apply add "$k"; done
comm -23 "$current" "$desired" | while read -r k; do apply remove "$k" force; done
echo "ACL sync done: $(wc -l < "$desired") desired ACLs."
