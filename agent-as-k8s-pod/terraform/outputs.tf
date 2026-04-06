output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "agent_role_arn" {
  value = aws_iam_role.agent_pod.arn
}

output "kubeconfig_cmd" {
  value = "aws eks update-kubeconfig --region us-east-1 --name ${aws_eks_cluster.main.name}"
}

