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
