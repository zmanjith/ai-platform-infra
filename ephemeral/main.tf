data "aws_caller_identity" "current" {}

module "networking" {
  source = "../modules/networking"

  project_name = var.project_name
  vpc_cidr     = "10.0.0.0/16"
}

module "eks" {
  source = "../modules/eks"

  project_name       = var.project_name
  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version

  public_subnet_ids = module.networking.public_subnet_ids

  all_subnet_ids = concat(
    module.networking.public_subnet_ids,
    module.networking.private_subnet_ids
  )

  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
}

locals {
  eks_oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(module.eks.oidc_issuer, "https://", "")}"
}


