# aurora-postgres-server

A nullplatform dependency service that provisions and manages a shared **Amazon Aurora PostgreSQL cluster** on AWS. It acts as the infrastructure layer in a two-tier database architecture, creating the actual Aurora cluster (writer + configurable readers) that one or more [`aurora-postgres-db`](../aurora-postgres-db) services consume.

## What It Does

- Provisions an Aurora PostgreSQL cluster (`aws_rds_cluster` + `aws_rds_cluster_instance` × (1 writer + `reader_count` readers)) inside a VPC using Terraform (via OpenTofu)
- Stores the master password in AWS Secrets Manager (`nullplatform/aurora/<instance>/master`)
- Creates a dedicated security group allowing port 5432 within the VPC
- Manages per-link databases and users: each link to an application creates a dedicated PostgreSQL database and user with scoped grants
- Stores connection metadata (writer endpoint, reader endpoint) in nullplatform service attributes so linked services and `aurora-postgres-db` can discover the cluster

## Architecture

```
nullplatform Application
        │
        │ link (creates DB + user)
        ▼
aurora-postgres-server  ──────► AWS Aurora PostgreSQL Cluster
  (this service)                 │  ├─ Writer instance + N reader instances
                                  │  ├─ Security Group (port 5432, VPC-scoped)
                                  │  ├─ Secrets Manager (master password)
                                  │  └─ S3 Bucket (Terraform state)
        └─ per link:
             postgresql_database.<link_name>
             postgresql_role.<link_name>
             postgresql_grant.*
```

## Nullplatform Integration

- **Dependency service type**: registered as a `dependency` service in nullplatform
- **Provider resolution**: reads `account.region` and `vpc.id` from account-level nullplatform providers at creation time
- **Service attributes**: writes Aurora connection metadata back to nullplatform via `np service patch` after provisioning
- **Link attributes**: writes per-link DB credentials to link attributes via `np link patch` so applications can consume them as environment variables
- **Dimension matching**: supports nullplatform dimensions so multiple environments (e.g., `cluster: prod`, `cluster: staging`) can have isolated Aurora clusters

### Service Attributes (written after create)

| Attribute | Visibility | Description |
|---|---|---|
| `hostname` | exported | Aurora cluster writer endpoint |
| `hostname_reader` | exported | Aurora cluster reader endpoint (routes to the writer if `reader_count = 0`) |
| `port` | exported | Aurora port (5432) |
| `db_cluster_identifier` | internal | AWS Aurora cluster identifier |
| `master_secret_arn` | internal | Secrets Manager ARN for master credentials |
| `engine_family` | internal | Always `"aurora-postgresql"` — used only by `aurora-postgres-db`'s auto-discovery to disambiguate this server from other database dependency services (e.g. a classic RDS `rds-postgres-server`) sharing the same dimensions |

### Link Attributes (written per link)

| Attribute | Description |
|---|---|
| `username` | PostgreSQL user for this link |
| `password` | PostgreSQL password (injected as secret) |
| `database_name` | PostgreSQL database name for this link |

## Configuration Parameters

| Parameter | Type | Default | Allowed Values | Editable After Create |
|---|---|---|---|---|
| `instance_class` | string | `db.r6g.large` | `db.t4g.medium`, `db.r6g.large`, `db.r6g.xlarge`, `db.r6g.2xlarge`, `db.r6g.4xlarge` | Yes |
| `reader_count` | number | `0` | 0–15 | Yes |
| `postgres_version` | string | `16` | `13`, `14`, `15`, `16` | No |

> `postgres_version` cannot be changed after creation, mirroring `rds-postgres-server`'s `postgres_version` immutability — major version upgrades require manual intervention.
> `reader_count` is safe to change at any time: Terraform adds/removes `aws_rds_cluster_instance` resources by index, not by writer/reader role — Aurora's cluster endpoints (`hostname`/`hostname_reader`) always route to whichever instance currently holds that role, re-electing a writer automatically on failover.

## Workflows

| Workflow | Trigger | What It Does |
|---|---|---|
| `create` | Service created | Provisions the Aurora cluster, writer + reader instances, security group, Secrets Manager secret, S3 tfstate bucket |
| `update` | Service updated | Applies Terraform changes (instance class, reader count) |
| `delete` | Service deleted | Destroys the cluster and all instances; **no final snapshot is taken** |
| `link` | Application linked | Creates a PostgreSQL database + user with `CONNECT`, `USAGE`, and DML grants |
| `unlink` | Application unlinked | Revokes grants only; database and user are **preserved** for data retention |

## Requirements

See [`specs/install/README.md`](specs/install/README.md) to register the service on a nullplatform account, and [`specs/requirements/aws`](specs/requirements/aws) for the AssumeRole IAM role/policies the agent needs. Applying `requirements/aws` creates the role `nullplatform-<cluster_name>-aurora-postgres-server-role`. The AssumeRole setup steps (apply `requirements/`, grant the agent `sts:AssumeRole`, register an `identity-access-control` provider with selector `aurora-postgres-server`) are identical in shape to `rds-postgres-server`'s — only the role/selector name changes.

The VPC must have private subnets tagged `nullplatform/subnet-type=private`, same as `rds-postgres-server`.

## Important Considerations

### Data Loss on Delete

The cluster uses `skip_final_snapshot = true`. **Deleting the service permanently destroys all data** with no automated backup, across every instance in the cluster.

### Unlink Preserves Data

Only PostgreSQL **grants are revoked** on unlink — the database and user are preserved.

### Dimension Alignment

For `aurora-postgres-db` services to auto-discover this server, both services must share the same nullplatform dimensions (e.g., `cluster: prod`). Mismatched dimensions will cause discovery to fail.

### Do Not Run Alongside `rds-postgres-server` With the Same Dimensions Unless You Understand the Discovery Filter

`aurora-postgres-db` disambiguates its auto-discovery from a classic `rds-postgres-server` via the internal `engine_family` attribute this service writes. If you fork this service further, keep `engine_family = "aurora-postgresql"` in `write_service_outputs` — removing it re-opens the ambiguous-discovery failure mode.
