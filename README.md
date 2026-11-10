# Self-service Kafka connectors with Flux (POC)

Developers deploy Kafka Connect connectors to Confluent Platform by opening a pull request with a
connector definition. An admin reviews and squash-merges it, and Flux deploys it to the cluster.
Everything runs on GKE with Confluent for Kubernetes (CFK).

Diagrams of the workflow, components and Flux stages are in [docs/architecture.md](docs/architecture.md).

| Component | Details |
|---|---|
| Kafka | CP 8.4.1, 3 brokers + 3 KRaft controllers, SASL_SSL PLAIN everywhere, ACLs |
| Kafka Connect | 2 workers, custom image with JDBC 10.9.10, PostgreSQL driver, IBM MQ source 3.0.0 |
| Connectors | `mq-orders-source` (MQ to `mq.orders`), `pg-customers-source` (Postgres to `pg.customers`) |
| Sources and sinks | IBM MQ 9.4 (namespace `mq`), PostgreSQL (namespace `postgres`) |
| Secrets | Vault (KV v2) and External Secrets Operator; one Kafka user per connector |
| GitOps | Flux in pull-only mode (reads the public repo over HTTPS, never writes) |
| UIs | Vault UI, Flux Operator web UI, Confluent Control Center 2.7 |

## Repository layout

| Path | Owner | Content |
|---|---|---|
| `connectors/` | developers | One CFK `Connector` CR per file (`<name>.json`) + `kustomization.yaml` |
| `templates/` | admin | Allowed connector shapes (`mq-source`, `jdbc-source`, `jdbc-sink`) |
| `platform/kafka-admin/connector-registry.yaml` | admin | Connector identities: name, type, allowed topics |
| `platform/kafka-admin/topics.yaml` | admin | `KafkaTopic` CRs (developers cannot create topics) |
| `platform/` | admin | Operators, secrets, Kafka, Connect, Control Center, data sources |
| `clusters/poc/` | admin | Flux Kustomizations (stages) |
| `ci/`, `.github/` | admin | PR validation (`validate_connectors.py`, workflow `validate-connectors`) |
| `scripts/` | admin | Runbook scripts and helpers |

`.github/CODEOWNERS` makes the admin (`@1123`) the required reviewer for every path.

## Runbook (admin)

Prerequisites: `gcloud`, `kubectl`, `docker` with buildx, `gh` (logged in as the repo owner), `flux`, `jq`, `openssl`,
`python3` with PyYAML. Copy `env.local.example` to `.env.local` and set `PROJECT` and `OWNER`. Versions and names are in
`00-env.sh`.

| Step | Script | What it does |
|---|---|---|
| 1 | `scripts/01-create-cluster.sh` | Regional GKE cluster (3 zones) and Artifact Registry |
| 2 | `scripts/02-pki.sh` | Demo CA, Vault certificate and generated credentials in `pki/` and `.secrets/` (git-ignored) |
| 3 | `scripts/03-build-connect-image.sh` | Builds and pushes the Connect image with the connector plugins |
| 4 | `scripts/04-bootstrap-secrets.sh` | The only secrets not from Vault: CA key pair, CA certificate, Vault TLS |
| 5 | `scripts/05-github-flux-bootstrap.sh` | Creates the GitHub repo, installs Flux (pull-only) and the sync config. Push `main` yourself |
| 6 | `scripts/06-vault-bootstrap.sh` | Initialises, unseals and seeds Vault. Unseal key and root token: `.secrets/vault-init.json` |
| 7 | `scripts/07-github-protection.sh` | Branch protection, squash-merge only, invites the developers (`GH_DEVELOPERS`) |

After step 6, Flux brings up the stages in order: operators, secrets, data-sources and kafka,
kafka-admin, connect, then control-center and connectors. Check with `flux get ks`; all must be `True`.

### Operations

- **Vault is sealed after a pod restart:** run `scripts/06-vault-bootstrap.sh --unseal`.
- **Force a sync:** `flux reconcile source git flux-system && flux reconcile ks connectors`.
- **Re-run the ACL sync:** delete the Job (`kubectl -n confluent delete job kafka-acl-sync`), then
  `flux reconcile ks kafka-admin`. The Job also runs automatically whenever the registry changes.
- **Test a platform change before pushing:** `flux suspend ks <stage>`, then
  `kustomize build platform/<dir> | kubectl apply --server-side --force-conflicts --field-manager=kustomize-controller -f -`,
  then commit, push, and `flux resume ks <stage>`.
- **Connector status:** `kubectl -n confluent get connector` or Control Center.

### UIs

