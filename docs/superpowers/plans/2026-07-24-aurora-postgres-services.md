# Aurora PostgreSQL nullplatform services Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port `nullplatform/services-rds`'s two-tier RDS PostgreSQL dependency-service pattern to Amazon Aurora PostgreSQL (provisioned, writer + N configurable readers), as a new standalone repo `services-aurora`.

**Architecture:** Two nullplatform dependency services — `aurora-postgres-server` (provisions an `aws_rds_cluster` + `aws_rds_cluster_instance` fleet, Secrets Manager master secret, security group, per-service S3 tfstate bucket) and `aurora-postgres-db` (auto-discovers a matching `aurora-postgres-server` via nullplatform dimensions + a new `engine_family` attribute, then manages PostgreSQL databases/users/grants on top of it via the `cyrilgdn/postgresql` Terraform provider — no AWS resources of its own).

**Tech Stack:** OpenTofu 1.9.0, Terraform providers `hashicorp/aws ~> 6.0`, `hashicorp/random ~> 3.0`, `cyrilgdn/postgresql ~> 1.21`; bash (agent runtime scripts); nullplatform `np` CLI; AWS CLI; `jq`.

Source reference repo (read-only, do not modify): `~/Documents/code/nullplatform/services-rds`.
New repo root: `~/Documents/code/nullplatform/lulobank/services-aurora` (already `git init`-ed, first commit = the design spec doc).

## Global Constraints

- Engine: **`aurora-postgresql` only.** `postgres_version` enum `["13", "14", "15", "16"]`, default `"16"`, editable only at create (mirrors the original's `postgres_version` immutability).
- Capacity mode: **provisioned only** — `instance_class` string, default `"db.r6g.large"`, editable after create.
- Topology: **writer + `reader_count` readers**, `reader_count` integer 0–15, default `0`, editable after create.
- Terraform state: one S3 bucket per service instance, named `np-service-<SERVICE_ID>`, versioned — identical mechanism to the source repo, not changed.
- Secrets Manager secret name prefix for Aurora master passwords: `nullplatform/aurora/<instance_name>/master` (the source repo uses `nullplatform/rds/...` — the new prefix is required for the auto-discovery disambiguation, see Task 10).
- New internal (non-exported) service attribute on `aurora-postgres-server`: `engine_family = "aurora-postgresql"`, used only by `aurora-postgres-db`'s discovery filter.
- IAM role naming: `nullplatform-<cluster_name>-aurora-postgres-server-role` / `nullplatform-<cluster_name>-aurora-postgres-db-role` (same `<cluster_name>` convention as the source repo — this is a nullplatform "cluster" concept, e.g. an EKS cluster name, unrelated to the Aurora database cluster).
- `aurora-postgres-db` has **no `deployment/` directory** — the source repo's `rds-postgres-db/deployment/` is dead/unused code (confirmed: nothing in its workflows or scripts sets `TOFU_MODULE_DIR` to it), and this port deliberately does not carry that dead code forward.
- Out of scope for this plan: porting `services-rds/.github/workflows/*` (release automation, conventional-commit/branch-validation linting) — those reference nullplatform-internal CI conventions unrelated to whether the Aurora service itself works, and are not required for a working, testable implementation. Note this to the user as a follow-up if they want repo governance parity too.
- Every Terraform-touching task's "test" step is `tofu fmt -recursive <dir>` (auto-fix formatting) followed by `tofu init -backend=false && tofu validate` inside that module directory (no real AWS/state needed for structural validation). Every bash-script task's test step is `bash -n <script>` on every script touched. Where a task changes actual script *logic* (not just renaming), the test step also runs a standalone `jq`/shell assertion against representative fixture data, since these scripts have no AWS/nullplatform sandbox available in this environment.
- Do not modify anything under `~/Documents/code/nullplatform/services-rds` — it is read-only reference material for this plan.

---

### Task 1: Root project scaffold

**Files:**
- Create: `services-aurora/Dockerfile`
- Create: `services-aurora/.trivyignore`
- Create: `services-aurora/.gitignore`
- Create: `services-aurora/README.md`

**Interfaces:**
- Produces: the placeholder container image (`Dockerfile`) and repo-hygiene files every later task's CI/tooling assumes exist at repo root.

- [ ] **Step 1: Copy the Dockerfile verbatim from the source repo**

```bash
cp ~/Documents/code/nullplatform/services-rds/Dockerfile ~/Documents/code/nullplatform/lulobank/services-aurora/Dockerfile
```

- [ ] **Step 2: Copy `.trivyignore` verbatim**

```bash
cp ~/Documents/code/nullplatform/services-rds/.trivyignore ~/Documents/code/nullplatform/lulobank/services-aurora/.trivyignore
```

- [ ] **Step 3: Write `.gitignore`**

The source repo's `.gitignore` is generic Node.js boilerplate that (surprisingly) has no Terraform-specific entries. Write a Terraform-appropriate one instead of copying it verbatim:

Create `services-aurora/.gitignore`:
```
# Terraform / OpenTofu
**/.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!**/terraform.tfvars.example
crash.log
crash.*.log

# IDE
.idea
.vscode-test
```

- [ ] **Step 4: Write the root README**

Create `services-aurora/README.md`:
```markdown
<h2 align="center">
    <a href="https://httpie.io" target="blank_">
        <img height="100" alt="nullplatform" src="https://nullplatform.com/favicon/android-chrome-192x192.png" />
    </a>
    <br>
    <br>
    Nullplatform "Any Technology" Template
    <br>
</h2>

This is a minimalistic sample on how you can create an application on arbitrary technology.
In particular, we're spinning up an image that contains an echo server.
You can check *Echo Server* documentation [here](https://ealenn.github.io/Echo-Server/).

## How do I modify this template to build my own application?

1. Change the Dockerfile to run the application / binary that you are building
2. Deploy your application in nullplatform

## Services in this repo

- [`aurora-postgres-server`](aurora-postgres-server/README.md) — provisions an Aurora PostgreSQL cluster (writer + configurable readers) in AWS.
- [`aurora-postgres-db`](aurora-postgres-db/README.md) — provisions a logical PostgreSQL database + per-link users inside an existing `aurora-postgres-server` cluster.
```

- [ ] **Step 5: Verify and commit**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
ls Dockerfile .trivyignore .gitignore README.md
git add Dockerfile .trivyignore .gitignore README.md
git commit -m "chore: scaffold root project files"
```
Expected: all four files listed with no error, commit succeeds.

---

### Task 2: `aurora-postgres-server/deployment` — the Aurora cluster Terraform module

**Files:**
- Create: `aurora-postgres-server/deployment/variables.tf`
- Create: `aurora-postgres-server/deployment/data.tf`
- Create: `aurora-postgres-server/deployment/main.tf`
- Create: `aurora-postgres-server/deployment/outputs.tf`
- Create: `aurora-postgres-server/deployment/backend.tf`
- Create: `aurora-postgres-server/deployment/providers.tf`

**Interfaces:**
- Consumes: none (first Terraform module in the plan).
- Produces: outputs `hostname`, `hostname_reader`, `port`, `db_cluster_identifier`, `master_secret_arn` — consumed by Task 5 (`write_service_outputs`) and Task 3 (`permissions/` module, via variables passed at link time).

- [ ] **Step 1: Copy `backend.tf` and `providers.tf` verbatim (unchanged from the source repo)**

```bash
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/deployment
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-server/deployment/backend.tf \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/deployment/backend.tf
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-server/deployment/providers.tf \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/deployment/providers.tf
```

- [ ] **Step 2: Copy `data.tf` verbatim (VPC/subnet discovery is identical for Aurora)**

```bash
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-server/deployment/data.tf \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/deployment/data.tf
```

- [ ] **Step 3: Write `variables.tf`**

Create `aurora-postgres-server/deployment/variables.tf`:
```hcl
variable "service_id" {
  type        = string
  description = "Nullplatform service ID"
}

variable "instance_name" {
  type        = string
  description = "Unique instance name for AWS resource naming (format: np-<service_id>)"
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the Aurora cluster will be deployed"
}

variable "instance_class" {
  type        = string
  default     = "db.r6g.large"
  description = "Aurora instance class applied to every cluster instance (writer and readers)"
}

variable "reader_count" {
  type        = number
  default     = 0
  description = "Number of Aurora reader instances in addition to the writer"

  validation {
    condition     = var.reader_count >= 0 && var.reader_count <= 15
    error_message = "reader_count must be between 0 and 15"
  }
}

variable "postgres_version" {
  type        = string
  default     = "16"
  description = "Aurora PostgreSQL major version"
}

variable "backup_retention_period" {
  type        = number
  default     = 7
  description = "Number of days to retain automated backups. 0 disables backups."
}

variable "backup_window" {
  type        = string
  default     = "03:00-04:00"
  description = "Daily time range for automated backups (UTC, hh:mm-hh:mm)"
}

variable "maintenance_window" {
  type        = string
  default     = "Mon:04:00-Mon:05:00"
  description = "Weekly time range for maintenance operations (UTC, ddd:hh:mm-ddd:hh:mm)"
}
```

- [ ] **Step 4: Write `main.tf`**

Create `aurora-postgres-server/deployment/main.tf`:
```hcl
# ---------------------------------------------------------------------------
# Security group for Aurora (allows PostgreSQL traffic from within the VPC)
# ---------------------------------------------------------------------------

resource "aws_security_group" "aurora" {
  name        = "np-aurora-${var.instance_name}"
  description = "Allow PostgreSQL access from within the VPC"
  vpc_id      = var.vpc_id

  ingress {
    from_port = 5432
    to_port   = 5432
    protocol  = "tcp"
    # Use every CIDR block associated with the VPC, not just the primary one.
    # EKS clusters commonly add a secondary CIDR block for pod networking —
    # pods get IPs from the secondary range, so restricting to the primary
    # CIDR silently blocks agent-pod-to-Aurora connectivity.
    cidr_blocks = [for c in data.aws_vpc.main.cidr_block_associations : c.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    "managed-by" = "nullplatform"
    "service-id" = var.service_id
  }
}

# ---------------------------------------------------------------------------
# Master password (stored in Secrets Manager, used by link permissions)
# ---------------------------------------------------------------------------

resource "random_password" "master" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "master" {
  name                    = "nullplatform/aurora/${var.instance_name}/master"
  recovery_window_in_days = 0

  tags = {
    "managed-by"     = "nullplatform"
    "aurora-cluster" = var.instance_name
    "service-id"     = var.service_id
  }
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    username = "master"
    password = random_password.master.result
  })
}

# ---------------------------------------------------------------------------
# Aurora PostgreSQL cluster
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = var.instance_name
  subnet_ids = data.aws_subnets.private.ids

  tags = {
    "managed-by" = "nullplatform"
    "service-id" = var.service_id
  }
}

resource "aws_rds_cluster" "main" {
  cluster_identifier = var.instance_name
  engine             = "aurora-postgresql"
  engine_version     = var.postgres_version

  master_username = "master"
  master_password = random_password.master.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  storage_encrypted   = true
  port                = 5432
  skip_final_snapshot = true
  deletion_protection = false

  backup_retention_period      = var.backup_retention_period
  preferred_backup_window      = var.backup_window
  preferred_maintenance_window = var.maintenance_window

  tags = {
    "managed-by" = "nullplatform"
    "service-id" = var.service_id
  }

  depends_on = [aws_secretsmanager_secret_version.master]
}

resource "aws_rds_cluster_instance" "main" {
  count = 1 + var.reader_count

  identifier         = "${var.instance_name}-${count.index}"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = var.instance_class
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  publicly_accessible = false

  tags = {
    "managed-by" = "nullplatform"
    "service-id" = var.service_id
  }
}
```

- [ ] **Step 5: Write `outputs.tf`**

Create `aurora-postgres-server/deployment/outputs.tf`:
```hcl
output "hostname" {
  value       = aws_rds_cluster.main.endpoint
  description = "Aurora cluster writer endpoint"
}

output "hostname_reader" {
  value       = aws_rds_cluster.main.reader_endpoint
  description = "Aurora cluster reader endpoint (load-balances across reader instances; routes to the writer if reader_count = 0)"
}

output "port" {
  value       = aws_rds_cluster.main.port
  description = "Aurora cluster port"
}

output "db_cluster_identifier" {
  value       = aws_rds_cluster.main.cluster_identifier
  description = "AWS Aurora cluster identifier"
}

output "master_secret_arn" {
  value       = aws_secretsmanager_secret.master.arn
  description = "ARN of the Secrets Manager secret for master credentials"
}
```

- [ ] **Step 6: Validate the module**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/deployment
tofu fmt
tofu init -backend=false
tofu validate
```
Expected: `tofu fmt` reports no further changes needed on a second run; `tofu validate` prints `Success! The configuration is valid.`

