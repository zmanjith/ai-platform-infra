module "github_oidc" {
  source = "../modules/github-oidc"

  github_org    = "zmanjith"
  github_repo   = "ai-platform"
  github_branch = "feature1"

  # Match the working GitHub Actions OIDC subject.
  github_subject = "repo:zmanjith@42224522/ai-platform@1452414594:ref:refs/heads/feature1"

  role_name = "github-actions-ai-platform"
}

module "ecr" {
  source = "../modules/ecr"

  project_name            = var.project_name
  github_actions_role_arn = module.github_oidc.github_actions_role_arn
}

module "alb_controller" {
  source = "../modules/alb-controller"

  cluster_name      = var.cluster_name
  oidc_provider_arn = var.oidc_provider_arn
  oidc_issuer       = var.oidc_issuer
}