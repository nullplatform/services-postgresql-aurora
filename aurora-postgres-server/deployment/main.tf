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
