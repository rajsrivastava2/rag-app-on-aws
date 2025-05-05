# RAG Infrastructure on AWS

Terraform-based Infrastructure as Code (IaC) for deploying the complete AWS infrastructure with backend codes required by the 

- [RAG UI](https://github.com/genieincodebottle/rag-app-on-aws-ui).

- [Infra Provisioning Lifecycle Flow](https://github.com/genieincodebottle/rag-app-on-aws/blob/main/images/infra_provisioning_sequence.png)

I’ll break this down in a Yt video soon, coming in a few days.

## Table of Contents

- [Overview](#overview)
- [Infrastructure Components](#infrastructure-components)
- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
- [CI/CD Pipeline](#cicd-pipeline)
- [Environment Management](#environment-management)
- [Utilities](#utilities)
- [Contributing](#contributing)
- [Related Projects](#related-projects)

## Overview

This repository contains the complete Terraform codebase for provisioning and managing the AWS infrastructure that powers the RAG (Retrieval-Augmented Generation) application. It implements infrastructure as code best practices, enabling consistent, repeatable deployments across multiple environments (dev, staging, production).

## Infrastructure Components

The following AWS resources are provisioned and managed:

1. **Networking (VPC)**
   - Custom VPC with public and private subnets
   - NAT Gateways for outbound connectivity
   - Security Groups for access control
   - VPC Endpoints for secure AWS service access

2. **Compute (Lambda)**
   - Document Processor Lambda
   - Query Processor Lambda
   - Upload Handler Lambda
   - Database Initialization Lambda
   - Authentication Handler Lambda

3. **Storage**
   - S3 buckets for document storage
   - DynamoDB tables for metadata
   - PostgreSQL RDS instance with pgvector extension

4. **API & Authentication**
   - API Gateway with REST endpoints
   - Cognito User Pools for authentication
   - JWT authorization for API endpoints

5. **Monitoring & Logging**
   - CloudWatch dashboards
   - Lambda function logs
   - SNS alerts for critical issues

## Repository Structure

```
.
├── .github/workflows/       # GitHub Actions CI/CD pipeline
├── environments/            # Environment-specific configurations
│   └── dev/                 # Development environment
│   └── staging/             # Staging environment
    └── prod/                # Prod environment
├── modules/                 # Reusable Terraform modules
│   ├── api/                 # API Gateway configuration
│   ├── auth/                # Cognito authentication
│   ├── compute/             # Lambda functions
│   ├── database/            # RDS PostgreSQL
│   ├── monitoring/          # CloudWatch resources
│   ├── storage/             # S3 and DynamoDB
│   └── vpc/                 # Network infrastructure
├── scripts/                 # Utility scripts
└── src/                     # Lambda function source code
```

To deploy the project with your own unique project name on AWS, change the project_name in environments/<stage>/terraform.tfvars.
This avoids errors from S3 bucket and ther resources name conflicts if the default name "rag-app" is already in use.

## Prerequisites

- Terraform 1.5.7 or later
- AWS CLI configured with appropriate credentials
- Python 3.11+ (for running Lambda function tests)
- GitHub account (for CI/CD pipeline)
- Required GitHub repository secrets (for CI/CD pipeline):
  - `AWS_ACCESS_KEY_ID`: Your AWS access key
  - `AWS_SECRET_ACCESS_KEY`: Your AWS secret key
  - `SONAR_TOKEN`: Your SonarQube authentication token

## Deployment

### Setting Up Required Secrets

Before you can run the CI/CD pipeline, you need to set up the following secrets in your GitHub repository:

1. **AWS Credentials**:
   - **AWS_ACCESS_KEY_ID**: Your AWS access key
   - **AWS_SECRET_ACCESS_KEY**: Your AWS secret key

   To generate AWS access keys:
   1. Log in to the AWS Management Console
   2. Navigate to IAM > Users > [Your User] > Security credentials
   3. Under "Access keys", click "Create access key"
   4. Save the Access key ID and Secret access key securely
   5. Add these values as secrets in your GitHub repository settings

   The IAM user should have sufficient permissions to create AWS resources (AdministratorAccess policy is recommended for simplicity, but you may want to use more restricted permissions in production environments).


2. **SonarQube Token**:
   - **SONAR_TOKEN**: Your SonarQube authentication token

This step is optional and only needed if you want to explore the quality gate feature. The pipeline will proceed even if it fails. You can generate the token using SonarCloud.

3. **Adding Secrets to Your Repository**:
   1. In your GitHub repository, go to Settings > Secrets and variables > Actions
   2. Click "New repository secret"
   3. Add each of the three required secrets (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, SONAR_TOKEN)

### Manual Deployment

1. Navigate to the desired environment directory:
   ```bash
   cd environments/dev
   ```

2. Initialize Terraform:
   ```bash
   terraform init
   ```

3. Plan the deployment:
   ```bash
   terraform plan -var="reset_db_password=false" -var="bastion_allowed_cidr=['0.0.0.0/0']"
   ```

4. Apply the configuration:
   ```bash
   terraform apply -var="reset_db_password=false" -var="bastion_allowed_cidr=['0.0.0.0/0']"
   ```

5. Retrieve the API endpoint and other outputs:
   ```bash
   terraform output api_endpoint
   terraform output cognito_app_client_id
   ```

### Automated Deployment

The repository includes a GitHub Actions workflow that automatically deploys when code is pushed to the main branch:

1. Ensure all required secrets (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and SONAR_TOKEN) are configured in your GitHub repository settings.

2. Push changes to trigger deployment:
   **For Dev env**
   ```bash
   git push origin develop
   ```
   
   **For Staging/Prod env**
   ```bash
   git push origin main
   ```

3. Monitor the workflow execution in the GitHub Actions tab of your repository.

4. You can also manually trigger the workflow:
   - Go to the Actions tab in your GitHub repository
   - Select the "Terraform AWS Deployment" workflow
   - Click "Run workflow"
   - Select the environment and other parameters
   - Click "Run workflow"

## CI/CD Pipeline

The `.github/workflows/deploy.yml` file defines a comprehensive CI/CD pipeline:

1. **Determine Environment**: Selects the appropriate environment (dev/staging/prod) based on the branch or manual trigger
2. **Code Quality**: Runs SonarQube analysis on Lambda function code
3. **Build Lambda**: Packages Lambda functions with dependencies
4. **Terraform Plan**: Generates and validates a Terraform plan
5. **Terraform Apply**: Applies the Terraform configuration to create/update infrastructure
6. **Database Initialization**: Invokes the DB init Lambda to set up pgvector extension
7. **Integration Tests**: Verifies end-to-end functionality

## Environment Management

The repository supports multiple deployment environments:

- **Development (dev)**: Used for development and testing
- **Staging**: Pre-production environment for validation
- **Production (prod)**: Live production environment

Each environment has its own configuration in the `environments/` directory.

## Utilities

The `scripts/` directory contains utility scripts:

- **cleanup.sh**: Safely removes all AWS resources when needed
- **import_resources.sh**: Imports existing resources into Terraform state
- **network-diagnostics.sh**: Troubleshoots VPC and connectivity issues

## Uninstallation

To remove all AWS resources provisioned by this project, a cleanup script is provided:

1. Navigate to the scripts directory:
   ```bash
   cd scripts
   chmod +x cleanup.sh
   ./cleanup.sh
   ```
   
## Related Projects

- [RAG UI](https://github.com/genieincodebottle/rag-app-on-aws-ui): The Streamlit web application that uses this infrastructure

## Contributing

Contributions to this project are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

**Note**: Make sure you have appropriate AWS permissions before attempting to deploy this infrastructure. The Terraform code will create resources that may incur minimal costs in your AWS account. Always review the Terraform plan output before applying changes to understand what resources will be created and potential costs.

Never commit AWS access keys or other sensitive credentials directly to your repository. Always use GitHub secrets or other secure methods to manage credentials.