| UI | Port-forward | URL | Login |
|---|---|---|---|
| Vault | `kubectl -n vault port-forward vault-0 8200:8200` | https://localhost:8200 | root token from `.secrets/vault-init.json` |
| Flux | `kubectl -n flux-system port-forward svc/flux-operator 9080:9080` | http://localhost:9080 | anonymous, read-only |
| Control Center | `kubectl -n confluent port-forward svc/controlcenter 9021:9021` | https://localhost:9021 | `c3-admin` (full) or `c3-viewer` (read-only); passwords in Vault `kv/kafka/control-center` |

The certificates are signed by the demo CA (`pki/`), so the browser shows a warning unless you trust that CA.

### Onboarding a connector (admin, before the developer's PR)

1. Add the connector to `platform/kafka-admin/connector-registry.yaml` (name, type, topics).
2. Add any new topic to `platform/kafka-admin/topics.yaml`.
3. Commit and push. Flux creates the topic and the ACL sync Job grants the ACLs.
4. Run `scripts/onboard-connector.sh <name>`. It creates the connector's Kafka password in Vault. Brokers and
   Connect pick it up within about a minute, with no restart.

Offboarding, after the connector file was deleted: remove the registry entry (the ACLs are removed),
remove the topic if no longer needed, and run `scripts/onboard-connector.sh <name> --remove`.

### Teardown

`scripts/99-teardown.sh` stops Flux, deletes the GKE cluster and its persistent disks, and deletes the Artifact
Registry repository. It asks for confirmation. Options: `--yes`, `--local` (also deletes `pki/`, `.secrets/`
and `build/`), `--github-repo` (also deletes the GitHub repo; needs `gh auth refresh -s delete_repo`).

## Developer guide

You can add, change and delete connectors for identities the admin has onboarded. Topics, credentials and
ACLs are managed by the admin. Ask the admin to onboard a new connector name first.

### Add a connector

```bash
git switch -c add-my-connector
# MQ queue to Kafka
scripts/new-connector.sh mq-source   CONNECTOR_NAME=mq-orders-source QUEUE=ORDERS.IN TOPIC=mq.orders
# Postgres table to Kafka (MODE: incrementing | timestamp | timestamp+incrementing)
scripts/new-connector.sh jdbc-source CONNECTOR_NAME=pg-customers-source TABLE=customers TOPIC=pg.customers \
                                     MODE=timestamp+incrementing INCREMENTING_COLUMN=id TIMESTAMP_COLUMN=updated_at
# Kafka to Postgres table
scripts/new-connector.sh jdbc-sink   CONNECTOR_NAME=pg-customers-sink TOPIC=pg.customers TABLE=customers_copy PK_COLUMNS=id
git add connectors/ && git commit -m "Add my connector" && git push -u origin add-my-connector
gh pr create --fill
```

The script fills in a template from `templates/`, writes `connectors/<name>.json`, and updates
`connectors/kustomization.yaml`. You can also copy a template by hand and replace the `<<PLACEHOLDER>>` values.

### Change or delete a connector

- **Change:** edit the placeholder values in `connectors/<name>.json` (e.g. table, mode), then open a PR.
- **Delete:** run `rm connectors/<name>.json && scripts/new-connector.sh --sync-kustomization`, then open a PR.
  After the merge, Flux removes the connector from Connect.

### What CI checks (`validate` must pass before merge)

- The file is an exact copy of a template; only the `<<PLACEHOLDER>>` values may differ, and no keys may be
  added or removed.
- The connector name is registered with the same type, and the file is named `<name>.json`.
- The topic is granted to this connector in the registry.
- `connectors/kustomization.yaml` lists exactly the JSON files in `connectors/`.
- JDBC source: the columns match `MODE`.

Validator, templates and registry are taken from `main`, so a PR cannot weaken its own checks.
To run the check locally: `python3 ci/validate_connectors.py --trusted . --candidate .`.

### After the merge

Flux syncs within about a minute. Check the result in Control Center (`c3-viewer`), the Flux UI, or with
`kubectl -n confluent get connector`. Every connector uses its own Kafka user and can only access
its registered topics.

## Security notes (POC simplifications)

- Vault runs as a single node with manual unseal, and the root token is stored locally in `.secrets/`.
- Control Center connects to Kafka as the `admin` super user. `c3-admin` can change topics and
  connectors outside GitOps; use `c3-viewer` for read-only access.
- Prometheus and Alertmanager (Control Center sidecars) use plain HTTP inside the cluster.
- In a personal GitHub repository, every collaborator with push access can press *merge*. Branch protection
  still requires an approval from the code owner and a passing `validate` check. An organisation repo with merge
  restrictions would close this gap.
- The admin is not subject to branch protection (`enforce_admins=false`).
- Connectors have no dead letter queue. A malformed record stops a sink task until the admin skips it.
