resource "aws_eks_cluster" "main" {
    name = var.cluster_name
    role_arn = aws_iam_role.cluster.arn
    version = var.kubernetes_version

    vpc_config {
        subnet_ids = concat(
            [for s in aws_subnet.public : s.id],
            [for s in aws_subnet.private : s.id]
        )
    }

    access_config {
        authentication_mode = "API"
    }

    depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}
