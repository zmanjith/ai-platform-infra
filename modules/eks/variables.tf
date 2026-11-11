variable "project_name" {
  description = "Project name"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for worker nodes"
  type        = list(string)
}

variable "all_subnet_ids" {
  description = "Public and private subnet IDs for EKS control plane"
  type        = list(string)
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to access the EKS API endpoint"
  type        = list(string)
}