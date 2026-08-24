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
# Secrets Manager IAM policy — read the Aurora master password, manage the
# app-level credentials secret this service creates in db_setup/
#
# The KMS statement covers the case where the aurora-postgres-server sets
# secret_kms_key_id: Secrets Manager then calls KMS on this role's behalf to
# wrap and unwrap the secret, so without it CreateSecret/GetSecretValue fail
# with AccessDenied on the key rather than on the secret. The key ARN is
# operator-supplied and therefore not knowable here, so the grant is scoped by
# kms:ViaService instead — these actions are only allowed when the call comes
# through Secrets Manager, never for decrypting anything else with that key.
################################################################################

resource "aws_iam_policy" "nullplatform_aurora_postgres_db_secretsmanager_policy" {
  count = local.iam_create ? 1 : 0

  name        = "${local.policies_name_prefix}-aurora-postgres-db-secretsmanager-policy"
  description = "Policy for reading the Aurora master password and managing the app-level credentials secret in Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
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
        ]
        Resource = "arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:nullplatform/aurora/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "kms:ViaService" = "secretsmanager.*.amazonaws.com"
          }
        }
      }
    ]
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
