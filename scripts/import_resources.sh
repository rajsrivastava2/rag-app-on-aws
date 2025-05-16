#!/bin/bash

# Get project variables
if [ "$#" -ge 1 ]; then
  PROJECT_NAME=$1
else
  # Try to get from terraform.tfvars
  PROJECT_NAME=$(grep project_name terraform.tfvars 2>/dev/null | cut -d '=' -f2 | tr -d ' "')
fi

if [ "$#" -ge 2 ]; then
  STAGE=$2
else
  # Try to get from terraform.tfvars
  STAGE=$(grep stage terraform.tfvars 2>/dev/null | cut -d '=' -f2 | tr -d ' "')
fi

if [ "$#" -ge 3 ]; then
  REGION=$3
else
  # Try to get from terraform.tfvars
  REGION=$(grep aws_region terraform.tfvars 2>/dev/null | cut -d '=' -f2 | tr -d ' "')
fi

# Set default values if not found
PROJECT_NAME=${PROJECT_NAME}
STAGE=${STAGE}
REGION=${REGION}

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "Starting resource import process for ${PROJECT_NAME}-${STAGE}..."

# Function to check if resource is already in state
function check_state() {
  terraform state list | grep -q "$1"
  return $?
}

# ----------------------------------------
# VPC Resources
# ----------------------------------------

VPC_NAME="${PROJECT_NAME}-${STAGE}-vpc"

echo -e "${YELLOW}Checking VPC: ${VPC_NAME}${NC}"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${VPC_NAME}" --query "Vpcs[0].VpcId" --output text --region "${REGION}" 2>/dev/null)

if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  echo -e "${GREEN}VPC exists (${VPC_ID}), checking state...${NC}"
  
  if check_state "module.vpc.aws_vpc.main"; then
    echo -e "${GREEN}VPC already in state.${NC}"
  else
    echo -e "${YELLOW}Importing VPC...${NC}"
    terraform import "module.vpc.aws_vpc.main" "${VPC_ID}"
    
    # You may need to import subnets, route tables, etc.
    echo -e "${YELLOW}Note: Subnets, route tables, and other VPC resources may need manual import${NC}"
  fi
else
  echo -e "${YELLOW}VPC doesn't exist, will be created by Terraform${NC}"
fi

# ----------------------------------------
# Import VPC Endpoints if they exist
# ----------------------------------------

echo -e "${YELLOW}Checking VPC Endpoints...${NC}"
S3_ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${REGION}.s3" --query "VpcEndpoints[0].VpcEndpointId" --output text --region "${REGION}" 2>/dev/null)

if [ "$S3_ENDPOINT_ID" != "None" ] && [ -n "$S3_ENDPOINT_ID" ]; then
  echo -e "${GREEN}S3 VPC Endpoint exists (${S3_ENDPOINT_ID}), checking state...${NC}"
  
  if check_state "module.vpc.aws_vpc_endpoint.s3"; then
    echo -e "${GREEN}S3 VPC Endpoint already in state.${NC}"
  else
    echo -e "${YELLOW}Importing S3 VPC Endpoint...${NC}"
    terraform import "module.vpc.aws_vpc_endpoint.s3" "${S3_ENDPOINT_ID}"
  fi
else
  echo -e "${YELLOW}S3 VPC Endpoint doesn't exist, will be created by Terraform${NC}"
fi

# ----------------------------------------
# Import DynamoDB Endpoints if they exist
# ----------------------------------------

DYNAMODB_ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${REGION}.dynamodb" --query "VpcEndpoints[0].VpcEndpointId" --output text --region "${REGION}" 2>/dev/null)

if [ "$DYNAMODB_ENDPOINT_ID" != "None" ] && [ -n "$DYNAMODB_ENDPOINT_ID" ]; then
  echo -e "${GREEN}DynamoDB VPC Endpoint exists (${DYNAMODB_ENDPOINT_ID}), checking state...${NC}"
  
  if check_state "module.vpc.aws_vpc_endpoint.dynamodb"; then
    echo -e "${GREEN}DynamoDB VPC Endpoint already in state.${NC}"
  else
    echo -e "${YELLOW}Importing DynamoDB VPC Endpoint...${NC}"
    terraform import "module.vpc.aws_vpc_endpoint.dynamodb" "${DYNAMODB_ENDPOINT_ID}"
  fi
else
  echo -e "${YELLOW}DynamoDB VPC Endpoint doesn't exist, will be created by Terraform${NC}"
fi

# ----------------------------------------
# Security Groups
# ----------------------------------------
SECURITY_GROUPS=(
  "bastion:module.vpc.aws_security_group.bastion[0]"
  "lambda:module.vpc.aws_security_group.lambda"
  "db:module.vpc.aws_security_group.database"
)

