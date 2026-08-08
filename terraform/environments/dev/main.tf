terraform {
	required_version = ">=1.7.0"

	required_providers {
		aws = {
			source = "hashicorp/aws"
			version = "~>5.0"
		}
	}

	backend "s3" {
		bucket		 = "mlops-platform-tf-state-20260808"
		key			 = "eks/dev/terraform.tfstate"
		region		 = "ap-southeast-2"
		dynamodb_table = "mlops-platform-tf-state-lock-20260808"
		encrypt		 = true
	}
}

provider "aws" {
	region = "ap-southeast-2"
}

module "eks_platform" {
	source = "../../modules/eks-platform"
	cluster_name = "mlops-eks-dev"
}