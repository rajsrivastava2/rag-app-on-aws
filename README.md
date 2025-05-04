# End-to-End RAG App On AWS

A Retrieval-Augmented Generation (RAG) application implemented on AWS using serverless architecture.

## Overview

This project implements a complete RAG system deployed on AWS that allows users to:

1. Upload documents (PDF, TXT, CSV)
2. Process and extract text from documents 
3. Create vector embeddings for document chunks
4. Store embeddings in PostgreSQL with pgvector
5. Query documents using natural language
6. Get AI-generated responses based on retrieved document content

The application architecture follows best practices for AWS deployment including infrastructure as code (Terraform), CI/CD with GitHub Actions, and multi-environment support (dev, staging, prod).

## Architecture

![RAG Architecture](https://mermaid.ink/img/)

### Key Components:

1. **Frontend Interface**: API Gateway serving REST API endpoints
2. **Document Processing Pipeline**:
   - Upload Handler Lambda: Receives documents, stores in S3
   - Document Processor Lambda: Chunks text, creates embeddings
   - Query Processor Lambda: Provides natural language query capabilities
3. **Storage**:
   - Amazon S3: Raw document storage
   - PostgreSQL RDS with pgvector: Vector embeddings and metadata
   - DynamoDB: Additional metadata and state management
4. **Networking**:
   - VPC with public/private subnets
   - NAT Gateway for Lambda internet access
   - VPC Endpoints for private AWS service access
5. **Security**:
   - IAM roles following least privilege
   - Secrets Manager for secure credential storage
   - Network security groups
6. **Monitoring**:
   - CloudWatch dashboards and alerts
   - Lambda logging
   - SNS for notifications


## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.5.0
- Python 3.11+
- Docker (optional, for local development)
- Appropriate AWS account permissions to create required resources

## Getting Started

### Initial Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/your-username/rag-app-on-aws.git
   cd rag-app-on-aws
   ```

2. Install dependencies:
   ```bash
   pip install -r requirements.txt
   pip install -r requirements-dev.txt  # for development
   ```

3. Create a Gemini API key:
   - Create a secret in AWS Secrets Manager named "rag-app-gemini-api-key" with the format:
     ```json
     {
       "api_key": "your-gemini-api-key"
     }
     ```

### Deploying with Terraform

1. Initialize Terraform in the desired environment directory:
   ```bash
   cd environments/dev  # or staging/prod
   terraform init
   ```

2. Plan deployment:
   ```bash
   terraform plan -out=tfplan
   ```

3. Apply deployment:
   ```bash
   terraform apply tfplan
   ```

### Using GitHub Actions CI/CD

The project includes a GitHub Actions workflow in `.github/workflows/deploy.yml` that handles:
- Code quality checks with SonarQube
- Building Lambda packages
- Terraform infrastructure provisioning
- Database initialization
- Integration testing

To use it:
1. Fork or clone this repository
2. Create dev/staging/prod env at GitHub Settings/Environment (Visible only when your repo is Public)
3. Configure repository secrets at diifernt env created in earlier step:
   - `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` with appropriate permissions
   - `SONAR_TOKEN` for SonarQube analysis

4. Push to the appropriate branch:
   - `develop` for dev environment
   - `main` for production environment
   - Or use manual workflow dispatch

## Usage

After deployment, you'll have an API Gateway endpoint with the following endpoints:

1. **Upload Endpoint**: 
   ```
   POST /upload
   
   {
     "file_name": "my_document.pdf",
     "file_content": "base64-encoded-file-content",
     "user_id": "user-123"
   }
   ```

2. **Query Endpoint**:
   ```
   POST /query
   
   {
     "query": "What does this document say about XYZ?",
     "user_id": "user-123"
   }
   ```

## Development

### Local Development and Testing

1. Run unit tests:
   ```bash
   python -m pytest src/tests/unit
   ```

2. Database Connectivity Test:
   ```bash
   python utils/db_connectivity_test.py --secret-arn <your-db-secret-arn>
   ```

3. Network Diagnostics:
   ```bash
   ./scripts/network-diagnostics.sh dev
   ```

### Adding New Features

1. Lambda Functions:
   - Add new functions in the `src/` directory
   - Update `modules/compute/main.tf` to provision new Lambda
   - Add appropriate IAM permissions

2. Database Extensions:
   - Modify `src/db_init/db_init.py` to add new tables/schemas
   - Run database initialization manually or trigger through CI/CD

## Environment Management

The project supports three environments:
- **dev**: For development and testing
- **staging**: Pre-production validation
- **prod**: Production environment

Each environment has its own configuration in the `environments/` directory.

## Customization Options

You can customize the deployment by modifying the appropriate `terraform.tfvars` file:

- **Infrastructure Sizing**:
  - `lambda_memory_size`: Memory allocation for Lambda functions
  - `lambda_timeout`: Timeout for Lambda executions
  - `db_instance_class`: RDS instance type
  - `db_allocated_storage`: RDS storage size

- **Network Configuration**:
  - `vpc_cidr`: VPC CIDR block
  - `az_count`: Number of Availability Zones
  - `single_nat_gateway`: Whether to use a single NAT Gateway (cost savings)

- **Storage Options**:
  - `enable_lifecycle_rules`: Enable S3 lifecycle rules
  - `standard_ia_transition_days`: Days before transitioning to IA storage
  - `glacier_transition_days`: Days before transitioning to Glacier

## Troubleshooting

### Common Issues

1. **Lambda Connectivity Issues**:
   - Check VPC configuration
   - Verify security group rules
   - Run `./scripts/network-diagnostics.sh <env>` for diagnosis

2. **Database Access Problems**:
   - Verify DB is in available state
   - Check security group ingress/egress rules
   - Verify DB credentials in Secrets Manager

3. **CI/CD Failures**:
   - Check CloudWatch logs for Lambda errors
   - Verify AWS credentials have sufficient permissions
   - Check SonarQube analysis requirements

## Cleanup Resources

To avoid unnecessary AWS charges, you can use the provided cleanup script to remove all resources created by this project:

1. Make the script executable:
   ```bash
   chmod +x cleanup.sh
   ```

2. Run for a specific environment:
   ```bash
   ./cleanup.sh dev     # For dev environment
   ./cleanup.sh staging # For staging environment
   ./cleanup.sh prod    # For production environment
   ```

3. Run in force mode (no interactive prompts):
   ```bash
   ./cleanup.sh dev true
   ```

4. Customize region or project name if needed:
   ```bash
   AWS_REGION=us-east-1 PROJECT_NAME=my-custom-name ./cleanup.sh dev
   ```

The cleanup script performs these actions:
- Empties S3 buckets (including versioned objects)
- Disables RDS deletion protection
- Cleans up Lambda permissions
- Runs `terraform destroy` for the specified environment
- Optionally removes Terraform state files and infrastructure

**Warning**: This script will permanently delete all resources and data. Make sure to backup any important information before running it.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