for SG_ITEM in "${SECURITY_GROUPS[@]}"; do
  SG_NAME=$(echo $SG_ITEM | cut -d':' -f1)
  SG_STATE=$(echo $SG_ITEM | cut -d':' -f2)
  SG_FULL_NAME="${PROJECT_NAME}-${STAGE}-${SG_NAME}-sg"

  echo -e "${YELLOW}Checking Security Group: ${SG_FULL_NAME}${NC}"
  SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_FULL_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[0].GroupId" --output text --region "${REGION}" 2>/dev/null)

  if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
    echo -e "${GREEN}Security group exists (${SG_ID}), checking state...${NC}"
    if check_state "${SG_STATE}"; then
      echo -e "${GREEN}Security group already in Terraform state.${NC}"
    else
      echo -e "${YELLOW}Importing security group...${NC}"
      terraform import "${SG_STATE}" "${SG_ID}"
    fi
  else
    echo -e "${YELLOW}Security group ${SG_FULL_NAME} doesn't exist, will be created by Terraform${NC}"
  fi
done

# ----------------------------------------
# S3 Bucket
# ----------------------------------------
BUCKET_NAME="${PROJECT_NAME}-${STAGE}-documents"

echo -e "${YELLOW}Checking S3 bucket: ${BUCKET_NAME}${NC}"
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo -e "${GREEN}Bucket exists, checking state...${NC}"
  
  if check_state "module.storage.aws_s3_bucket.documents"; then
    echo -e "${GREEN}Bucket already in state.${NC}"
  else
    echo -e "${YELLOW}Importing bucket...${NC}"
    terraform import "module.storage.aws_s3_bucket.documents" "${BUCKET_NAME}"
    
    # Import related configurations
    echo -e "${YELLOW}Importing bucket encryption configuration...${NC}"
    terraform import "module.storage.aws_s3_bucket_server_side_encryption_configuration.documents" "${BUCKET_NAME}"
    
    echo -e "${YELLOW}Importing bucket CORS configuration...${NC}"
    terraform import "module.storage.aws_s3_bucket_cors_configuration.documents" "${BUCKET_NAME}"
    
    echo -e "${YELLOW}Importing bucket public access block configuration...${NC}"
    terraform import "module.storage.aws_s3_bucket_public_access_block.documents" "${BUCKET_NAME}"
    
    # Import lifecycle configuration if exists
    if aws s3api get-bucket-lifecycle-configuration --bucket "${BUCKET_NAME}" 2>/dev/null; then
      echo -e "${YELLOW}Importing bucket lifecycle configuration...${NC}"
      terraform import "module.storage.aws_s3_bucket_lifecycle_configuration.documents" "${BUCKET_NAME}"
    fi
  fi
else
  echo -e "${YELLOW}Bucket doesn't exist, will be created by Terraform${NC}"
fi

# ----------------------------------------
# DynamoDB Table
# ----------------------------------------
TABLE_NAME="${PROJECT_NAME}-${STAGE}-metadata"

echo -e "${YELLOW}Checking DynamoDB table: ${TABLE_NAME}${NC}"
if aws dynamodb describe-table --table-name "${TABLE_NAME}" --region "${REGION}" 2>/dev/null; then
  echo -e "${GREEN}Table exists, checking state...${NC}"
  
  if check_state "module.storage.aws_dynamodb_table.metadata"; then
    echo -e "${GREEN}Table already in state.${NC}"
  else
    echo -e "${YELLOW}Importing table...${NC}"
    terraform import "module.storage.aws_dynamodb_table.metadata" "${TABLE_NAME}"
  fi
else
  echo -e "${YELLOW}Table doesn't exist, will be created by Terraform${NC}"
fi

# ----------------------------------------
# RDS DB Parameter Group - Safe Import Handling
# ----------------------------------------
DB_IDENTIFIER="${PROJECT_NAME}-${STAGE}-postgres"
DB_PARAMETER_GROUP="${PROJECT_NAME}-${STAGE}-postgres-params"

