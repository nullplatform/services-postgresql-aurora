# aurora-postgres-db

A nullplatform dependency service that provisions and manages a **PostgreSQL database** within an existing Aurora cluster managed by [`aurora-postgres-server`](../aurora-postgres-server). It handles database creation, app-level user management, and per-link fine-grained access control. Unlike `aurora-postgres-server`, it does not provision any Aurora/EC2 infrastructure — the one AWS resource it does create is the Secrets Manager secret holding the app-level PostgreSQL credentials.

## What It Does

- Auto-discovers a compatible `aurora-postgres-server` in the same nullplatform namespace using dimension matching **and** an internal `engine_family = "aurora-postgresql"` attribute (disambiguates from a classic RDS `rds-postgres-server` that might share the same dimensions)
- Creates a dedicated PostgreSQL database and application-level user within that cluster
- Manages per-link permissions: each link to an application applies scoped grants (`read`, `write`, or `read-write`) to the single, shared service-level PostgreSQL user — links do not get their own user, only their own grant set
- Stores connection credentials in nullplatform service and link attributes for injection into applications, and mirrors the app-level credentials into a Secrets Manager secret (same convention as the `aurora-postgres-server` master secret)

## Architecture

```
nullplatform Application
        │
        │ link (applies grants to the shared service-level user)
        ▼
 aurora-postgres-db  ──────► aurora-postgres-server  ──────► AWS Aurora PostgreSQL
  (this service)              (auto-discovered)                │
        │                                                       ├─ database: app_<application_id>
        │                                                       └─ user: app_<application_id>  (service-level, shared by every link)
        └─ per link:
             postgresql_grant.*  (on the existing service-level user — no new role is created)
```

Unlike `aurora-postgres-server`, this service creates no Aurora/EC2 infrastructure — it only manages PostgreSQL-level objects on the shared Aurora cluster: one database and one role at service level, plus per-link grants on that same role, plus one Secrets Manager secret for the app-level credentials it generates.

## Nullplatform Integration

- **Dependency service type**: registered as a `dependency` service in nullplatform
- **Auto-discovery**: at creation time, queries nullplatform for `dependency` services in the same namespace with `status=active`, attributes `hostname` + `master_secret_arn` set, `engine_family == "aurora-postgresql"`, filtered by matching dimensions
- **Service attributes**: writes connection metadata back to nullplatform via `np service patch`
- **Link attributes**: writes per-link credentials to nullplatform via `np link patch` for injection into application environment

### Service Attributes (written after create)

| Attribute | Visibility | Description |
|---|---|---|
| `hostname` | exported | Aurora writer endpoint |
| `port` | exported | Aurora port (5432) |
| `username` | exported | Service-level PostgreSQL user |
| `password` | hidden | Service-level PostgreSQL password |
| `database_name` | exported | PostgreSQL database name |
| `master_secret_arn` | internal | Secrets Manager ARN for the `aurora-postgres-server` master credentials (used for link operations) |
| `app_secret_arn` | internal | Secrets Manager ARN for this service's own app-level credentials |

### Link Attributes (written per link)

| Attribute | Description |
|---|---|
| `username` | The service-level PostgreSQL user, mirrored to the link (same value for every link on this service) |
| `password` | The service-level PostgreSQL password, mirrored to the link |
| `database_name` | Database name (same as service-level database) |
| `app_secret_arn` | Secrets Manager ARN for the service-level app credentials (mirrored from the service attribute) |

## Link Parameters

| Parameter | Type | Required | Default | Allowed Values |
|---|---|---|---|---|
| `access_level` | enum | No | `read-write` | `read`, `write`, `read-write` |

### Access Level Grants

| Level | Grants |
|---|---|
| `read` | `CONNECT` on database, `USAGE` on schema, `SELECT` on tables and sequences |
| `write` | `CONNECT` on database, `USAGE` on schema, `INSERT`, `UPDATE`, `DELETE` on tables, `USAGE` on sequences |
| `read-write` | All of the above + `CREATE` on schema (allows running migrations) |

