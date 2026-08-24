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
          "rds:DescribeGlobalClusters",
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
#
# The KMS statement is what makes the secret_kms_key_id parameter usable: when
# it is set, Secrets Manager calls KMS on this role's behalf to wrap and unwrap
# the master secret, so without it CreateSecret/GetSecretValue fail with
# AccessDenied on the key rather than on the secret. The key ARN is
# operator-supplied and therefore not knowable here, so the grant is scoped by
# kms:ViaService instead — these actions are only allowed when the call comes
# through Secrets Manager, never for decrypting anything else with that key.
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
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey"
        ],
        "Resource" : "*",
        "Condition" : {
          "StringLike" : {
            "kms:ViaService" : "secretsmanager.*.amazonaws.com"
          }
        }
      }
    ]
  })
}