echo -e "${YELLOW}Checking DB Parameter Group: ${DB_PARAMETER_GROUP}${NC}"
if aws rds describe-db-parameter-groups --db-parameter-group-name "${DB_PARAMETER_GROUP}" --region "${REGION}" 2>/dev/null; then
  echo -e "${GREEN}DB Parameter Group exists. Checking if it's in use...${NC}"

  # Check if any DB instances are using this parameter group
  USING_INSTANCES=$(aws rds describe-db-instances \
    --region "${REGION}" \
    --query "DBInstances[?DBParameterGroups[?DBParameterGroupName=='${DB_PARAMETER_GROUP}']].DBInstanceIdentifier" \
    --output text)

  if [ -n "$USING_INSTANCES" ]; then
    echo -e "${YELLOW}Parameter group is in use by: $USING_INSTANCES${NC}"
    echo -e "${YELLOW}Importing to Terraform state only. Skipping deletion.${NC}"
  else
    echo -e "${GREEN}Parameter group exists but not in use. Still only importing.${NC}"
  fi

  # Import to Terraform state if not already imported
  if check_state "module.database.aws_db_parameter_group.postgres"; then
    echo -e "${GREEN}DB Parameter Group already in Terraform state.${NC}"
  else
    echo -e "${YELLOW}Importing DB Parameter Group into Terraform state...${NC}"
    terraform import "module.database.aws_db_parameter_group.postgres" "${DB_PARAMETER_GROUP}" || true
  fi

else
  echo -e "${YELLOW}DB Parameter Group does not exist. Terraform will create it.${NC}"
fi


# ----------------------------------------
# RDS Subnet Group
# ----------------------------------------

DB_SUBNET_GROUP="${PROJECT_NAME}-${STAGE}-db-subnet-group"

echo -e "${YELLOW}Checking RDS Subnet Group: ${DB_SUBNET_GROUP}${NC}"
if aws rds describe-db-subnet-groups --db-subnet-group-name "${DB_SUBNET_GROUP}" --region "${REGION}" 2>/dev/null; then
  echo -e "${GREEN}Subnet group exists, checking state...${NC}"
  
  if check_state "module.vpc.aws_db_subnet_group.main"; then
    echo -e "${GREEN}Subnet group already in state.${NC}"
  else
    echo -e "${YELLOW}Importing RDS subnet group...${NC}"
    terraform import "module.vpc.aws_db_subnet_group.main" "${DB_SUBNET_GROUP}"
  fi
else
  echo -e "${YELLOW}Subnet group doesn't exist, will be created by Terraform${NC}"
fi


echo -e "${YELLOW}Checking RDS instance: ${DB_IDENTIFIER}${NC}"
DB_EXISTS=$(aws rds describe-db-instances --db-instance-identifier "${DB_IDENTIFIER}" --query "DBInstances[0].DBInstanceIdentifier" --output text --region "${REGION}" 2>/dev/null)

if [ "$DB_EXISTS" == "${DB_IDENTIFIER}" ]; then
  echo -e "${GREEN}RDS instance exists (${DB_IDENTIFIER}), checking state...${NC}"
  
  # Check if already in state
  if check_state "module.database.aws_db_instance.postgres\[0\]"; then
    echo -e "${GREEN}RDS instance already in state.${NC}"
  else
    echo -e "${YELLOW}Importing RDS instance...${NC}"
    terraform import "module.database.aws_db_instance.postgres[0]" "${DB_IDENTIFIER}"
    
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}Successfully imported RDS instance into Terraform state.${NC}"
    else
      echo -e "${RED}Failed to import RDS instance.${NC}"
    fi
  fi
else
  echo -e "${YELLOW}RDS instance ${DB_IDENTIFIER} doesn't exist, will be created by Terraform.${NC}"
fi

# ----------------------------------------
# Secrets Manager
# ----------------------------------------

DB_SECRET_NAME="${PROJECT_NAME}-${STAGE}-db-credentials"

echo -e "${YELLOW}Checking Secrets Manager secret: ${DB_SECRET_NAME}${NC}"
DB_SECRET_ARN=$(aws secretsmanager list-secrets --filters "Key=name,Values=${DB_SECRET_NAME}" --query "SecretList[0].ARN" --output text --region "${REGION}" 2>/dev/null)

if [ -n "$DB_SECRET_ARN" ] && [ "$DB_SECRET_ARN" != "None" ]; then
  echo -e "${GREEN}Secret exists (${DB_SECRET_ARN}), checking state...${NC}"
  
  if check_state "module.database.aws_secretsmanager_secret.db_credentials"; then
    echo -e "${GREEN}Secret already in state.${NC}"
  else
    echo -e "${YELLOW}Importing secret...${NC}"
    terraform import "module.database.aws_secretsmanager_secret.db_credentials" "${DB_SECRET_ARN}"
    
    # Import secret version if exists
    CURRENT_VERSION=$(aws secretsmanager describe-secret --secret-id ${DB_SECRET_ARN} --query "VersionIdsToStages" --output text --region "${REGION}" | grep AWSCURRENT | awk '{print $1}')
    
    if [ -n "$CURRENT_VERSION" ]; then
      echo -e "${YELLOW}Importing secret version...${NC}"
      if check_state "module.database.aws_secretsmanager_secret_version.db_credentials"; then
        terraform state rm module.database.aws_secretsmanager_secret_version.db_credentials
      fi
      terraform import "module.database.aws_secretsmanager_secret_version.db_credentials" "${DB_SECRET_ARN}|${CURRENT_VERSION}"
    fi
  fi