- [ ] **Step 7: Commit**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
git add aurora-postgres-server/deployment
git commit -m "feat: add Aurora PostgreSQL cluster Terraform module"
```

---

### Task 3: `aurora-postgres-server/permissions` — per-link PostgreSQL grants module

This module is unchanged from the source repo: it only talks to whatever PostgreSQL endpoint it's given via variables (`db_host`, `db_port`) — it has no AWS-resource-type-specific logic, so it is a verbatim copy.

**Files:**
- Create: `aurora-postgres-server/permissions/{backend.tf,providers.tf,variables.tf,locals.tf,main.tf,outputs.tf}`

**Interfaces:**
- Consumes: `db_host`/`db_port` (the cluster's writer endpoint from Task 2's `hostname`/`port` outputs), `master_username`/`master_password` (from the Secrets Manager secret Task 2 creates).
- Produces: outputs `db_username`, `db_password`, `database_name` — consumed by Task 5's `write_link_outputs`.

- [ ] **Step 1: Copy all six files verbatim**

```bash
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/permissions
for f in backend.tf providers.tf variables.tf locals.tf main.tf outputs.tf; do
  cp ~/Documents/code/nullplatform/services-rds/rds-postgres-server/permissions/$f \
     ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/permissions/$f
done
```

- [ ] **Step 2: Validate**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/permissions
tofu fmt
tofu init -backend=false
tofu validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
git add aurora-postgres-server/permissions
git commit -m "feat: add aurora-postgres-server per-link permissions module"
```

---

### Task 4: `aurora-postgres-server/entrypoint` and the assume-role script trio

The `entrypoint`/`service` scripts are 100% generic across every AWS service in the source repo (no RDS/Aurora-specific strings). `entrypoint/link` and `assume_role`/`assume_role_step` embed the service name in env var prefixes and session names, so those need renaming.

**Files:**
- Create: `aurora-postgres-server/entrypoint/{entrypoint,service,link}`
- Create: `aurora-postgres-server/scripts/aws/{assume_role,assume_role_lib,assume_role_step}`

**Interfaces:**
- Produces: `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` env vars (exported by `assume_role_step`, consumed by every later `do_tofu`/AWS-CLI step in every workflow).

- [ ] **Step 1: Copy `entrypoint` and `service` verbatim**

```bash
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/entrypoint
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/scripts/aws
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-server/entrypoint/entrypoint \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/entrypoint/entrypoint
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-server/entrypoint/service \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/entrypoint/service
chmod +x ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/entrypoint/entrypoint \
         ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/entrypoint/service
```

- [ ] **Step 2: Copy `entrypoint/link` verbatim (server variant: create→link, delete→unlink, no "update" case)**

```bash
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-server/entrypoint/link \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/entrypoint/link
chmod +x ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/entrypoint/link
```

- [ ] **Step 3: Copy `assume_role_lib` verbatim (engine-agnostic pure helper)**

```bash
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-server/scripts/aws/assume_role_lib \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/scripts/aws/assume_role_lib
```

- [ ] **Step 4: Write `scripts/aws/assume_role` (env var prefix renamed `RDS_POSTGRES_SERVER_` → `AURORA_POSTGRES_SERVER_`)**

Create `aurora-postgres-server/scripts/aws/assume_role`:
```bash
#!/bin/bash
# Sourceable helper — do NOT execute directly.
# Reads AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN from the environment. If set, calls
# sts:AssumeRole and exports temporary credentials so all subsequent AWS calls
# (including tofu) use that role. If empty, does nothing — the agent's
# credentials (pod IRSA) handle auth.
#
# Requires: aws CLI, jq.
# Expects:  AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN (set by scripts/aws/assume_role_step),
#           SERVICE_ID (optional, used for the session name).

if [ -n "${AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN:-}" ]; then
  echo "   🔑 Assuming role: $AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN"

  _ar_sts_error=$(mktemp)
  if ! ASSUMED_CREDS=$(aws sts assume-role \
    --role-arn "$AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN" \
    --role-session-name "np-aurora-postgres-server-${SERVICE_ID:-workflow}" \
    --output json 2>"$_ar_sts_error"); then
    echo "   ❌ sts:AssumeRole failed for $AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN" >&2
    cat "$_ar_sts_error" >&2
    rm -f "$_ar_sts_error"
    return 1
  fi
  rm -f "$_ar_sts_error"

  _ar_access_key=$(echo "$ASSUMED_CREDS"    | jq -r '.Credentials.AccessKeyId // ""')
  _ar_secret_key=$(echo "$ASSUMED_CREDS"    | jq -r '.Credentials.SecretAccessKey // ""')
  _ar_session_token=$(echo "$ASSUMED_CREDS" | jq -r '.Credentials.SessionToken // ""')

  if [ -z "$_ar_access_key" ] || [ -z "$_ar_secret_key" ] || [ -z "$_ar_session_token" ]; then
    echo "   ❌ sts:AssumeRole returned incomplete credentials for $AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN" >&2
    return 1
  fi

  export AWS_ACCESS_KEY_ID="$_ar_access_key"
  export AWS_SECRET_ACCESS_KEY="$_ar_secret_key"
  export AWS_SESSION_TOKEN="$_ar_session_token"

  echo "   ✅ Role assumed successfully"
else
  echo "   ✅ assume_role=skipped (using agent credentials)"
fi
```

- [ ] **Step 5: Write `scripts/aws/assume_role_step` (selector renamed `rds-postgres-server` → `aurora-postgres-server`)**

Create `aurora-postgres-server/scripts/aws/assume_role_step`:
```bash
#!/bin/bash
# Dedicated workflow step: resolve the target IAM role and assume it, exporting
# temporary credentials so every subsequent step (including tofu) inherits them.
#
# Runs FIRST in each AWS-touching workflow. The workflow YAML must declare
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_SESSION_TOKEN as
# output:environment so the engine propagates them to the following steps.
#
# The AWS IAM provider (type "aws-iam-configuration", stored key
# "iam_role_arns.arns") is looked up directly via the np CLI, at the service's
# namespace NRN. CONTEXT.providers[...] is NOT used here (confirmed live on a
# real agent to never be populated regardless of provider_categories).
#
# Resolution precedence (see resolve_assume_role_arn in assume_role_lib):
#   $AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN -> IAM provider by selector
#     -> $AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN_DEFAULT -> agent credentials
#
# Requires: aws CLI, np CLI, jq. Expects: CONTEXT (engine-injected), SERVICE_ID (optional).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/assume_role_lib"

AURORA_POSTGRES_SERVER_ASSUME_ROLE_SELECTOR="${AURORA_POSTGRES_SERVER_ASSUME_ROLE_SELECTOR:-aurora-postgres-server}"

# NRN of the service from CONTEXT (falls back to scope / generic event). Use the
# full NRN as-is — do NOT strip it. Resolution walks UP the NRN hierarchy.
NRN=$(echo "${CONTEXT:-}" | jq -r '.service.nrn // .scope.nrn // .entity_nrn // ""' 2>/dev/null)

# Dimensions (if any) as key:value,key:value — lets np resolve the
# most-specific IAM provider the same way it would for a k8s scope.
DIMENSIONS=$(echo "${CONTEXT:-}" | jq -r '
  if (.service.dimensions | type) == "object" and ((.service.dimensions | length) > 0)
  then [ .service.dimensions | to_entries[] | "\(.key):\(.value)" ] | join(",")
  else empty end' 2>/dev/null)

# Resolve the IAM provider for this NRN + dimensions via the category query, which
# resolves up the NRN hierarchy and returns the effective provider .attributes.
# NOTE: --limit is incompatible with --categories (np rejects it), so it is NOT
# passed here.
IAM_PROVIDER=$(np provider list \
  --nrn "$NRN" \
  --categories identity-access-control \
  ${DIMENSIONS:+--dimensions "$DIMENSIONS"} \
  --format json 2>/dev/null \
  | jq -c '(.results // [])[0].attributes // {}')

AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN=$(resolve_assume_role_arn \
  "$IAM_PROVIDER" \
  "$AURORA_POSTGRES_SERVER_ASSUME_ROLE_SELECTOR" \
  "AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN" \
  "AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN_DEFAULT")
export AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN

# scripts/aws/assume_role performs sts:AssumeRole and exports AWS_* when an ARN is set,
# or no-ops (leaving agent credentials in place) when empty. Non-zero only when
# sts:AssumeRole itself fails.
if ! source "$SCRIPT_DIR/assume_role"; then
  echo "   ❌ assume_role step failed: could not assume $AURORA_POSTGRES_SERVER_ASSUME_ROLE_ARN" >&2
  echo "" >&2
  echo "💡 Possible causes:" >&2
  echo "   • The agent's role is not allowed to sts:AssumeRole the target role" >&2
  echo "   • The target role does not exist or does not trust the agent role" >&2
  echo "   • There is no role ARN configured for selector=$AURORA_POSTGRES_SERVER_ASSUME_ROLE_SELECTOR at NRN=$NRN${DIMENSIONS:+ dimensions=$DIMENSIONS}" >&2
  echo "" >&2
  exit 1
fi
```

- [ ] **Step 6: Make the new scripts executable and syntax-check every file touched**

```bash
chmod +x ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/scripts/aws/{assume_role,assume_role_lib,assume_role_step}
for f in ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/entrypoint/{entrypoint,service,link} \
         ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/scripts/aws/{assume_role,assume_role_lib,assume_role_step}; do
  bash -n "$f" && echo "OK: $f"
done
```
Expected: `OK: <path>` printed for all six files, no syntax errors.

- [ ] **Step 7: Commit**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
git add aurora-postgres-server/entrypoint aurora-postgres-server/scripts
git commit -m "feat: add aurora-postgres-server entrypoint and assume-role scripts"
```

---

### Task 5: `aurora-postgres-server/scripts/aws` — context builders and output writers

`build_context` needs `reader_count` instead of `allocated_storage`/`multi_az`; `write_service_outputs` needs the new `hostname_reader`/`db_cluster_identifier`/`engine_family` fields. `do_tofu`, `build_permissions_context`, `write_link_outputs`, `delete_tfstate_bucket` are fully generic (no RDS/Aurora-specific strings) and are copied verbatim.

**Files:**
- Create: `aurora-postgres-server/scripts/aws/build_context` (edited)
- Create: `aurora-postgres-server/scripts/aws/write_service_outputs` (edited)
- Create: `aurora-postgres-server/scripts/aws/{do_tofu,build_permissions_context,write_link_outputs,delete_tfstate_bucket}` (verbatim)

**Interfaces:**
- Consumes: Task 2's Terraform outputs (`hostname`, `hostname_reader`, `port`, `db_cluster_identifier`, `master_secret_arn`).
- Produces: `TOFU_VARIABLES` (consumed by `do_tofu`), and the service attributes written via `np service patch` (consumed by Task 10's `aurora-postgres-db` auto-discovery, which reads `hostname`/`master_secret_arn`/`engine_family`).

- [ ] **Step 1: Copy the four verbatim scripts**

```bash
for f in do_tofu build_permissions_context write_link_outputs delete_tfstate_bucket; do
  cp ~/Documents/code/nullplatform/services-rds/rds-postgres-server/scripts/aws/$f \
     ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/scripts/aws/$f
  chmod +x ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/scripts/aws/$f
done
```

- [ ] **Step 2: Write the fixture-based test for `write_service_outputs`'s new attribute set (write it before the script, confirm it fails)**

Create `/tmp/test_write_service_outputs_attrs.sh`:
```bash
#!/bin/bash
set -euo pipefail
# Mirrors the ATTRS jq construction inside write_service_outputs, fed with
# fixture values, asserting the new Aurora-specific fields are present.
HOSTNAME="np-test.cluster-xxxx.us-east-1.rds.amazonaws.com"
HOSTNAME_READER="np-test.cluster-ro-xxxx.us-east-1.rds.amazonaws.com"
PORT="5432"
DB_CLUSTER_IDENTIFIER="np-test"
MASTER_SECRET_ARN="arn:aws:secretsmanager:us-east-1:123456789012:secret:nullplatform/aurora/np-test/master-AbCdEf"

ATTRS=$(jq -n \
  --arg hostname              "$HOSTNAME" \
  --arg hostname_reader       "$HOSTNAME_READER" \
  --arg port                  "$PORT" \
  --arg db_cluster_identifier "$DB_CLUSTER_IDENTIFIER" \
  --arg master_secret_arn     "$MASTER_SECRET_ARN" \
  '{
    hostname:               $hostname,
    hostname_reader:        $hostname_reader,
    port:                   ($port | tonumber),
    db_cluster_identifier:  $db_cluster_identifier,
    engine_family:          "aurora-postgresql"
  } + (if $master_secret_arn != "" then {master_secret_arn: $master_secret_arn} else {} end)')

echo "$ATTRS" | jq -e '
  .engine_family == "aurora-postgresql" and
  .hostname_reader == "np-test.cluster-ro-xxxx.us-east-1.rds.amazonaws.com" and
  .db_cluster_identifier == "np-test" and
  (.port == 5432) and
  (.master_secret_arn | startswith("arn:aws:secretsmanager"))
