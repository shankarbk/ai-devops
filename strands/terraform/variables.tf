variable "aws_region" {
  default = "us-east-1"
}

variable "cluster_name" {
  default = "devops-agent-eks"
}

variable "availability_zones" {
  default = [
    "us-east-1a",
    "us-east-1b"
  ]
}