## Workflows

| Workflow | Trigger | What It Does |
|---|---|---|
| `create` | Service created | Auto-discovers server, creates database + app user, stores app credentials in Secrets Manager, writes service attributes |
| `update` | Service updated | No-op (no configurable parameters) |
| `delete` | Service deleted | Reassigns owned objects to master, destroys app user and its Secrets Manager secret; **database is preserved** |
| `link` | Application linked | Applies scoped grants for this link to the existing service-level PostgreSQL user |
| `unlink` | Application unlinked | Revokes grants only; user and database are **preserved** |

## Database and Username Derivation

```
database_name = "app_<application_id>"
username      = "app_<application_id>"
```

This is a service-level derivation only — there is no separate per-link username. Every link on the same service shares this one PostgreSQL user, distinguished only by the grants each link's `access_level` applies to it.

## Infrastructure Resources Created

| Resource | Description |
|---|---|
| `postgresql_database` | The application database (preserved on delete) |
| `postgresql_role` | The service-level app user |
| `aws_secretsmanager_secret` | Stores the app-level credentials (`nullplatform/aurora/<service_id>/app`); destroyed alongside the app user on service delete |

The app secret is encrypted with whatever KMS key the auto-discovered `aurora-postgres-server` has in its `secret_kms_key_id` attribute, so a cluster's master secret and all of its app secrets share one customer-managed key and one revocation point. When the server leaves it unset, AWS encrypts the app secret with the default `aws/secretsmanager` managed key. There is no per-database override: the key is an infrastructure-level choice that belongs on the server.

No Aurora, EC2, or VPC resources are created — those belong to the auto-discovered `aurora-postgres-server`.

## Requirements

- An active **`aurora-postgres-server`** service in the same nullplatform namespace with `status: active`, matching dimensions, and `hostname`/`master_secret_arn`/`engine_family` attributes already set.
- [`specs/requirements/aws`](specs/requirements/aws) creates the AssumeRole IAM role (selector `aurora-postgres-db`; Secrets Manager access — read the master secret, full lifecycle on the app secret it owns — scoped to `nullplatform/aurora/*`, plus `kms:Decrypt`/`kms:GenerateDataKey` scoped by `kms:ViaService` to Secrets Manager so a customer-managed `secret_kms_key_id` works). As with `rds-postgres-db`, this grant is shared per cluster, not per instance: anything that assumes the role can create/update/delete any secret under that prefix, not just its own.

## Install in your organization

