module "networking" {
  source = "./modules/networking"

  project_name = var.project_name
  vpc_cidr     = "10.0.0.0/16"
}
data "aws_caller_identity" "current" {}

module "github_oidc" {
  source = "./modules/github-oidc"

  github_org    = "zmanjith"
  github_repo   = "ai-platform"
  github_branch = "feature1"

  github_subject = "repo:zmanjith@42224522/ai-platform@1452414594:ref:refs/heads/feature1"

  role_name = "github-actions-ai-platform"
}

module "ecr" {
  source = "./modules/ecr"

  project_name            = var.project_name
  github_actions_role_arn = module.github_oidc.github_actions_role_arn
}

#EKS cluster module

module "eks" {
  source = "./modules/eks"

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

module "alb_controller" {
  source = "./modules/alb-controller"

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = local.eks_oidc_provider_arn
  oidc_issuer       = module.eks.oidc_issuer
}