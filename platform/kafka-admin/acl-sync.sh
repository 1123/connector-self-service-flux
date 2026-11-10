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

# Parse "kafka-acls --list" output in plain bash (the cp-server image ships no awk).
parse_acls() {
  local line rt n pt re_res re_acl
  re_res='resourceType=([A-Z_]+), name=([^,]+), patternType=([A-Z]+)'
  re_acl='principal=([^,]+), host=([^,]+), operation=([A-Z_]+), permissionType=([A-Z]+)'
  while IFS= read -r line; do
    if [[ "$line" =~ $re_res ]]; then rt=${BASH_REMATCH[1]} n=${BASH_REMATCH[2]} pt=${BASH_REMATCH[3]}
    elif [[ "$line" =~ $re_acl ]]; then
      echo "${BASH_REMATCH[1]}|$rt|$pt|$n|${BASH_REMATCH[3]}|${BASH_REMATCH[2]}|${BASH_REMATCH[4]}"
    fi
  done
}
acls --list | parse_acls | sort -u > "$current"

pascal() { local w out="" IFS=_; for w in $1; do w=${w,,}; out+=${w^}; done; echo "$out"; }
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
