provider "aws" {
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}


module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = "appvia-dns-tls-demo"
  cluster_version = "1.19"
  subnets         = data.aws_subnet_ids.default.ids
  write_kubeconfig = true
  vpc_id = data.aws_vpc.default.id
  enable_irsa = true

    workers_group_defaults = {
      root_volume_type = "gp2"
    }

  worker_groups = [
    {
      name                          = "worker-group"
      instance_type                 = "t3a.small"
      asg_desired_capacity          = 3
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

data "aws_iam_policy_document" "externaldns_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-dns:external-dns"]
    }

    principals {
      identifiers = [module.eks.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

data "aws_iam_policy_document" "externaldns_role" {
  statement {
    effect  = "Allow"
    actions = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/*"]
  }
  statement {
    effect  = "Allow"
    actions = ["route53:ListHostedZones", "route53:ListResourceRecordSets"]
    resources = ["*"]
  }

}

resource "aws_iam_role" "externaldns_route53" {
  assume_role_policy = data.aws_iam_policy_document.externaldns_assume.json
  name               = "externaldns_route53"
  inline_policy {
    name   = "externaldns_role"
    policy = data.aws_iam_policy_document.externaldns_role.json
  }
}

data "aws_caller_identity" "current" {}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

