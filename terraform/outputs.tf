output "ecr_repository_url" {
  value = aws_ecr_repository.worker.repository_url
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.worker.arn
}

output "worker_security_group_id" {
  value = aws_security_group.worker.id
}

output "subnet_ids" {
  value = var.subnet_ids
}

output "assign_public_ip" {
  value = var.assign_public_ip
}

output "secret_arns" {
  value = {
    source = aws_secretsmanager_secret.source_db_dsn.arn
    target = aws_secretsmanager_secret.target_db_dsn.arn
  }
}
