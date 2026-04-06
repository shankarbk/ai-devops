# ─── EKS CLUSTER ──────────────────────────────────────────────────────────
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = "1.29"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    security_group_ids      = [aws_security_group.nodes.id]
    endpoint_private_access = false   # public endpoint only (simpler)
    endpoint_public_access  = true
    public_access_cidrs     = ["0.0.0.0/0"]  # lock this to your IP in prod!
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  tags = { Name = var.cluster_name }
}

# ─── MANAGED NODE GROUP ───────────────────────────────────────────────────
# Managed node groups handle node lifecycle (launch, replace on failure).
# t3.micro = Free Tier eligible (750 hrs/month for first 12 months).
# min_size=1, max_size=2 keeps costs low while allowing scale for learning.

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "main"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.public[*].id

  instance_types = ["t3.micro"]
  disk_size      = 20   # GB — minimum viable
  ami_type       = "AL2023_x86_64_STANDARD"   # Amazon Linux 2 EKS-optimized AMI

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 3
  }

  update_config {
    max_unavailable = 1   # rolling updates: replace 1 node at a time
  }

  depends_on = [aws_iam_role_policy_attachment.node_policies]

  tags = {
    "k8s.io/cluster-autoscaler/enabled"              = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}"  = "owned"
  }
}