The service is published once as the package `np-aurora-postgres-db` (specification "Aurora PostgreSQL DB"), visible to every organization. You do not copy its specs: you install the package and use it read-only. How installing a package works, how it coexists with a copy you registered, how to upgrade, and when to fork instead are in the [package installation guide](https://docs.nullplatform.com/docs/packages/install); this section has what is specific to this service.

Already registered a copy from the former `specs/install`? It keeps working: it called tofu-modules' `service_definition` on specs that stay in every release, and the package installs next to it, as the guide explains. If you sourced that directory as a module, pin its `?ref` to a release that still has it.

Installing it touches the same three layers as registering a service yourself, and only the nullplatform layer changes:

| Layer | What | Module |
|---|---|---|
| infrastructure (AWS credentials) | The IAM role the service assumes | [`specs/requirements/aws`](specs/requirements/aws) |
| nullplatform (nullplatform API key) | The installation of the package and the agent channel | tofu-modules' `service_package_installation` |
| bindings | The role under selector `aurora-postgres-db` in your IAM provider | your `aws-iam-configuration` provider |

Pick ONE release of this repository (the latest is on its [releases page](https://github.com/nullplatform/services-postgresql-aurora/releases)) and use its version in both places below: the IAM role is the one the worker of that same release expects. Both services of this repository share the release, so install them at the same version.

```hcl
# ── infrastructure layer ─────────────────────────────────────────────
module "aurora_postgres_db_requirements" {
  source       = "git::https://github.com/nullplatform/services-postgresql-aurora.git//aurora-postgres-db/specs/requirements/aws?ref=vX.Y.Z"
  cluster_name = "<nullplatform agent cluster>"
}

# The agent role must be allowed to assume it: add it to the assume_role_arns
# of tofu-modules' infrastructure/aws/iam/agent.
#   assume_role_arns = [..., module.aurora_postgres_db_requirements.permissions_role_arn]

# ── nullplatform layer ───────────────────────────────────────────────
# For a service the installation is the whole nullplatform side, channel included.
module "aurora_postgres_db" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_package_installation?ref=v9.16.0"

  nrn                  = var.nrn
  package_slug         = "np-aurora-postgres-db"
  package_version      = "X.Y.Z" # the same release, without the v
  agent_tags_selectors = { cluster = "runtime" } # must match the agent's TAGS
}
# Keeping channels in a separate bindings layer instead? Use
# nullplatform/package_installation here and service_definition_agent_association
# there, with package_slug = "np-aurora-postgres-db".

# ── bindings layer ───────────────────────────────────────────────────
# One aws-iam-configuration per NRN and dimensions, at the account level: add
# the entry to the list your IAM provider already has. Both services of this
# repository go in the SAME provider, one selector each.
#   { selector = "aurora-postgres-db", arn = module.aurora_postgres_db_requirements.permissions_role_arn }
```

The service assumes the role it finds under selector `aurora-postgres-db` in the IAM provider closest to its NRN. To upgrade, move the release in both layers: `ref` of the requirements module and `package_version` of the installation. See tofu-modules' [`service_package_installation`](https://github.com/nullplatform/tofu-modules/tree/main/nullplatform/service_package_installation) for its inputs and outputs.

Prerequisites: an agent whose `TAGS` match the channel's `tags_selectors`, with `public.ecr.aws/nullplatform/*` in `worker.allowedRegistries` and `np-aurora-postgres-db` in its `worker_orchestrated_packages` (the worker then runs with the agent's identity, the one the role trusts); it also needs an active `aurora-postgres-server` service with matching dimensions in the same namespace.

## How the package is published

Every release publishes a new revision of the package from this repository, in the same run that pushes the worker image ([`.github/workflows/release.yml`](../.github/workflows/release.yml)): the `publish-package` job applies [`aurora-postgres-db/publish`](publish), a stack on tofu-modules' `service_package_publish`, which pins this tag's specs and the image by digest. The package version is the release tag, as for the image. The stack keeps its state where the organization secrets `PACKAGE_STATE_AWS_ACCOUNT_ID`, `PACKAGE_TFSTATE_BUCKET` and `PACKAGE_TFSTATE_REGION` point; the state role is `github-actions-<repository>-package-state` in that account, by convention.

## Important Considerations

These match `rds-postgres-db`'s documented behavior exactly (same Terraform design in `db_setup`/`permissions`):

- **Database is never destroyed**: `lifecycle { prevent_destroy = true }` on `postgresql_database.app`.
- **Two-phase deletion**: `reassign_owned` transfers ownership to master, then a targeted `tofu destroy` removes only the app role.
- **Stable password**: the single service-level password is keyed by `service_id` and shared by every link — there is no separate per-link password.
- **`read-write` allows schema modifications** (`CREATE` on `public`).
- **Dimension + engine_family alignment is critical** for discovery to succeed.
- **Orphaned PostgreSQL roles from failed creates**: `app_<application_id>` is stable across retries — a failed create that got as far as creating the role but not writing `hostname` leaves an orphaned role; a later `create` retry fails with `role "app_<application_id>" already exists`. Connect with master credentials and `DROP ROLE IF EXISTS app_<application_id>;` (after reassigning/dropping any owned objects) before retrying.