' > /dev/null && echo "PASS"
```

Run it now, before the real script exists, purely to confirm the fixture/jq shape itself is sound:
```bash
chmod +x /tmp/test_write_service_outputs_attrs.sh
/tmp/test_write_service_outputs_attrs.sh
```
Expected: `PASS` (this validates the jq expression that Step 3's real script will reuse verbatim — if this fixture doesn't pass, fix the jq filter here first).

- [ ] **Step 3: Write `scripts/aws/write_service_outputs`**

Create `aurora-postgres-server/scripts/aws/write_service_outputs`:
```bash
#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# write_service_outputs — Reads Terraform outputs from the deployment module
# and writes them to the NP service attributes via the API.
#
# Fields with "export: true" in the service spec (hostname, hostname_reader,
# port) become env vars in apps when a link is activated.
# Fields with "export: false" (db_cluster_identifier, master_secret_arn,
# engine_family) are stored internally: db_cluster_identifier/master_secret_arn
# are used by build_permissions_context during link actions; engine_family is
# used by aurora-postgres-db's auto-discovery to disambiguate this server from
# a classic rds-postgres-server sharing the same dimensions.
# ---------------------------------------------------------------------------

cd "$OUTPUT_DIR"

SERVICE_ID=$(echo "$CONTEXT" | jq -r '.service.id')

echo "Reading Terraform outputs for service $SERVICE_ID..."

HOSTNAME=$(tofu output -raw hostname 2>/dev/null || echo "")
HOSTNAME_READER=$(tofu output -raw hostname_reader 2>/dev/null || echo "")
PORT=$(tofu output -raw port 2>/dev/null || echo "")
DB_CLUSTER_IDENTIFIER=$(tofu output -raw db_cluster_identifier 2>/dev/null || echo "")
MASTER_SECRET_ARN=$(tofu output -raw master_secret_arn 2>/dev/null || echo "")

if [ -z "$HOSTNAME" ]; then
  echo "WARNING: No hostname output found. Skipping attribute update."
  exit 0
fi

ATTRS=$(jq -n \
  --arg hostname              "$HOSTNAME" \
  --arg hostname_reader       "$HOSTNAME_READER" \
  --arg port                  "$PORT" \
  --arg db_cluster_identifier "$DB_CLUSTER_IDENTIFIER" \
  --arg master_secret_arn     "${MASTER_SECRET_ARN:-}" \
  '{
    hostname:               $hostname,
    hostname_reader:        $hostname_reader,
    port:                   ($port | tonumber),
    db_cluster_identifier:  $db_cluster_identifier,
    engine_family:          "aurora-postgresql"
  } + (if $master_secret_arn != "" then {master_secret_arn: $master_secret_arn} else {} end)')

echo "Updating service $SERVICE_ID attributes:"
echo "  hostname:              $HOSTNAME"
echo "  hostname_reader:       $HOSTNAME_READER"
echo "  port:                  $PORT"
echo "  db_cluster_identifier: $DB_CLUSTER_IDENTIFIER"
echo "  engine_family:         aurora-postgresql"

np service patch --id "$SERVICE_ID" --body "{\"attributes\": $ATTRS}"
echo "Service attributes updated successfully."
```
```bash
chmod +x ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/scripts/aws/write_service_outputs
```

- [ ] **Step 4: Re-run the fixture test against the logic now embedded in the real script (extract and diff)**

```bash
bash -n ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/scripts/aws/write_service_outputs && echo "SYNTAX OK"
grep -A12 "^ATTRS=\$(jq -n" ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/scripts/aws/write_service_outputs
```
Expected: `SYNTAX OK`, and the printed jq block matches the one already proven correct by `/tmp/test_write_service_outputs_attrs.sh` in Step 2.

- [ ] **Step 5: Write `scripts/aws/build_context`**

Create `aurora-postgres-server/scripts/aws/build_context`:
```bash
#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build_context — Extracts variables from the NP notification context and
# prepares the Terraform execution environment for service actions.
#
# For link actions, also extracts LINK_* variables consumed by
# build_permissions_context in the next workflow step.
# ---------------------------------------------------------------------------

# --- Parse service context --------------------------------------------------

SERVICE_ID=$(echo "$CONTEXT" | jq -r '.service.id')
SERVICE_NAME=$(echo "$CONTEXT" | jq -r '.service.name // ""')
SERVICE_NAME="${SERVICE_NAME:-svc-${SERVICE_ID}}"

# Sanitize name for use in AWS resource identifiers (lowercase, alphanumeric + hyphens, max 55 chars)
INSTANCE_NAME="np-$(echo "$SERVICE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//' | cut -c1-55)"

# Merge .service.attributes with action .parameters.
# CRITICAL: On the first "create" action, .service.attributes is empty or incomplete.
# The user-provided values are in .parameters. The jq * operator merges objects
# with the right-hand side taking precedence, so parameters always win.
SERVICE_ATTRS=$(echo "$CONTEXT" | jq -r '(.service.attributes // {}) * (.parameters // {})')

INSTANCE_CLASS=$(echo "$SERVICE_ATTRS"   | jq -r '.instance_class    // "db.r6g.large"')
READER_COUNT=$(echo "$SERVICE_ATTRS"     | jq -r '.reader_count      // 0')
POSTGRES_VERSION=$(echo "$SERVICE_ATTRS" | jq -r '.postgres_version  // "16"')

# --- Read static config from values.yaml ------------------------------------
# CRITICAL: $VALUES is a FILE PATH (set by "np service workflow exec --values <path>"),
# NOT JSON content. Read values with yaml_value() from build_context.
yaml_value() {
  local key="$1" default="$2" file="$3"
  local val
  val=$(grep "^${key}:" "$file" 2>/dev/null | sed 's/^[^:]*: *//;s/^"//;s/"$//' | head -1)
  echo "${val:-$default}"
}

AWS_PROFILE_VAL=$(yaml_value "aws_profile" "" "$VALUES")

if [ -n "${AWS_PROFILE_VAL}" ] && [ -z "${AWS_PROFILE:-}" ]; then
  export AWS_PROFILE="${AWS_PROFILE_VAL}"
fi

# --- Resolve AWS context from nullplatform provider -------------------------
# Both region and VPC are stored in runtime_configuration providers scoped to
# the account. We derive the account NRN from the service NRN by stripping
# everything from :namespace= onward, then query each provider by stored_keys.

ACCOUNT_NRN=$(echo "$CONTEXT" | jq -r '.service.nrn // .entity_nrn // ""' | sed 's/:namespace=.*$//')

if [ -z "$ACCOUNT_NRN" ]; then
  echo "ERROR: could not derive account NRN from .service.nrn in context" >&2
  exit 1
fi

NP_PROVIDERS=$(np provider list --nrn "$ACCOUNT_NRN" --format json --limit 100)

echo "Resolving region and VPC for account: ${ACCOUNT_NRN}"

# Resolve region from the account provider (stored key: account.region)
ACCOUNT_PROVIDER_ID=$(echo "$NP_PROVIDERS" \
  | jq -r '[(.results // [])[] | select((.data_source.stored_keys // []) | contains(["account.region"]))] | first | .id // ""')

if [ -z "$ACCOUNT_PROVIDER_ID" ] || [ "$ACCOUNT_PROVIDER_ID" = "null" ]; then
  echo "ERROR: no account provider with account.region found for ${ACCOUNT_NRN}" >&2
  exit 1
fi

ACCOUNT_PROVIDER_DATA=$(np provider read --id "$ACCOUNT_PROVIDER_ID" --format json)
REGION=$(echo "$ACCOUNT_PROVIDER_DATA" | jq -r '.attributes.account.region // ""')

if [ -z "$REGION" ]; then
  echo "ERROR: account.region not found in provider ${ACCOUNT_PROVIDER_ID}" >&2
  exit 1
fi

echo "Using region: ${REGION}"
export REGION

# Resolve VPC ID from the VPC provider (stored key: vpc.id)
VPC_PROVIDER_ID=$(echo "$NP_PROVIDERS" \
  | jq -r '[(.results // [])[] | select((.data_source.stored_keys // []) | contains(["vpc.id"]))] | first | .id // ""')

if [ -z "$VPC_PROVIDER_ID" ] || [ "$VPC_PROVIDER_ID" = "null" ]; then
  echo "ERROR: no VPC provider found for account ${ACCOUNT_NRN}" >&2
  exit 1
fi

VPC_PROVIDER_DATA=$(np provider read --id "$VPC_PROVIDER_ID" --format json)
VPC_ID=$(echo "$VPC_PROVIDER_DATA" | jq -r '.attributes.vpc.id // ""')

if [ -z "$VPC_ID" ]; then
  echo "ERROR: vpc.id not found in provider ${VPC_PROVIDER_ID}" >&2
  exit 1
fi

echo "Using VPC: ${VPC_ID}"

# --- Ensure per-instance tfstate bucket exists ------------------------------
# Each service instance gets its own S3 bucket so state is isolated and the
# bucket name is deterministic (reconstructable from SERVICE_ID alone).
# The agent IAM role must allow s3:CreateBucket + s3:PutBucketVersioning
# on arn:aws:s3:::np-service-* and the usual Get/Put/Delete/List actions.

TFSTATE_BUCKET="np-service-${SERVICE_ID}"

if ! aws s3api head-bucket --bucket "$TFSTATE_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "Creating tfstate bucket: ${TFSTATE_BUCKET}"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$TFSTATE_BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$TFSTATE_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  aws s3api put-bucket-versioning --bucket "$TFSTATE_BUCKET" \
    --versioning-configuration Status=Enabled
  echo "Bucket ${TFSTATE_BUCKET} created with versioning enabled."
else
  echo "Using existing tfstate bucket: ${TFSTATE_BUCKET}"
fi

export TFSTATE_BUCKET

# --- Set Terraform execution variables --------------------------------------

export OUTPUT_DIR="/tmp/np-service-${SERVICE_ID}"
mkdir -p "$OUTPUT_DIR"

export TOFU_MODULE_DIR="$SERVICE_PATH/deployment"

export TOFU_INIT_VARIABLES="-backend-config=bucket=${TFSTATE_BUCKET} -backend-config=key=terraform.tfstate -backend-config=region=${REGION}"

export TOFU_VARIABLES="-var=service_id=${SERVICE_ID} -var=instance_name=${INSTANCE_NAME} -var=region=${REGION} -var=vpc_id=${VPC_ID} -var=instance_class=${INSTANCE_CLASS} -var=reader_count=${READER_COUNT} -var=postgres_version=${POSTGRES_VERSION}"

# --- Extract link context (link workflows only) -----------------------------
# These are consumed by build_permissions_context in the next workflow step.

if [ "${ACTION_SOURCE:-}" = "link" ]; then
  export LINK_ID=$(echo "$CONTEXT"   | jq -r '.link.id       // ""')
  export LINK_NAME=$(echo "$CONTEXT" | jq -r '.link.name     // ""')
  export SCOPE_ID=$(echo "$CONTEXT"  | jq -r '.link.scope.id // ""')
  export SCOPE_NRN=$(echo "$CONTEXT" | jq -r '.link.scope.nrn // ""')

  LINK_ATTRS=$(echo "$CONTEXT" | jq -r '(.link.attributes // {}) * (.parameters // {})')
  export LINK_ACCESS_LEVEL=$(echo "$LINK_ATTRS" | jq -r '.access_level // "read-write"')
fi
```
```bash
chmod +x ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/scripts/aws/build_context
```

- [ ] **Step 6: Syntax-check every script in this task**

```bash
for f in build_context write_service_outputs do_tofu build_permissions_context write_link_outputs delete_tfstate_bucket; do
  bash -n ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/scripts/aws/$f && echo "OK: $f"
done
```
Expected: `OK: <name>` for all six scripts.

- [ ] **Step 7: Commit**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
git add aurora-postgres-server/scripts/aws
git commit -m "feat: add aurora-postgres-server context/output scripts"
```

---

### Task 6: `aurora-postgres-server/specs` — service spec, link spec, install, and IAM requirements

**Files:**
- Create: `aurora-postgres-server/specs/service-spec.json.tpl`
- Create: `aurora-postgres-server/specs/links/connect.json.tpl`
- Create: `aurora-postgres-server/specs/install/README.md`
- Create: `aurora-postgres-server/specs/install/aws/{main.tf,variables.tf,outputs.tf,terraform.tfvars.example}`
- Create: `aurora-postgres-server/specs/requirements/aws/{main.tf,variables.tf,locals.tf,output.tf,data.tf,versions.tf}`

**Interfaces:**
- Produces: the nullplatform service/link specification JSON that the platform validates `create`/`update`/`link` parameters against (must match the attribute names used by every script in Tasks 2, 3, 5).

- [ ] **Step 1: Write `specs/service-spec.json.tpl`**

