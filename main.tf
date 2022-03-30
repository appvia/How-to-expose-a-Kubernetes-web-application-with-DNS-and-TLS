provider "aws" {
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

module "eks" {
  source           = "terraform-aws-modules/eks/aws"
  cluster_name     = "appvia-dns-tls-demo"
  version          = "15.0.0"
  cluster_version  = "1.19"
  subnets          = data.aws_subnet_ids.default.ids
  write_kubeconfig = true
  vpc_id           = data.aws_vpc.default.id
  enable_irsa      = true

  workers_group_defaults = {
    root_volume_type = "gp2"
  }

  worker_groups = [
    {
      name                 = "worker-group"
      instance_type        = "t3a.small"
      asg_desired_capacity = 3
    }
  ]
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}
