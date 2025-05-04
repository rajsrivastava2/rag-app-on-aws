terraform {
  backend "s3" {
    bucket         = "rag-app-on-aws-terraform-state"
    key            = "staging/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "rag-app-on-aws-staging-terraform-state-lock"
    encrypt        = true
    # Skip version validation for CI/CD environments
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}