Create `aurora-postgres-server/specs/service-spec.json.tpl`:
```json
{
  "name": "Aurora PostgreSQL Server",
  "slug": "aurora-postgres-server",
  "type": "dependency",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "available_links": ["connect"],
  "selectors": {
    "category": "Database",
    "imported": false,
    "provider": "AWS",
    "sub_category": "Relational Database"
  },
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": ["instance_class"],
      "properties": {
        "instance_class": {
          "type": "string",
          "title": "Instance Class",
          "default": "db.r6g.large",
          "description": "Aurora instance class applied to every cluster instance (writer and readers)",
          "editableOn": ["create", "update"],
          "order": 1
        },
        "reader_count": {
          "type": "number",
          "title": "Reader Count",
          "default": 0,
          "minimum": 0,
          "maximum": 15,
          "description": "Number of Aurora reader instances in addition to the writer",
          "editableOn": ["create", "update"],
          "order": 2
        },
        "postgres_version": {
          "type": "string",
          "title": "Aurora PostgreSQL Version",
          "default": "16",
          "enum": ["13", "14", "15", "16"],
          "description": "Aurora PostgreSQL major version (cannot be changed after creation)",
          "editableOn": ["create"],
          "order": 3
        },
        "hostname": {
          "type": "string",
          "title": "Hostname",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Aurora cluster writer endpoint (auto-populated after creation)",
          "order": 4
        },
        "hostname_reader": {
          "type": "string",
          "title": "Reader Hostname",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Aurora cluster reader endpoint (auto-populated after creation)",
          "order": 5
        },
        "port": {
          "type": "number",
          "title": "Port",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Aurora port (auto-populated after creation)",
          "order": 6
        },
        "db_cluster_identifier": {
          "type": "string",
          "export": false,
          "visibleOn": [],
          "editableOn": [],
          "description": "Internal AWS Aurora cluster identifier"
        },
        "master_secret_arn": {
          "type": "string",
          "export": false,
          "visibleOn": [],
          "editableOn": [],
          "description": "ARN of the Secrets Manager secret holding master credentials (internal use)"
        },
        "engine_family": {
          "type": "string",
          "export": false,
          "visibleOn": [],
          "editableOn": [],
          "description": "Internal marker used by aurora-postgres-db auto-discovery to disambiguate this server from other database dependency services (always \"aurora-postgresql\")"
        }
      }
    },
    "values": {}
  }
}
```

