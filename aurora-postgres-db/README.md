# aurora-postgres-db

A nullplatform dependency service that provisions and manages a **PostgreSQL database** within an existing Aurora cluster managed by [`aurora-postgres-server`](../aurora-postgres-server). It handles database creation, app-level user management, and per-link fine-grained access control — without creating any AWS infrastructure itself.

## What It Does

- Auto-discovers a compatible `aurora-postgres-server` in the same nullplatform namespace using dimension matching **and** an internal `engine_family = "aurora-postgresql"` attribute (disambiguates from a classic RDS `rds-postgres-server` that might share the same dimensions)
- Creates a dedicated PostgreSQL database and application-level user within that cluster
- Manages per-link permissions: each link to an application applies scoped grants (`read`, `write`, or `read-write`) to the single, shared service-level PostgreSQL user — links do not get their own user, only their own grant set
- Stores connection credentials in nullplatform service and link attributes for injection into applications

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

Unlike `aurora-postgres-server`, this service creates no AWS resources. It only manages PostgreSQL-level objects on the shared Aurora cluster: one database and one role at service level, plus per-link grants on that same role — unlike `aurora-postgres-server`, which creates a dedicated role per link.

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
| `master_secret_arn` | internal | Secrets Manager ARN (used for link operations) |

### Link Attributes (written per link)

| Attribute | Description |
|---|---|
| `username` | The service-level PostgreSQL user, mirrored to the link (same value for every link on this service) |
| `password` | The service-level PostgreSQL password, mirrored to the link |
| `database_name` | Database name (same as service-level database) |

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
| `create` | Service created | Auto-discovers server, creates database + app user, writes service attributes |
| `update` | Service updated | No-op (no configurable parameters) |
| `delete` | Service deleted | Reassigns owned objects to master, destroys app user; **database is preserved** |
| `link` | Application linked | Applies scoped grants for this link to the existing service-level PostgreSQL user |
| `unlink` | Application unlinked | Revokes grants only; user and database are **preserved** |

## Database and Username Derivation

```
database_name = "app_<application_id>"
username      = "app_<application_id>"
```

This is a service-level derivation only — there is no separate per-link username. Every link on the same service shares this one PostgreSQL user, distinguished only by the grants each link's `access_level` applies to it.

## Requirements

- An active **`aurora-postgres-server`** service in the same nullplatform namespace with `status: active`, matching dimensions, and `hostname`/`master_secret_arn`/`engine_family` attributes already set.
- See [`specs/install/README.md`](specs/install/README.md) and [`specs/requirements/aws`](specs/requirements/aws) for platform registration and the AssumeRole IAM role (selector `aurora-postgres-db`; Secrets Manager read access scoped to `nullplatform/aurora/*`).

## Important Considerations

These match `rds-postgres-db`'s documented behavior exactly (same Terraform design in `db_setup`/`permissions`):

- **Database is never destroyed**: `lifecycle { prevent_destroy = true }` on `postgresql_database.app`.
- **Two-phase deletion**: `reassign_owned` transfers ownership to master, then a targeted `tofu destroy` removes only the app role.
- **Stable password**: the single service-level password is keyed by `service_id` and shared by every link — there is no separate per-link password.
- **`read-write` allows schema modifications** (`CREATE` on `public`).
- **Dimension + engine_family alignment is critical** for discovery to succeed.
- **Orphaned PostgreSQL roles from failed creates**: `app_<application_id>` is stable across retries — a failed create that got as far as creating the role but not writing `hostname` leaves an orphaned role; a later `create` retry fails with `role "app_<application_id>" already exists`. Connect with master credentials and `DROP ROLE IF EXISTS app_<application_id>;` (after reassigning/dropping any owned objects) before retrying.
