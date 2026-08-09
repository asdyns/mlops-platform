resource "aws_eks_node_group" "main" {
    cluster_name = aws_eks_cluster.main.name
    node_group_name = "${var.cluster_name}-node-group"
    node_role_arn = aws_iam_role.node.arn
    subnet_ids = [for s in aws_subnet.private : s.id]

    capacity_type = "SPOT"
    instance_types = ["t2.medium", "t3.medium", "t3a.medium"]

    scaling_config {
        min_size = 1
        max_size = 2
        desired_size = 2
    }

    launch_template {
        id = aws_launch_template.node.id
        version = aws_launch_template.node.latest_version
    }

    depends_on = [
        aws_iam_role_policy_attachment.node_worker_policy,
        aws_iam_role_policy_attachment.node_cni_policy,
        aws_iam_role_policy_attachment.node_ecr_policy
    ]
}

resource "aws_launch_template" "node" {
    name_prefix = "${var.cluster_name}-node-"

    tag_specifications {
        resource_type = "instance"
        tags = {
            Name = "${var.cluster_name}-node"
        }
    }
}