else
  echo -e "${YELLOW}Secret doesn't exist, will be created by Terraform${NC}"
fi

GEMINI_SECRET_NAME="${PROJECT_NAME}-${STAGE}-gemini-api-key"

echo -e "${YELLOW}Checking Secrets Manager secret: ${GEMINI_SECRET_NAME}${NC}"
GEMINI_SECRET_ARN=$(aws secretsmanager list-secrets --filters "Key=name,Values=${GEMINI_SECRET_NAME}" --query "SecretList[0].ARN" --output text --region "${REGION}" 2>/dev/null)

if [ -n "$GEMINI_SECRET_ARN" ] && [ "$GEMINI_SECRET_ARN" != "None" ]; then
  echo -e "${GREEN}Secret exists (${GEMINI_SECRET_ARN}), checking state...${NC}"
  
  if check_state "module.compute.aws_secretsmanager_secret.gemini_api_credentials"; then
    echo -e "${GREEN}Secret already in state.${NC}"
  else
    echo -e "${YELLOW}Importing secret...${NC}"
    terraform import "module.compute.aws_secretsmanager_secret.gemini_api_credentials" "${GEMINI_SECRET_ARN}"
    
    # Import secret version if exists
    CURRENT_VERSION=$(aws secretsmanager describe-secret --secret-id ${GEMINI_SECRET_ARN} --query "VersionIdsToStages" --output text --region "${REGION}" | grep AWSCURRENT | awk '{print $1}')
    
    if [ -n "$CURRENT_VERSION" ]; then
      echo -e "${YELLOW}Importing secret version...${NC}"
      if check_state "module.compute.aws_secretsmanager_secret_version.gemini_api_credentials"; then
        terraform state rm module.compute.aws_secretsmanager_secret_version.gemini_api_credentials
      fi
      terraform import "module.compute.aws_secretsmanager_secret_version.gemini_api_credentials" "${GEMINI_SECRET_ARN}|${CURRENT_VERSION}"
    fi
  fi
else
  echo -e "${YELLOW}Secret doesn't exist, will be created by Terraform${NC}"
fi

# ----------------------------------------
# Lambda Functions
# ----------------------------------------

LAMBDA_FUNCTIONS=(
  "${PROJECT_NAME}-${STAGE}-document-processor:module.compute.aws_lambda_function.document_processor"
  "${PROJECT_NAME}-${STAGE}-query-processor:module.compute.aws_lambda_function.query_processor"
  "${PROJECT_NAME}-${STAGE}-upload-handler:module.compute.aws_lambda_function.upload_handler"
  "${PROJECT_NAME}-${STAGE}-db-init:module.compute.aws_lambda_function.db_init"
)

for LAMBDA_ITEM in "${LAMBDA_FUNCTIONS[@]}"; do
  LAMBDA_NAME=$(echo $LAMBDA_ITEM | cut -d':' -f1)
  LAMBDA_STATE=$(echo $LAMBDA_ITEM | cut -d':' -f2)
  
  echo -e "${YELLOW}Checking Lambda function: ${LAMBDA_NAME}${NC}"
  if aws lambda get-function --function-name "${LAMBDA_NAME}" --region "${REGION}" 2>/dev/null; then
    echo -e "${GREEN}Function exists, checking state...${NC}"
    
    if check_state "${LAMBDA_STATE}"; then
      echo -e "${GREEN}Function already in state.${NC}"
    else
      echo -e "${YELLOW}Importing function...${NC}"
      terraform import "${LAMBDA_STATE}" "${LAMBDA_NAME}"
    fi
  else
    echo -e "${YELLOW}Function doesn't exist, will be created by Terraform${NC}"
  fi
done

# ----------------------------------------
# IAM Role
# ----------------------------------------

ROLE_NAME="${PROJECT_NAME}-${STAGE}-lambda-role"

echo -e "${YELLOW}Checking IAM role: ${ROLE_NAME}${NC}"
if aws iam get-role --role-name "${ROLE_NAME}" 2>/dev/null; then
  echo -e "${GREEN}Role exists, checking state...${NC}"
  
  if check_state "module.compute.aws_iam_role.lambda_role"; then
    echo -e "${GREEN}Role already in state.${NC}"
  else
    echo -e "${YELLOW}Importing role...${NC}"
    terraform import "module.compute.aws_iam_role.lambda_role" "${ROLE_NAME}"
  fi
