###############################################################################
# main.tf — DevOps Agent EKS Cluster (Free Tier / Low-Cost Optimized)
#
# COST DECISIONS EXPLAINED:
#  ✓ Single AZ only      → saves cross-AZ data transfer ($0.01/GB)
#  ✓ No NAT Gateway      → saves $0.045/hr (~$33/month)
#  ✓ Public subnets only → nodes get public IPs, route via IGW for free
#  ✓ t3.micro nodes      → Free Tier (750 hrs/month first 12 months)
#  ✓ 1 node minimum      → don't pay for idle capacity
#  ✓ 20GB disk           → minimum viable EBS (charged at $0.10/GB-month)
#  ✓ No CloudWatch logs  → avoids log ingestion charges ($0.50/GB)
#  ✗ EKS control plane   → unavoidable $0.10/hr; destroy when done!
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.5.0"
}

provider "aws" {
  region = var.aws_region

  # Free Tier tip: tag every resource for cost tracking in Cost Explorer
  default_tags {
    tags = {
      Project     = "devops-agent"
      Environment = "dev"
      ManagedBy   = "terraform"
      # Use this tag to find all resources for cleanup
      AutoDelete  = "true"
    }
  }
}

###############################################################################
# DATA SOURCES
###############################################################################

# Use only ONE availability zone to avoid cross-AZ data transfer charges.
# Multi-AZ is for production HA — overkill and costly for learning.
data "aws_availability_zones" "available" {
  state = "available"
  # Filter to avoid local zones (opt-in) that may cause issues
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

###############################################################################
# VPC — Two subnets (EKS requirement) but nodes only in AZ-1 (cost saving)
#
# WHY TWO SUBNETS?
#   EKS control plane is an AWS-managed service that runs across multiple AZs
#   for its own high availability. AWS REQUIRES subnet_ids to span at least
#   2 different AZs when creating the cluster — even if you only want nodes
#   in one AZ. This is a hard API constraint, not optional.
#
# HOW WE KEEP COSTS LOW DESPITE TWO SUBNETS:
#   - subnet_az1 (10.0.1.0/24): used by BOTH the cluster AND node group
#   - subnet_az2 (10.0.2.0/24): used ONLY by the cluster definition (satisfies
#     the 2-AZ requirement). No EC2 nodes are ever launched here.
#   - No node in AZ-2 means zero cross-AZ data transfer charges ($0.01/GB).
#   - No NAT Gateway in either AZ — nodes use public IPs via IGW (free).
#
# COST IMPACT OF SECOND SUBNET: $0.00
#   Empty subnets cost nothing. AWS charges for resources inside subnets
#   (EC2, NAT GW, etc.), not for the subnet CIDRs themselves.
###############################################################################

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true  # Required: nodes resolve EKS API server hostname
  enable_dns_hostnames = true  # Required: nodes register with EKS by hostname

  tags = {
    Name = "${var.cluster_name}-vpc"
    # EKS uses this tag to discover the VPC for its internal use
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

# ── Subnet AZ-1 ── nodes live here, cluster references this ──────────────
# This is where your t3.micro worker node will actually run.
resource "aws_subnet" "public_az1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  # Nodes get public IPs → can reach ECR/Bedrock via IGW with no NAT Gateway
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.cluster_name}-public-az1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

# ── Subnet AZ-2 ── cluster definition only, NO nodes launched here ────────
# Exists purely to satisfy EKS's "must span 2 AZs" requirement.
# No EC2 instances, no NAT Gateway, no cost beyond the subnet CIDR itself.
resource "aws_subnet" "public_az2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  # map_public_ip_on_launch intentionally false — no nodes will launch here
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.cluster_name}-public-az2-control-plane-only"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# Single route table shared by both subnets — both need IGW for control plane
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.cluster_name}-public-rt" }
}

resource "aws_route_table_association" "public_az1" {
  subnet_id      = aws_subnet.public_az1.id
  route_table_id = aws_route_table.public.id
}

# AZ-2 also needs the route table so EKS control plane ENIs can reach the internet
resource "aws_route_table_association" "public_az2" {
  subnet_id      = aws_subnet.public_az2.id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# SECURITY GROUPS
#
# WHY TWO SEPARATE SECURITY GROUPS?
#   EKS recommends separating the cluster (control plane) SG from the node SG.
#   The cluster SG manages traffic between control plane and nodes.
#   The node SG manages traffic between nodes and external sources.
#
# COST IMPACT: Security groups are free. Be precise to stay secure.
###############################################################################

# Security group for the EKS cluster control plane
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS cluster control plane security group"
  vpc_id      = aws_vpc.main.id

  # Allow nodes to call the Kubernetes API server (port 443)
  ingress {
    description     = "Nodes to API server"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.nodes.id]
  }

  egress {
    description = "Control plane outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-cluster-sg" }
}

