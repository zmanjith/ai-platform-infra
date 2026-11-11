variable "github_org" {
  description = "GitHub username or organisation"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "github_branch" {
  description = "Branch allowed to assume the role"
  type        = string
  default     = "feature1"
}

variable "role_name" {
  description = "IAM role name for GitHub Actions"
  type        = string
}

variable "github_subject" {
  description = "Exact GitHub OIDC subject allowed to assume the role"
  type        = string
}