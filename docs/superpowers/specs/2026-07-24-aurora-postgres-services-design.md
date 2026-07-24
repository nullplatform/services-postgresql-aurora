# Aurora PostgreSQL nullplatform services — design

## Context

`nullplatform/services-rds` implements a two-tier dependency-service pattern
for Amazon RDS PostgreSQL:

- **`rds-postgres-server`** — provisions the AWS infrastructure (a single
  `aws_db_instance`, security group, Secrets Manager master secret, per-service
  S3 tfstate bucket).
- **`rds-postgres-db`** — auto-discovers a compatible `rds-postgres-server` in
  the same nullplatform namespace (via dimension matching), and manages
  PostgreSQL-level objects (database, app user, per-link users/grants) on top
  of it, without creating any AWS resources itself.

This design ports that same pattern to **Amazon Aurora PostgreSQL**, as a new
project `services-aurora` living at
`~/Documents/code/nullplatform/lulobank/services-aurora`, structured as its
own local git repository (no remote).

## Scope decisions (confirmed with user)

- Engine: **Aurora PostgreSQL only** (not MySQL). This lets the "db" layer
  (`aurora-postgres-db`) reuse the `cyrilgdn/postgresql` Terraform provider
  and almost all of `rds-postgres-db`'s Terraform/scripts unchanged.
- Capacity mode: **Provisioned only** (fixed `instance_class`), no Aurora
  Serverless v2.
- Topology: **writer + N configurable readers** (`reader_count`, 0–15,
  editable post-create), not a fixed single-instance or fixed writer+1.
- Naming: root folder `services-aurora`; services `aurora-postgres-server`
  and `aurora-postgres-db` (mirrors `services-rds` / `rds-postgres-server` /
  `rds-postgres-db` naming convention).
- Repo: initialize `services-aurora` as its own local git repo (`git init` +
  first commit), same as `services-rds`.

## Architecture

```
services-aurora/
├── Dockerfile                       (copied as-is — placeholder echo server)
├── .trivyignore
├── README.md
├── aurora-postgres-server/          — provisions the Aurora cluster in AWS
│   ├── deployment/                  aws_rds_cluster + aws_rds_cluster_instance × (1 + reader_count)
│   ├── entrypoint/                  (entrypoint, service, link — unchanged from rds-postgres-server)
│   ├── permissions/                 (postgresql provider config — unchanged)
│   ├── scripts/aws/                 (assume_role*, build_context, do_tofu, write_service_outputs,
│   │                                 write_link_outputs, build_permissions_context, delete_tfstate_bucket,
│   │                                 reassign_owned — adapted for cluster outputs)
│   ├── specs/
│   │   ├── install/aws/             (service registration — same pattern, new service_path)
│   │   ├── requirements/aws/        (IAM role/policies — RDS actions extended for clusters)
│   │   ├── links/connect.json.tpl   (unchanged shape)
│   │   └── service-spec.json.tpl    (new params: reader_count; drops allocated_storage, multi_az;
│   │                                 new internal attr: engine_family, hostname_reader)
│   ├── values.yaml
│   ├── workflows/aws/{create,update,delete,link,unlink}.yaml  (unchanged shape)
│   └── README.md
└── aurora-postgres-db/              — logical DB inside the cluster (auto-discovery)
    ├── db_setup/, permissions/      (unchanged — same postgresql_database/role/grant resources)
    ├── entrypoint/, scripts/aws/    (build_db_setup_context: discovery filter gains engine_family check)
    ├── specs/...
    ├── values.yaml
    ├── workflows/aws/...
    └── README.md
```

## `aurora-postgres-server` — deltas from `rds-postgres-server`

### `deployment/`

| Original (`aws_db_instance`) | Aurora (`aws_rds_cluster` + `aws_rds_cluster_instance`) |
|---|---|
| One `aws_db_instance` resource | `aws_rds_cluster` (cluster control plane) + `aws_rds_cluster_instance` with `count = 1 + var.reader_count` |
| `var.multi_az` (bool) | Removed — `var.reader_count` (0–15) replaces it; each additional instance is real HA |
| `var.allocated_storage` | Removed — Aurora storage auto-scales, not declared |
| `backup_window` / `maintenance_window` variables | Same nullplatform-facing param names; map internally to `aws_rds_cluster`'s `preferred_backup_window` / `preferred_maintenance_window` |
| output `hostname` = instance address | output `hostname` = `aws_rds_cluster.main.endpoint` (writer/cluster endpoint) |
| — | new output `hostname_reader` = `aws_rds_cluster.main.reader_endpoint` (load-balances across readers; if `reader_count = 0` it still resolves, routing to the writer) |
| output `db_instance_identifier` | output `db_cluster_identifier` |
| SG (port 5432, all VPC CIDR associations), subnet group, Secrets Manager master secret, `storage_encrypted = true`, `skip_final_snapshot = true`, `deletion_protection = false` | **Unchanged** |

Secrets Manager secret name changes prefix: `nullplatform/aurora/<instance_name>/master`
(was `nullplatform/rds/...`) — see Discovery disambiguation below.

### Configuration parameters (`specs/service-spec.json.tpl`)

