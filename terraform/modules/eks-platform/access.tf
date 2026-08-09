data "aws_caller_identity" "current" {}

resource "aws_eks_access_entry" "admin" {
    cluster_name = aws_eks_cluster.main.name
    principal_arn = data.aws_caller_identity.current.arn
}

resource "aws_eks_access_policy_association" "admin" {
    cluster_name = aws_eks_cluster.main.name
    principal_arn = aws_eks_access_entry.admin.principal_arn
    policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

    access_scope {
        type = "cluster"
    }
}
