###############################################################################
# outputs.tf — Values you'll need after terraform apply
#
# Run: terraform output         → see all values
# Run: terraform output -json   → machine-readable for scripts
###############################################################################

output "cluster_name" {
  description = "EKS cluster name — use in all aws eks commands"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server URL — kubectl talks to this"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster"
  value       = aws_eks_cluster.main.version
}

output "cluster_oidc_issuer" {
  description = "OIDC issuer URL — needed for IRSA debugging"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "agent_role_arn" {
  description = "IAM role ARN for the agent pod — annotate ServiceAccount with this"
  value       = aws_iam_role.agent_pod.arn
}

output "ecr_repository_url" {
  description = "ECR repository URL — use in: docker tag my-image <this-url>:latest"
  value       = aws_ecr_repository.agent.repository_url
}

output "node_role_arn" {
  description = "IAM role ARN for worker nodes (for reference/debugging)"
  value       = aws_iam_role.eks_nodes.arn
}

# ── Ready-to-run commands ──────────────────────────────────────────────────

output "cmd_configure_kubectl" {
  description = "Run this to configure kubectl after apply"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}

output "cmd_ecr_login" {
  description = "Run this to authenticate Docker to ECR before pushing images"
  value       = "aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${aws_ecr_repository.agent.repository_url}"
}

output "cmd_apply_rbac" {
  description = "Run this to apply RBAC after setting AGENT_ROLE_ARN in rbac.yaml"
  value       = "AGENT_ROLE_ARN=${aws_iam_role.agent_pod.arn} envsubst < k8s/rbac.yaml | kubectl apply -f -"
}

output "cmd_watch_nodes" {
  description = "Watch nodes come online after cluster creation"
  value       = "kubectl get nodes -w"
}

output "cmd_destroy" {
  description = "IMPORTANT: Run this to avoid charges when done!"
  value       = "cd terraform && terraform destroy -auto-approve"
}

# ── Cost estimate ──────────────────────────────────────────────────────────

output "cost_estimate" {
  description = "Estimated hourly cost while cluster is running"
  value = {
    eks_control_plane = "$0.10/hr (unavoidable — destroy when done!)"
    node_t3_micro     = "$0.00/hr if within Free Tier 750hr/month limit"
    ebs_20gb          = "$0.066/day ($2/month) — negligible"
    ecr_storage       = "$0.00 if image < 500MB (Free Tier limit)"
    total_estimate    = "~$0.10/hr = $2.40 for a full 24-hour session"
  }
}
