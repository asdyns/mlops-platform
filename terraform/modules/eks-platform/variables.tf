variable "cluster_name" {
    description = "The name of the EKS cluster used in resource names and tags"
    type       = string
}

variable "vpc_cidr" {
    description = "The CIDR block for the VPC"
    type        = string
    default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
    description = "List of CIDR blocks for public subnets, keyed by AZs"
    type        = map(string)
    default     = {
        "ap-southeast-2a" = "10.0.1.0/24"
        "ap-southeast-2b" = "10.0.2.0/24"
    }
}

variable "private_subnet_cidrs" {
    description = "List of CIDR blocks for private subnets, keyed by AZs"
    type        = map(string)
    default     = {
        "ap-southeast-2a" = "10.0.10.0/24"
        "ap-southeast-2b" = "10.0.20.0/24"
    }
}