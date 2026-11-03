terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Credentials come from the environment / AWS profile, never from this code.
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = var.project }
  }
}

data "aws_caller_identity" "current" {}

# ---------- ECR ----------
resource "aws_ecr_repository" "worker" {
  name                 = var.project
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "worker" {
  repository = aws_ecr_repository.worker.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

# ---------- Secrets (containers only; set values outside Terraform) ----------
resource "aws_secretsmanager_secret" "source_db_dsn" {
  name = "${var.project}/SOURCE_DB_DSN"
}

resource "aws_secretsmanager_secret" "target_db_dsn" {
  name = "${var.project}/TARGET_DB_DSN"
}

# ---------- Logs ----------
resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.project}"
  retention_in_days = var.log_retention_days
}

# ---------- IAM ----------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# Execution role: pull image, write logs, read ONLY the two secrets.
resource "aws_iam_role" "execution" {
  name               = "${var.project}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [aws_ecr_repository.worker.arn]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.worker.arn}:*"]
  }
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.source_db_dsn.arn,
      aws_secretsmanager_secret.target_db_dsn.arn,
    ]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# Task role: the app itself needs no AWS permissions.
resource "aws_iam_role" "task" {
  name               = "${var.project}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# ---------- Security groups ----------
resource "aws_security_group" "worker" {
  name        = "${var.project}-worker"
  description = "ETL worker tasks"
  vpc_id      = var.vpc_id
}

# No inbound rules. Outbound: DB port to the DB SGs, HTTPS for ECR/Secrets/Logs.
resource "aws_vpc_security_group_egress_rule" "to_db" {
  for_each                     = toset(var.db_security_group_ids)
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
  description                  = "Postgres to databases"
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.worker.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS to AWS APIs"
}

# Allow the worker into each database SG.
resource "aws_vpc_security_group_ingress_rule" "db_from_worker" {
  for_each                     = toset(var.db_security_group_ids)
  security_group_id            = each.value
  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
  description                  = "ETL worker"
}

# ---------- ECS ----------
resource "aws_ecs_cluster" "this" {
  name = var.project

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "worker" {
  family                   = var.project
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "worker"
    image     = "${aws_ecr_repository.worker.repository_url}:v2"
    essential = true
    secrets = [
      { name = "SOURCE_DB_DSN", valueFrom = aws_secretsmanager_secret.source_db_dsn.arn },
      { name = "TARGET_DB_DSN", valueFrom = aws_secretsmanager_secret.target_db_dsn.arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.worker.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "worker"
      }
    }
  }])
}
