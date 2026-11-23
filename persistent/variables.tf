variable "aws_region" {
  description = "AWS region for the AI platform"
  type        = string
  default     = "ap-southeast-2"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "ai-platform"
}

#cluster variables
variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "ai-platform-eks"
}

variable "kubernetes_version" {
  description = "Supported EKS Kubernetes version"
  type        = string
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Allowed CIDRs for EKS API access"
  type        = list(string)
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN"
  type        = string
}

variable "oidc_issuer" {
  description = "EKS OIDC issuer URL"
  type        = string
}