| Parameter | Type | Default | Editable after create | Notes |
|---|---|---|---|---|
| `instance_class` | string | `db.r6g.large` | Yes | Aurora instance classes (`db.r6g.*`, `db.t4g.*`), not RDS classic classes |
| `reader_count` | number | `0` | Yes | 0–15. Changing it adds/removes `aws_rds_cluster_instance` resources |
| `postgres_version` | string | `16` | No | Major-version-only, `enum: ["13", "14", "15", "16"]`, same UX as original — AWS resolves latest minor |
| `backup_retention_period`, `backup_window`, `maintenance_window` | — | same as original | Yes | Same names/defaults as `rds-postgres-server`, mapped to Aurora cluster attribute names internally |
| `hostname` | string | — | export, read-only | Cluster writer endpoint |
| `hostname_reader` | string | — | export, read-only | **New.** Cluster reader endpoint |
| `port` | number | — | export, read-only | 5432 |
| `db_cluster_identifier`, `master_secret_arn`, `engine_family` | — | internal only | not exported | `engine_family = "aurora-postgresql"`, written at create; used only for `aurora-postgres-db` auto-discovery |

### IAM (`specs/requirements/aws/main.tf`)

Same 4-policy shape as the original (RDS / EC2 SG / Secrets Manager / S3),
role named `nullplatform-<cluster_name>-aurora-postgres-server-role`. The RDS
policy gains cluster-level actions:

```
rds:CreateDBCluster, DeleteDBCluster, ModifyDBCluster, DescribeDBClusters
rds:CreateDBInstance, DeleteDBInstance, ModifyDBInstance, DescribeDBInstances   (cluster instances)
rds:CreateDBSubnetGroup, DeleteDBSubnetGroup, DescribeDBSubnetGroups, ModifyDBSubnetGroup
rds:AddTagsToResource, ListTagsForResource, RemoveTagsFromResource
rds:DescribeDBClusterParameterGroups, DescribeDBEngineVersions, DescribeOrderableDBInstanceOptions
iam:CreateServiceLinkedRole
```

EC2 security-group, S3 tfstate, and Secrets Manager policies are otherwise
identical to the original (same actions, same `np-service-*` / secret-ARN
resource scoping — only the secret-ARN prefix changes, see below).

## `aurora-postgres-db` — deltas from `rds-postgres-db`

Functionally identical: same `postgresql_database` / `postgresql_role` /
`postgresql_grant` / `postgresql_default_privileges` resources in `db_setup/`
and `permissions/`, same `access_level` grants table (`read` / `write` /
`read-write`), same two-phase deletion (`reassign_owned` then targeted
`tofu destroy`), same database-name/username derivation from
`application_id` / `link_id`. IAM role renamed
`nullplatform-<cluster_name>-aurora-postgres-db-role`; its Secrets Manager
read policy is scoped to `nullplatform/aurora/*` instead of `nullplatform/rds/*`.

### Auto-discovery disambiguation (the one substantive design addition)

`rds-postgres-db`'s `build_db_setup_context` discovers its server with:

```
np service list --type dependency --status active
  | select(hostname and master_secret_arn set, dimensions match)
```

This does **not** filter by which service definition produced the match. If
an `rds-postgres-server` and an `aurora-postgres-server` ever coexist in the
same namespace with the same dimensions, both satisfy that filter, and
`aurora-postgres-db` would hard-fail with "multiple servers found" — a safe
failure, but avoidable friction.

Fix (additive only — `services-rds` is not touched):

1. `aurora-postgres-server` writes an internal (non-exported) attribute
   `engine_family: "aurora-postgresql"` at create time.
2. `aurora-postgres-db/scripts/aws/build_db_setup_context` adds
   `.attributes.engine_family == "aurora-postgresql"` to its `jq` selection
   filter, alongside the existing hostname/master_secret_arn/dimensions
   checks.

Since classic `rds-postgres-server` instances never have `engine_family` set,
they're excluded automatically — no changes needed on that side.

## Inherited behaviors / considerations (unchanged from `services-rds`, carried into the new README)

- **Data loss on delete**: `skip_final_snapshot = true` on the cluster — deleting
  the service destroys the cluster and all reader instances with no automated
  backup.
- **Unlink preserves data**: only grants are revoked; database/user survive.
- **Dimension alignment** between `aurora-postgres-server` and
  `aurora-postgres-db` is required for discovery to succeed.
- **Orphaned PostgreSQL roles from failed creates**: same root cause/remedy as
  the original (`app_<application_id>` is stable across retries).
- **`reader_count` scaling is safe by construction**: Terraform manages
  `aws_rds_cluster_instance` resources by index, not by writer/reader role.
  This works because the cluster's `endpoint` / `reader_endpoint` always
  route to whichever instance currently holds that role — Aurora re-elects a
  writer automatically on failover, independent of Terraform's resource
  indexing.

## Validation plan

Executable in this environment, after scaffolding:

- `tofu validate` + `tofu fmt -check` on every new Terraform module
  (`deployment`, `permissions`, `db_setup`, `requirements/aws`, `install/aws`).
- `bash -n` syntax check on every adapted script.
- `jq`/YAML well-formedness checks on `service-spec.json.tpl`,
  `connect.json.tpl`, `values.yaml`.

**Not executable here** (explicitly out of scope for this session): a live
`tofu plan`/`apply` against a real AWS account/VPC, or a full
`create → link → unlink → delete` cycle against a real nullplatform account.
Those remain manual verification steps for the user before treating this as
production-ready.