else
  echo -e "${YELLOW}Role doesn't exist, will be created by Terraform${NC}"
fi


# ----------------------------------------
# IAM Role - Flow Logs
# ----------------------------------------

FLOW_LOG_ROLE="${PROJECT_NAME}-${STAGE}-flow-logs-role"

echo -e "${YELLOW}Checking IAM role: ${FLOW_LOG_ROLE}${NC}"
if aws iam get-role --role-name "${FLOW_LOG_ROLE}" 2>/dev/null; then
  echo -e "${GREEN}Flow logs role exists, checking state...${NC}"
  
  if check_state "module.vpc.aws_iam_role.flow_logs"; then
    echo -e "${GREEN}Flow logs role already in state.${NC}"
  else
    echo -e "${YELLOW}Importing flow logs role...${NC}"
    terraform import "module.vpc.aws_iam_role.flow_logs" "${FLOW_LOG_ROLE}"
  fi
else
  echo -e "${YELLOW}Flow logs role doesn't exist, will be created by Terraform${NC}"
fi


# ----------------------------------------
# IAM Policy
# ----------------------------------------

POLICY_NAME="${PROJECT_NAME}-${STAGE}-lambda-policy"
# Get the policy ARN
POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" --output text)

if [ -n "$POLICY_ARN" ]; then
  echo -e "${GREEN}Policy exists (${POLICY_ARN}), checking state...${NC}"
  
  if check_state "module.compute.aws_iam_policy.lambda_policy"; then
    echo -e "${GREEN}Policy already in state.${NC}"
  else
    echo -e "${YELLOW}Importing policy...${NC}"
    terraform import "module.compute.aws_iam_policy.lambda_policy" "${POLICY_ARN}"
  fi
else
  echo -e "${YELLOW}Policy doesn't exist, will be created by Terraform${NC}"
fi

# ----------------------------------------
# API Gateway - Updated to handle REST API Gateway
# ----------------------------------------

API_NAME="${PROJECT_NAME}-${STAGE}-api"

# Use the AWS CLI to get the API Gateway ID for REST API
API_ID=$(aws apigateway get-rest-apis --query "items[?name=='${API_NAME}'].id" --output text --region "${REGION}" 2>/dev/null)

if [ -n "$API_ID" ]; then
  echo -e "${GREEN}REST API Gateway exists (${API_ID}), checking state...${NC}"
  
  if check_state "module.api.aws_api_gateway_rest_api.main"; then
    echo -e "${GREEN}API Gateway already in state.${NC}"
  else
    echo -e "${YELLOW}Importing API Gateway...${NC}"
    terraform import "module.api.aws_api_gateway_rest_api.main" "${API_ID}"
    
    # Try to import the stage too
    STAGE_NAME="${STAGE}"
    echo -e "${YELLOW}Importing API Gateway stage...${NC}"
    terraform import "module.api.aws_api_gateway_stage.main" "${API_ID}/${STAGE_NAME}"
    
    # Import routes and methods (these might need manual adjustment)
    echo -e "${YELLOW}Note: Resources, methods, and integrations might need manual import if plan shows differences${NC}"
  fi
else
  echo -e "${YELLOW}API Gateway doesn't exist, will be created by Terraform${NC}"
fi

# ----------------------------------------
# CloudWatch Logs
# ----------------------------------------

LOG_GROUPS=(
  "/aws/lambda/${PROJECT_NAME}-${STAGE}-document-processor:module.monitoring.aws_cloudwatch_log_group.document_processor"
  "/aws/lambda/${PROJECT_NAME}-${STAGE}-query-processor:module.monitoring.aws_cloudwatch_log_group.query_processor"
  "/aws/lambda/${PROJECT_NAME}-${STAGE}-upload-handler:module.monitoring.aws_cloudwatch_log_group.upload_handler"
  "/aws/lambda/${PROJECT_NAME}-${STAGE}-auth-handler:module.monitoring.aws_cloudwatch_log_group.auth_handler"
  "/aws/lambda/${PROJECT_NAME}-${STAGE}-db-init:module.monitoring.aws_cloudwatch_log_group.auth_handler"
  "/aws/apigateway/${PROJECT_NAME}-${STAGE}-api:module.api.aws_cloudwatch_log_group.api_gateway"
)

