# ─── EKS CLUSTER ROLE ───────────────────────────────────────────────────
# EKS control plane needs permission to manage AWS resources on your behalf
# (create ENIs for nodes, describe EC2 instances, etc.)

resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# ─── EKS NODE ROLE ──────────────────────────────────────────────────────
# EC2 worker nodes need permissions to:
# 1. Join the EKS cluster (EKSWorkerNodePolicy)
# 2. Pull images from ECR (AmazonEC2ContainerRegistryReadOnly)
# 3. Set up pod networking (AmazonEKS_CNI_Policy)

resource "aws_iam_role" "eks_nodes" {
  name = "${var.cluster_name}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

locals {
  node_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  count      = length(local.node_policies)
  policy_arn = local.node_policies[count.index]
  role       = aws_iam_role.eks_nodes.name
}

# ─── IRSA: Agent Pod → Bedrock ──────────────────────────────────────────
# IRSA = IAM Roles for Service Accounts
# This lets our agent Pod assume an IAM role WITHOUT embedding credentials.
# The OIDC provider links the K8s ServiceAccount to the IAM role.
# THIS IS THE CORRECT WAY — never mount AWS credentials in pods.

data "aws_eks_cluster" "this" {
  name = aws_eks_cluster.main.name
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_role" "agent_pod" {
  name = "${var.cluster_name}-agent-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" =
            "system:serviceaccount:default:devops-agent"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "agent_bedrock" {
  name = "agent-bedrock-access"
  role = aws_iam_role.agent_pod.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:PutUseCaseForModelAccess", "aws-marketplace:Subscribe"]
      Resource = "arn:aws:bedrock:*::foundation-model/anthropic.claude-3-haiku-*"
    }]
  })
}