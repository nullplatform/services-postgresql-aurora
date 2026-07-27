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