# Security group for EC2 worker nodes
resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes-sg"
  description = "EKS worker node security group"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.cluster_name}-nodes-sg" }
}

# Nodes must talk to each other (pod-to-pod traffic, kube-proxy, CNI)
resource "aws_security_group_rule" "nodes_internal" {
  description              = "Allow all inter-node traffic"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.nodes.id
  security_group_id        = aws_security_group.nodes.id
}

# EKS control plane calls back to kubelet on each node (port 10250)
# This is how kubectl exec, kubectl logs, etc. work
resource "aws_security_group_rule" "nodes_from_controlplane" {
  description              = "Control plane to kubelet API"
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.cluster.id
  security_group_id        = aws_security_group.nodes.id
}

# All outbound: ECR pulls, Bedrock API calls, apt updates, etc.
resource "aws_security_group_rule" "nodes_outbound" {
  description       = "All outbound"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.nodes.id
}

###############################################################################
# EKS CLUSTER
#
# WHY VERSION 1.29?
#   Latest stable as of mid-2024. Always use the latest available —
#   older versions lose support and you can't upgrade for free.
#
# WHY endpoint_public_access = true?
#   You need to run kubectl from your laptop. Private-only endpoint
#   requires VPN or bastion host — unnecessary complexity for dev.
#   The API server is secured by IAM auth anyway.
#
# WHY NO enabled_cluster_log_types?
#   CloudWatch Logs charges $0.50/GB ingestion + $0.03/GB storage.
#   Control plane logs can generate 1-5GB/day on even a small cluster.
#   For learning, disable all logging and use kubectl for debugging instead.
###############################################################################

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = "1.35"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids = [
      aws_subnet.public_az1.id,  # nodes run here
      aws_subnet.public_az2.id,  # control plane 2nd AZ requirement only
    ]

    # Attach BOTH security groups so control plane ↔ node communication works
    security_group_ids = [aws_security_group.cluster.id]

    # Public: your laptop can reach the API server
    endpoint_public_access  = true
    # Restrict to your own IP — change 0.0.0.0/0 to YOUR_IP/32 for security
    public_access_cidrs     = [var.allowed_cidr]
    # Private: disabled to avoid cross-VPC complexity
    endpoint_private_access = false
  }

  # COST SAVING: No control plane log types = no CloudWatch charges
  # Uncomment only if you need to debug cluster startup issues:
  # enabled_cluster_log_types = ["api", "audit"]

  # Ensure IAM role exists before creating cluster
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_cluster_vpc_resource_controller,
  ]

  tags = { Name = var.cluster_name }
}

###############################################################################
# EKS MANAGED NODE GROUP — t3.micro, single node minimum
#
# WHY MANAGED NODE GROUP vs SELF-MANAGED?
#   Managed node groups handle node provisioning, OS patching, and
#   graceful drain/replace during cluster upgrades. Self-managed is
#   more flexible but requires you to write launch templates and
#   handle AMI updates manually. Not worth the complexity for learning.
#
# WHY t3.micro?
#   Free Tier: 750 hours/month for the first 12 months.
#   For a dev cluster running 2-3 hours at a time, essentially free.
#   t3.micro = 1 vCPU, 1GB RAM. Tight but workable for 2-3 small pods.
#
# WHY desired_size = 1, min = 1, max = 2?
#   Start with 1 node to minimize cost.
#   Max 2 lets the agent scale_deployment tool demonstrate scaling.
#   Don't set max > 2 on a Free Tier account — you'll exceed 750 hr limit.
#
# WHY disk_size = 20?
#   EBS gp2 costs $0.10/GB-month. 20GB = $2/month if left running.
#   20GB is the minimum that fits the EKS node AMI + a few container images.
###############################################################################

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "main"
  node_role_arn   = aws_iam_role.eks_nodes.arn

  # Only the one public subnet — single AZ intentional for cost
  subnet_ids = [aws_subnet.public_az1.id]

  # t3.micro = Free Tier eligible for first 12 months
  instance_types = [var.node_instance_type]

  # Minimum disk. The EKS AMI itself uses ~8GB, leaving ~12GB for images.
  disk_size = 20

  # Amazon Linux 2 EKS-optimized AMI — pre-configured with kubelet, CNI
  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"  # Switch to SPOT for 60-90% savings if you accept interruptions

  scaling_config {
    desired_size = var.node_desired_size  # default: 2 Every pod on EKS needs its own private IP address from the VPC. AWS allocates IPs based on the number of ENIs an instance can hold. t3.micro maxes out at 4 pods total.
    min_size     = 1
    max_size     = 2  # max 2 to stay within Free Tier 750hr limit
  }

  # Rolling update: replace 1 node at a time
  update_config {
    max_unavailable = 1
  }

  # Tag nodes for Cluster Autoscaler (if you later add it)
  tags = {
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
  ]
}
