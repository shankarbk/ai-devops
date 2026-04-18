###############################################################################
# variables.tf — All configurable values with cost-optimized defaults
#
# To override any variable: create a terraform.tfvars file:
#   aws_region = "us-east-1"
#   cluster_name = "my-devops-agent"
#   allowed_cidr = "203.0.113.10/32"   # your IP only!
###############################################################################

variable "aws_region" {
  description = "AWS region. us-east-1 is required for Bedrock Free Tier access."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2", "ap-southeast-1"], var.aws_region)
    error_message = "Use us-east-1 for max Bedrock model availability and Free Tier benefits."
  }
}

variable "cluster_name" {
  description = "Name prefix for all resources. Keep it short — some AWS names have length limits."
  type        = string
  default     = "devops-agent-cluster"

  validation {
    condition     = length(var.cluster_name) <= 20
    error_message = "cluster_name must be 20 chars or less (EKS name limit)."
  }
}

variable "node_instance_type" {
  description = <<-EOF
    EC2 instance type for worker nodes.
    
    COST OPTIONS (cheapest first):
      t3.micro  — Free Tier (750hr/mo), 1 vCPU, 1GB RAM. Good for 2-3 tiny pods.
      t3.small  — $0.0208/hr, 1 vCPU, 2GB RAM. Better if pods OOMKill on micro.
      t3.medium — $0.0416/hr, 2 vCPU, 4GB RAM. Comfortable for real workloads.
    
    START with t3.micro. If your agent pod keeps getting OOMKilled, move to t3.small.
  EOF
  type        = string
  default     = "t3.micro"

  validation {
    condition     = can(regex("^t3\\.(micro|small|medium)$", var.node_instance_type))
    error_message = "For Free Tier, use t3.micro. For more RAM: t3.small or t3.medium."
  }
}

variable "node_desired_size" {
  description = <<-EOF
    Number of worker nodes to start with.
    
    1 = minimum cost (~$0 on Free Tier for t3.micro)
    2 = allows testing pod scheduling and agent scale_deployment tool properly
    
    Default: 1 — scale to 2 manually when testing scaling features.
  EOF
  type        = number
  default     = 2

  validation {
    condition     = var.node_desired_size >= 1 && var.node_desired_size <= 2
    error_message = "desired_size must be 1 or 2 for Free Tier safety."
  }
}

variable "allowed_cidr" {
  description = <<-EOF
    CIDR block allowed to reach the EKS API server (kubectl access).
    
    SECURITY: Change this to YOUR_IP/32 instead of 0.0.0.0/0.
    Find your IP: curl ifconfig.me
    Example: allowed_cidr = "203.0.113.10/32"
    
    0.0.0.0/0 is fine for quick testing but locks EKS API to no-one harmful
    since it still requires valid AWS IAM credentials to authenticate.
  EOF
  type        = string
  default     = "0.0.0.0/0"
}

variable "k8s_namespace" {
  description = "Kubernetes namespace where the agent pod will run."
  type        = string
  default     = "default"
}

variable "agent_service_account" {
  description = "Name of the Kubernetes ServiceAccount used by the agent pod. Must match k8s/rbac.yaml."
  type        = string
  default     = "devops-agent-sa"
}