for LOG_ITEM in "${LOG_GROUPS[@]}"; do
  LOG_NAME=$(echo $LOG_ITEM | cut -d':' -f1)
  LOG_STATE=$(echo $LOG_ITEM | cut -d':' -f2)

  echo -e "${YELLOW}Checking CloudWatch log group: ${LOG_NAME}${NC}"
  if aws logs describe-log-groups --log-group-name "${LOG_NAME}" --region "${REGION}" --query "logGroups[0].logGroupName" --output text 2>/dev/null | grep -q "${LOG_NAME}"; then
    echo -e "${GREEN}Log group exists, checking state...${NC}"
    
    if check_state "${LOG_STATE}"; then
      echo -e "${GREEN}Log group already in state.${NC}"
    else
      echo -e "${YELLOW}Importing log group...${NC}"
      terraform import "${LOG_STATE}" "${LOG_NAME}"
    fi
  else
    echo -e "${YELLOW}Log group doesn't exist, will be created by Terraform${NC}"
  fi
done

# ----------------------------------------
# SNS Topic
# ----------------------------------------

TOPIC_NAME="${PROJECT_NAME}-${STAGE}-alerts"

# List all SNS topics and filter by name
TOPIC_ARN=$(aws sns list-topics --region "${REGION}" --query "Topics[?ends_with(TopicArn,'${TOPIC_NAME}')].TopicArn" --output text)

if [ -n "$TOPIC_ARN" ]; then
  echo -e "${GREEN}SNS Topic exists (${TOPIC_ARN}), checking state...${NC}"
  
  if check_state "module.monitoring.aws_sns_topic.alerts"; then
    echo -e "${GREEN}SNS Topic already in state.${NC}"
  else
    echo -e "${YELLOW}Importing SNS Topic...${NC}"
    terraform import "module.monitoring.aws_sns_topic.alerts" "${TOPIC_ARN}"
    
    # Import subscriptions
    echo -e "${YELLOW}Note: SNS subscriptions may need manual import${NC}"
  fi
else
  echo -e "${YELLOW}SNS Topic doesn't exist, will be created by Terraform${NC}"
fi

# Import SNS subscription for Slack if in production
if [ "$STAGE" == "prod" ]; then
  echo -e "${YELLOW}Checking for Slack subscription to SNS topic${NC}"
  
  if [ -n "$TOPIC_ARN" ]; then
    # Get subscription ARN for HTTPS protocol (Slack)
    SUBSCRIPTION_ARN=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --query "Subscriptions[?Protocol=='https'].SubscriptionArn" --output text --region "${REGION}")
    
    if [ -n "$SUBSCRIPTION_ARN" ] && [ "$SUBSCRIPTION_ARN" != "PendingConfirmation" ] && [ "$SUBSCRIPTION_ARN" != "None" ]; then
      echo -e "${GREEN}Slack subscription exists, checking state...${NC}"
      
      if check_state "module.monitoring.aws_sns_topic_subscription.slack\[0\]"; then
        echo -e "${GREEN}Slack subscription already in state.${NC}"
      else
        echo -e "${YELLOW}Importing Slack subscription...${NC}"
        terraform import "module.monitoring.aws_sns_topic_subscription.slack[0]" "${SUBSCRIPTION_ARN}"
      fi
    else
      echo -e "${YELLOW}Slack subscription doesn't exist or is pending confirmation${NC}"
    fi
  fi
fi

# ----------------------------------------
# CloudWatch Alarms
# ----------------------------------------
ALARMS=(
  "${PROJECT_NAME}-${STAGE}-document-processor-errors:module.monitoring.aws_cloudwatch_metric_alarm.document_processor_errors"
  "${PROJECT_NAME}-${STAGE}-query-processor-errors:module.monitoring.aws_cloudwatch_metric_alarm.query_processor_errors"
)

for ALARM_ITEM in "${ALARMS[@]}"; do
  ALARM_NAME=$(echo $ALARM_ITEM | cut -d':' -f1)
  ALARM_STATE=$(echo $ALARM_ITEM | cut -d':' -f2)
  
  echo -e "${YELLOW}Checking CloudWatch alarm: ${ALARM_NAME}${NC}"
  if aws cloudwatch describe-alarms --alarm-names "${ALARM_NAME}" --region "${REGION}" --query "MetricAlarms[0].AlarmName" --output text 2>/dev/null | grep -q "${ALARM_NAME}"; then
    echo -e "${GREEN}Alarm exists, checking state...${NC}"
    
    if check_state "${ALARM_STATE}"; then
      echo -e "${GREEN}Alarm already in state.${NC}"
    else
      echo -e "${YELLOW}Importing alarm...${NC}"
      terraform import "${ALARM_STATE}" "${ALARM_NAME}"
    fi
  else
    echo -e "${YELLOW}Alarm doesn't exist, will be created by Terraform${NC}"
  fi
done

# ----------------------------------------
# Lambda Code Bucket
# ----------------------------------------

LAMBDA_CODE_BUCKET="${PROJECT_NAME}-${STAGE}-lambda-code"

