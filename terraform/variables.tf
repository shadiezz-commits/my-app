variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "project" {
  type    = string
  default = "etl-worker"
}

variable "vpc_id" {
  description = "VPC where the Fargate tasks and databases live"
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the Fargate tasks"
  type        = list(string)
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_security_group_ids" {
  description = "Security groups attached to the source/target databases; they will allow the worker on db_port"
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Set true only if the subnets are public with no NAT/VPC endpoints"
  type        = bool
  default     = false
}

variable "log_retention_days" {
  type    = number
  default = 30
}
