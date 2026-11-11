provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "AI-Platform"
      Environment = "Development"
      ManagedBy   = "Terraform"
    }
  }
}