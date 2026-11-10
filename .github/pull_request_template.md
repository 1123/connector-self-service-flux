## Connector change

- [ ] New connector / [ ] Changed connector / [ ] Removed connector
- Connector name(s):
- Template(s) used: `mq-source` / `jdbc-source` / `jdbc-sink`

Checklist
- [ ] Rendered with `scripts/new-connector.sh` (or edited only `<<PLACEHOLDER>>` values of the template)
- [ ] `connectors/kustomization.yaml` lists exactly the connector JSON files
- [ ] The connector is registered by an admin (`platform/kafka-admin/connector-registry.yaml`) with the topic used here
