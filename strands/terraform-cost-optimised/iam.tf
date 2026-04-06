###############################################################################
# iam.tf — All IAM roles and policies
#
# STRUCTURE:
#   1. EKS Cluster Role     — control plane assumes this
#   2. EKS Node Role        — EC2 worker nodes assume this
#   3. IRSA for Agent Pod   — the agent pod assumes this to call Bedrock
#
# KEY CONCEPT — IRSA (IAM Roles for Service Accounts):
#   Without IRSA: you'd put AWS_ACCESS_KEY_ID in a K8s Secret. Bad practice.
#   With IRSA: K8s injects a signed JWT into the pod → pod calls STS
#              AssumeRoleWithWebIdentity → gets temporary credentials.
#   Result: zero long-lived credentials stored anywhere. Auto-rotated hourly.
###############################################################################

###############################################################################
# 1. EKS CLUSTER ROLE
#
# The EKS control plane needs IAM permissions to:
#   - Create and manage ENIs for pod networking
#   - Describe EC2 instances and autoscaling groups
#   - Create security group rules for node communication
#   - Manage ELBs if you deploy services with LoadBalancer type
###############################################################################

resource "aws_iam_role" "eks_cluster" {
  name        = "${var.cluster_name}-cluster-role"
  description = "IAM role for EKS control plane"

  # Trust policy: only the EKS service can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "eks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# AmazonEKSClusterPolicy — everything the control plane needs
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# Needed for VPC CNI and security group management
resource "aws_iam_role_policy_attachment" "eks_cluster_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

###############################################################################
# 2. EKS NODE ROLE
#
# Worker nodes (EC2 instances) need permissions to:
#   - Join the EKS cluster and register as nodes (EKSWorkerNodePolicy)
#   - Set up pod networking via AWS VPC CNI (AmazonEKS_CNI_Policy)
#   - Pull container images from ECR (AmazonEC2ContainerRegistryReadOnly)
#
# NOTE: Node role should NOT have Bedrock permissions.
#       Pod-level permissions go on the IRSA role (see section 3).
#       Principle of least privilege: nodes don't need LLM access.
###############################################################################

resource "aws_iam_role" "eks_nodes" {
  name        = "${var.cluster_name}-node-role"
  description = "IAM role for EKS worker nodes"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  # Read-only: nodes can pull images but not push
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}

###############################################################################
# 3. IRSA — Agent Pod IAM Role
#
# HOW IRSA WORKS (step by step):
#   a) EKS cluster has an OIDC issuer URL (unique per cluster)
#   b) We create an IAM OIDC Provider that trusts that URL
#   c) We create an IAM role whose trust policy says:
#      "Allow tokens from OIDC provider where sub = serviceaccount:default:devops-agent"
#   d) K8s ServiceAccount is annotated with the role ARN
#   e) EKS automatically mounts a projected token into the pod
#   f) AWS SDKs (boto3) detect the token and call STS automatically
#
# NET RESULT: Your agent pod can call Bedrock API with no credentials stored.
###############################################################################

# Get the TLS certificate fingerprint for the EKS OIDC endpoint
# This is required to establish the trust relationship
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# Register the EKS cluster's OIDC provider with IAM
# This is the bridge between Kubernetes service accounts and IAM roles
resource "aws_iam_openid_connect_provider" "eks" {
  # The OIDC URL from the EKS cluster (e.g. https://oidc.eks.us-east-1.amazonaws.com/id/XXXXX)
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer

  # STS is the client that exchanges OIDC tokens for AWS credentials
  client_id_list = ["sts.amazonaws.com"]

  # Fingerprint of the OIDC endpoint's TLS certificate
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

# The IAM role our agent pod will assume via IRSA
resource "aws_iam_role" "agent_pod" {
  name        = "${var.cluster_name}-agent-pod-role"
  description = "IRSA role for devops-agent pod allows Bedrock and AgentCore access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          # Trust ONLY this specific OIDC provider (this EKS cluster)
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # sub = the specific K8s ServiceAccount that can assume this role
            # Format: system:serviceaccount:<namespace>:<serviceaccount-name>
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:${var.k8s_namespace}:${var.agent_service_account}"
            # aud = audience must be STS (not some other AWS service)
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Inline policy granting ONLY the Bedrock permissions the agent needs.
# We scope to haiku model only — don't give access to expensive models.
resource "aws_iam_role_policy" "agent_bedrock" {
  name = "${var.cluster_name}-agent-bedrock-policy"
  role = aws_iam_role.agent_pod.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvokeHaiku"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        # Scope to Haiku only — prevents accidental use of expensive models
        # Change to * if you want to allow Sonnet/Opus too
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-3-haiku-20240307-v1:0",
        ]
      },
      {
        # AgentCore runtime invocation permission
        Sid    = "AgentCoreRuntime"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:InvokeAgentRuntime",
          "bedrock-agentcore:GetAgentRuntime",
        ]
        Resource = "*"
      }
    ]
  })
}

###############################################################################
# ECR REPOSITORY — for storing the agent container image
#
# WHY ECR vs Docker Hub?
#   ECR pulls from within AWS are free (no data transfer charge).
#   Docker Hub pulls from EC2 are charged as internet egress ($0.09/GB).
#   For a 500MB image pulled on every node restart, ECR saves money.
#
# COST: ECR storage is $0.10/GB-month. A 500MB image = $0.05/month. Free Tier
#       includes 500MB of ECR storage. Enable image scanning for security.
###############################################################################

resource "aws_ecr_repository" "agent" {
  name                 = "${var.cluster_name}-agent"
  image_tag_mutability = "MUTABLE"  # allow overwriting 'latest' tag

  # Scan images for CVEs on push — free, catches security issues early
  image_scanning_configuration {
    scan_on_push = true
  }

  # Encrypt images at rest — free with default AWS-managed keys
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = { Name = "${var.cluster_name}-agent" }
}

# Lifecycle policy: auto-delete untagged images older than 7 days.
# ECR charges $0.10/GB-month — dangling images from CI/CD add up fast.
resource "aws_ecr_lifecycle_policy" "agent" {
  repository = aws_ecr_repository.agent.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Delete untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only last 3 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 3
        }
        action = { type = "expire" }
      }
    ]
  })
}
