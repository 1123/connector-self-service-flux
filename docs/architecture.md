# Architecture and workflow

Self-service Kafka connectors on Confluent Platform (CFK on GKE), delivered via GitOps with Flux.

## 1. Self-service workflow (PR to running connector)

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Developer (MartyD24)
    actor Admin as Admin (1123)
    participant GH as GitHub repo 1123/connector-self-service-flux
    participant CI as GitHub Actions (validate-connectors)
    participant Flux as Flux (source + kustomize controllers)
    participant CFK as CFK operator
    participant Connect as Kafka Connect (2 workers)

    Dev->>GH: push feature branch with connectors/NAME.json (full CFK Connector CR, based on templates/)
    Dev->>GH: open pull request against main
    GH->>CI: trigger on pull_request
    CI->>CI: checkout base branch (trusted validator, templates, registry) and PR branch (candidate)
    CI->>CI: validate_connectors.py: template conformance, registry (user, topics, class), secrets only via ${directory:...}
    CI->>CI: kubectl kustomize connectors/
    CI-->>GH: status check (pass / fail)
    GH->>Admin: review requested (CODEOWNERS: * @1123)
    opt new connector identity needed
        Admin->>GH: add entry to platform/kafka-admin/connector-registry.yaml
        Admin->>Admin: create credential in Vault kv/kafka/connector-users and create topic(s)
    end
    Admin->>GH: approve and squash-merge into main
    Flux->>GH: poll main (HTTPS, read-only, no write credentials)
    Flux->>Flux: reconcile stages in dependency order
    Flux->>CFK: apply / prune Connector CRs (stage connectors)
    CFK->>Connect: REST (HTTPS + basic auth) create / update / delete connector
    Connect-->>CFK: connector and task state
    CFK-->>Flux: Connector CR status (health check)
```

## 2. Git branches

```mermaid
flowchart LR
    feat["feature branch (developer)"] -->|pull request| pr{"CI validation + admin review"}
    pr -->|changes requested| feat
    pr -->|squash-merge by admin| main["main (single source of truth)"]
    adminpr["admin PRs: platform/, templates/, registry"] --> pr
    main -->|Flux polls, pull-only| cluster["GKE cluster"]
```

## 3. Runtime components and data flow

```mermaid
flowchart LR
    subgraph src["Sources"]
        mq["IBM MQ 9.4 (ns mq) - QM1 / ORDERS.IN"]
        pg[("PostgreSQL (ns postgres) - table customers")]
    end

    subgraph cp["Confluent Platform (ns confluent)"]
        kraft["KRaft controllers x3"]
        brokers["Kafka brokers x3 - SASL_SSL PLAIN + ACLs"]
        t1(["topic mq.orders"])
        t2(["topic pg.customers"])
        subgraph connect["Kafka Connect x2 (custom image)"]
            c1["mq-orders-source (Kafka user mq-orders-source)"]
            c2["pg-customers-source (Kafka user pg-customers-source)"]
            c3["pg-customers-sink (Kafka user pg-customers-sink)"]
        end
        acl["kafka-acl-sync Job (registry to ACLs)"]
        c3ui["Control Center 2.7 + Prometheus / Alertmanager"]
    end

    subgraph snk["Sinks"]
        pgc[("PostgreSQL - table customers_copy")]
    end

    subgraph sec["Secrets"]
        vault["Vault KV v2"] --> eso["External Secrets Operator"] --> k8s["K8s Secrets"]
    end

    mq -->|JMS| c1 -->|produce, TLS| t1
    pg -->|JDBC poll| c2 -->|produce, TLS| t2
    t2 -->|consume, TLS| c3 -->|JDBC upsert| pgc
    t1 --- brokers
    t2 --- brokers
    kraft --- brokers
    acl -->|admin user| brokers
    c3ui -->|metrics + admin| brokers
    c3ui -->|REST| connect
    k8s -.->|PLAIN users, hot reload| brokers
    k8s -.->|mounted, directory config provider| connect
```

## 4. Flux stages (Kustomizations in `clusters/poc/platform.yaml`)

```mermaid
flowchart LR
    git["GitRepository flux-system (main)"] --> ops["operators: CFK, ESO, Vault, Flux Operator UI"]
    ops --> sec["secrets: SecretStore + ExternalSecrets"]
    sec --> ds["data-sources: IBM MQ, Postgres"]
    sec --> kfk["kafka: KRaft + brokers"]
    kfk --> kadm["kafka-admin: topics, ACL sync Job"]
    kadm --> con["connect: Connect cluster"]
    ds --> con
    con --> c3["control-center"]
    con --> conn["connectors: connectors/*.json"]
```

## 5. Responsibilities

| Actor / component | Owns |
|---|---|
| Developer | `connectors/*.json` via pull requests |
| Admin | PR review and squash-merge, `templates/`, `platform/`, connector registry, Vault credentials, topics |
| GitHub Actions | Validation of the PR against the trusted templates/registry from the base branch |
| Flux | Pull-only sync of `main`, ordered stages, prune on delete |
| CFK | Kafka, KRaft, Connect, Control Center, Connector CRs |
| Vault + ESO | All credentials; one Kafka user per connector |
| ACL sync Job | Reconciles ACLs from the registry (least privilege per connector) |

## UI access (via port-forward)

| UI | URL | Credentials |
|---|---|---|
| Vault | https://localhost:8200 | root token in `.secrets/vault-init.json` |
| Flux UI | http://localhost:9080 | anonymous, read-only |
| Control Center | https://localhost:9021 | `c3-admin` / `c3-viewer` from Vault `kv/kafka/control-center` |
