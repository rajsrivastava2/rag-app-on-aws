provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.stage
      ManagedBy   = "Terraform"
      Application = "RAG App on AWS"
      CreatedAt   = formatdate("YYYY-MM-DD", timestamp())
    }
  }
}

# Required provider versions for better stability
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  required_version = ">= 1.5.0"
}