echo -e "${YELLOW}Checking S3 bucket: ${LAMBDA_CODE_BUCKET}${NC}"
if aws s3api head-bucket --bucket "${LAMBDA_CODE_BUCKET}" 2>/dev/null; then
  echo -e "${GREEN}Lambda code bucket exists, checking state...${NC}"
  
  if check_state "aws_s3_bucket.lambda_code"; then
    echo -e "${GREEN}Lambda code bucket already in state.${NC}"
  else
    echo -e "${YELLOW}Importing Lambda code bucket...${NC}"
    terraform import "aws_s3_bucket.lambda_code" "${LAMBDA_CODE_BUCKET}"
    
    # Import related configurations
    echo -e "${YELLOW}Importing bucket encryption configuration...${NC}"
    terraform import "aws_s3_bucket_server_side_encryption_configuration.lambda_code" "${LAMBDA_CODE_BUCKET}"
    
    echo -e "${YELLOW}Importing bucket public access block configuration...${NC}"
    terraform import "aws_s3_bucket_public_access_block.lambda_code" "${LAMBDA_CODE_BUCKET}"
    
    echo -e "${YELLOW}Importing bucket versioning configuration...${NC}"
    terraform import "aws_s3_bucket_versioning.lambda_code" "${LAMBDA_CODE_BUCKET}"
  fi
else
  echo -e "${YELLOW}Lambda code bucket doesn't exist, will be created by Terraform${NC}"
fi

# ----------------------------------------
# Cognito Resources
# ----------------------------------------

USER_POOL_NAME="${PROJECT_NAME}-${STAGE}-user-pool"
COGNITO_DOMAIN="${PROJECT_NAME}-${STAGE}-auth"
APP_CLIENT_NAME="${PROJECT_NAME}-${STAGE}-streamlit-client"

echo -e "${YELLOW}Checking Cognito User Pool: ${USER_POOL_NAME}${NC}"
USER_POOL_ID=$(aws cognito-idp list-user-pools --max-results 20 --query "UserPools[?Name=='${USER_POOL_NAME}'].Id" --output text --region "${REGION}" 2>/dev/null)

if [ -n "$USER_POOL_ID" ]; then
  echo -e "${GREEN}Cognito User Pool exists (${USER_POOL_ID}), checking state...${NC}"
  
  if check_state "module.auth.aws_cognito_user_pool.main"; then
    echo -e "${GREEN}Cognito User Pool already in state.${NC}"
  else
    echo -e "${YELLOW}Importing Cognito User Pool...${NC}"
    terraform import "module.auth.aws_cognito_user_pool.main" "${USER_POOL_ID}"
    
    # Import domain if it exists
    if aws cognito-idp describe-user-pool-domain --domain "${COGNITO_DOMAIN}" --region "${REGION}" 2>/dev/null; then
      echo -e "${YELLOW}Importing Cognito User Pool Domain...${NC}"
      terraform import "module.auth.aws_cognito_user_pool_domain.main" "${COGNITO_DOMAIN}"
    fi
    
    # Import app client if it exists
    APP_CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "${USER_POOL_ID}" --query "UserPoolClients[?ClientName=='${APP_CLIENT_NAME}'].ClientId" --output text --region "${REGION}" 2>/dev/null)
    if [ -n "$APP_CLIENT_ID" ]; then
      echo -e "${YELLOW}Importing Cognito App Client...${NC}"
      terraform import "module.auth.aws_cognito_user_pool_client.streamlit_client" "${USER_POOL_ID}/${APP_CLIENT_ID}"
    fi
  fi
else
  echo -e "${YELLOW}Cognito User Pool doesn't exist, will be created by Terraform${NC}"
fi

# ----------------------------------------
# API Gateway Auth Resources
# ----------------------------------------
echo -e "${YELLOW}Checking API Gateway Auth Resources${NC}"

