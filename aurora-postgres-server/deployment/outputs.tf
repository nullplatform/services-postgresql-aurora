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