- [ ] **Step 2: Write `specs/links/connect.json.tpl` (identical shape to the source repo's server-side link — db_name + access_level, both created directly on this cluster)**

Create `aurora-postgres-server/specs/links/connect.json.tpl`:
```json
{
  "name": "Connect",
  "slug": "connect",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "selectors": {
    "category": "Database",
    "imported": false,
    "provider": "AWS",
    "sub_category": "Relational Database"
  },
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": ["db_name", "access_level"],
      "properties": {
        "db_name": {
          "type": "string",
          "title": "Database Name",
          "description": "Name of the database to create inside the Aurora cluster",
          "editableOn": ["create"],
          "order": 1
        },
        "access_level": {
          "enum": ["read", "write", "read-write"],
          "type": "string",
          "title": "Access Level",
          "default": "read-write",
          "editableOn": ["create", "update"],
          "description": "Permission level: read (SELECT), write (INSERT/UPDATE/DELETE), read-write (both)",
          "order": 2
        },
        "username": {
          "type": "string",
          "title": "DB Username",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Database username (auto-populated after link creation)",
          "order": 3
        },
        "password": {
          "type": "string",
          "title": "DB Password",
          "export": {"type": "environment_variable", "secret": true},
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Database password (auto-populated, delivered as secret env var)",
          "order": 4
        },
        "database_name": {
          "type": "string",
          "title": "Database",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Database name (auto-populated after link creation)",
          "order": 5
        }
      }
    },
    "values": {}
  }
}
```

- [ ] **Step 3: Validate both JSON templates**

```bash
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/specs/links
jq empty ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/specs/service-spec.json.tpl && echo "service-spec OK"
jq empty ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/specs/links/connect.json.tpl && echo "connect OK"
```
Expected: `service-spec OK` and `connect OK`, no jq parse errors.

- [ ] **Step 4: Write `specs/install/README.md`**

Create `aurora-postgres-server/specs/install/README.md`:
```markdown
# Install — registering the aurora-postgres-server service

This directory holds the reference OpenTofu/Terraform used to **install**
aurora-postgres-server on a nullplatform account: registering its service
specification, link specification, and agent association (notification
channel) so `np service create` starts routing actions to an agent.

This is separate from `../requirements/aws`, which provisions the AWS
AssumeRole IAM role/policies the *agent* needs to operate the service — see
that module's variables and the "AssumeRole Setup Guide" in the top-level
[`README.md`](../../README.md) for that half of the setup.

## Layout

```
install/
├── README.md          (this file)
└── aws/                Working example
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── terraform.tfvars.example
```

## Using the example

```bash
cp -r aurora-postgres-server/specs/install/aws /path/to/your/infra/aurora-postgres-server
cd /path/to/your/infra/aurora-postgres-server
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # must set repository_org/repository_name to wherever this repo is hosted

tofu init
tofu apply
```

`tags_selectors` must match the tag selectors of the agent(s) that should
pick up aurora-postgres-server actions (the same selectors passed as
`tags_selectors` to the `nullplatform/agent` tofu-module).

Run this once per nullplatform namespace. It only registers the service
with the platform — it does not create any AWS infrastructure by itself
(that happens per-instance, at `create` time, via `deployment/` and the
AssumeRole role from `requirements/aws`).
```

- [ ] **Step 5: Write `specs/install/aws/main.tf`**

Note: unlike the source repo (a monorepo where `service_path = "databases/rds-postgres-server"`), this is a standalone repo, so `service_path` is just the top-level directory name.

Create `aurora-postgres-server/specs/install/aws/main.tf`:
```hcl
################################################################################
# Install — registers the aurora-postgres-server service definition and its
# agent association (notification channel) on a nullplatform account.
#
# This is the platform-registration half of adopting the service; the
# AWS AssumeRole IAM role/policies live in ../../requirements/aws and are
# applied separately (see that module's README and the top-level
# "AssumeRole Setup Guide" in ../../../README.md).
################################################################################

locals {
  service_path      = "aurora-postgres-server"
  available_links   = ["connect"]
  available_actions = []
}

module "service_definition" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v4.5.1"

  nrn               = var.nrn
  repository_org    = var.repository_org
  repository_name   = var.repository_name
  repository_branch = var.repository_branch
  repository_token  = var.repository_token
  service_path      = local.service_path
  service_name      = var.service_name
  available_links   = local.available_links
  available_actions = local.available_actions
}

module "service_definition_agent_association" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v4.5.1"

  nrn                          = var.nrn
  repository_service_spec_repo = "${var.repository_org}/${var.repository_name}"
  service_path                 = local.service_path
  service_specification_slug   = module.service_definition.service_specification_slug
  api_key                      = var.np_api_key
  tags_selectors               = var.tags_selectors
}
```

- [ ] **Step 6: Write `specs/install/aws/variables.tf`**

`repository_org`/`repository_name` have no default (unlike the source repo, which defaults to the `nullplatform/services` monorepo) — this repo lives wherever the user hosts it, so those must be supplied explicitly.

Create `aurora-postgres-server/specs/install/aws/variables.tf`:
```hcl
variable "nrn" {
  description = "NullPlatform Resource Name (namespace-level, e.g. organization=<org>:account=<account>:namespace=<namespace>) where the service definition is registered."
  type        = string
}

variable "np_api_key" {
  description = "nullplatform API key used by the agent association to authenticate against the nullplatform API."
  type        = string
  sensitive   = true
}

variable "tags_selectors" {
  description = "Agent tag selectors for the notification channel (must match the tags the target agent registers with)."
  type        = map(string)
}

variable "service_name" {
  description = "Display name for the aurora-postgres-server service in nullplatform."
  type        = string
  default     = "Aurora Postgres Server"
}

variable "repository_org" {
  description = "GitHub organization/user hosting this services-aurora repository."
  type        = string
}

variable "repository_name" {
  description = "Repository name hosting the aurora-postgres-server service spec templates."
  type        = string
  default     = "services-aurora"
}

variable "repository_branch" {
  description = "Branch of the services-aurora repository to register the service spec/links/entrypoint from."
  type        = string
  default     = "main"
}

variable "repository_token" {
  description = "Access token for private repositories."
  type        = string
  default     = null
  sensitive   = true
}
```

- [ ] **Step 7: Write `specs/install/aws/outputs.tf`**

Create `aurora-postgres-server/specs/install/aws/outputs.tf`:
```hcl
output "service_specification_id" {
  description = "ID of the registered aurora-postgres-server service specification."
  value       = module.service_definition.service_specification_id
}

output "service_specification_slug" {
  description = "Slug of the registered aurora-postgres-server service specification."
  value       = module.service_definition.service_specification_slug
}
```

- [ ] **Step 8: Write `specs/install/aws/terraform.tfvars.example`**

Create `aurora-postgres-server/specs/install/aws/terraform.tfvars.example`:
```hcl
nrn        = "" # namespace-level NRN, e.g. organization=<org>:account=<account>:namespace=<namespace>
np_api_key = ""

repository_org  = "" # GitHub org/user hosting your fork of services-aurora
repository_name = "services-aurora"

tags_selectors = {
  "environment" = ""
}

# repository_branch = "main"
```

- [ ] **Step 9: Copy `specs/requirements/aws/{data.tf,versions.tf}` verbatim (account/provider boilerplate, unchanged)**

```bash
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/specs/install/aws
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/specs/requirements/aws
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-server/specs/requirements/aws/data.tf \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/specs/requirements/aws/data.tf
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-server/specs/requirements/aws/versions.tf \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/specs/requirements/aws/versions.tf
```

- [ ] **Step 10: Copy `specs/requirements/aws/variables.tf` verbatim (identical shape — cluster_name/agent_role_arn/role_name/etc. are generic across every service)**

```bash
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-server/specs/requirements/aws/variables.tf \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/specs/requirements/aws/variables.tf
```

- [ ] **Step 11: Write `specs/requirements/aws/locals.tf` (role name renamed)**

Create `aurora-postgres-server/specs/requirements/aws/locals.tf`:
```hcl
locals {
  iam_module_name = "requirements-aurora-postgres-server"
  iam_create      = var.iam_create_role

  role_name            = var.role_name != "" ? var.role_name : "nullplatform-${var.cluster_name}-aurora-postgres-server-role"
  policies_name_prefix = var.policies_name_prefix != "" ? var.policies_name_prefix : "nullplatform-${var.cluster_name}"
  agent_role_arn       = var.agent_role_arn != "" ? var.agent_role_arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/nullplatform-${var.cluster_name}-agent-role"

  iam_default_tags = merge(var.iam_resource_tags_json, {
    ManagedBy = "aurora-postgres-server"
    Module    = local.iam_module_name
  })
}
```

- [ ] **Step 12: Write `specs/requirements/aws/main.tf` (RDS policy actions extended for clusters)**

Create `aurora-postgres-server/specs/requirements/aws/main.tf`:
```hcl
################################################################################
# Permissions role — assumed by the nullplatform agent role (sts:AssumeRole)
################################################################################

resource "aws_iam_role" "nullplatform_aurora_postgres_server" {
  count = local.iam_create ? 1 : 0

  name        = local.role_name
  description = "Permissions role assumed by the nullplatform agent role for aurora-postgres-server in cluster ${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = concat([local.agent_role_arn], var.additional_agent_role_arns) }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.iam_default_tags
}

################################################################################
# Policy attachments
################################################################################

resource "aws_iam_role_policy_attachment" "rds" {
  count      = local.iam_create ? 1 : 0
  role       = aws_iam_role.nullplatform_aurora_postgres_server[0].name
  policy_arn = aws_iam_policy.nullplatform_rds_policy[0].arn
}

resource "aws_iam_role_policy_attachment" "rds_sg" {
  count      = local.iam_create ? 1 : 0
  role       = aws_iam_role.nullplatform_aurora_postgres_server[0].name
  policy_arn = aws_iam_policy.nullplatform_rds_sg_policy[0].arn
}

resource "aws_iam_role_policy_attachment" "rds_secretsmanager" {
  count      = local.iam_create ? 1 : 0
  role       = aws_iam_role.nullplatform_aurora_postgres_server[0].name
  policy_arn = aws_iam_policy.nullplatform_rds_secretsmanager_policy[0].arn
}

resource "aws_iam_role_policy_attachment" "rds_s3" {
  count      = local.iam_create ? 1 : 0
  role       = aws_iam_role.nullplatform_aurora_postgres_server[0].name
  policy_arn = aws_iam_policy.nullplatform_rds_s3_policy[0].arn
}

################################################################################
# RDS/Aurora IAM policy
################################################################################

resource "aws_iam_policy" "nullplatform_rds_policy" {
  count = local.iam_create ? 1 : 0

  name        = "${local.policies_name_prefix}-rds-policy"
  description = "Policy for managing Aurora clusters, cluster instances, and subnet groups"

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "rds:CreateDBCluster",
          "rds:DeleteDBCluster",
          "rds:ModifyDBCluster",
          "rds:DescribeDBClusters",
          "rds:CreateDBInstance",
          "rds:DeleteDBInstance",
          "rds:ModifyDBInstance",
          "rds:DescribeDBInstances",
          "rds:CreateDBSubnetGroup",
          "rds:DeleteDBSubnetGroup",
          "rds:DescribeDBSubnetGroups",
          "rds:ModifyDBSubnetGroup",
          "rds:AddTagsToResource",
          "rds:ListTagsForResource",
          "rds:RemoveTagsFromResource",
          "rds:DescribeDBClusterParameterGroups",
          "rds:DescribeDBParameterGroups",
          "rds:DescribeDBParameters",
          "rds:DescribeDBEngineVersions",
          "rds:DescribeOrderableDBInstanceOptions",
          "rds:DescribeOptionGroups",
          "iam:CreateServiceLinkedRole"
        ],
        "Resource" : "*"
      }
    ]
  })
}

################################################################################
# EC2 Security Group IAM policy
################################################################################

resource "aws_iam_policy" "nullplatform_rds_sg_policy" {
  count = local.iam_create ? 1 : 0

  name        = "${local.policies_name_prefix}-rds-sg-policy"
  description = "Policy for managing EC2 security groups for Aurora"

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:DescribeSecurityGroups",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcAttribute",
          "ec2:DescribeSubnets",
          "ec2:CreateTags",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSecurityGroupRules"
        ],
        "Resource" : "*"
      }
    ]
  })
}

################################################################################
# S3 IAM policy (per-service tfstate buckets: np-service-<id>)
################################################################################

resource "aws_iam_policy" "nullplatform_rds_s3_policy" {
  count = local.iam_create ? 1 : 0

  name        = "${local.policies_name_prefix}-rds-s3-policy"
  description = "Policy for managing per-service S3 tfstate buckets (np-service-*)"

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "s3:CreateBucket",
          "s3:HeadBucket",
          "s3:PutBucketVersioning",
          "s3:ListBucket",
          "s3:ListBucketVersions",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:DeleteBucket"
        ],
        "Resource" : [
          "arn:aws:s3:::np-service-*",
          "arn:aws:s3:::np-service-*/*"
        ]
      }
    ]
  })
}

################################################################################
# Secrets Manager IAM policy
################################################################################

resource "aws_iam_policy" "nullplatform_rds_secretsmanager_policy" {
  count = local.iam_create ? 1 : 0

  name        = "${local.policies_name_prefix}-rds-secretsmanager-policy"
  description = "Policy for managing Secrets Manager secrets for the Aurora master password"

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "secretsmanager:CreateSecret",
          "secretsmanager:DeleteSecret",
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecret",
          "secretsmanager:TagResource",
          "secretsmanager:UntagResource",
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:ListSecretVersionIds"
        ],
        "Resource" : "*"
      }
    ]
  })
}
```

- [ ] **Step 13: Write `specs/requirements/aws/output.tf` (identifier renamed)**

Create `aurora-postgres-server/specs/requirements/aws/output.tf`:
```hcl
output "rds_policy_arn" {
  description = "ARN of the RDS/Aurora management policy"
  value       = local.iam_create ? aws_iam_policy.nullplatform_rds_policy[0].arn : ""
}

output "rds_sg_policy_arn" {
  description = "ARN of the EC2 security group policy"
  value       = local.iam_create ? aws_iam_policy.nullplatform_rds_sg_policy[0].arn : ""
}

output "rds_secretsmanager_policy_arn" {
  description = "ARN of the Secrets Manager policy"
  value       = local.iam_create ? aws_iam_policy.nullplatform_rds_secretsmanager_policy[0].arn : ""
}

output "permissions_role_arn" {
  description = "ARN of the aurora-postgres-server permissions role assumed by the nullplatform agent role. Pass to the agent (assume_role_arns)."
  value       = local.iam_create ? aws_iam_role.nullplatform_aurora_postgres_server[0].arn : ""
}

output "permissions_role_name" {
  description = "Name of the aurora-postgres-server permissions role"
  value       = local.iam_create ? aws_iam_role.nullplatform_aurora_postgres_server[0].name : ""
}

output "permissions_role_id" {
  description = "ID of the aurora-postgres-server permissions role"
  value       = local.iam_create ? aws_iam_role.nullplatform_aurora_postgres_server[0].id : ""
}
```

- [ ] **Step 14: Validate both Terraform modules under `specs/`**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/specs/install/aws
tofu fmt && tofu init -backend=false && tofu validate

cd ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/specs/requirements/aws
tofu fmt && tofu init -backend=false && tofu validate
```
Expected: `Success! The configuration is valid.` for both.

- [ ] **Step 15: Commit**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
git add aurora-postgres-server/specs
git commit -m "feat: add aurora-postgres-server specs (service/link spec, install, IAM requirements)"
```

---

### Task 7: `aurora-postgres-server` — values.yaml, workflows, README

**Files:**
- Create: `aurora-postgres-server/values.yaml`
- Create: `aurora-postgres-server/workflows/aws/{create,update,delete,link,unlink}.yaml`
- Create: `aurora-postgres-server/README.md`

**Interfaces:**
- Consumes: every script name from Tasks 4–5 (workflow steps reference them by exact path).
- Produces: the workflow definitions the nullplatform agent executes for each lifecycle action.

- [ ] **Step 1: Write `values.yaml`**

Unlike the source repo (which commits a real-looking `vpc_id`), use an obviously unfilled placeholder so nobody accidentally deploys into the wrong VPC.

Create `aurora-postgres-server/values.yaml`:
```yaml
# Aurora PostgreSQL Server Service — Static Configuration
# These values are not exposed in the NP UI. They configure the execution
# environment for the agent running this service.
#
# NOTE: In scripts, $VALUES is a FILE PATH (set by np service workflow exec --values).
#       It is NOT JSON content. Read values with yaml_value() from build_context.

# Named AWS profile for local testing (e.g. SSO profile with RDS/Aurora access)
# If set and AWS_PROFILE is not already in the environment, build_context
# will export it so Terraform and AWS CLI use the correct credentials.
# Run "aws sso login --profile <name>" before starting np-agent locally.
aws_profile: ""

# Provider categories the platform must resolve into CONTEXT.providers before
# running workflow steps. identity-access-control is required by
# scripts/aws/assume_role_step to look up the AssumeRole target ARN.
provider_categories:
  - identity-access-control
```

- [ ] **Step 2: Copy all five workflow YAMLs verbatim (step names/env-var names are fully generic — server flavor: create/update apply, delete destroys+cleans bucket, link/unlink run permissions module)**

```bash
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/workflows/aws
for f in create update delete link unlink; do
  cp ~/Documents/code/nullplatform/services-rds/rds-postgres-server/workflows/aws/$f.yaml \
     ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/workflows/aws/$f.yaml
done
```

- [ ] **Step 3: Validate the YAML and check every referenced script path exists**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server
for f in workflows/aws/*.yaml; do
  python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" && echo "YAML OK: $f"
done
grep -ohE '\$SERVICE_PATH/[^ ]+' workflows/aws/*.yaml | sed 's/\$SERVICE_PATH\///' | sort -u | while read -r rel; do
  [ -f "$rel" ] && echo "exists: $rel" || echo "MISSING: $rel"
done
```
Expected: `YAML OK` for all five files, and every referenced path prints `exists:` (no `MISSING:` lines).

- [ ] **Step 4: Write `README.md`**

Create `aurora-postgres-server/README.md`:
```markdown
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
| `hostname` | Aurora writer endpoint |
| `port` | Aurora port |

## Configuration Parameters

| Parameter | Type | Default | Allowed Values | Editable After Create |
|---|---|---|---|---|
| `instance_class` | string | `db.r6g.large` | Any Aurora-PostgreSQL-compatible instance class (e.g. `db.r6g.*`, `db.t4g.*`) | Yes |
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

See [`specs/install/README.md`](specs/install/README.md) to register the service on a nullplatform account, and [`specs/requirements/aws`](specs/requirements/aws) for the AssumeRole IAM role/policies the agent needs. The AssumeRole setup steps (apply `requirements/`, grant the agent `sts:AssumeRole`, register an `identity-access-control` provider with selector `aurora-postgres-server`) are identical in shape to `rds-postgres-server`'s — only the role/selector name changes.

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
```

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
git add aurora-postgres-server/values.yaml aurora-postgres-server/workflows aurora-postgres-server/README.md
git commit -m "feat: add aurora-postgres-server values/workflows/README"
```

---

### Task 8: `aurora-postgres-db/db_setup` and `aurora-postgres-db/permissions` — verbatim copies

Neither module has any RDS/Aurora-specific content — both talk to whatever PostgreSQL endpoint they're given via variables. Verbatim copy from `rds-postgres-db`.

**Files:**
- Create: `aurora-postgres-db/db_setup/{backend.tf,providers.tf,variables.tf,main.tf,outputs.tf}`
- Create: `aurora-postgres-db/permissions/{backend.tf,providers.tf,variables.tf,locals.tf,main.tf,outputs.tf}`

**Interfaces:**
- Consumes: `db_host`/`db_port`/`master_username`/`master_password` (resolved by Task 9's `build_db_setup_context`/`build_permissions_context` from the auto-discovered `aurora-postgres-server`'s attributes + Secrets Manager secret).
- Produces (`db_setup`): outputs `hostname`, `port`, `master_secret_arn`, `db_username`, `db_password`, `database_name` — consumed by Task 9's `write_service_outputs`.
- Produces (`permissions`): no outputs (writes directly to link attributes via Task 9's `write_link_outputs`, which reads from service attributes, not Terraform outputs).

- [ ] **Step 1: Copy `db_setup/` (5 files)**

```bash
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/db_setup
for f in backend.tf providers.tf variables.tf main.tf outputs.tf; do
  cp ~/Documents/code/nullplatform/services-rds/rds-postgres-db/db_setup/$f \
     ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/db_setup/$f
done
```

- [ ] **Step 2: Copy `permissions/` (6 files)**

```bash
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/permissions
for f in backend.tf providers.tf variables.tf locals.tf main.tf outputs.tf; do
  cp ~/Documents/code/nullplatform/services-rds/rds-postgres-db/permissions/$f \
     ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/permissions/$f
done
```

- [ ] **Step 3: Validate both modules**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/db_setup
tofu fmt && tofu init -backend=false && tofu validate

cd ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/permissions
tofu fmt && tofu init -backend=false && tofu validate
```
Expected: `Success! The configuration is valid.` for both.

- [ ] **Step 4: Commit**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
git add aurora-postgres-db/db_setup aurora-postgres-db/permissions
git commit -m "feat: add aurora-postgres-db db_setup and permissions modules"
```

---

### Task 9: `aurora-postgres-db/entrypoint` and the assume-role script trio

Same pattern as Task 4, applied to the "db" flavor (whose `entrypoint/link` also maps `"update"` → `"link"`, unlike the server's).

**Files:**
- Create: `aurora-postgres-db/entrypoint/{entrypoint,service,link}`
- Create: `aurora-postgres-db/scripts/aws/{assume_role,assume_role_lib,assume_role_step}`

- [ ] **Step 1: Copy `entrypoint`, `service`, and `link` verbatim from `rds-postgres-db`**

```bash
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/entrypoint
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/scripts/aws
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-db/entrypoint/entrypoint \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/entrypoint/entrypoint
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-db/entrypoint/service \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/entrypoint/service
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-db/entrypoint/link \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/entrypoint/link
chmod +x ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/entrypoint/{entrypoint,service,link}
```

- [ ] **Step 2: Copy `assume_role_lib` verbatim**

```bash
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-db/scripts/aws/assume_role_lib \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/scripts/aws/assume_role_lib
```

- [ ] **Step 3: Write `scripts/aws/assume_role` (prefix `RDS_POSTGRES_DB_` → `AURORA_POSTGRES_DB_`)**

Create `aurora-postgres-db/scripts/aws/assume_role`:
```bash
#!/bin/bash
# Sourceable helper — do NOT execute directly.
# Reads AURORA_POSTGRES_DB_ASSUME_ROLE_ARN from the environment. If set, calls
# sts:AssumeRole and exports temporary credentials so all subsequent AWS calls
# (including tofu) use that role. If empty, does nothing — the agent's
# credentials (pod IRSA) handle auth.
#
# Requires: aws CLI, jq.
# Expects:  AURORA_POSTGRES_DB_ASSUME_ROLE_ARN (set by scripts/aws/assume_role_step),
#           SERVICE_ID (optional, used for the session name).

if [ -n "${AURORA_POSTGRES_DB_ASSUME_ROLE_ARN:-}" ]; then
  echo "   🔑 Assuming role: $AURORA_POSTGRES_DB_ASSUME_ROLE_ARN"

  _ar_sts_error=$(mktemp)
  if ! ASSUMED_CREDS=$(aws sts assume-role \
    --role-arn "$AURORA_POSTGRES_DB_ASSUME_ROLE_ARN" \
    --role-session-name "np-aurora-postgres-db-${SERVICE_ID:-workflow}" \
    --output json 2>"$_ar_sts_error"); then
    echo "   ❌ sts:AssumeRole failed for $AURORA_POSTGRES_DB_ASSUME_ROLE_ARN" >&2
    cat "$_ar_sts_error" >&2
    rm -f "$_ar_sts_error"
    return 1
  fi
  rm -f "$_ar_sts_error"

  _ar_access_key=$(echo "$ASSUMED_CREDS"    | jq -r '.Credentials.AccessKeyId // ""')
  _ar_secret_key=$(echo "$ASSUMED_CREDS"    | jq -r '.Credentials.SecretAccessKey // ""')
  _ar_session_token=$(echo "$ASSUMED_CREDS" | jq -r '.Credentials.SessionToken // ""')

  if [ -z "$_ar_access_key" ] || [ -z "$_ar_secret_key" ] || [ -z "$_ar_session_token" ]; then
    echo "   ❌ sts:AssumeRole returned incomplete credentials for $AURORA_POSTGRES_DB_ASSUME_ROLE_ARN" >&2
    return 1
  fi

  export AWS_ACCESS_KEY_ID="$_ar_access_key"
  export AWS_SECRET_ACCESS_KEY="$_ar_secret_key"
  export AWS_SESSION_TOKEN="$_ar_session_token"

  echo "   ✅ Role assumed successfully"
else
  echo "   ✅ assume_role=skipped (using agent credentials)"
fi
```

- [ ] **Step 4: Write `scripts/aws/assume_role_step` (selector `rds-postgres-db` → `aurora-postgres-db`)**

Create `aurora-postgres-db/scripts/aws/assume_role_step`:
```bash
#!/bin/bash
# Dedicated workflow step: resolve the target IAM role and assume it, exporting
# temporary credentials so every subsequent step (including tofu) inherits them.
#
# Runs FIRST in each AWS-touching workflow. The workflow YAML must declare
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_SESSION_TOKEN as
# output:environment so the engine propagates them to the following steps.
#
# The AWS IAM provider (type "aws-iam-configuration", stored key
# "iam_role_arns.arns") is looked up directly via the np CLI, at the service's
# namespace NRN. CONTEXT.providers[...] is NOT used here (confirmed live on a
# real agent to never be populated regardless of provider_categories).
#
# Resolution precedence (see resolve_assume_role_arn in assume_role_lib):
#   $AURORA_POSTGRES_DB_ASSUME_ROLE_ARN -> IAM provider by selector
#     -> $AURORA_POSTGRES_DB_ASSUME_ROLE_ARN_DEFAULT -> agent credentials
#
# Requires: aws CLI, np CLI, jq. Expects: CONTEXT (engine-injected), SERVICE_ID (optional).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/assume_role_lib"

AURORA_POSTGRES_DB_ASSUME_ROLE_SELECTOR="${AURORA_POSTGRES_DB_ASSUME_ROLE_SELECTOR:-aurora-postgres-db}"

NRN=$(echo "${CONTEXT:-}" | jq -r '.service.nrn // .scope.nrn // .entity_nrn // ""' 2>/dev/null)

DIMENSIONS=$(echo "${CONTEXT:-}" | jq -r '
  if (.service.dimensions | type) == "object" and ((.service.dimensions | length) > 0)
  then [ .service.dimensions | to_entries[] | "\(.key):\(.value)" ] | join(",")
  else empty end' 2>/dev/null)

IAM_PROVIDER=$(np provider list \
  --nrn "$NRN" \
  --categories identity-access-control \
  ${DIMENSIONS:+--dimensions "$DIMENSIONS"} \
  --format json 2>/dev/null \
  | jq -c '(.results // [])[0].attributes // {}')

AURORA_POSTGRES_DB_ASSUME_ROLE_ARN=$(resolve_assume_role_arn \
  "$IAM_PROVIDER" \
  "$AURORA_POSTGRES_DB_ASSUME_ROLE_SELECTOR" \
  "AURORA_POSTGRES_DB_ASSUME_ROLE_ARN" \
  "AURORA_POSTGRES_DB_ASSUME_ROLE_ARN_DEFAULT")
export AURORA_POSTGRES_DB_ASSUME_ROLE_ARN

if ! source "$SCRIPT_DIR/assume_role"; then
  echo "   ❌ assume_role step failed: could not assume $AURORA_POSTGRES_DB_ASSUME_ROLE_ARN" >&2
  echo "" >&2
  echo "💡 Possible causes:" >&2
  echo "   • The agent's role is not allowed to sts:AssumeRole the target role" >&2
  echo "   • The target role does not exist or does not trust the agent role" >&2
  echo "   • There is no role ARN configured for selector=$AURORA_POSTGRES_DB_ASSUME_ROLE_SELECTOR at NRN=$NRN${DIMENSIONS:+ dimensions=$DIMENSIONS}" >&2
  echo "" >&2
  exit 1
fi
```

- [ ] **Step 5: Syntax-check and commit**

```bash
chmod +x ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/scripts/aws/{assume_role,assume_role_lib,assume_role_step}
for f in ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/entrypoint/{entrypoint,service,link} \
         ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/scripts/aws/{assume_role,assume_role_lib,assume_role_step}; do
  bash -n "$f" && echo "OK: $f"
done

cd ~/Documents/code/nullplatform/lulobank/services-aurora
git add aurora-postgres-db/entrypoint aurora-postgres-db/scripts
git commit -m "feat: add aurora-postgres-db entrypoint and assume-role scripts"
```
Expected: `OK: <path>` for all six files before the commit.

---

### Task 10: `aurora-postgres-db/scripts/aws` — auto-discovery, context builders, and output writers

Only `build_db_setup_context` gets new logic (the `engine_family` discovery filter). Everything else in this directory is fully generic (no RDS/Aurora-specific strings) and copied verbatim.

**Files:**
- Create: `aurora-postgres-db/scripts/aws/build_db_setup_context` (edited)
- Create: `aurora-postgres-db/scripts/aws/{build_context,build_permissions_context,do_tofu,write_service_outputs,write_link_outputs,reassign_owned,delete_tfstate_bucket}` (verbatim)

**Interfaces:**
- Consumes: `aurora-postgres-server`'s service attributes `hostname`, `port`, `master_secret_arn`, `engine_family` (via `np service list`/`np service read`).
- Produces: `TOFU_VARIABLES`/`TOFU_MODULE_DIR` (consumed by `do_tofu` against `db_setup/`), and this service's own attributes (consumed by Task 11's spec and by `write_link_outputs`).

- [ ] **Step 1: Copy the seven verbatim scripts**

```bash
for f in build_context build_permissions_context do_tofu write_service_outputs write_link_outputs reassign_owned delete_tfstate_bucket; do
  cp ~/Documents/code/nullplatform/services-rds/rds-postgres-db/scripts/aws/$f \
     ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/scripts/aws/$f
  chmod +x ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/scripts/aws/$f
done
```

- [ ] **Step 2: Write the fixture-based test for the discovery filter (before writing the real script)**

Create `/tmp/test_discovery_filter.sh`:
```bash
#!/bin/bash
set -euo pipefail
# Mirrors the jq select() filter inside build_db_setup_context. Feeds two
# candidate services with identical dimensions — one a classic
# rds-postgres-server (no engine_family), one an aurora-postgres-server
# (engine_family set) — and asserts only the Aurora one is selected.

FIXTURE='{"results": [
  {"id": "svc-rds-classic", "name": "rds server", "dimensions": {"cluster": "prod"},
   "attributes": {"hostname": "rds.example.com", "master_secret_arn": "arn:rds"}},
  {"id": "svc-aurora", "name": "aurora server", "dimensions": {"cluster": "prod"},
   "attributes": {"hostname": "aurora.example.com", "master_secret_arn": "arn:aurora", "engine_family": "aurora-postgresql"}}
]}'
DIMS='{"cluster": "prod"}'

RESULT=$(echo "$FIXTURE" | jq --argjson dims "$DIMS" \
  '[(.results // .) | .[] | . as $svc | select(
    (.attributes.hostname // "") != "" and
    (.attributes.master_secret_arn // "") != "" and
    (.attributes.engine_family // "") == "aurora-postgresql" and
    ($dims | to_entries | all(. as $kv | ($svc.dimensions[$kv.key] // null) == $kv.value))
  )]')

echo "$RESULT" | jq -e 'length == 1 and .[0].id == "svc-aurora"' > /dev/null && echo "PASS"
```

Run it now to confirm the filter shape is correct on its own:
```bash
chmod +x /tmp/test_discovery_filter.sh
/tmp/test_discovery_filter.sh
```
Expected: `PASS` (only the Aurora candidate is selected out of the two).

- [ ] **Step 3: Write `scripts/aws/build_db_setup_context`**

Create `aurora-postgres-db/scripts/aws/build_db_setup_context`:
```bash
#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build_db_setup_context — Prepares Tofu execution context for the db_setup
# module. Used by both service create and service delete.
#
# Service create: auto-discovers the aurora-postgres-server with matching
#   dimensions AND engine_family="aurora-postgresql" (the engine_family check
#   disambiguates from a classic rds-postgres-server that might share the
#   same dimensions in the same namespace), derives DB name/username from
#   application_id, then retrieves master credentials from Secrets Manager.
#
# Service delete: SERVER_HOSTNAME is already exported by build_context
#   (read from service attributes), so server discovery is skipped.
#   If service was never created (SERVER_HOSTNAME empty), exits cleanly.
# ---------------------------------------------------------------------------

yaml_value() {
  local key="$1" default="$2" file="$3"
  local val
  val=$(grep "^${key}:" "$file" 2>/dev/null | sed 's/^[^:]*: *//;s/^"//;s/"$//' | head -1)
  echo "${val:-$default}"
}