if [ -n "$API_ID" ]; then
  # Check if auth resource exists
  AUTH_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "${API_ID}" --query "items[?pathPart=='auth'].id" --output text --region "${REGION}" 2>/dev/null)
  
  if [ -n "$AUTH_RESOURCE_ID" ]; then
    echo -e "${GREEN}Auth resource exists (${AUTH_RESOURCE_ID}), checking state...${NC}"
    
    if check_state "module.api.aws_api_gateway_resource.auth"; then
      echo -e "${GREEN}Auth resource already in state.${NC}"
    else
      echo -e "${YELLOW}Importing Auth resource...${NC}"
      terraform import "module.api.aws_api_gateway_resource.auth" "${API_ID}/${AUTH_RESOURCE_ID}"
      
      # Import auth method
      echo -e "${YELLOW}Importing Auth method...${NC}"
      terraform import "module.api.aws_api_gateway_method.auth" "${API_ID}/${AUTH_RESOURCE_ID}/POST"
      
      # Import auth integration
      echo -e "${YELLOW}Importing Auth integration...${NC}"
      terraform import "module.api.aws_api_gateway_integration.auth" "${API_ID}/${AUTH_RESOURCE_ID}/POST"
      
      # Import CORS method
      echo -e "${YELLOW}Importing Auth CORS method...${NC}"
      terraform import "module.api.aws_api_gateway_method.auth_options" "${API_ID}/${AUTH_RESOURCE_ID}/OPTIONS"
      
      # Import CORS integration
      echo -e "${YELLOW}Importing Auth CORS integration...${NC}"
      terraform import "module.api.aws_api_gateway_integration.auth_options" "${API_ID}/${AUTH_RESOURCE_ID}/OPTIONS"
    fi
  else
    echo -e "${YELLOW}Auth resource doesn't exist, will be created by Terraform${NC}"
  fi
  
  # Check if JWT authorizer exists
  JWT_AUTHORIZER_ID=$(aws apigateway get-authorizers --rest-api-id "${API_ID}" --query "items[?name=='${PROJECT_NAME}-${STAGE}-jwt-authorizer'].id" --output text --region "${REGION}" 2>/dev/null)
  
  if [ -n "$JWT_AUTHORIZER_ID" ]; then
    echo -e "${GREEN}JWT authorizer exists (${JWT_AUTHORIZER_ID}), checking state...${NC}"
    
    if check_state "module.api.aws_api_gateway_authorizer.jwt_authorizer"; then
      echo -e "${GREEN}JWT authorizer already in state.${NC}"
    else
      echo -e "${YELLOW}Importing JWT authorizer...${NC}"
      terraform import "module.api.aws_api_gateway_authorizer.jwt_authorizer" "${API_ID}/${JWT_AUTHORIZER_ID}"
    fi
  else
    echo -e "${YELLOW}JWT authorizer doesn't exist, will be created by Terraform${NC}"
  fi
else
  echo -e "${YELLOW}API Gateway doesn't exist, Auth resources will be created by Terraform${NC}"
fi


# ----------------------------------------
# NAT Gateway Elastic IP
# ----------------------------------------

echo -e "${YELLOW}Checking for existing NAT EIP${NC}"
NAT_EIP_ALLOC_ID=$(aws ec2 describe-addresses --query "Addresses[?Tags[?Key=='Name' && Value=='${PROJECT_NAME}-${STAGE}-nat-eip']].AllocationId" --output text --region "${REGION}" 2>/dev/null)

if [ -n "$NAT_EIP_ALLOC_ID" ]; then
  echo -e "${GREEN}EIP exists (${NAT_EIP_ALLOC_ID}), checking state...${NC}"
  
  if check_state "module.vpc.aws_eip.nat[0]"; then
    echo -e "${GREEN}EIP already in state.${NC}"
  else
    echo -e "${YELLOW}Importing EIP...${NC}"
    terraform import "module.vpc.aws_eip.nat[0]" "${NAT_EIP_ALLOC_ID}"
  fi
else
  echo -e "${YELLOW}EIP not found, will be created by Terraform${NC}"
fi


# ----------------------------------------
# Lambda Permissions for Auth Handler
# ----------------------------------------
AUTH_HANDLER_NAME="${PROJECT_NAME}-${STAGE}-auth-handler"

echo -e "${YELLOW}Checking Lambda permission for Auth Handler${NC}"
if aws lambda get-policy --function-name "${AUTH_HANDLER_NAME}" --region "${REGION}" 2>/dev/null | grep -q "AllowAPIGatewayInvokeAuth"; then
  echo -e "${GREEN}Lambda permission for Auth Handler exists, checking state...${NC}"
  
  if check_state "module.api.aws_lambda_permission.api_gateway_auth"; then
    echo -e "${GREEN}Lambda permission already in state.${NC}"
  else
    echo -e "${YELLOW}Importing Lambda permission...${NC}"
    terraform import "module.api.aws_lambda_permission.api_gateway_auth" "${AUTH_HANDLER_NAME}/AllowAPIGatewayInvokeAuth"
  fi
else
  echo -e "${YELLOW}Lambda permission for Auth Handler doesn't exist, will be created by Terraform${NC}"
fi

# ----------------------------------------
# Lambda Permissions
# ----------------------------------------
echo -e "${YELLOW}Note: Lambda permissions might need manual import if plan shows differences${NC}"

echo -e "${GREEN}Resource import process completed!${NC}"
echo -e "${YELLOW}Run 'terraform plan' to see if any differences still exist${NC}"

