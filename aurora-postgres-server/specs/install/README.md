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