REGION=$(yaml_value "region" "us-east-1" "$VALUES")
AWS_PROFILE_VAL=$(yaml_value "aws_profile" "" "$VALUES")

if [ -n "${AWS_PROFILE_VAL}" ] && [ -z "${AWS_PROFILE:-}" ]; then
  export AWS_PROFILE="${AWS_PROFILE_VAL}"
fi

SERVICE_ID=$(echo "$CONTEXT" | jq -r '.service.id')
ACTION_TYPE=$(echo "$CONTEXT" | jq -r '.type // ""')

# --- Resolve connection info -----------------------------------------------

if [ -n "${SERVER_HOSTNAME:-}" ]; then
  # Service delete: use stored service attributes already exported by build_context
  echo "Using stored service attributes for DB setup context..."
  DB_HOST="$SERVER_HOSTNAME"
  DB_PORT="${SERVER_PORT:-5432}"
  MASTER_SECRET_ARN="$SERVER_MASTER_SECRET_ARN"
  DB_NAME_VAL="${DB_NAME:-}"
  DB_USERNAME_VAL="${DB_USERNAME:-}"

else
  if [ "$ACTION_TYPE" = "delete" ]; then
    echo "Service has no stored hostname — was never created successfully. Skipping DB cleanup."
    export SETUP_SKIPPED=true
    exit 0
  fi

  # Service create: auto-discover aurora-postgres-server with matching
  # dimensions AND engine_family="aurora-postgresql". np service list --type
  # dependency only filters by service type, not by which service definition
  # produced the match — without the engine_family check, a classic
  # rds-postgres-server sharing the same dimensions would also satisfy
  # hostname/master_secret_arn and cause an ambiguous "multiple servers
  # found" failure (or worse, an incorrect match).
  ENTITY_NRN=$(echo "$CONTEXT" | jq -r '.entity_nrn // ""')
  SERVICE_DIMENSIONS=$(echo "$CONTEXT" | jq -c '.service.dimensions // {}')
  echo "Auto-discovering Aurora server in ${ENTITY_NRN} (dimensions: ${SERVICE_DIMENSIONS})..."

  SERVER_SERVICES=$(np service list \
    --nrn "$ENTITY_NRN" \
    --type dependency \
    --status active \
    --format json | \
    jq --argjson dims "$SERVICE_DIMENSIONS" \
    '[(.results // .) | .[] | . as $svc | select(
      (.attributes.hostname // "") != "" and
      (.attributes.master_secret_arn // "") != "" and
      (.attributes.engine_family // "") == "aurora-postgresql" and
      ($dims | to_entries | all(. as $kv | ($svc.dimensions[$kv.key] // null) == $kv.value))
    )]')
  SERVER_COUNT=$(echo "$SERVER_SERVICES" | jq 'length')

  if [ "$SERVER_COUNT" -eq 0 ]; then
    echo "ERROR: No active Aurora server found in ${ENTITY_NRN} matching dimensions: ${SERVICE_DIMENSIONS}" >&2
    echo "       Create an aurora-postgres-server service with matching dimensions first." >&2
    exit 1
  elif [ "$SERVER_COUNT" -gt 1 ]; then
    echo "ERROR: Multiple Aurora servers found in ${ENTITY_NRN} matching dimensions: ${SERVICE_DIMENSIONS}" >&2
    echo "       Available options:" >&2
    echo "$SERVER_SERVICES" | jq -r '.[] | "  - \(.id)  \(.name)  (\(.attributes.hostname))"' >&2
    exit 1
  fi

  SERVER_SERVICE_ID=$(echo "$SERVER_SERVICES" | jq -r '.[0].id')
  echo "Auto-discovered server: ${SERVER_SERVICE_ID} ($(echo "$SERVER_SERVICES" | jq -r '.[0].name'))"

  SERVER_JSON=$(np service read --id "$SERVER_SERVICE_ID" --format json)
  DB_HOST=$(echo "$SERVER_JSON" | jq -r '.attributes.hostname // ""')
  DB_PORT=$(echo "$SERVER_JSON" | jq -r '.attributes.port // "5432"')
  MASTER_SECRET_ARN=$(echo "$SERVER_JSON" | jq -r '.attributes.master_secret_arn // ""')

  if [ -z "$DB_HOST" ]; then
    echo "ERROR: Server ${SERVER_SERVICE_ID} has no hostname attribute." >&2
    echo "       Has the aurora-postgres-server been created successfully?" >&2
    exit 1
  fi

  # Derive DB name and username from application_id
  APPLICATION_ID=$(echo "$CONTEXT" | jq -r '.tags.application_id // ""')
  if [ -z "$APPLICATION_ID" ]; then
    echo "ERROR: Could not extract application_id from context tags." >&2
    exit 1
  fi

  DB_NAME_VAL="app_${APPLICATION_ID}"
  DB_USERNAME_VAL="app_${APPLICATION_ID}"
  echo "Database: ${DB_NAME_VAL}, Username: ${DB_USERNAME_VAL}"
fi

# --- Retrieve master credentials from Secrets Manager ----------------------

echo "Retrieving master credentials from Secrets Manager..."
MASTER_CREDS=$(aws secretsmanager get-secret-value \
  --secret-id "$MASTER_SECRET_ARN" \
  --query 'SecretString' \
  --output text)

MASTER_USER=$(echo "$MASTER_CREDS" | jq -r '.username')
MASTER_PASS=$(echo "$MASTER_CREDS" | jq -r '.password')

# --- Prepare working directory and sensitive vars --------------------------

mkdir -p "$OUTPUT_DIR"
cat > "$OUTPUT_DIR/sensitive.auto.tfvars" <<EOF
master_password = "${MASTER_PASS}"
EOF

# --- Set Terraform execution variables -------------------------------------

export TOFU_MODULE_DIR="$SERVICE_PATH/db_setup"
export TOFU_IMPORT_DB_NAME="$DB_NAME_VAL"

export TOFU_INIT_VARIABLES="-backend-config=bucket=${TFSTATE_BUCKET} -backend-config=key=db_setup.tfstate -backend-config=region=${REGION}"

export TOFU_VARIABLES="-var=service_id=${SERVICE_ID} -var=db_host=${DB_HOST} -var=db_port=${DB_PORT} -var=db_name=${DB_NAME_VAL} -var=db_username=${DB_USERNAME_VAL} -var=master_username=${MASTER_USER} -var=master_secret_arn=${MASTER_SECRET_ARN}"
```
```bash
chmod +x ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/scripts/aws/build_db_setup_context
```

- [ ] **Step 4: Confirm the real script's filter matches the already-proven fixture, and syntax-check everything**

```bash
grep -A6 "'\[(.results" ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/scripts/aws/build_db_setup_context
for f in build_context build_db_setup_context build_permissions_context do_tofu write_service_outputs write_link_outputs reassign_owned delete_tfstate_bucket; do
  bash -n ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/scripts/aws/$f && echo "OK: $f"
done
```
Expected: the printed jq filter block contains `engine_family` matching what `/tmp/test_discovery_filter.sh` already proved correct in Step 2, and `OK: <name>` for all eight scripts.

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
git add aurora-postgres-db/scripts/aws
git commit -m "feat: add aurora-postgres-db discovery/context/output scripts"
```

---

### Task 11: `aurora-postgres-db/specs` — service spec, link spec, install, IAM requirements

**Files:**
- Create: `aurora-postgres-db/specs/service-spec.json.tpl`
- Create: `aurora-postgres-db/specs/links/connect.json.tpl`
- Create: `aurora-postgres-db/specs/install/README.md`
- Create: `aurora-postgres-db/specs/install/aws/{main.tf,variables.tf,outputs.tf,terraform.tfvars.example}`
- Create: `aurora-postgres-db/specs/requirements/aws/{main.tf,variables.tf,locals.tf,output.tf,data.tf,versions.tf}`

- [ ] **Step 1: Write `specs/service-spec.json.tpl`**

Create `aurora-postgres-db/specs/service-spec.json.tpl`:
```json
{
  "name": "Aurora PostgreSQL DB",
  "slug": "aurora-postgres-db",
  "type": "dependency",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "available_links": ["connect"],
  "selectors": {
    "category": "Database",
    "imported": false,
    "provider": "AWS",
    "sub_category": "Relational Database"
  },
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": [],
      "properties": {
        "hostname": {
          "type": "string",
          "title": "Hostname",
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Aurora writer endpoint",
          "order": 1
        },
        "port": {
          "type": "number",
          "title": "Port",
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Aurora port",
          "order": 2
        },
        "username": {
          "type": "string",
          "title": "DB Username",
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Database username",
          "order": 3
        },
        "password": {
          "type": "string",
          "title": "DB Password",
          "visibleOn": [],
          "editableOn": [],
          "description": "Database password (internal use — exposed to apps via link)",
          "order": 4
        },
        "database_name": {
          "type": "string",
          "title": "Database",
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Database name",
          "order": 5
        },
        "master_secret_arn": {
          "type": "string",
          "visibleOn": [],
          "editableOn": [],
          "description": "ARN of the Secrets Manager secret for master credentials (internal use)",
          "order": 6
        }
      }
    },
    "values": {}
  }
}
```

- [ ] **Step 2: Write `specs/links/connect.json.tpl` (access_level only — db_name is fixed at service level)**

Create `aurora-postgres-db/specs/links/connect.json.tpl`:
```json
{
  "name": "Connect",
  "slug": "connect",
  "unique": false,
  "assignable_to": "any",
  "use_default_actions": true,
  "selectors": {
    "category": "Database",
    "imported": false,
    "provider": "AWS",
    "sub_category": "Relational Database"
  },
  "attributes": {
    "schema": {
      "type": "object",
      "$schema": "http://json-schema.org/draft-07/schema#",
      "required": [],
      "properties": {
        "access_level": {
          "enum": ["read", "write", "read-write"],
          "type": "string",
          "title": "Access Level",
          "default": "read-write",
          "editableOn": ["create", "update"],
          "description": "Permission level: read (SELECT), write (INSERT/UPDATE/DELETE), read-write (both)",
          "order": 1
        },
        "hostname": {
          "type": "string",
          "title": "Hostname",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Aurora writer endpoint",
          "order": 2
        },
        "port": {
          "type": "number",
          "title": "Port",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Aurora port",
          "order": 3
        },
        "username": {
          "type": "string",
          "title": "DB Username",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Database username",
          "order": 4
        },
        "password": {
          "type": "string",
          "title": "DB Password",
          "export": {"type": "environment_variable", "secret": true},
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Database password (auto-generated at service create)",
          "order": 5
        },
        "database_name": {
          "type": "string",
          "title": "Database",
          "export": true,
          "visibleOn": ["read"],
          "editableOn": [],
          "description": "Database name",
          "order": 6
        },
        "master_secret_arn": {
          "type": "string",
          "export": false,
          "visibleOn": [],
          "editableOn": [],
          "description": "ARN of the Secrets Manager secret for master credentials (internal use)"
        }
      }
    },
    "values": {}
  }
}
```

- [ ] **Step 3: Validate both JSON templates**

```bash
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/specs/links
jq empty ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/specs/service-spec.json.tpl && echo "service-spec OK"
jq empty ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/specs/links/connect.json.tpl && echo "connect OK"
```
Expected: `service-spec OK` and `connect OK`.

- [ ] **Step 4: Write `specs/install/README.md`**

Create `aurora-postgres-db/specs/install/README.md`:
```markdown
# Install — registering the aurora-postgres-db service

This directory holds the reference OpenTofu/Terraform used to **install**
aurora-postgres-db on a nullplatform account: registering its service
specification, link specification, and agent association (notification
channel) so `np service create` starts routing actions to an agent.

This is separate from `../requirements/aws`, which provisions the AWS
AssumeRole IAM role/policies the *agent* needs to operate the service.

## Layout

```
install/
├── README.md          (this file)
└── aws/                Working example
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── terraform.tfvars.example
```

## Using the example

```bash
cp -r aurora-postgres-db/specs/install/aws /path/to/your/infra/aurora-postgres-db
cd /path/to/your/infra/aurora-postgres-db
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # must set repository_org/repository_name to wherever this repo is hosted

tofu init
tofu apply
```

`tags_selectors` must match the tag selectors of the agent(s) that should
pick up aurora-postgres-db actions.

Run this once per nullplatform namespace, alongside the matching
aurora-postgres-server install (see that service's
[`specs/install/README.md`](../../aurora-postgres-server/specs/install/README.md)).
It only registers the service with the platform — it does not create any
AWS infrastructure by itself (this service never creates AWS infrastructure
at all; see the top-level [`README.md`](../../../README.md)).
```

- [ ] **Step 5: Write `specs/install/aws/main.tf`**

Create `aurora-postgres-db/specs/install/aws/main.tf`:
```hcl
################################################################################
# Install — registers the aurora-postgres-db service definition and its
# agent association (notification channel) on a nullplatform account.
################################################################################

locals {
  service_path      = "aurora-postgres-db"
  available_links   = ["connect"]
  available_actions = []
}

module "service_definition" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=v4.5.1"

  nrn               = var.nrn
  repository_org    = var.repository_org
  repository_name   = var.repository_name
  repository_branch = var.repository_branch
  repository_token  = var.repository_token
  service_path      = local.service_path
  service_name      = var.service_name
  available_links   = local.available_links
  available_actions = local.available_actions
}

module "service_definition_agent_association" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=v4.5.1"

  nrn                          = var.nrn
  repository_service_spec_repo = "${var.repository_org}/${var.repository_name}"
  service_path                 = local.service_path
  service_specification_slug   = module.service_definition.service_specification_slug
  api_key                      = var.np_api_key
  tags_selectors               = var.tags_selectors
}
```

- [ ] **Step 6: Write `specs/install/aws/variables.tf`**

Create `aurora-postgres-db/specs/install/aws/variables.tf`:
```hcl
variable "nrn" {
  description = "NullPlatform Resource Name (namespace-level, e.g. organization=<org>:account=<account>:namespace=<namespace>) where the service definition is registered."
  type        = string
}

variable "np_api_key" {
  description = "nullplatform API key used by the agent association to authenticate against the nullplatform API."
  type        = string
  sensitive   = true
}

variable "tags_selectors" {
  description = "Agent tag selectors for the notification channel (must match the tags the target agent registers with)."
  type        = map(string)
}

variable "service_name" {
  description = "Display name for the aurora-postgres-db service in nullplatform."
  type        = string
  default     = "Aurora Postgres DB"
}

variable "repository_org" {
  description = "GitHub organization/user hosting this services-aurora repository."
  type        = string
}

variable "repository_name" {
  description = "Repository name hosting the aurora-postgres-db service spec templates."
  type        = string
  default     = "services-aurora"
}

variable "repository_branch" {
  description = "Branch of the services-aurora repository to register the service spec/links/entrypoint from."
  type        = string
  default     = "main"
}

variable "repository_token" {
  description = "Access token for private repositories."
  type        = string
  default     = null
  sensitive   = true
}
```

- [ ] **Step 7: Write `specs/install/aws/outputs.tf`**

Create `aurora-postgres-db/specs/install/aws/outputs.tf`:
```hcl
output "service_specification_id" {
  description = "ID of the registered aurora-postgres-db service specification."
  value       = module.service_definition.service_specification_id
}

output "service_specification_slug" {
  description = "Slug of the registered aurora-postgres-db service specification."
  value       = module.service_definition.service_specification_slug
}
```

- [ ] **Step 8: Copy `specs/install/aws/terraform.tfvars.example` (identical content to `aurora-postgres-server`'s, written in Task 6 Step 8 — verbatim copy)**

```bash
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/specs/install/aws
cp ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-server/specs/install/aws/terraform.tfvars.example \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/specs/install/aws/terraform.tfvars.example
```

- [ ] **Step 9: Copy `specs/requirements/aws/{data.tf,versions.tf}` verbatim**

```bash
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/specs/requirements/aws
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-db/specs/requirements/aws/data.tf \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/specs/requirements/aws/data.tf
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-db/specs/requirements/aws/versions.tf \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/specs/requirements/aws/versions.tf
```

- [ ] **Step 10: Copy `specs/requirements/aws/variables.tf` verbatim**

```bash
cp ~/Documents/code/nullplatform/services-rds/rds-postgres-db/specs/requirements/aws/variables.tf \
   ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/specs/requirements/aws/variables.tf
```

- [ ] **Step 11: Write `specs/requirements/aws/locals.tf` (role name renamed)**

Create `aurora-postgres-db/specs/requirements/aws/locals.tf`:
```hcl
locals {
  iam_module_name = "requirements-aurora-postgres-db"
  iam_create      = var.iam_create_role

  role_name            = var.role_name != "" ? var.role_name : "nullplatform-${var.cluster_name}-aurora-postgres-db-role"
  policies_name_prefix = var.policies_name_prefix != "" ? var.policies_name_prefix : "nullplatform-${var.cluster_name}"
  agent_role_arn       = var.agent_role_arn != "" ? var.agent_role_arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/nullplatform-${var.cluster_name}-agent-role"

  iam_default_tags = merge(var.iam_resource_tags_json, {
    ManagedBy = "aurora-postgres-db"
    Module    = local.iam_module_name
  })
}
```

- [ ] **Step 12: Write `specs/requirements/aws/main.tf` (secret ARN prefix changed to `nullplatform/aurora/*`, role renamed)**

Create `aurora-postgres-db/specs/requirements/aws/main.tf`:
```hcl
################################################################################
# Permissions role — assumed by the nullplatform agent role (sts:AssumeRole)
################################################################################

resource "aws_iam_role" "nullplatform_aurora_postgres_db" {
  count = local.iam_create ? 1 : 0

  name        = local.role_name
  description = "Permissions role assumed by the nullplatform agent role for aurora-postgres-db in cluster ${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = concat([local.agent_role_arn], var.additional_agent_role_arns) }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.iam_default_tags
}

################################################################################
# Secrets Manager IAM policy — read-only access to the Aurora master password
################################################################################

resource "aws_iam_policy" "nullplatform_aurora_postgres_db_secretsmanager_policy" {
  count = local.iam_create ? 1 : 0

  name        = "${local.policies_name_prefix}-aurora-postgres-db-secretsmanager-policy"
  description = "Policy for reading the Aurora master password from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = "arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:nullplatform/aurora/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "aurora_postgres_db_secretsmanager" {
  count      = local.iam_create ? 1 : 0
  role       = aws_iam_role.nullplatform_aurora_postgres_db[0].name
  policy_arn = aws_iam_policy.nullplatform_aurora_postgres_db_secretsmanager_policy[0].arn
}

################################################################################
# S3 IAM policy (per-service tfstate buckets: np-service-*)
################################################################################

resource "aws_iam_policy" "nullplatform_aurora_postgres_db_s3_policy" {
  count = local.iam_create ? 1 : 0

  name        = "${local.policies_name_prefix}-aurora-postgres-db-s3-policy"
  description = "Policy for managing per-service S3 tfstate buckets (np-service-*)"

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "s3:CreateBucket",
          "s3:HeadBucket",
          "s3:PutBucketVersioning",
          "s3:ListBucket",
          "s3:ListBucketVersions",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:DeleteBucket"
        ],
        "Resource" : [
          "arn:aws:s3:::np-service-*",
          "arn:aws:s3:::np-service-*/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "aurora_postgres_db_s3" {
  count      = local.iam_create ? 1 : 0
  role       = aws_iam_role.nullplatform_aurora_postgres_db[0].name
  policy_arn = aws_iam_policy.nullplatform_aurora_postgres_db_s3_policy[0].arn
}
```

- [ ] **Step 13: Write `specs/requirements/aws/output.tf` (identifiers renamed)**

Create `aurora-postgres-db/specs/requirements/aws/output.tf`:
```hcl
output "permissions_role_arn" {
  description = "ARN of the aurora-postgres-db permissions role assumed by the nullplatform agent role. Pass to the agent (assume_role_arns)."
  value       = local.iam_create ? aws_iam_role.nullplatform_aurora_postgres_db[0].arn : ""
}

output "permissions_role_name" {
  description = "Name of the aurora-postgres-db permissions role"
  value       = local.iam_create ? aws_iam_role.nullplatform_aurora_postgres_db[0].name : ""
}

output "permissions_role_id" {
  description = "ID of the aurora-postgres-db permissions role"
  value       = local.iam_create ? aws_iam_role.nullplatform_aurora_postgres_db[0].id : ""
}

output "secretsmanager_policy_arn" {
  description = "ARN of the Secrets Manager read policy"
  value       = local.iam_create ? aws_iam_policy.nullplatform_aurora_postgres_db_secretsmanager_policy[0].arn : ""
}

output "s3_policy_arn" {
  description = "ARN of the per-service tfstate S3 policy"
  value       = local.iam_create ? aws_iam_policy.nullplatform_aurora_postgres_db_s3_policy[0].arn : ""
}
```

- [ ] **Step 14: Validate both Terraform modules under `specs/`**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/specs/install/aws
tofu fmt && tofu init -backend=false && tofu validate

cd ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/specs/requirements/aws
tofu fmt && tofu init -backend=false && tofu validate
```
Expected: `Success! The configuration is valid.` for both.

- [ ] **Step 15: Commit**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
git add aurora-postgres-db/specs
git commit -m "feat: add aurora-postgres-db specs (service/link spec, install, IAM requirements)"
```

---

### Task 12: `aurora-postgres-db` — values.yaml, workflows, README

**Files:**
- Create: `aurora-postgres-db/values.yaml`
- Create: `aurora-postgres-db/workflows/aws/{create,update,delete,link,unlink}.yaml`
- Create: `aurora-postgres-db/README.md`

- [ ] **Step 1: Write `values.yaml` (no `vpc_id` — this service never touches AWS networking directly)**

Create `aurora-postgres-db/values.yaml`:
```yaml
# Aurora PostgreSQL DB Service — Static Configuration
# These values are not exposed in the NP UI. They configure the execution
# environment for the agent running this service.
#
# NOTE: In scripts, $VALUES is a FILE PATH (set by np service workflow exec --values).
#       It is NOT JSON content. Read values with yaml_value() from build_context.

# AWS region used only for S3 tfstate bucket + Secrets Manager operations —
# this service creates no AWS infrastructure of its own.
region: us-east-1

# Named AWS profile for local testing (e.g. SSO profile with Secrets Manager access)
# If set and AWS_PROFILE is not already in the environment, build_context
# will export it so Terraform and AWS CLI use the correct credentials.
# Run "aws sso login --profile <name>" before starting np-agent locally.
aws_profile: ""

# Provider categories the platform must resolve into CONTEXT.providers before
# running workflow steps. identity-access-control is required by
# scripts/aws/assume_role_step to look up the AssumeRole target ARN.
provider_categories:
  - identity-access-control
```

- [ ] **Step 2: Copy all five workflow YAMLs verbatim**

```bash
mkdir -p ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/workflows/aws
for f in create update delete link unlink; do
  cp ~/Documents/code/nullplatform/services-rds/rds-postgres-db/workflows/aws/$f.yaml \
     ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db/workflows/aws/$f.yaml
done
```

- [ ] **Step 3: Validate the YAML and check every referenced script path exists**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora/aurora-postgres-db
for f in workflows/aws/*.yaml; do
  python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" && echo "YAML OK: $f"
done
grep -ohE '\$SERVICE_PATH/[^ ]+' workflows/aws/*.yaml | sed 's/\$SERVICE_PATH\///' | sort -u | while read -r rel; do
  [ -f "$rel" ] && echo "exists: $rel" || echo "MISSING: $rel"
done
```
Expected: `YAML OK` for all five files, no `MISSING:` lines (this also confirms `db_setup` exists but that no workflow references a `deployment/` directory — the dead-code cleanup from the Global Constraints section).

- [ ] **Step 4: Write `README.md`**

Create `aurora-postgres-db/README.md`:
```markdown
# aurora-postgres-db

A nullplatform dependency service that provisions and manages a **PostgreSQL database** within an existing Aurora cluster managed by [`aurora-postgres-server`](../aurora-postgres-server). It handles database creation, app-level user management, and per-link fine-grained access control — without creating any AWS infrastructure itself.

## What It Does

- Auto-discovers a compatible `aurora-postgres-server` in the same nullplatform namespace using dimension matching **and** an internal `engine_family = "aurora-postgresql"` attribute (disambiguates from a classic RDS `rds-postgres-server` that might share the same dimensions)
- Creates a dedicated PostgreSQL database and application-level user within that cluster
- Manages per-link permissions: each link to an application gets its own PostgreSQL user with scoped grants (`read`, `write`, or `read-write`)
- Stores connection credentials in nullplatform service and link attributes for injection into applications

## Architecture

```
nullplatform Application
        │
        │ link (creates user + grants)
        ▼
 aurora-postgres-db  ──────► aurora-postgres-server  ──────► AWS Aurora PostgreSQL
  (this service)              (auto-discovered)                │
        │                                                       ├─ database: app_<application_id>
        │                                                       ├─ user: app_<application_id>  (service-level)
        └─ per link:                                            └─ user: np_<link_id_prefix>   (per link)
             postgresql_role.<link>
             postgresql_grant.*
```

Unlike `aurora-postgres-server`, this service creates no AWS resources. It only manages PostgreSQL-level objects (databases, roles, grants) on the shared Aurora cluster.

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
| `username` | Per-link PostgreSQL user (`np_<first 16 chars of link_id>`) |
| `password` | Per-link PostgreSQL password |
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
| `link` | Application linked | Creates per-link PostgreSQL user with scoped grants |
| `unlink` | Application unlinked | Revokes grants only; user and database are **preserved** |

## Database and Username Derivation

```
database_name = "app_<application_id>"
username      = "app_<application_id>"
```

Link-level: `username = "np_<first 16 hex chars of link_id>"`.

## Requirements

- An active **`aurora-postgres-server`** service in the same nullplatform namespace with `status: active`, matching dimensions, and `hostname`/`master_secret_arn`/`engine_family` attributes already set.
- See [`specs/install/README.md`](specs/install/README.md) and [`specs/requirements/aws`](specs/requirements/aws) for platform registration and the AssumeRole IAM role (selector `aurora-postgres-db`; Secrets Manager read access scoped to `nullplatform/aurora/*`).

## Important Considerations

These match `rds-postgres-db`'s documented behavior exactly (same Terraform design in `db_setup`/`permissions`):

- **Database is never destroyed**: `lifecycle { prevent_destroy = true }` on `postgresql_database.app`.
- **Two-phase deletion**: `reassign_owned` transfers ownership to master, then a targeted `tofu destroy` removes only the app role.
- **Stable passwords**: service-level password keyed by `service_id`; per-link passwords keyed by `link_id`.
- **`read-write` allows schema modifications** (`CREATE` on `public`).
- **Dimension + engine_family alignment is critical** for discovery to succeed.
- **Orphaned PostgreSQL roles from failed creates**: `app_<application_id>` is stable across retries — a failed create that got as far as creating the role but not writing `hostname` leaves an orphaned role; a later `create` retry fails with `role "app_<application_id>" already exists`. Connect with master credentials and `DROP ROLE IF EXISTS app_<application_id>;` (after reassigning/dropping any owned objects) before retrying.
```

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
git add aurora-postgres-db/values.yaml aurora-postgres-db/workflows aurora-postgres-db/README.md
git commit -m "feat: add aurora-postgres-db values/workflows/README"
```

---

### Task 13: Full-repo validation sweep

**Files:** none new — validates everything created in Tasks 1–12.

- [ ] **Step 1: Run `tofu fmt -check -recursive` and `tofu validate` (with local backend) over every Terraform module in the repo**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
tofu fmt -check -recursive .
echo "fmt exit: $?"

for dir in aurora-postgres-server/deployment aurora-postgres-server/permissions \
           aurora-postgres-server/specs/install/aws aurora-postgres-server/specs/requirements/aws \
           aurora-postgres-db/db_setup aurora-postgres-db/permissions \
           aurora-postgres-db/specs/install/aws aurora-postgres-db/specs/requirements/aws; do
  echo "--- $dir ---"
  (cd "$dir" && rm -rf .terraform && tofu init -backend=false >/dev/null && tofu validate)
done
```
Expected: `fmt exit: 0`, and `Success! The configuration is valid.` for all eight modules.

- [ ] **Step 2: Syntax-check every bash script in the repo**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
find . -path '*/entrypoint/*' -o -path '*/scripts/aws/*' | while read -r f; do
  [ -f "$f" ] || continue
  bash -n "$f" && echo "OK: $f" || echo "FAIL: $f"
done
```
Expected: `OK: <path>` for every script, no `FAIL:` lines.

- [ ] **Step 3: Validate every JSON/YAML template**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
find . -name "*.json.tpl" | while read -r f; do
  jq empty "$f" && echo "JSON OK: $f" || echo "JSON FAIL: $f"
done
find . -path '*/workflows/aws/*.yaml' -o -name "values.yaml" | while read -r f; do
  python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" && echo "YAML OK: $f" || echo "YAML FAIL: $f"
done
```
Expected: `JSON OK`/`YAML OK` for every file, no `FAIL` lines.

- [ ] **Step 4: Clean up leftover `.terraform` directories from validation and re-check git status**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
find . -type d -name ".terraform" -exec rm -rf {} + 2>/dev/null
git status
```
Expected: `.terraform` directories are gone (excluded by the `.gitignore` from Task 1 in any case); `git status` shows a clean tree (everything already committed by prior tasks) or only expected untracked scratch files.

- [ ] **Step 5: Final commit if anything is outstanding**

```bash
cd ~/Documents/code/nullplatform/lulobank/services-aurora
git add -A
git status --short
# Only commit if the above shows staged changes:
git commit -m "chore: repo-wide validation sweep" || echo "nothing to commit"
```

---

## What this plan does NOT cover (explicitly out of scope)

- Porting `services-rds/.github/workflows/*` CI automation (see Global Constraints).
- Any live `tofu plan`/`apply` against a real AWS account, or a real `create → link → unlink → delete` cycle against a nullplatform account — both require live AWS/nullplatform credentials this environment does not have. This is the same limitation called out in the design spec's Validation Plan section.
