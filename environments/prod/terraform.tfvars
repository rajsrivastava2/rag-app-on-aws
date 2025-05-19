# Project settings
project_name = "rag-app"
stage        = "prod"
aws_region   = "us-east-1"

# Lambda settings
lambda_memory_size = 512
lambda_timeout     = 150

# GitHub repository settings
github_repo        = "rajsrivastava2/rag-app-on-aws"
github_branch      = "main"

# Monitoring
alert_email = "rajsrivastava2@gmail.com"

# VPC settings
vpc_cidr   = "10.0.0.0/16"
az_count   = 2
# Added VPC settings
single_nat_gateway  = true   # Cost saving for dev environment. Change to true if needed in Prod
enable_flow_logs    = false  # Useful prod. Change to true if needed in Prod   
create_bastion_sg   = false  # Useful for dev environment
bastion_allowed_cidr = ["0.0.0.0/0"]  # Restrict this in production

# Storage settings
# Added storage settings
enable_lifecycle_rules      = false  # Only enable to true in prod (false here for demo purpose)
standard_ia_transition_days = 90
glacier_transition_days     = 365

# Database settings
db_instance_class     = "db.t3.micro"
db_allocated_storage  = 20
db_name               = "ragapp"
db_username           = "ragadmin"
import_db             = false
# Added database settings
reset_db_password     = false  # Only set to true when you need to reset the password
