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
| `secret_kms_key_id` | string | _(none)_ | Any KMS key ID/ARN in the account | Yes |

> `postgres_version` cannot be changed after creation, mirroring `rds-postgres-server`'s `postgres_version` immutability — major version upgrades require manual intervention.
> `reader_count` is safe to change at any time: Terraform adds/removes `aws_rds_cluster_instance` resources by index, not by writer/reader role — Aurora's cluster endpoints (`hostname`/`hostname_reader`) always route to whichever instance currently holds that role, re-electing a writer automatically on failover.
> `secret_kms_key_id` controls which KMS key encrypts the master password secret in Secrets Manager. If left unset, AWS encrypts it with the default `aws/secretsmanager` managed key — pass a customer-managed key ARN here only if this instance requires its own key. This is unrelated to the customer-managed key already used for cluster storage encryption (`aws_kms_key.aurora`). Using it requires the `kms:Decrypt`/`kms:GenerateDataKey` grant in [`specs/requirements/aws`](specs/requirements/aws), scoped by `kms:ViaService` to Secrets Manager; the key's own key policy must also allow this role.

## Workflows

| Workflow | Trigger | What It Does |
|---|---|---|
| `create` | Service created | Provisions the Aurora cluster, writer + reader instances, security group, Secrets Manager secret, S3 tfstate bucket |
| `update` | Service updated | Applies Terraform changes (instance class, reader count) |
| `delete` | Service deleted | Destroys the cluster and all instances; **no final snapshot is taken** |
| `link` | Application linked | Creates a PostgreSQL database + user with `CONNECT`, `USAGE`, and DML grants |
| `unlink` | Application unlinked | Revokes grants only; database and user are **preserved** for data retention |

## Requirements

Applying [`specs/requirements/aws`](specs/requirements/aws) creates the role `nullplatform-<cluster_name>-aurora-postgres-server-role` the worker assumes; the rest of the setup is in [Install in your organization](#install-in-your-organization) below.

The VPC must have private subnets tagged `nullplatform/subnet-type=private`, same as `rds-postgres-server`.

## Install in your organization

The service is published once as the package `np-aurora-postgres-server` (specification "Aurora PostgreSQL Server"), visible to every organization. You do not copy its specs: you install the package and use it read-only. How installing a package works, how it coexists with a copy you registered, how to upgrade, and when to fork instead are in the [package installation guide](https://docs.nullplatform.com/docs/packages/install); this section has what is specific to this service.

Already registered a copy from the former `specs/install`? It keeps working: it called tofu-modules' `service_definition` on specs that stay in every release, and the package installs next to it, as the guide explains. If you sourced that directory as a module, pin its `?ref` to a release that still has it.

Installing it touches the same three layers as registering a service yourself, and only the nullplatform layer changes:

| Layer | What | Module |
|---|---|---|
| infrastructure (AWS credentials) | The IAM role the service assumes | [`specs/requirements/aws`](specs/requirements/aws) |
| nullplatform (nullplatform API key) | The installation of the package and the agent channel | tofu-modules' `service_package_installation` |
| bindings | The role under selector `aurora-postgres-server` in your IAM provider | your `aws-iam-configuration` provider |

Pick ONE release of this repository (the latest is on its [releases page](https://github.com/nullplatform/services-postgresql-aurora/releases)) and use its version in both places below: the IAM role is the one the worker of that same release expects. Both services of this repository share the release, so install them at the same version.

```hcl
# ── infrastructure layer ─────────────────────────────────────────────
module "aurora_postgres_server_requirements" {
  source       = "git::https://github.com/nullplatform/services-postgresql-aurora.git//aurora-postgres-server/specs/requirements/aws?ref=vX.Y.Z"
  cluster_name = "<nullplatform agent cluster>"
}

# The agent role must be allowed to assume it: add it to the assume_role_arns
# of tofu-modules' infrastructure/aws/iam/agent.
#   assume_role_arns = [..., module.aurora_postgres_server_requirements.permissions_role_arn]

# ── nullplatform layer ───────────────────────────────────────────────
# For a service the installation is the whole nullplatform side, channel included.
module "aurora_postgres_server" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_package_installation?ref=v9.16.0"

  nrn                  = var.nrn
  package_slug         = "np-aurora-postgres-server"
  package_version      = "X.Y.Z" # the same release, without the v
  agent_tags_selectors = { cluster = "runtime" } # must match the agent's TAGS
}
# Keeping channels in a separate bindings layer instead? Use
# nullplatform/package_installation here and service_definition_agent_association
# there, with package_slug = "np-aurora-postgres-server".

# ── bindings layer ───────────────────────────────────────────────────
# One aws-iam-configuration per NRN and dimensions, at the account level: add
# the entry to the list your IAM provider already has. Both services of this
# repository go in the SAME provider, one selector each.
#   { selector = "aurora-postgres-server", arn = module.aurora_postgres_server_requirements.permissions_role_arn }
```

The service assumes the role it finds under selector `aurora-postgres-server` in the IAM provider closest to its NRN. To upgrade, move the release in both layers: `ref` of the requirements module and `package_version` of the installation. See tofu-modules' [`service_package_installation`](https://github.com/nullplatform/tofu-modules/tree/main/nullplatform/service_package_installation) for its inputs and outputs.

Prerequisites: an agent whose `TAGS` match the channel's `tags_selectors`, with `public.ecr.aws/nullplatform/*` in `worker.allowedRegistries` and `np-aurora-postgres-server` in its `worker_orchestrated_packages` (the worker then runs with the agent's identity, the one the role trusts), and the `aws-configuration` and `aws-networking-configuration` providers at the NRN or above it.

## How the package is published

Every release publishes a new revision of the package from this repository, in the same run that pushes the worker image ([`.github/workflows/release.yml`](../.github/workflows/release.yml)): the `publish-package` job applies [`aurora-postgres-server/publish`](publish), a stack on tofu-modules' `service_package_publish`, which pins this tag's specs and the image by digest. The package version is the release tag, as for the image. The stack keeps its state where the organization secrets `PACKAGE_STATE_AWS_ACCOUNT_ID`, `PACKAGE_TFSTATE_BUCKET` and `PACKAGE_TFSTATE_REGION` point; the state role is `github-actions-<repository>-package-state` in that account, by convention.

## Important Considerations

### Data Loss on Delete

The cluster uses `skip_final_snapshot = true`. **Deleting the service permanently destroys all data** with no automated backup, across every instance in the cluster.

### Unlink Preserves Data

Only PostgreSQL **grants are revoked** on unlink — the database and user are preserved.

### Dimension Alignment

For `aurora-postgres-db` services to auto-discover this server, both services must share the same nullplatform dimensions (e.g., `cluster: prod`). Mismatched dimensions will cause discovery to fail.

### Do Not Run Alongside `rds-postgres-server` With the Same Dimensions Unless You Understand the Discovery Filter

`aurora-postgres-db` disambiguates its auto-discovery from a classic `rds-postgres-server` via the internal `engine_family` attribute this service writes. If you fork this service further, keep `engine_family = "aurora-postgresql"` in `write_service_outputs` — removing it re-opens the ambiguous-discovery failure mode.
