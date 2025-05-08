#!/bin/bash

# ============================================================
# AWS RAG Application Cleanup Script
# ============================================================
# This script thoroughly removes all AWS resources created for the RAG application
# with proper dependency handling and verification

# Set text colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Banner
echo -e "${BLUE}"
echo "============================================================"
echo "     Enhanced AWS RAG Application - Complete Cleanup Script  "
echo "============================================================"
echo -e "${NC}"

# Get project configuration
read -p "Enter your project name (default: rag-app): " PROJECT_NAME
PROJECT_NAME=${PROJECT_NAME:-rag-app}

read -p "Enter environment/stage (default: dev): " STAGE
STAGE=${STAGE:-dev}

read -p "Enter AWS region (default: us-east-1): " AWS_REGION
AWS_REGION=${AWS_REGION:-us-east-1}

# Standard prefix for resources
PREFIX="${PROJECT_NAME}-${STAGE}"

echo -e "\n${YELLOW}This script will DELETE ALL resources for:"
echo -e "  Project: ${PROJECT_NAME}"
echo -e "  Stage: ${STAGE}"
echo -e "  Region: ${AWS_REGION}${NC}"
echo -e "${RED}WARNING: This action is IRREVERSIBLE and will delete ALL data!${NC}"
read -p "Are you sure you want to proceed? (yes/no): " CONFIRMATION

if [[ $CONFIRMATION != "yes" ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo -e "\n${YELLOW}Starting cleanup process...${NC}"

# Function to check if a command exists
check_command() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${YELLOW}Warning: $1 command not found. Some functionality may be limited.${NC}"
        return 1
    fi
    return 0
}

# Check for AWS CLI
if ! check_command aws; then
    echo -e "${RED}Error: AWS CLI is required for this script.${NC}"
    exit 1
fi

# Check for jq command
if ! check_command jq; then
    echo -e "${YELLOW}Warning: jq command not found. Will use alternative methods for JSON processing.${NC}"
    USE_JQ=false
else
    USE_JQ=true
fi

# Function to run a command with error handling
run_command() {
    local cmd="$1"
    local error_msg="$2"
    local success_msg="$3"
    local ignore_error="${4:-false}"
    
    echo -e "${BLUE}Running: $cmd${NC}"
    
    # Execute the command
    eval "$cmd"
    local status=$?
    
    if [ $status -eq 0 ]; then
        if [ -n "$success_msg" ]; then
            echo -e "${GREEN}$success_msg${NC}"
        fi
        return 0
    else
        if [ "$ignore_error" = "true" ]; then
            if [ -n "$error_msg" ]; then
                echo -e "${YELLOW}$error_msg (continuing)${NC}"
            fi
            return 0
        else
            if [ -n "$error_msg" ]; then
                echo -e "${RED}$error_msg${NC}"
            fi
            return 1
        fi
    fi
}

# Function to wait with a countdown
wait_with_message() {
    local seconds="$1"
    local message="$2"
    
    echo -n -e "${YELLOW}$message "
    for (( i=seconds; i>=1; i-- )); do
        echo -n -e "$i... "
        sleep 1
    done
    echo -e "${NC}"
}

# Function to check if a resource exists and return an identifier
resource_exists() {
    local resource_type="$1"
    local identifier="$2"
    local query="$3"
    local exists=false
    local id=""
    
    case "$resource_type" in
        "lambda")
            # Check if lambda function exists
            id=$(aws lambda get-function --function-name "$identifier" --region $AWS_REGION --query "Configuration.FunctionName" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "api")
            # Check if API Gateway exists
            id=$(aws apigateway get-rest-apis --region $AWS_REGION --query "items[?name=='$identifier'].id" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "cognito")
            # Check if Cognito User Pool exists
            id=$(aws cognito-idp list-user-pools --max-results 20 --region $AWS_REGION --query "UserPools[?Name=='$identifier'].Id" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "bucket")
            # Check if S3 bucket exists
            if aws s3api head-bucket --bucket "$identifier" --region $AWS_REGION 2>/dev/null; then
                echo "$identifier"
                return 0
            else
                return 1
            fi
            ;;
        "table")
            # Check if DynamoDB table exists
            id=$(aws dynamodb describe-table --table-name "$identifier" --region $AWS_REGION --query "Table.TableName" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "rds")
            # Check if RDS instance exists
            id=$(aws rds describe-db-instances --db-instance-identifier "$identifier" --region $AWS_REGION --query "DBInstances[0].DBInstanceIdentifier" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "vpc")
            # Check if VPC exists
            id=$(aws ec2 describe-vpcs --region $AWS_REGION --filters "$query" --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "secret")
            # Check if Secret exists
            id=$(aws secretsmanager describe-secret --secret-id "$identifier" --region $AWS_REGION --query "ARN" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "log-group")
            # Check if CloudWatch Log Group exists
            id=$(aws logs describe-log-groups --log-group-name-prefix "$identifier" --region $AWS_REGION --query "logGroups[0].logGroupName" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        *)
            echo "Unknown resource type: $resource_type"
            ;;
    esac
    
    if [ "$exists" = true ]; then
        #echo "$id"
        return 0
    else
        return 1
    fi
}

echo -e "\n${YELLOW}Step 1: Clear any Terraform state locks${NC}"
DYNAMODB_TABLE="${PREFIX}-terraform-state-lock"

# Check if the DynamoDB table exists
if table_id=$(resource_exists "table" "$DYNAMODB_TABLE"); then
    echo "Terraform state lock table exists: $table_id"
    
    # Scan for any locks
    if [ $USE_JQ = true ]; then
        # Use jq for processing if available
        locks=$(aws dynamodb scan --table-name $DYNAMODB_TABLE --region $AWS_REGION --output json | jq -r '.Items[] | select(.LockID.S | contains("terraform-")) | .LockID.S' 2>/dev/null || echo "")
    else
        # Fallback method without jq
        locks=$(aws dynamodb scan --table-name $DYNAMODB_TABLE --region $AWS_REGION --output text | grep -o 'LockID.*terraform-[^ ]*' | awk '{print $2}' || echo "")
    fi
    
    if [ -n "$locks" ]; then
        echo -e "${YELLOW}Found Terraform state locks. Clearing...${NC}"
        for lock in $locks; do
            run_command "aws dynamodb delete-item --table-name $DYNAMODB_TABLE --key '{\"LockID\":{\"S\":\"$lock\"}}' --region $AWS_REGION" \
                "Failed to remove lock: $lock" \
                "Successfully removed lock: $lock" \
                "true"
        done
    else
        echo "No Terraform state locks found."
    fi
else
    echo "Terraform state lock table does not exist or cannot be accessed."
fi

echo -e "\n${YELLOW}Step 2: Disable CloudFormation stack deletion protection${NC}"
# List stacks with the project name and disable deletion protection if enabled
stacks=$(aws cloudformation list-stacks --region $AWS_REGION --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query "StackSummaries[?contains(StackName, '${PREFIX}')].StackName" --output text)

if [ -n "$stacks" ]; then
    echo "Found CloudFormation stacks potentially related to this project:"
    for stack in $stacks; do
        echo "Checking stack: $stack"
        protection=$(aws cloudformation describe-stacks --stack-name $stack --region $AWS_REGION --query "Stacks[0].EnableTerminationProtection" --output text 2>/dev/null || echo "false")
        
        if [ "$protection" = "true" ]; then
            echo -e "${YELLOW}Stack $stack has termination protection enabled. Disabling...${NC}"
            run_command "aws cloudformation update-termination-protection --stack-name $stack --no-enable-termination-protection --region $AWS_REGION" \
                "Failed to disable termination protection for stack: $stack" \
                "Successfully disabled termination protection for stack: $stack" \
                "true"
        else
            echo "Stack $stack does not have termination protection enabled."
        fi
    done
else
    echo "No CloudFormation stacks found for this project."
fi

echo -e "\n${YELLOW}Step 3: Remove all API Gateway resources${NC}"
api_name="${PREFIX}-api"
api_id=$(resource_exists "api" "$api_name")

if [ -n "$api_id" ]; then
    echo "Found API Gateway: $api_id"
    
    # First find and delete all custom domain name mappings for this API
    echo "Checking for custom domain name mappings..."
    domains=$(aws apigateway get-domain-names --region $AWS_REGION --query "items[].domainName" --output text)
    
    for domain in $domains; do
        mappings=$(aws apigateway get-base-path-mappings --domain-name $domain --region $AWS_REGION --query "items[?restApiId=='$api_id'].basePath" --output text 2>/dev/null || echo "")
        
        if [ -n "$mappings" ]; then
            echo -e "${YELLOW}Found domain mapping for API: $domain${NC}"
            for mapping in $mappings; do
                # Handle (none) base path special case
                if [ "$mapping" = "(none)" ]; then
                    mapping=""
                fi
                
                run_command "aws apigateway delete-base-path-mapping --domain-name $domain --base-path \"$mapping\" --region $AWS_REGION" \
                    "Failed to delete base path mapping for domain: $domain, path: $mapping" \
                    "Successfully deleted base path mapping for domain: $domain, path: $mapping" \
                    "true"
            done
        fi
    done
    
    # Then delete the API itself
    run_command "aws apigateway delete-rest-api --rest-api-id $api_id --region $AWS_REGION" \
        "Failed to delete API Gateway: $api_id" \
        "Successfully deleted API Gateway: $api_id"
else
    echo "No API Gateway found with name: $api_name"
fi

echo -e "\n${YELLOW}Step 4: Clear Cognito User Pool${NC}"
user_pool_name="${PREFIX}-user-pool"
user_pool_id=$(resource_exists "cognito" "$user_pool_name")

if [ -n "$user_pool_id" ]; then
    echo "Found Cognito User Pool: $user_pool_id"
    
    # 1. Delete domain first (if exists)
    domain="${PROJECT_NAME}-${STAGE}-auth"
    domain_exists=$(aws cognito-idp describe-user-pool-domain --domain $domain --region $AWS_REGION --query "DomainDescription.Domain" --output text 2>/dev/null || echo "")
    
    if [ -n "$domain_exists" ] && [ "$domain_exists" != "None" ]; then
        echo "Deleting Cognito Domain: $domain"
        run_command "aws cognito-idp delete-user-pool-domain --domain $domain --user-pool-id $user_pool_id --region $AWS_REGION" \
            "Failed to delete Cognito domain: $domain" \
            "Successfully deleted Cognito domain: $domain" \
            "true"
    fi
    
    # 2. Delete app clients
    echo "Finding and deleting User Pool App Clients..."
    client_ids=$(aws cognito-idp list-user-pool-clients --user-pool-id $user_pool_id --region $AWS_REGION --query "UserPoolClients[].ClientId" --output text)
    
    for client_id in $client_ids; do
        if [ -n "$client_id" ]; then
            echo "Deleting App Client: $client_id"
            run_command "aws cognito-idp delete-user-pool-client --user-pool-id $user_pool_id --client-id $client_id --region $AWS_REGION" \
                "Failed to delete Cognito app client: $client_id" \
                "Successfully deleted Cognito app client: $client_id" \
                "true"
        fi
    done
    
    # 3. Delete identity providers if any
    echo "Finding and deleting Identity Providers..."
    providers=$(aws cognito-idp list-identity-providers --user-pool-id $user_pool_id --region $AWS_REGION --query "Providers[].ProviderName" --output text 2>/dev/null || echo "")
    
    for provider in $providers; do
        if [ -n "$provider" ] && [ "$provider" != "COGNITO" ]; then
            echo "Deleting Identity Provider: $provider"
            run_command "aws cognito-idp delete-identity-provider --user-pool-id $user_pool_id --provider-name $provider --region $AWS_REGION" \
                "Failed to delete identity provider: $provider" \
                "Successfully deleted identity provider: $provider" \
                "true"
        fi
    done
    
    # 4. Delete resource servers if any
    echo "Finding and deleting Resource Servers..."
    resource_servers=$(aws cognito-idp list-resource-servers --user-pool-id $user_pool_id --region $AWS_REGION --query "ResourceServers[].Identifier" --output text 2>/dev/null || echo "")
    
    for resource_server in $resource_servers; do
        if [ -n "$resource_server" ]; then
            echo "Deleting Resource Server: $resource_server"
            run_command "aws cognito-idp delete-resource-server --user-pool-id $user_pool_id --identifier $resource_server --region $AWS_REGION" \
                "Failed to delete resource server: $resource_server" \
                "Successfully deleted resource server: $resource_server" \
                "true"
        fi
    done
    
    # 5. Delete user pool
    echo "Deleting User Pool: $user_pool_id"
    run_command "aws cognito-idp delete-user-pool --user-pool-id $user_pool_id --region $AWS_REGION" \
        "Failed to delete Cognito User Pool: $user_pool_id" \
        "Successfully deleted Cognito User Pool: $user_pool_id"
else
    echo "No Cognito User Pool found with name: $user_pool_name"
fi

echo -e "\n${YELLOW}Step 5: Remove all Lambda functions and layers${NC}"
# List of Lambda functions to delete
LAMBDA_FUNCTIONS=(
    "${PREFIX}-auth-handler"
    "${PREFIX}-document-processor"
    "${PREFIX}-query-processor"
    "${PREFIX}-upload-handler"
    "${PREFIX}-db-init"
)

for func in "${LAMBDA_FUNCTIONS[@]}"; do
    if function_name=$(resource_exists "lambda" "$func"); then
        echo "Found Lambda function: $function_name"
        
        # 1. First remove event source mappings
        echo "Checking for event source mappings..."
        mappings=$(aws lambda list-event-source-mappings --function-name $function_name --region $AWS_REGION --query "EventSourceMappings[].UUID" --output text 2>/dev/null || echo "")
        
        for mapping in $mappings; do
            if [ -n "$mapping" ]; then
                echo "Deleting event source mapping: $mapping"
                run_command "aws lambda delete-event-source-mapping --uuid $mapping --region $AWS_REGION" \
                    "Failed to delete event source mapping: $mapping" \
                    "Successfully deleted event source mapping: $mapping" \
                    "true"
            fi
        done
        
        # 2. Remove function-url configurations if any
        echo "Checking for function URL configurations..."
        has_url=$(aws lambda get-function-url-config --function-name $function_name --region $AWS_REGION 2>/dev/null && echo "true" || echo "false")
        
        if [ "$has_url" = "true" ]; then
            echo "Deleting function URL configuration for $function_name"
            run_command "aws lambda delete-function-url-config --function-name $function_name --region $AWS_REGION" \
                "Failed to delete function URL for: $function_name" \
                "Successfully deleted function URL for: $function_name" \
                "true"
        fi
        
        # 3. Remove function concurrency if any
        echo "Checking for function concurrency settings..."
        concurrency=$(aws lambda get-function-concurrency --function-name $function_name --region $AWS_REGION --query "ReservedConcurrentExecutions" --output text 2>/dev/null || echo "")
        
        if [ -n "$concurrency" ] && [ "$concurrency" != "None" ]; then
            echo "Removing concurrency settings for $function_name"
            run_command "aws lambda delete-function-concurrency --function-name $function_name --region $AWS_REGION" \
                "Failed to delete function concurrency for: $function_name" \
                "Successfully deleted function concurrency for: $function_name" \
                "true"
        fi
        
        # 4. Delete the function
        echo "Deleting Lambda function: $function_name"
        run_command "aws lambda delete-function --function-name $function_name --region $AWS_REGION" \
            "Failed to delete Lambda function: $function_name" \
            "Successfully deleted Lambda function: $function_name"
    else
        echo "Lambda function not found: $func"
    fi
done

# Find and delete any Lambda layers with the project prefix
echo "Finding Lambda layers with prefix: ${PREFIX}"
layer_versions=$(aws lambda list-layers --region $AWS_REGION --query "Layers[?starts_with(LayerName, '${PREFIX}')].{Name:LayerName,Arn:LatestMatchingVersion.LayerVersionArn}" --output json 2>/dev/null)

if [ -n "$layer_versions" ] && [ "$layer_versions" != "[]" ]; then
    if [ $USE_JQ = true ]; then
        # Process with jq if available
        layer_names=$(echo $layer_versions | jq -r '.[].Name')
        for layer_name in $layer_names; do
            echo "Found Lambda layer: $layer_name, retrieving versions..."
            versions=$(aws lambda list-layer-versions --layer-name $layer_name --region $AWS_REGION --query "LayerVersions[].Version" --output text)
            
            for version in $versions; do
                echo "Deleting Lambda layer: $layer_name version $version"
                run_command "aws lambda delete-layer-version --layer-name $layer_name --version-number $version --region $AWS_REGION" \
                    "Failed to delete Lambda layer: $layer_name version $version" \
                    "Successfully deleted Lambda layer: $layer_name version $version" \
                    "true"
            done
        done
    else
        # Simple grep method if jq not available
        echo "Found Lambda layers with prefix ${PREFIX}, but jq is not available for processing."
        echo "Please check and delete Lambda layers manually if needed."
    fi
else
    echo "No Lambda layers found with prefix: ${PREFIX}"
fi

echo -e "\n${YELLOW}Step 6: Delete CloudWatch Log Groups${NC}"
# Delete log groups for Lambda functions
for func in "${LAMBDA_FUNCTIONS[@]}"; do
    log_group="/aws/lambda/$func"
    log_group_name=$(resource_exists "log-group" "$log_group")
    echo $log_group_name
    if [ $? -eq 0 ]; then
        echo "Found Log Group: $log_group_name"
        run_command "aws logs delete-log-group --log-group-name \"$log_group_name\" --region $AWS_REGION" \
            "Failed to delete Log Group: $log_group_name" \
            "Successfully deleted Log Group: $log_group_name"
    else
        echo "Log Group not found: $log_group"
    fi
done

# Delete API Gateway log group
api_log_group="/aws/apigateway/${PREFIX}-api"
log_group_name=$(resource_exists "log-group" "$api_log_group")
echo $log_group_name
if [ $? -eq 0 ]; then
    echo "Found API Gateway Log Group: $log_group_name"
    run_command "aws logs delete-log-group --log-group-name \"$log_group_name\" --region $AWS_REGION" \
        "Failed to delete API Gateway Log Group: $log_group_name" \
        "Successfully deleted API Gateway Log Group: $log_group_name"
else
    echo "API Gateway Log Group not found: $api_log_group"
fi

# Delete VPC flow logs group if it exists
vpc_flow_log_group="/aws/vpc/flowlogs/${PREFIX}"
log_group_name=$(resource_exists "log-group" "$vpc_flow_log_group")
if [ $? -eq 0 ]; then
    echo "Found VPC Flow Log Group: $log_group_name"
    run_command "aws logs delete-log-group --log-group-name \"$log_group_name\" --region $AWS_REGION" \
        "Failed to delete VPC Flow Log Group: $log_group_name" \
        "Successfully deleted VPC Flow Log Group: $log_group_name"
else
    echo "VPC Flow Log Group not found: $vpc_flow_log_group"
fi

echo -e "\n${YELLOW}Step 7: Delete Secrets Manager secrets${NC}"
SECRETS=(
    "${PREFIX}-db-credentials"
    "${PREFIX}-gemini-api-key"
)

for secret in "${SECRETS[@]}"; do
    if secret_arn=$(resource_exists "secret" "$secret"); then
        echo "Found secret: $secret"
        run_command "aws secretsmanager delete-secret --secret-id \"$secret\" --force-delete-without-recovery --region $AWS_REGION" \
            "Failed to delete secret: $secret" \
            "Successfully deleted secret: $secret"
    else
        echo "Secret not found: $secret"
    fi
done

echo -e "\n${YELLOW}Step 8: Delete SNS topics${NC}"
# Find and delete SNS topics with the project name
topics=$(aws sns list-topics --region $AWS_REGION --query "Topics[?contains(TopicArn, '${PREFIX}')].TopicArn" --output text)

if [ -n "$topics" ]; then
    for topic_arn in $topics; do
        echo "Found SNS topic: $topic_arn"
        
        # Delete all subscriptions first
        echo "Finding and deleting topic subscriptions..."
        subscriptions=$(aws sns list-subscriptions-by-topic --topic-arn $topic_arn --region $AWS_REGION --query "Subscriptions[].SubscriptionArn" --output text)
        
        for sub_arn in $subscriptions; do
            if [ "$sub_arn" != "PendingConfirmation" ]; then
                echo "Deleting subscription: $sub_arn"
                run_command "aws sns unsubscribe --subscription-arn $sub_arn --region $AWS_REGION" \
                    "Failed to delete subscription: $sub_arn" \
                    "Successfully deleted subscription: $sub_arn" \
                    "true"
            fi
        done
        
        # Delete the topic itself
        run_command "aws sns delete-topic --topic-arn $topic_arn --region $AWS_REGION" \
            "Failed to delete SNS topic: $topic_arn" \
            "Successfully deleted SNS topic: $topic_arn"
    done
else
    echo "No SNS topics found with name containing: ${PREFIX}"
fi

echo -e "\n${YELLOW}Step 9: Delete CloudWatch Alarms${NC}"
# Find and delete CloudWatch alarms with the project name
alarms=$(aws cloudwatch describe-alarms --region $AWS_REGION --query "MetricAlarms[?contains(AlarmName, '${PREFIX}')].AlarmName" --output text)

if [ -n "$alarms" ]; then
    for alarm in $alarms; do
        echo "Found CloudWatch alarm: $alarm"
        run_command "aws cloudwatch delete-alarms --alarm-names \"$alarm\" --region $AWS_REGION" \
            "Failed to delete CloudWatch alarm: $alarm" \
            "Successfully deleted CloudWatch alarm: $alarm"
    done
else
    echo "No CloudWatch alarms found with name containing: ${PREFIX}"
fi

echo -e "\n${YELLOW}Step 10: Delete RDS instances and related resources${NC}"
DB_INSTANCE="${PREFIX}-postgres"
DB_PARAM_GROUP="${PREFIX}-postgres-params"
DB_SUBNET_GROUP="${PREFIX}-db-subnet-group"

# Check if RDS instance exists
if db_instance=$(resource_exists "rds" "$DB_INSTANCE"); then
    echo "Found RDS instance: $db_instance"
    
    # 1. Disable deletion protection first if enabled
    protection=$(aws rds describe-db-instances --db-instance-identifier $db_instance --region $AWS_REGION --query "DBInstances[0].DeletionProtection" --output text)
    
    if [ "$protection" = "true" ]; then
        echo "RDS instance has deletion protection enabled. Disabling..."
        run_command "aws rds modify-db-instance --db-instance-identifier $db_instance --no-deletion-protection --apply-immediately --region $AWS_REGION" \
            "Failed to disable deletion protection for RDS instance: $db_instance" \
            "Successfully disabled deletion protection for RDS instance: $db_instance"
        
        # Wait for the modification to complete
        echo "Waiting for modification to complete..."
        run_command "aws rds wait db-instance-available --db-instance-identifier $db_instance --region $AWS_REGION" \
            "Failed to wait for RDS instance modification" \
            "RDS instance modification completed"
    fi
    
    # 2. Delete DB instance, skipping final snapshot and deleting automated backups
    echo "Deleting RDS instance: $db_instance"
    run_command "aws rds delete-db-instance --db-instance-identifier $db_instance --skip-final-snapshot --delete-automated-backups --region $AWS_REGION" \
        "Failed to delete RDS instance: $db_instance" \
        "Successfully initiated deletion of RDS instance: $db_instance"
    
    # Wait for DB instance to be deleted before continuing
    echo "Waiting for RDS instance deletion to complete (this may take several minutes)..."
    wait_with_message 60 "Waiting for RDS instance deletion (checking every 60 seconds)..."
    
    # We'll use a loop to check status with increasing wait times
    for attempt in {1..10}; do
        status=$(aws rds describe-db-instances --db-instance-identifier $db_instance --region $AWS_REGION --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null || echo "deleted")
        
        if [ "$status" = "deleted" ] || [ -z "$status" ]; then
            echo -e "${GREEN}RDS instance deletion completed.${NC}"
            break
        else
            echo "RDS instance status: $status. Waiting longer..."
            wait_time=$((30 + $attempt * 30))  # Increasing wait time with each attempt
            wait_with_message $wait_time "Still waiting for RDS deletion to complete..."
        fi
    done
fi

# Delete parameter group (regardless of whether instance was found)
if run_command "aws rds describe-db-parameter-groups --db-parameter-group-name $DB_PARAM_GROUP --region $AWS_REGION >/dev/null 2>&1" "" "" "true"; then
    echo "Found DB parameter group: $DB_PARAM_GROUP"
    run_command "aws rds delete-db-parameter-group --db-parameter-group-name $DB_PARAM_GROUP --region $AWS_REGION" \
        "Failed to delete DB parameter group: $DB_PARAM_GROUP" \
        "Successfully deleted DB parameter group: $DB_PARAM_GROUP" \
        "true"
else
    echo "DB parameter group not found: $DB_PARAM_GROUP"
fi

# Delete subnet group (regardless of whether instance was found)
if run_command "aws rds describe-db-subnet-groups --db-subnet-group-name $DB_SUBNET_GROUP --region $AWS_REGION >/dev/null 2>&1" "" "" "true"; then
    echo "Found DB subnet group: $DB_SUBNET_GROUP"
    run_command "aws rds delete-db-subnet-group --db-subnet-group-name $DB_SUBNET_GROUP --region $AWS_REGION" \
        "Failed to delete DB subnet group: $DB_SUBNET_GROUP" \
        "Successfully deleted DB subnet group: $DB_SUBNET_GROUP" \
        "true"
else
    echo "DB subnet group not found: $DB_SUBNET_GROUP"
fi

echo -e "\n${YELLOW}Step 11: Delete DynamoDB tables${NC}"
TABLES=(
    "${PREFIX}-metadata"
    "${PREFIX}-terraform-state-lock"
)

for table in "${TABLES[@]}"; do
    if table_name=$(resource_exists "table" "$table"); then
        echo "Found DynamoDB table: $table_name"
        run_command "aws dynamodb delete-table --table-name $table_name --region $AWS_REGION" \
            "Failed to delete DynamoDB table: $table_name" \
            "Successfully deleted DynamoDB table: $table_name"
    else
        echo "DynamoDB table not found: $table"
    fi
done

echo -e "\n${YELLOW}Step 12: Empty and delete S3 buckets${NC}"
BUCKETS=(
    "${PREFIX}-documents"
    "${PREFIX}-lambda-code"
    "${PROJECT_NAME}-terraform-state"
)

for bucket in "${BUCKETS[@]}"; do
    if bucket_name=$(resource_exists "bucket" "$bucket"); then
        echo "Found S3 bucket: $bucket_name"
        
        # Check if bucket versioning is enabled
        versioning=$(aws s3api get-bucket-versioning --bucket $bucket_name --region $AWS_REGION --query "Status" --output text 2>/dev/null || echo "")
        
        # Disable versioning first if enabled
        if [ "$versioning" = "Enabled" ]; then
            echo "Bucket versioning is enabled. Suspending..."
            run_command "aws s3api put-bucket-versioning --bucket $bucket_name --versioning-configuration Status=Suspended --region $AWS_REGION" \
                "Failed to suspend bucket versioning for: $bucket_name" \
                "Successfully suspended versioning for bucket: $bucket_name" \
                "true"
        fi
        
        # Special handling for terraform state bucket
        if [[ $bucket == *"terraform-state"* ]]; then
            echo "This is a terraform state bucket. Will only remove objects for stage: ${STAGE}"
            echo "Deleting objects under stage prefix: ${STAGE}/"
            run_command "aws s3 rm s3://$bucket_name/$STAGE/ --recursive --region $AWS_REGION" \
                "Failed to delete terraform state objects" \
                "Successfully deleted terraform state objects" \
                "true"
            
            # Don't delete the terraform state bucket, just move on
            echo "Skipping deletion of terraform state bucket to preserve other environments"
            continue
        fi
        
        echo "Emptying bucket: $bucket_name"
        
        # Step 1: Remove all standard objects first
        run_command "aws s3 rm s3://$bucket_name --recursive --region $AWS_REGION" \
            "Failed to delete standard objects from bucket: $bucket_name" \
            "Deleted standard objects from bucket: $bucket_name" \
            "true"
        
        # Step 2: Delete all versions and delete markers
        # Create a temporary file for processing
        TEMP_FILE=$(mktemp)
        
        echo "Retrieving object versions and delete markers..."
        run_command "aws s3api list-object-versions --bucket $bucket_name --region $AWS_REGION --output json > $TEMP_FILE" \
            "Failed to list object versions for bucket: $bucket_name" \
            "Retrieved object versions for bucket: $bucket_name" \
            "true"
        
        if [ -s "$TEMP_FILE" ]; then
            # Process versions first
            if [ $USE_JQ = true ]; then
                # Use jq for robust processing
                echo "Processing object versions with jq..."
                versions=$(jq -r '.Versions[] | "\(.Key)|\(.VersionId)"' $TEMP_FILE 2>/dev/null || echo "")
                
                for version_info in $versions; do
                    IFS='|' read -r key version_id <<< "$version_info"
                    if [ -n "$key" ] && [ -n "$version_id" ]; then
                        echo "Deleting object: $key (version $version_id)"
                        run_command "aws s3api delete-object --bucket $bucket_name --key \"$key\" --version-id \"$version_id\" --region $AWS_REGION" \
                            "Failed to delete object version" \
                            "" \
                            "true"
                    fi
                done
                
                # Process delete markers
                echo "Processing delete markers with jq..."
                markers=$(jq -r '.DeleteMarkers[] | "\(.Key)|\(.VersionId)"' $TEMP_FILE 2>/dev/null || echo "")
                
                for marker_info in $markers; do
                    IFS='|' read -r key version_id <<< "$marker_info"
                    if [ -n "$key" ] && [ -n "$version_id" ]; then
                        echo "Deleting delete marker: $key (version $version_id)"
                        run_command "aws s3api delete-object --bucket $bucket_name --key \"$key\" --version-id \"$version_id\" --region $AWS_REGION" \
                            "Failed to delete delete marker" \
                            "" \
                            "true"
                    fi
                done
            else
                # Fallback without jq using grep and sed
                echo "Processing object versions without jq (limited functionality)..."
                
                # Extract Key and VersionId pairs
                grep '"Key":' $TEMP_FILE | sed 's/.*"Key": "\(.*\)".*/\1/' > keys.txt
                grep '"VersionId":' $TEMP_FILE | sed 's/.*"VersionId": "\(.*\)".*/\1/' > versions.txt

                paste keys.txt versions.txt | while IFS=$'\t' read -r key version; do
                    if [ -n "$key" ] && [ -n "$version" ]; then
                        echo "Deleting object: $key (version $version)"
                        run_command "aws s3api delete-object --bucket $bucket_name --key \"$key\" --version-id \"$version\" --region $AWS_REGION" \
                            "Failed to delete object version" "" "true"
                    fi
                done

                rm -f keys.txt versions.txt
            fi
        fi
        
        # Clean up temp file
        rm -f $TEMP_FILE
        
        # Step 3: Final check to make sure bucket is empty
        echo "Performing final verification that bucket is empty..."
        run_command "aws s3 rm s3://$bucket_name --recursive --region $AWS_REGION" \
            "Failed during final cleanup check" \
            "Bucket verified empty" \
            "true"
        
        # Step 4: Delete the bucket
        echo "Deleting bucket: $bucket_name"
        run_command "aws s3api delete-bucket --bucket $bucket_name --region $AWS_REGION" \
            "Failed to delete bucket: $bucket_name" \
            "Successfully deleted bucket: $bucket_name"
    else
        echo "S3 bucket not found: $bucket"
    fi
done

echo -e "\n${YELLOW}Step 13: Delete IAM roles and policies${NC}"
# Find IAM roles with the project prefix
roles=$(aws iam list-roles --query "Roles[?starts_with(RoleName, '${PREFIX}')].RoleName" --output text)

if [ -n "$roles" ]; then
    for role_name in $roles; do
        echo "Found IAM role: $role_name"
        
        # Step 1: Remove all attached policies
        echo "Finding and detaching policies for role: $role_name"
        attached_policies=$(aws iam list-attached-role-policies --role-name $role_name --query "AttachedPolicies[].PolicyArn" --output text)
        
        for policy_arn in $attached_policies; do
            echo "Detaching policy: $policy_arn from role: $role_name"
            run_command "aws iam detach-role-policy --role-name $role_name --policy-arn $policy_arn --region $AWS_REGION" \
                "Failed to detach policy: $policy_arn" \
                "Successfully detached policy: $policy_arn" \
                "true"
        done
        
        # Step 2: Delete all inline policies
        echo "Finding and deleting inline policies for role: $role_name"
        inline_policies=$(aws iam list-role-policies --role-name $role_name --query "PolicyNames[]" --output text)
        
        for policy_name in $inline_policies; do
            echo "Deleting inline policy: $policy_name from role: $role_name"
            run_command "aws iam delete-role-policy --role-name $role_name --policy-name $policy_name" \
                "Failed to delete inline policy: $policy_name" \
                "Successfully deleted inline policy: $policy_name" \
                "true"
        done
        
        # Step 3: Check if the role has any instance profiles
        echo "Checking for instance profiles attached to role: $role_name"
        instance_profiles=$(aws iam list-instance-profiles-for-role --role-name $role_name --query "InstanceProfiles[].InstanceProfileName" --output text)
        
        for profile_name in $instance_profiles; do
            echo "Removing role from instance profile: $profile_name"
            run_command "aws iam remove-role-from-instance-profile --instance-profile-name $profile_name --role-name $role_name" \
                "Failed to remove role from instance profile: $profile_name" \
                "Successfully removed role from instance profile: $profile_name" \
                "true"
        done
        
        # Step 4: Delete the role
        echo "Deleting IAM role: $role_name"
        run_command "aws iam delete-role --role-name $role_name" \
            "Failed to delete IAM role: $role_name" \
            "Successfully deleted IAM role: $role_name"
    done
else
    echo "No IAM roles found with prefix: ${PREFIX}"
fi

# Find and delete IAM policies with the project prefix
echo "Finding IAM policies with prefix: ${PREFIX}"
policies=$(aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, '${PREFIX}')].Arn" --output text)

if [ -n "$policies" ]; then
    for policy_arn in $policies; do
        echo "Found IAM policy: $policy_arn"
        
        # Delete policy versions first (except default)
        echo "Finding and deleting non-default versions for policy: $policy_arn"
        policy_versions=$(aws iam list-policy-versions --policy-arn $policy_arn --query "Versions[?!IsDefaultVersion].VersionId" --output text)
        
        for version_id in $policy_versions; do
            echo "Deleting policy version: $version_id"
            run_command "aws iam delete-policy-version --policy-arn $policy_arn --version-id $version_id" \
                "Failed to delete policy version: $version_id" \
                "Successfully deleted policy version: $version_id" \
                "true"
        done
        
        # Delete the policy
        echo "Deleting IAM policy: $policy_arn"
        run_command "aws iam delete-policy --policy-arn $policy_arn" \
            "Failed to delete IAM policy: $policy_arn" \
            "Successfully deleted IAM policy: $policy_arn"
    done
else
    echo "No IAM policies found with prefix: ${PREFIX}"
fi

echo -e "\n${YELLOW}Step 14: Delete VPC and related resources${NC}"
# Lookup VPC by tag name
vpc_filter="Name=tag:Name,Values=${PREFIX}-vpc"
vpc_id=$(resource_exists "vpc" "$vpc_filter")

# If not found by tag name, try with a wildcard tag search
if [ -z "$vpc_id" ]; then
    echo "VPC not found with specific tag, trying alternative search..."
    vpc_filter="Name=tag-key,Values=Name Name=tag-value,Values=*${PROJECT_NAME}*${STAGE}*"
    vpc_id=$(resource_exists "vpc" "$vpc_filter")
fi

# If still not found, try finding any VPC that might match the project
if [ -z "$vpc_id" ]; then
    echo "VPC not found with tag search, trying to find VPC by examining resources..."
    vpc_id=$(aws ec2 describe-vpcs --region $AWS_REGION --query "Vpcs[].VpcId" --output text | head -1)
    if [ -n "$vpc_id" ]; then
        echo "Found a VPC to check: $vpc_id"
        
        # Verify this is likely our project's VPC by looking for resources with our prefix
        resource_count=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --region $AWS_REGION | grep -c "${PREFIX}")
        if [ "$resource_count" -gt 0 ]; then
            echo "Confirmed VPC $vpc_id belongs to this project based on subnet naming"
        else
            echo "VPC $vpc_id doesn't appear to be related to this project. Skipping VPC cleanup."
            vpc_id=""
        fi
    fi
fi

if [ -n "$vpc_id" ]; then
    echo "Found VPC: $vpc_id. Starting cleanup of all associated resources..."
    
    # 1. Find and terminate EC2 instances
    echo "Checking for EC2 instances..."
    instances=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$vpc_id" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text --region $AWS_REGION)
    
    if [ -n "$instances" ]; then
        echo "Found EC2 instances in the VPC. Terminating: $instances"
        run_command "aws ec2 terminate-instances --instance-ids $instances --region $AWS_REGION" \
            "Failed to terminate EC2 instances" \
            "Successfully initiated termination of EC2 instances" \
            "true"
        
        echo "Waiting for instances to terminate..."
        run_command "aws ec2 wait instance-terminated --instance-ids $instances --region $AWS_REGION" \
            "Failed to wait for instance termination" \
            "All instances terminated" \
            "true"
    else
        echo "No EC2 instances found in the VPC."
    fi
    
    # 2. Find and release any Elastic IP addresses that might be associated with this VPC
    echo "Checking for Elastic IPs associated with VPC resources..."
    
    # Get all network interfaces in the VPC
    vpc_network_interfaces=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
    
    # Find and release EIPs associated with these network interfaces
    for eni in $vpc_network_interfaces; do
        echo "Checking for EIPs associated with network interface: $eni"
        eip_alloc_ids=$(aws ec2 describe-addresses --filters "Name=network-interface-id,Values=$eni" --query "Addresses[].AllocationId" --output text --region $AWS_REGION)
        
        for eip_id in $eip_alloc_ids; do
            if [ -n "$eip_id" ]; then
                echo "Found Elastic IP ($eip_id) associated with network interface $eni"
                # Disassociate the EIP first
                assoc_id=$(aws ec2 describe-addresses --allocation-ids $eip_id --query "Addresses[0].AssociationId" --output text --region $AWS_REGION)
                if [ -n "$assoc_id" ] && [ "$assoc_id" != "None" ]; then
                    echo "Disassociating Elastic IP $eip_id (association: $assoc_id)"
                    run_command "aws ec2 disassociate-address --association-id $assoc_id --region $AWS_REGION" \
                        "Failed to disassociate Elastic IP" \
                        "Successfully disassociated Elastic IP" \
                        "true"
                    # Wait a moment for the disassociation to take effect
                    sleep 5
                fi
                
                # Now release the Elastic IP
                echo "Releasing Elastic IP: $eip_id"
                run_command "aws ec2 release-address --allocation-id $eip_id --region $AWS_REGION" \
                    "Failed to release Elastic IP: $eip_id" \
                    "Successfully released Elastic IP: $eip_id" \
                    "true"
            fi
        done
    done
    
    # 3. Delete any load balancers in the VPC
    echo "Checking for load balancers in the VPC..."
    
    # Find Application Load Balancers
    albs=$(aws elbv2 describe-load-balancers --region $AWS_REGION --query "LoadBalancers[?VpcId=='$vpc_id'].LoadBalancerArn" --output text)
    for alb in $albs; do
        if [ -n "$alb" ]; then
            echo "Found Application Load Balancer: $alb. Deleting..."
            run_command "aws elbv2 delete-load-balancer --load-balancer-arn $alb --region $AWS_REGION" \
                "Failed to delete Load Balancer" \
                "Successfully deleted Load Balancer" \
                "true"
        fi
    done
    
    # Wait for load balancers to be deleted
    if [ -n "$albs" ]; then
        echo "Waiting for load balancers to be deleted..."
        sleep 30
    fi
    
    # Find Classic Load Balancers
    clbs=$(aws elb describe-load-balancers --region $AWS_REGION --query "LoadBalancerDescriptions[?VPCId=='$vpc_id'].LoadBalancerName" --output text 2>/dev/null || echo "")
    for clb in $clbs; do
        if [ -n "$clb" ]; then
            echo "Found Classic Load Balancer: $clb. Deleting..."
            run_command "aws elb delete-load-balancer --load-balancer-name $clb --region $AWS_REGION" \
                "Failed to delete Classic Load Balancer" \
                "Successfully deleted Classic Load Balancer" \
                "true"
        fi
    done
    
    # Wait for load balancers to be deleted
    if [ -n "$clbs" ]; then
        echo "Waiting for classic load balancers to be deleted..."
        sleep 30
    fi
    
    # 4. Delete NAT Gateways - with extra careful checking
    echo "Finding and deleting NAT Gateways..."
    nat_gateways=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_id" --query "NatGateways[?State!='deleted'].NatGatewayId" --output text --region $AWS_REGION)
    
    if [ -n "$nat_gateways" ]; then
        for nat_id in $nat_gateways; do
            echo "Deleting NAT Gateway: $nat_id"
            run_command "aws ec2 delete-nat-gateway --nat-gateway-id $nat_id --region $AWS_REGION" \
                "Failed to delete NAT Gateway: $nat_id" \
                "Successfully initiated deletion of NAT Gateway: $nat_id" \
                "true"
        done
        
        # Wait for NAT gateways to be deleted - this can take some time
        echo "Waiting for NAT gateways to be deleted (this may take up to 5 minutes)..."
        wait_with_message 30 "Initial wait for NAT gateway deletion..."
        
        # Check status in a loop until all NAT gateways are deleted
        max_attempts=10
        attempt=1
        all_deleted=false
        
        until [ "$all_deleted" = true ] || [ $attempt -gt $max_attempts ]; do
            all_deleted=true
            
            for nat_id in $nat_gateways; do
                status=$(aws ec2 describe-nat-gateways --nat-gateway-ids $nat_id --region $AWS_REGION --query "NatGateways[0].State" --output text 2>/dev/null || echo "deleted")
                
                if [ "$status" != "deleted" ] && [ -n "$status" ]; then
                    echo "NAT Gateway $nat_id status: $status"
                    all_deleted=false
                else
                    echo "NAT Gateway $nat_id is deleted"
                fi
            done
            
            if [ "$all_deleted" = false ]; then
                echo "Attempt $attempt/$max_attempts: Some NAT gateways still not deleted. Waiting..."
                wait_with_message 30 "Continuing to wait for NAT gateway deletion..."
                attempt=$((attempt+1))
            fi
        done
        
        if [ "$all_deleted" = false ]; then
            echo -e "${YELLOW}Warning: Some NAT gateways may not have been fully deleted after multiple attempts.${NC}"
            echo "This might affect VPC deletion. Consider checking AWS console and manually deleting any remaining NAT gateways."
        else
            echo -e "${GREEN}All NAT gateways successfully deleted.${NC}"
        fi
    else
        echo "No NAT Gateways found in the VPC."
    fi
    
    # 5. Delete VPC Endpoints
    echo "Finding and deleting VPC Endpoints..."
    endpoints=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc_id" --query "VpcEndpoints[].VpcEndpointId" --output text --region $AWS_REGION)
    
    if [ -n "$endpoints" ]; then
        echo "Deleting VPC Endpoints: $endpoints"
        run_command "aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $endpoints --region $AWS_REGION" \
            "Failed to delete VPC endpoints" \
            "Successfully deleted VPC endpoints" \
            "true"
        
        # Wait for endpoints to be deleted
        echo "Waiting for endpoints to be deleted..."
        wait_with_message 30 "Waiting for VPC endpoints to be deleted..."
    else
        echo "No VPC Endpoints found."
    fi
    
    # 6. Delete any VPN connections
    echo "Finding and deleting VPN connections..."
    vpn_connections=$(aws ec2 describe-vpn-connections --filters "Name=vpc-id,Values=$vpc_id" --query "VpnConnections[?State!='deleted'].VpnConnectionId" --output text --region $AWS_REGION)
    
    if [ -n "$vpn_connections" ]; then
        for vpn_id in $vpn_connections; do
            echo "Deleting VPN Connection: $vpn_id"
            run_command "aws ec2 delete-vpn-connection --vpn-connection-id $vpn_id --region $AWS_REGION" \
                "Failed to delete VPN connection: $vpn_id" \
                "Successfully deleted VPN connection: $vpn_id" \
                "true"
        done
        
        # Wait for VPN connections to be deleted
        echo "Waiting for VPN connections to be deleted..."
        wait_with_message 30 "Waiting for VPN connections to be deleted..."
    else
        echo "No VPN Connections found."
    fi
    
    # 7. Delete VPC peering connections
    echo "Finding and deleting VPC peering connections..."
    peering_connections=$(aws ec2 describe-vpc-peering-connections --filters "Name=requester-vpc-info.vpc-id,Values=$vpc_id" --query "VpcPeeringConnections[].VpcPeeringConnectionId" --output text --region $AWS_REGION)
    peering_connections_accepter=$(aws ec2 describe-vpc-peering-connections --filters "Name=accepter-vpc-info.vpc-id,Values=$vpc_id" --query "VpcPeeringConnections[].VpcPeeringConnectionId" --output text --region $AWS_REGION)
    
    # Combine both requester and accepter peering connections
    peering_connections="$peering_connections $peering_connections_accepter"
    
    if [ -n "$peering_connections" ]; then
        for peer_id in $peering_connections; do
            if [ -n "$peer_id" ]; then
                echo "Deleting VPC Peering Connection: $peer_id"
                run_command "aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id $peer_id --region $AWS_REGION" \
                    "Failed to delete VPC peering connection: $peer_id" \
                    "Successfully deleted VPC peering connection: $peer_id" \
                    "true"
            fi
        done
    else
        echo "No VPC Peering Connections found."
    fi
    
    # 8. Delete network interfaces with enhanced handling
    echo "Finding and deleting network interfaces..."
    network_interfaces=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
    
    if [ -n "$network_interfaces" ]; then
        for eni_id in $network_interfaces; do
            echo "Processing Network Interface: $eni_id"
            
            # Get detailed info about the interface
            eni_info=$(aws ec2 describe-network-interfaces --network-interface-ids $eni_id --region $AWS_REGION --output json 2>/dev/null)
            
            # Check if the interface is attached
            has_attachment=false
            if [ $USE_JQ = true ]; then
                attachment_state=$(echo "$eni_info" | jq -r '.NetworkInterfaces[0].Attachment.Status // empty' 2>/dev/null)
                attachment_id=$(echo "$eni_info" | jq -r '.NetworkInterfaces[0].Attachment.AttachmentId // empty' 2>/dev/null)
                if [ -n "$attachment_state" ]; then
                    has_attachment=true
                fi
            else
                attachment_id=$(echo "$eni_info" | grep -o '"AttachmentId": "[^"]*"' | head -1 | cut -d'"' -f4)
                if [ -n "$attachment_id" ]; then
                    has_attachment=true
                fi
            fi
            
            # If the interface is attached, try to detach it
            if [ "$has_attachment" = true ] && [ -n "$attachment_id" ]; then
                echo "Network interface is attached. Attempting to detach: $attachment_id"
                
                # Check if the attachment allows force detachment
                if [ $USE_JQ = true ]; then
                    delete_on_termination=$(echo "$eni_info" | jq -r '.NetworkInterfaces[0].Attachment.DeleteOnTermination // false' 2>/dev/null)
                else
                    delete_on_termination=$(echo "$eni_info" | grep -o '"DeleteOnTermination": true' | head -1)
                    if [ -n "$delete_on_termination" ]; then
                        delete_on_termination=true
                    else
                        delete_on_termination=false
                    fi
                fi
                
                # Attempt to detach with force option
                echo "Attempting force detachment of network interface: $eni_id"
                run_command "aws ec2 detach-network-interface --attachment-id $attachment_id --force --region $AWS_REGION" \
                    "Failed to detach network interface (continuing anyway)" \
                    "Successfully detached network interface" \
                    "true"
                
                # Wait for the detachment to complete
                echo "Waiting for detachment to complete..."
                sleep 15
            fi
            
            # Now try to delete the ENI
            max_attempts=5
            for attempt in $(seq 1 $max_attempts); do
                echo "Attempt $attempt/$max_attempts: Deleting Network Interface: $eni_id"
                if run_command "aws ec2 delete-network-interface --network-interface-id $eni_id --region $AWS_REGION" \
                    "" \
                    "Successfully deleted network interface: $eni_id" \
                    "true"; then
                    break
                else
                    echo "Failed to delete network interface, waiting before retry..."
                    sleep 10
                fi
            done
        done
    else
        echo "No Network Interfaces found."
    fi
    
    # 9. Delete security groups (except default)
    echo "Finding and deleting security groups..."
    security_groups=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=!default" --query "SecurityGroups[].GroupId" --output text --region $AWS_REGION)
    
    if [ -n "$security_groups" ]; then
        # First try to remove dependencies between security groups by removing all ingress/egress rules
        for sg_id in $security_groups; do
            echo "Removing all rules from security group: $sg_id"
            
            # Get all ingress rules referencing other security groups
            if [ $USE_JQ = true ]; then
                sg_rules=$(aws ec2 describe-security-groups --group-ids $sg_id --region $AWS_REGION | jq -r '.SecurityGroups[0].IpPermissions[] | select(.UserIdGroupPairs != null and .UserIdGroupPairs != [])' 2>/dev/null)
                if [ -n "$sg_rules" ]; then
                    echo "Revoking all ingress rules referencing other security groups"
                    run_command "aws ec2 revoke-security-group-ingress --group-id $sg_id --ip-permissions '$sg_rules' --region $AWS_REGION" "" "" "true"
                fi
                
                # Get all egress rules referencing other security groups
                sg_egress_rules=$(aws ec2 describe-security-groups --group-ids $sg_id --region $AWS_REGION | jq -r '.SecurityGroups[0].IpPermissionsEgress[] | select(.UserIdGroupPairs != null and .UserIdGroupPairs != [])' 2>/dev/null)
                if [ -n "$sg_egress_rules" ]; then
                    echo "Revoking all egress rules referencing other security groups"
                    run_command "aws ec2 revoke-security-group-egress --group-id $sg_id --ip-permissions '$sg_egress_rules' --region $AWS_REGION" "" "" "true"
                fi
            else
                # Simplified approach without jq - just try to remove all references to the group itself
                echo "Revoking self-references without jq"
                run_command "aws ec2 revoke-security-group-ingress --group-id $sg_id --protocol all --source-group $sg_id --region $AWS_REGION" "" "" "true"
                run_command "aws ec2 revoke-security-group-egress --group-id $sg_id --protocol all --source-group $sg_id --region $AWS_REGION" "" "" "true"
            fi
        done
        
        # Now try to delete each security group
        for sg_id in $security_groups; do
            echo "Deleting Security Group: $sg_id"
            max_attempts=5
            for attempt in $(seq 1 $max_attempts); do
                if run_command "aws ec2 delete-security-group --group-id $sg_id --region $AWS_REGION" \
                    "" \
                    "Successfully deleted security group: $sg_id" \
                    "true"; then
                    break
                else
                    echo "Failed to delete security group on attempt $attempt. Waiting before retry..."
                    sleep 10
                fi
            done
        done
    else
        echo "No Security Groups found (except default group)."
    fi
    
    # 10. Delete Network ACLs (except default)
    echo "Finding and deleting network ACLs..."
    network_acls=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkAcls[?!IsDefault].NetworkAclId" --output text --region $AWS_REGION)
    
    if [ -n "$network_acls" ]; then
        for acl_id in $network_acls; do
            echo "Deleting Network ACL: $acl_id"
            run_command "aws ec2 delete-network-acl --network-acl-id $acl_id --region $AWS_REGION" \
                "Failed to delete Network ACL: $acl_id" \
                "Successfully deleted Network ACL: $acl_id" \
                "true"
        done
    else
        echo "No Network ACLs found (except default ACL)."
    fi
    
    # 11. Delete subnets
    echo "Finding and deleting subnets..."
    subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --query "Subnets[].SubnetId" --output text --region $AWS_REGION)
    
    if [ -n "$subnets" ]; then
        for subnet_id in $subnets; do
            echo "Deleting Subnet: $subnet_id"
            max_attempts=5
            for attempt in $(seq 1 $max_attempts); do
                if run_command "aws ec2 delete-subnet --subnet-id $subnet_id --region $AWS_REGION" \
                    "" \
                    "Successfully deleted subnet: $subnet_id" \
                    "true"; then
                    break
                else
                    echo "Failed to delete subnet on attempt $attempt. Waiting before retry..."
                    sleep 10
                fi
            done
        done
    else
        echo "No Subnets found."
    fi
    
    # 12. Delete route tables (except the main one)
    echo "Finding and deleting route tables..."
    route_tables=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" --query "RouteTables[?!Associations[?Main]].RouteTableId" --output text --region $AWS_REGION)
    
    if [ -n "$route_tables" ]; then
        for rt_id in $route_tables; do
            # First disassociate any associations
            echo "Finding and removing route table associations for: $rt_id"
            associations=$(aws ec2 describe-route-tables --route-table-ids $rt_id --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" --output text --region $AWS_REGION)
            
            for assoc_id in $associations; do
                if [ -n "$assoc_id" ]; then
                    echo "Disassociating route table association: $assoc_id"
                    run_command "aws ec2 disassociate-route-table --association-id $assoc_id --region $AWS_REGION" \
                        "Failed to disassociate route table: $assoc_id" \
                        "Successfully disassociated route table: $assoc_id" \
                        "true"
                fi
            done
            
            # Then delete any non-propagated routes in the route table
            echo "Deleting routes from route table: $rt_id"
            routes=$(aws ec2 describe-route-tables --route-table-ids $rt_id --query "RouteTables[0].Routes[?Origin=='CreateRoute'].DestinationCidrBlock" --output text --region $AWS_REGION)
            
            for cidr in $routes; do
                if [ -n "$cidr" ]; then
                    echo "Deleting route for CIDR: $cidr"
                    run_command "aws ec2 delete-route --route-table-id $rt_id --destination-cidr-block $cidr --region $AWS_REGION" \
                        "Failed to delete route for CIDR: $cidr" \
                        "Successfully deleted route for CIDR: $cidr" \
                        "true"
                fi
            done
            
            # Then delete the route table
            echo "Deleting Route Table: $rt_id"
            run_command "aws ec2 delete-route-table --route-table-id $rt_id --region $AWS_REGION" \
                "Failed to delete route table: $rt_id" \
                "Successfully deleted route table: $rt_id" \
                "true"
        done
    else
        echo "No Route Tables found (except main route table)."
    fi
    
    # 13. Delete internet gateways - with enhanced handling
    echo "Finding and deleting internet gateways..."
    igws=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" --query "InternetGateways[].InternetGatewayId" --output text --region $AWS_REGION)
    
    if [ -n "$igws" ]; then
        for igw in $igws; do
            # First detach the IGW from VPC
            echo "Detaching Internet Gateway: $igw from VPC: $vpc_id"
            run_command "aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $vpc_id --region $AWS_REGION" \
                "Failed to detach internet gateway: $igw" \
                "Successfully detached internet gateway: $igw" \
                "true"
            
            # Wait a moment for the detachment to complete
            sleep 5
            
            # Then delete the IGW
            echo "Deleting Internet Gateway: $igw"
            run_command "aws ec2 delete-internet-gateway --internet-gateway-id $igw --region $AWS_REGION" \
                "Failed to delete internet gateway: $igw" \
                "Successfully deleted internet gateway: $igw" \
                "true"
        done
    else
        echo "No Internet Gateways found."
    fi
    
    # 14. Wait before trying to delete the VPC
    echo "Waiting 30 seconds before attempting to delete VPC..."
    wait_with_message 30 "Final waiting period before VPC deletion..."
    
    # Perform a final check for any remaining dependencies
    echo "Performing final dependency check before VPC deletion..."
    
    remaining_sg=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region $AWS_REGION)
    remaining_subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --query "Subnets[].SubnetId" --output text --region $AWS_REGION)
    remaining_rtb=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" --query "RouteTables[?!Associations[?Main]].RouteTableId" --output text --region $AWS_REGION)
    remaining_acl=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkAcls[?!IsDefault].NetworkAclId" --output text --region $AWS_REGION)
    remaining_igw=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" --query "InternetGateways[].InternetGatewayId" --output text --region $AWS_REGION)
    remaining_eni=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
    remaining_natgw=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_id" --query "NatGateways[?State!='deleted'].NatGatewayId" --output text --region $AWS_REGION)
    
    # Report any remaining dependencies
    dependencies_exist=false
    
    if [ -n "$remaining_sg" ]; then
        echo -e "${YELLOW}Found remaining security groups: $remaining_sg${NC}"
        dependencies_exist=true
    fi
    
    if [ -n "$remaining_subnets" ]; then
        echo -e "${YELLOW}Found remaining subnets: $remaining_subnets${NC}"
        dependencies_exist=true
    fi
    
    if [ -n "$remaining_rtb" ]; then
        echo -e "${YELLOW}Found remaining route tables: $remaining_rtb${NC}"
        dependencies_exist=true
    fi
    
    if [ -n "$remaining_acl" ]; then
        echo -e "${YELLOW}Found remaining network ACLs: $remaining_acl${NC}"
        dependencies_exist=true
    fi
    
    if [ -n "$remaining_igw" ]; then
        echo -e "${YELLOW}Found remaining internet gateways: $remaining_igw${NC}"
        dependencies_exist=true
    fi
    
    if [ -n "$remaining_eni" ]; then
        echo -e "${YELLOW}Found remaining network interfaces: $remaining_eni${NC}"
        dependencies_exist=true
    fi
    
    if [ -n "$remaining_natgw" ]; then
        echo -e "${YELLOW}Found remaining NAT gateways: $remaining_natgw${NC}"
        dependencies_exist=true
    fi
    
    if [ "$dependencies_exist" = true ]; then
        echo -e "${YELLOW}Some VPC dependencies still exist. These may prevent VPC deletion.${NC}"
        echo "Making one last attempt to remove remaining dependencies..."
        
        # Special handling for ENIs - these can be particularly troublesome
        if [ -n "$remaining_eni" ]; then
            echo "Attempting aggressive removal of remaining network interfaces..."
            for eni_id in $remaining_eni; do
                # Get detailed info about the interface
                echo "Processing stuck network interface: $eni_id"
                
                attachment_id=$(aws ec2 describe-network-interfaces --network-interface-ids $eni_id --region $AWS_REGION --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null || echo "")
                
                # If attached, try one more forced detachment
                if [ -n "$attachment_id" ] && [ "$attachment_id" != "None" ]; then
                    echo "Final attempt to force-detach network interface: $eni_id"
                    run_command "aws ec2 detach-network-interface --attachment-id $attachment_id --force --region $AWS_REGION" "" "" "true"
                    sleep 15
                fi
                
                # Try one more time to delete the interface
                echo "Final attempt to delete network interface: $eni_id"
                run_command "aws ec2 delete-network-interface --network-interface-id $eni_id --region $AWS_REGION" "" "" "true"
            done
        fi
        
        # Final check for NAT gateways
        if [ -n "$remaining_natgw" ]; then
            echo "Attempting to forcefully clean up NAT gateways..."
            for natgw_id in $remaining_natgw; do
                echo "Final attempt to delete NAT Gateway: $natgw_id"
                run_command "aws ec2 delete-nat-gateway --nat-gateway-id $natgw_id --region $AWS_REGION" "" "" "true"
            done
            echo "Waiting longer for NAT gateway deletion..."
            wait_with_message 60 "Extended waiting for NAT gateway deletion..."
        fi
    fi
    
    # 15. Delete the VPC
    echo "Attempting to delete VPC: $vpc_id"
    
    # Make multiple attempts with increasing wait times
    successful_deletion=false
    for attempt in {1..3}; do
        if run_command "aws ec2 delete-vpc --vpc-id $vpc_id --region $AWS_REGION" \
            "" \
            "Successfully deleted VPC: $vpc_id"; then
            successful_deletion=true
            break
        else
            echo "Failed to delete VPC on attempt $attempt."
            
            if [ $attempt -lt 3 ]; then
                wait_time=$((30 * attempt))
                echo "Waiting $wait_time seconds before next attempt..."
                sleep $wait_time
                
                # Check again for any remaining dependencies
                echo "Rechecking for dependencies..."
                remaining_eni=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
                
                if [ -n "$remaining_eni" ]; then
                    echo "Still found these network interfaces: $remaining_eni"
                    for eni_id in $remaining_eni; do
                        echo "Emergency attempt to delete network interface: $eni_id"
                        aws ec2 detach-network-interface --network-interface-id $eni_id --force --region $AWS_REGION 2>/dev/null || true
                        sleep 5
                        aws ec2 delete-network-interface --network-interface-id $eni_id --region $AWS_REGION 2>/dev/null || true
                    done
                fi
            fi
        fi
    done
    
    # Check if VPC was successfully deleted
    vpc_exists=$(aws ec2 describe-vpcs --vpc-ids $vpc_id --region $AWS_REGION 2>/dev/null && echo "true" || echo "false")
    if [ "$vpc_exists" = "true" ]; then
        echo -e "${YELLOW}Warning: VPC $vpc_id may still exist after deletion attempts.${NC}"
        echo "You may need to manually delete the VPC and its dependencies from the AWS Console."
        
        # Provide specific guidance on what might be blocking deletion
        echo -e "\n${YELLOW}Checking what resources might be blocking VPC deletion:${NC}"
        
        # Re-check all dependency types
        remaining_sg=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region $AWS_REGION)
        remaining_subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --query "Subnets[].SubnetId" --output text --region $AWS_REGION)
        remaining_rtb=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" --query "RouteTables[?!Associations[?Main]].RouteTableId" --output text --region $AWS_REGION)
        remaining_acl=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkAcls[?!IsDefault].NetworkAclId" --output text --region $AWS_REGION)
        remaining_igw=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" --query "InternetGateways[].InternetGatewayId" --output text --region $AWS_REGION)
        remaining_eni=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
        remaining_natgw=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_id" --query "NatGateways[?State!='deleted'].NatGatewayId" --output text --region $AWS_REGION)
        remaining_endpoints=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc_id" --query "VpcEndpoints[].VpcEndpointId" --output text --region $AWS_REGION)
        remaining_peering=$(aws ec2 describe-vpc-peering-connections --filters "Name=requester-vpc-info.vpc-id,Values=$vpc_id" --query "VpcPeeringConnections[].VpcPeeringConnectionId" --output text --region $AWS_REGION)
        
        # Print out all remaining resources
        [ -n "$remaining_sg" ] && echo "Security Groups: $remaining_sg"
        [ -n "$remaining_subnets" ] && echo "Subnets: $remaining_subnets"
        [ -n "$remaining_rtb" ] && echo "Route Tables: $remaining_rtb"
        [ -n "$remaining_acl" ] && echo "Network ACLs: $remaining_acl"
        [ -n "$remaining_igw" ] && echo "Internet Gateways: $remaining_igw"
        [ -n "$remaining_eni" ] && echo "Network Interfaces: $remaining_eni"
        [ -n "$remaining_natgw" ] && echo "NAT Gateways: $remaining_natgw"
        [ -n "$remaining_endpoints" ] && echo "VPC Endpoints: $remaining_endpoints"
        [ -n "$remaining_peering" ] && echo "VPC Peering Connections: $remaining_peering"
        
        # For network interfaces, show what they're attached to
        if [ -n "$remaining_eni" ]; then
            echo -e "\n${YELLOW}Network Interface Attachment Details:${NC}"
            for eni_id in $remaining_eni; do
                attachment_info=$(aws ec2 describe-network-interfaces --network-interface-ids $eni_id --region $AWS_REGION --query "NetworkInterfaces[0].Attachment" --output json 2>/dev/null || echo "Not attached")
                description=$(aws ec2 describe-network-interfaces --network-interface-ids $eni_id --region $AWS_REGION --query "NetworkInterfaces[0].Description" --output text 2>/dev/null || echo "No description")
                echo "ENI $eni_id: $description"
                echo "Attachment: $attachment_info"
                echo "-------------------------"
            done
        fi
        
        echo -e "\n${YELLOW}Manual Cleanup Instructions:${NC}"
        echo "1. Go to AWS Console → VPC Dashboard"
        echo "2. Delete resources in this order:"
        echo "   - Network Interfaces (check EC2 → Network Interfaces)"
        echo "   - NAT Gateways"
        echo "   - Internet Gateways (detach first, then delete)"
        echo "   - Subnets"
        echo "   - Security Groups"
        echo "   - Network ACLs"
        echo "   - Route Tables"
        echo "   - VPC Endpoints"
        echo "   - Finally, delete the VPC itself"
    else
        echo -e "${GREEN}VPC was successfully deleted.${NC}"
    fi
else
    echo "No VPC found with the specified prefix: ${PREFIX}"
fi#!/bin/bash

# ============================================================
# Enhanced AWS RAG Application Cleanup Script
# ============================================================
# This script thoroughly removes all AWS resources created for the RAG application
# with proper dependency handling and verification

# Set text colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Banner
echo -e "${BLUE}"
echo "============================================================"
echo "     Enhanced AWS RAG Application - Complete Cleanup Script  "
echo "============================================================"
echo -e "${NC}"

# Get project configuration
read -p "Enter your project name (default: rag-app): " PROJECT_NAME
PROJECT_NAME=${PROJECT_NAME:-rag-app}

read -p "Enter environment/stage (default: dev): " STAGE
STAGE=${STAGE:-dev}

read -p "Enter AWS region (default: us-east-1): " AWS_REGION
AWS_REGION=${AWS_REGION:-us-east-1}

# Standard prefix for resources
PREFIX="${PROJECT_NAME}-${STAGE}"

echo -e "\n${YELLOW}This script will DELETE ALL resources for:"
echo -e "  Project: ${PROJECT_NAME}"
echo -e "  Stage: ${STAGE}"
echo -e "  Region: ${AWS_REGION}${NC}"
echo -e "${RED}WARNING: This action is IRREVERSIBLE and will delete ALL data!${NC}"
read -p "Are you sure you want to proceed? (yes/no): " CONFIRMATION

if [[ $CONFIRMATION != "yes" ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo -e "\n${YELLOW}Starting cleanup process...${NC}"

# Function to check if a command exists
check_command() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${YELLOW}Warning: $1 command not found. Some functionality may be limited.${NC}"
        return 1
    fi
    return 0
}

# Check for AWS CLI
if ! check_command aws; then
    echo -e "${RED}Error: AWS CLI is required for this script.${NC}"
    exit 1
fi

# Check for jq command
if ! check_command jq; then
    echo -e "${YELLOW}Warning: jq command not found. Will use alternative methods for JSON processing.${NC}"
    USE_JQ=false
else
    USE_JQ=true
fi

# Function to run a command with error handling
run_command() {
    local cmd="$1"
    local error_msg="$2"
    local success_msg="$3"
    local ignore_error="${4:-false}"
    
    echo -e "${BLUE}Running: $cmd${NC}"
    
    # Execute the command
    eval "$cmd"
    local status=$?
    
    if [ $status -eq 0 ]; then
        if [ -n "$success_msg" ]; then
            echo -e "${GREEN}$success_msg${NC}"
        fi
        return 0
    else
        if [ "$ignore_error" = "true" ]; then
            if [ -n "$error_msg" ]; then
                echo -e "${YELLOW}$error_msg (continuing)${NC}"
            fi
            return 0
        else
            if [ -n "$error_msg" ]; then
                echo -e "${RED}$error_msg${NC}"
            fi
            return 1
        fi
    fi
}

# Function to wait with a countdown
wait_with_message() {
    local seconds="$1"
    local message="$2"
    
    echo -n -e "${YELLOW}$message "
    for (( i=seconds; i>=1; i-- )); do
        echo -n -e "$i... "
        sleep 1
    done
    echo -e "${NC}"
}

# Function to check if a resource exists and return an identifier
resource_exists() {
    local resource_type="$1"
    local identifier="$2"
    local query="$3"
    local exists=false
    local id=""
    
    case "$resource_type" in
        "lambda")
            # Check if lambda function exists
            id=$(aws lambda get-function --function-name "$identifier" --region $AWS_REGION --query "Configuration.FunctionName" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "api")
            # Check if API Gateway exists
            id=$(aws apigateway get-rest-apis --region $AWS_REGION --query "items[?name=='$identifier'].id" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "cognito")
            # Check if Cognito User Pool exists
            id=$(aws cognito-idp list-user-pools --max-results 20 --region $AWS_REGION --query "UserPools[?Name=='$identifier'].Id" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "bucket")
            # Check if S3 bucket exists - fix to return just the bucket name
            if aws s3api head-bucket --bucket "$identifier" --region $AWS_REGION 2>/dev/null; then
                exists=true
                id="$identifier"  # Just return the bucket name, not the metadata
            fi
            ;;
        "table")
            # Check if DynamoDB table exists
            id=$(aws dynamodb describe-table --table-name "$identifier" --region $AWS_REGION --query "Table.TableName" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "rds")
            # Check if RDS instance exists
            id=$(aws rds describe-db-instances --db-instance-identifier "$identifier" --region $AWS_REGION --query "DBInstances[0].DBInstanceIdentifier" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "vpc")
            # Check if VPC exists
            id=$(aws ec2 describe-vpcs --region $AWS_REGION --filters "$query" --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "secret")
            # Check if Secret exists
            id=$(aws secretsmanager describe-secret --secret-id "$identifier" --region $AWS_REGION --query "ARN" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        "log-group")
            # Check if CloudWatch Log Group exists
            id=$(aws logs describe-log-groups --log-group-name-prefix "$identifier" --region $AWS_REGION --query "logGroups[0].logGroupName" --output text 2>/dev/null || echo "")
            if [ -n "$id" ] && [ "$id" != "None" ]; then exists=true; fi
            ;;
        *)
            echo "Unknown resource type: $resource_type"
            ;;
    esac
    
    if [ "$exists" = true ]; then
        echo "$id"
        return 0
    else
        return 1
    fi
}

echo -e "\n${YELLOW}Step 1: Clear any Terraform state locks${NC}"
DYNAMODB_TABLE="${PREFIX}-terraform-state-lock"

# Check if the DynamoDB table exists
if table_id=$(resource_exists "table" "$DYNAMODB_TABLE"); then
    echo "Terraform state lock table exists: $table_id"
    
    # Scan for any locks
    if [ $USE_JQ = true ]; then
        # Use jq for processing if available
        locks=$(aws dynamodb scan --table-name $DYNAMODB_TABLE --region $AWS_REGION --output json | jq -r '.Items[] | select(.LockID.S | contains("terraform-")) | .LockID.S' 2>/dev/null || echo "")
    else
        # Fallback method without jq
        locks=$(aws dynamodb scan --table-name $DYNAMODB_TABLE --region $AWS_REGION --output text | grep -o 'LockID.*terraform-[^ ]*' | awk '{print $2}' || echo "")
    fi
    
    if [ -n "$locks" ]; then
        echo -e "${YELLOW}Found Terraform state locks. Clearing...${NC}"
        for lock in $locks; do
            run_command "aws dynamodb delete-item --table-name $DYNAMODB_TABLE --key '{\"LockID\":{\"S\":\"$lock\"}}' --region $AWS_REGION" \
                "Failed to remove lock: $lock" \
                "Successfully removed lock: $lock" \
                "true"
        done
    else
        echo "No Terraform state locks found."
    fi
else
    echo "Terraform state lock table does not exist or cannot be accessed."
fi

echo -e "\n${YELLOW}Step 2: Disable CloudFormation stack deletion protection${NC}"
# List stacks with the project name and disable deletion protection if enabled
stacks=$(aws cloudformation list-stacks --region $AWS_REGION --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query "StackSummaries[?contains(StackName, '${PREFIX}')].StackName" --output text)

if [ -n "$stacks" ]; then
    echo "Found CloudFormation stacks potentially related to this project:"
    for stack in $stacks; do
        echo "Checking stack: $stack"
        protection=$(aws cloudformation describe-stacks --stack-name $stack --region $AWS_REGION --query "Stacks[0].EnableTerminationProtection" --output text 2>/dev/null || echo "false")
        
        if [ "$protection" = "true" ]; then
            echo -e "${YELLOW}Stack $stack has termination protection enabled. Disabling...${NC}"
            run_command "aws cloudformation update-termination-protection --stack-name $stack --no-enable-termination-protection --region $AWS_REGION" \
                "Failed to disable termination protection for stack: $stack" \
                "Successfully disabled termination protection for stack: $stack" \
                "true"
        else
            echo "Stack $stack does not have termination protection enabled."
        fi
    done
else
    echo "No CloudFormation stacks found for this project."
fi

echo -e "\n${YELLOW}Step 3: Remove all API Gateway resources${NC}"
api_name="${PREFIX}-api"
api_id=$(resource_exists "api" "$api_name")

if [ -n "$api_id" ]; then
    echo "Found API Gateway: $api_id"
    
    # First find and delete all custom domain name mappings for this API
    echo "Checking for custom domain name mappings..."
    domains=$(aws apigateway get-domain-names --region $AWS_REGION --query "items[].domainName" --output text)
    
    for domain in $domains; do
        mappings=$(aws apigateway get-base-path-mappings --domain-name $domain --region $AWS_REGION --query "items[?restApiId=='$api_id'].basePath" --output text 2>/dev/null || echo "")
        
        if [ -n "$mappings" ]; then
            echo -e "${YELLOW}Found domain mapping for API: $domain${NC}"
            for mapping in $mappings; do
                # Handle (none) base path special case
                if [ "$mapping" = "(none)" ]; then
                    mapping=""
                fi
                
                run_command "aws apigateway delete-base-path-mapping --domain-name $domain --base-path \"$mapping\" --region $AWS_REGION" \
                    "Failed to delete base path mapping for domain: $domain, path: $mapping" \
                    "Successfully deleted base path mapping for domain: $domain, path: $mapping" \
                    "true"
            done
        fi
    done
    
    # Then delete the API itself
    run_command "aws apigateway delete-rest-api --rest-api-id $api_id --region $AWS_REGION" \
        "Failed to delete API Gateway: $api_id" \
        "Successfully deleted API Gateway: $api_id"
else
    echo "No API Gateway found with name: $api_name"
fi

echo -e "\n${YELLOW}Step 4: Clear Cognito User Pool${NC}"
user_pool_name="${PREFIX}-user-pool"
user_pool_id=$(resource_exists "cognito" "$user_pool_name")

if [ -n "$user_pool_id" ]; then
    echo "Found Cognito User Pool: $user_pool_id"
    
    # 1. Delete domain first (if exists)
    domain="${PROJECT_NAME}-${STAGE}-auth"
    domain_exists=$(aws cognito-idp describe-user-pool-domain --domain $domain --region $AWS_REGION --query "DomainDescription.Domain" --output text 2>/dev/null || echo "")
    
    if [ -n "$domain_exists" ] && [ "$domain_exists" != "None" ]; then
        echo "Deleting Cognito Domain: $domain"
        run_command "aws cognito-idp delete-user-pool-domain --domain $domain --user-pool-id $user_pool_id --region $AWS_REGION" \
            "Failed to delete Cognito domain: $domain" \
            "Successfully deleted Cognito domain: $domain" \
            "true"
    fi
    
    # 2. Delete app clients
    echo "Finding and deleting User Pool App Clients..."
    client_ids=$(aws cognito-idp list-user-pool-clients --user-pool-id $user_pool_id --region $AWS_REGION --query "UserPoolClients[].ClientId" --output text)
    
    for client_id in $client_ids; do
        if [ -n "$client_id" ]; then
            echo "Deleting App Client: $client_id"
            run_command "aws cognito-idp delete-user-pool-client --user-pool-id $user_pool_id --client-id $client_id --region $AWS_REGION" \
                "Failed to delete Cognito app client: $client_id" \
                "Successfully deleted Cognito app client: $client_id" \
                "true"
        fi
    done
    
    # 3. Delete identity providers if any
    echo "Finding and deleting Identity Providers..."
    providers=$(aws cognito-idp list-identity-providers --user-pool-id $user_pool_id --region $AWS_REGION --query "Providers[].ProviderName" --output text 2>/dev/null || echo "")
    
    for provider in $providers; do
        if [ -n "$provider" ] && [ "$provider" != "COGNITO" ]; then
            echo "Deleting Identity Provider: $provider"
            run_command "aws cognito-idp delete-identity-provider --user-pool-id $user_pool_id --provider-name $provider --region $AWS_REGION" \
                "Failed to delete identity provider: $provider" \
                "Successfully deleted identity provider: $provider" \
                "true"
        fi
    done
    
    # 4. Delete resource servers if any
    echo "Finding and deleting Resource Servers..."
    resource_servers=$(aws cognito-idp list-resource-servers --user-pool-id $user_pool_id --region $AWS_REGION --query "ResourceServers[].Identifier" --output text 2>/dev/null || echo "")
    
    for resource_server in $resource_servers; do
        if [ -n "$resource_server" ]; then
            echo "Deleting Resource Server: $resource_server"
            run_command "aws cognito-idp delete-resource-server --user-pool-id $user_pool_id --identifier $resource_server --region $AWS_REGION" \
                "Failed to delete resource server: $resource_server" \
                "Successfully deleted resource server: $resource_server" \
                "true"
        fi
    done
    
    # 5. Delete user pool
    echo "Deleting User Pool: $user_pool_id"
    run_command "aws cognito-idp delete-user-pool --user-pool-id $user_pool_id --region $AWS_REGION" \
        "Failed to delete Cognito User Pool: $user_pool_id" \
        "Successfully deleted Cognito User Pool: $user_pool_id"
else
    echo "No Cognito User Pool found with name: $user_pool_name"
fi

echo -e "\n${YELLOW}Step 5: Remove all Lambda functions and layers${NC}"
# List of Lambda functions to delete
LAMBDA_FUNCTIONS=(
    "${PREFIX}-auth-handler"
    "${PREFIX}-document-processor"
    "${PREFIX}-query-processor"
    "${PREFIX}-upload-handler"
    "${PREFIX}-db-init"
)

for func in "${LAMBDA_FUNCTIONS[@]}"; do
    if function_name=$(resource_exists "lambda" "$func"); then
        echo "Found Lambda function: $function_name"
        
        # 1. First remove event source mappings
        echo "Checking for event source mappings..."
        mappings=$(aws lambda list-event-source-mappings --function-name $function_name --region $AWS_REGION --query "EventSourceMappings[].UUID" --output text 2>/dev/null || echo "")
        
        for mapping in $mappings; do
            if [ -n "$mapping" ]; then
                echo "Deleting event source mapping: $mapping"
                run_command "aws lambda delete-event-source-mapping --uuid $mapping --region $AWS_REGION" \
                    "Failed to delete event source mapping: $mapping" \
                    "Successfully deleted event source mapping: $mapping" \
                    "true"
            fi
        done
        
        # 2. Remove function-url configurations if any
        echo "Checking for function URL configurations..."
        has_url=$(aws lambda get-function-url-config --function-name $function_name --region $AWS_REGION 2>/dev/null && echo "true" || echo "false")
        
        if [ "$has_url" = "true" ]; then
            echo "Deleting function URL configuration for $function_name"
            run_command "aws lambda delete-function-url-config --function-name $function_name --region $AWS_REGION" \
                "Failed to delete function URL for: $function_name" \
                "Successfully deleted function URL for: $function_name" \
                "true"
        fi
        
        # 3. Remove function concurrency if any
        echo "Checking for function concurrency settings..."
        concurrency=$(aws lambda get-function-concurrency --function-name $function_name --region $AWS_REGION --query "ReservedConcurrentExecutions" --output text 2>/dev/null || echo "")
        
        if [ -n "$concurrency" ] && [ "$concurrency" != "None" ]; then
            echo "Removing concurrency settings for $function_name"
            run_command "aws lambda delete-function-concurrency --function-name $function_name --region $AWS_REGION" \
                "Failed to delete function concurrency for: $function_name" \
                "Successfully deleted function concurrency for: $function_name" \
                "true"
        fi
        
        # 4. Delete the function
        echo "Deleting Lambda function: $function_name"
        run_command "aws lambda delete-function --function-name $function_name --region $AWS_REGION" \
            "Failed to delete Lambda function: $function_name" \
            "Successfully deleted Lambda function: $function_name"
    else
        echo "Lambda function not found: $func"
    fi
done

# Find and delete any Lambda layers with the project prefix
echo "Finding Lambda layers with prefix: ${PREFIX}"
layer_versions=$(aws lambda list-layers --region $AWS_REGION --query "Layers[?starts_with(LayerName, '${PREFIX}')].{Name:LayerName,Arn:LatestMatchingVersion.LayerVersionArn}" --output json 2>/dev/null)

if [ -n "$layer_versions" ] && [ "$layer_versions" != "[]" ]; then
    if [ $USE_JQ = true ]; then
        # Process with jq if available
        layer_names=$(echo $layer_versions | jq -r '.[].Name')
        for layer_name in $layer_names; do
            echo "Found Lambda layer: $layer_name, retrieving versions..."
            versions=$(aws lambda list-layer-versions --layer-name $layer_name --region $AWS_REGION --query "LayerVersions[].Version" --output text)
            
            for version in $versions; do
                echo "Deleting Lambda layer: $layer_name version $version"
                run_command "aws lambda delete-layer-version --layer-name $layer_name --version-number $version --region $AWS_REGION" \
                    "Failed to delete Lambda layer: $layer_name version $version" \
                    "Successfully deleted Lambda layer: $layer_name version $version" \
                    "true"
            done
        done
    else
        # Simple grep method if jq not available
        echo "Found Lambda layers with prefix ${PREFIX}, but jq is not available for processing."
        echo "Please check and delete Lambda layers manually if needed."
    fi
else
    echo "No Lambda layers found with prefix: ${PREFIX}"
fi

echo -e "\n${YELLOW}Step 6: Delete CloudWatch Log Groups${NC}"
# Delete log groups for Lambda functions
for func in "${LAMBDA_FUNCTIONS[@]}"; do
    log_group="/aws/lambda/$func"
    if log_group_name=$(resource_exists "log-group" "$log_group"); then
        echo "Found Log Group: $log_group_name"
        run_command "aws logs delete-log-group --log-group-name \"$log_group_name\" --region $AWS_REGION" \
            "Failed to delete Log Group: $log_group_name" \
            "Successfully deleted Log Group: $log_group_name"
    else
        echo "Log Group not found: $log_group"
    fi
done

# Delete API Gateway log group
api_log_group="/aws/apigateway/${PREFIX}-api"
if log_group_name=$(resource_exists "log-group" "$api_log_group"); then
    echo "Found API Gateway Log Group: $log_group_name"
    run_command "aws logs delete-log-group --log-group-name \"$log_group_name\" --region $AWS_REGION" \
        "Failed to delete API Gateway Log Group: $log_group_name" \
        "Successfully deleted API Gateway Log Group: $log_group_name"
else
    echo "API Gateway Log Group not found: $api_log_group"
fi

# Delete VPC flow logs group if it exists
vpc_flow_log_group="/aws/vpc/flowlogs/${PREFIX}"
if log_group_name=$(resource_exists "log-group" "$vpc_flow_log_group"); then
    echo "Found VPC Flow Log Group: $log_group_name"
    run_command "aws logs delete-log-group --log-group-name \"$log_group_name\" --region $AWS_REGION" \
        "Failed to delete VPC Flow Log Group: $log_group_name" \
        "Successfully deleted VPC Flow Log Group: $log_group_name"
else
    echo "VPC Flow Log Group not found: $vpc_flow_log_group"
fi

echo -e "\n${YELLOW}Step 7: Delete Secrets Manager secrets${NC}"
SECRETS=(
    "${PREFIX}-db-credentials"
    "${PREFIX}-gemini-api-key"
)

for secret in "${SECRETS[@]}"; do
    if secret_arn=$(resource_exists "secret" "$secret"); then
        echo "Found secret: $secret"
        run_command "aws secretsmanager delete-secret --secret-id \"$secret\" --force-delete-without-recovery --region $AWS_REGION" \
            "Failed to delete secret: $secret" \
            "Successfully deleted secret: $secret"
    else
        echo "Secret not found: $secret"
    fi
done

echo -e "\n${YELLOW}Step 8: Delete SNS topics${NC}"
# Find and delete SNS topics with the project name
topics=$(aws sns list-topics --region $AWS_REGION --query "Topics[?contains(TopicArn, '${PREFIX}')].TopicArn" --output text)

if [ -n "$topics" ]; then
    for topic_arn in $topics; do
        echo "Found SNS topic: $topic_arn"
        
        # Delete all subscriptions first
        echo "Finding and deleting topic subscriptions..."
        subscriptions=$(aws sns list-subscriptions-by-topic --topic-arn $topic_arn --region $AWS_REGION --query "Subscriptions[].SubscriptionArn" --output text)
        
        for sub_arn in $subscriptions; do
            if [ "$sub_arn" != "PendingConfirmation" ]; then
                echo "Deleting subscription: $sub_arn"
                run_command "aws sns unsubscribe --subscription-arn $sub_arn --region $AWS_REGION" \
                    "Failed to delete subscription: $sub_arn" \
                    "Successfully deleted subscription: $sub_arn" \
                    "true"
            fi
        done
        
        # Delete the topic itself
        run_command "aws sns delete-topic --topic-arn $topic_arn --region $AWS_REGION" \
            "Failed to delete SNS topic: $topic_arn" \
            "Successfully deleted SNS topic: $topic_arn"
    done
else
    echo "No SNS topics found with name containing: ${PREFIX}"
fi

echo -e "\n${YELLOW}Step 9: Delete CloudWatch Alarms${NC}"
# Find and delete CloudWatch alarms with the project name
alarms=$(aws cloudwatch describe-alarms --region $AWS_REGION --query "MetricAlarms[?contains(AlarmName, '${PREFIX}')].AlarmName" --output text)

if [ -n "$alarms" ]; then
    for alarm in $alarms; do
        echo "Found CloudWatch alarm: $alarm"
        run_command "aws cloudwatch delete-alarms --alarm-names \"$alarm\" --region $AWS_REGION" \
            "Failed to delete CloudWatch alarm: $alarm" \
            "Successfully deleted CloudWatch alarm: $alarm"
    done
else
    echo "No CloudWatch alarms found with name containing: ${PREFIX}"
fi

echo -e "\n${YELLOW}Step 10: Delete RDS instances and related resources${NC}"
DB_INSTANCE="${PREFIX}-postgres"
DB_PARAM_GROUP="${PREFIX}-postgres-params"
DB_SUBNET_GROUP="${PREFIX}-db-subnet-group"

# Check if RDS instance exists
if db_instance=$(resource_exists "rds" "$DB_INSTANCE"); then
    echo "Found RDS instance: $db_instance"
    
    # 1. Disable deletion protection first if enabled
    protection=$(aws rds describe-db-instances --db-instance-identifier $db_instance --region $AWS_REGION --query "DBInstances[0].DeletionProtection" --output text)
    
    if [ "$protection" = "true" ]; then
        echo "RDS instance has deletion protection enabled. Disabling..."
        run_command "aws rds modify-db-instance --db-instance-identifier $db_instance --no-deletion-protection --apply-immediately --region $AWS_REGION" \
            "Failed to disable deletion protection for RDS instance: $db_instance" \
            "Successfully disabled deletion protection for RDS instance: $db_instance"
        
        # Wait for the modification to complete
        echo "Waiting for modification to complete..."
        run_command "aws rds wait db-instance-available --db-instance-identifier $db_instance --region $AWS_REGION" \
            "Failed to wait for RDS instance modification" \
            "RDS instance modification completed"
    fi
    
    # 2. Delete DB instance, skipping final snapshot and deleting automated backups
    echo "Deleting RDS instance: $db_instance"
    run_command "aws rds delete-db-instance --db-instance-identifier $db_instance --skip-final-snapshot --delete-automated-backups --region $AWS_REGION" \
        "Failed to delete RDS instance: $db_instance" \
        "Successfully initiated deletion of RDS instance: $db_instance"
    
    # Wait for DB instance to be deleted before continuing
    echo "Waiting for RDS instance deletion to complete (this may take several minutes)..."
    wait_with_message 60 "Waiting for RDS instance deletion (checking every 60 seconds)..."
    
    # We'll use a loop to check status with increasing wait times
    for attempt in {1..10}; do
        status=$(aws rds describe-db-instances --db-instance-identifier $db_instance --region $AWS_REGION --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null || echo "deleted")
        
        if [ "$status" = "deleted" ] || [ -z "$status" ]; then
            echo -e "${GREEN}RDS instance deletion completed.${NC}"
            break
        else
            echo "RDS instance status: $status. Waiting longer..."
            wait_time=$((30 + $attempt * 30))  # Increasing wait time with each attempt
            wait_with_message $wait_time "Still waiting for RDS deletion to complete..."
        fi
    done
fi

# Delete parameter group (regardless of whether instance was found)
if run_command "aws rds describe-db-parameter-groups --db-parameter-group-name $DB_PARAM_GROUP --region $AWS_REGION >/dev/null 2>&1" "" "" "true"; then
    echo "Found DB parameter group: $DB_PARAM_GROUP"
    run_command "aws rds delete-db-parameter-group --db-parameter-group-name $DB_PARAM_GROUP --region $AWS_REGION" \
        "Failed to delete DB parameter group: $DB_PARAM_GROUP" \
        "Successfully deleted DB parameter group: $DB_PARAM_GROUP" \
        "true"
else
    echo "DB parameter group not found: $DB_PARAM_GROUP"
fi

# Delete subnet group (regardless of whether instance was found)
if run_command "aws rds describe-db-subnet-groups --db-subnet-group-name $DB_SUBNET_GROUP --region $AWS_REGION >/dev/null 2>&1" "" "" "true"; then
    echo "Found DB subnet group: $DB_SUBNET_GROUP"
    run_command "aws rds delete-db-subnet-group --db-subnet-group-name $DB_SUBNET_GROUP --region $AWS_REGION" \
        "Failed to delete DB subnet group: $DB_SUBNET_GROUP" \
        "Successfully deleted DB subnet group: $DB_SUBNET_GROUP" \
        "true"
else
    echo "DB subnet group not found: $DB_SUBNET_GROUP"
fi

echo -e "\n${YELLOW}Step 11: Delete DynamoDB tables${NC}"
TABLES=(
    "${PREFIX}-metadata"
    "${PREFIX}-terraform-state-lock"
)

for table in "${TABLES[@]}"; do
    if table_name=$(resource_exists "table" "$table"); then
        echo "Found DynamoDB table: $table_name"
        run_command "aws dynamodb delete-table --table-name $table_name --region $AWS_REGION" \
            "Failed to delete DynamoDB table: $table_name" \
            "Successfully deleted DynamoDB table: $table_name"
    else
        echo "DynamoDB table not found: $table"
    fi
done

echo -e "\n${YELLOW}Step 12: Empty and delete S3 buckets${NC}"
BUCKETS=(
    "${PREFIX}-documents"
    "${PREFIX}-lambda-code"
    "${PROJECT_NAME}-terraform-state"
)

for bucket in "${BUCKETS[@]}"; do
    if bucket_name=$(resource_exists "bucket" "$bucket"); then
        echo "Found S3 bucket: $bucket_name"
        
        # Check if bucket versioning is enabled
        versioning=$(aws s3api get-bucket-versioning --bucket $bucket_name --region $AWS_REGION --query "Status" --output text 2>/dev/null || echo "")
        
        # Disable versioning first if enabled
        if [ "$versioning" = "Enabled" ]; then
            echo "Bucket versioning is enabled. Suspending..."
            run_command "aws s3api put-bucket-versioning --bucket $bucket_name --versioning-configuration Status=Suspended --region $AWS_REGION" \
                "Failed to suspend bucket versioning for: $bucket_name" \
                "Successfully suspended versioning for bucket: $bucket_name" \
                "true"
        fi
        
        # Special handling for terraform state bucket
        if [[ $bucket == *"terraform-state"* ]]; then
            echo "This is a terraform state bucket. Will only remove objects for stage: ${STAGE}"
            echo "Deleting objects under stage prefix: ${STAGE}/"
            run_command "aws s3 rm s3://$bucket_name/$STAGE/ --recursive --region $AWS_REGION" \
                "Failed to delete terraform state objects" \
                "Successfully deleted terraform state objects" \
                "true"
            
            # Don't delete the terraform state bucket, just move on
            echo "Skipping deletion of terraform state bucket to preserve other environments"
            continue
        fi
        
        echo "Emptying bucket: $bucket_name"
        
        # Step 1: Remove all standard objects first
        run_command "aws s3 rm s3://$bucket_name --recursive --region $AWS_REGION" \
            "Failed to delete standard objects from bucket: $bucket_name" \
            "Deleted standard objects from bucket: $bucket_name" \
            "true"
        
        # Step 2: Delete all versions and delete markers
        # Create a temporary file for processing
        TEMP_FILE=$(mktemp)
        
        echo "Retrieving object versions and delete markers..."
        run_command "aws s3api list-object-versions --bucket $bucket_name --region $AWS_REGION --output json > $TEMP_FILE" \
            "Failed to list object versions for bucket: $bucket_name" \
            "Retrieved object versions for bucket: $bucket_name" \
            "true"
        
        if [ -s "$TEMP_FILE" ]; then
            # Process versions first
            if [ $USE_JQ = true ]; then
                # Use jq for robust processing
                echo "Processing object versions with jq..."
                versions=$(jq -r '.Versions[] | "\(.Key)|\(.VersionId)"' $TEMP_FILE 2>/dev/null || echo "")
                
                for version_info in $versions; do
                    IFS='|' read -r key version_id <<< "$version_info"
                    if [ -n "$key" ] && [ -n "$version_id" ]; then
                        echo "Deleting object: $key (version $version_id)"
                        run_command "aws s3api delete-object --bucket $bucket_name --key \"$key\" --version-id \"$version_id\" --region $AWS_REGION" \
                            "Failed to delete object version" \
                            "" \
                            "true"
                    fi
                done
                
                # Process delete markers
                echo "Processing delete markers with jq..."
                markers=$(jq -r '.DeleteMarkers[] | "\(.Key)|\(.VersionId)"' $TEMP_FILE 2>/dev/null || echo "")
                
                for marker_info in $markers; do
                    IFS='|' read -r key version_id <<< "$marker_info"
                    if [ -n "$key" ] && [ -n "$version_id" ]; then
                        echo "Deleting delete marker: $key (version $version_id)"
                        run_command "aws s3api delete-object --bucket $bucket_name --key \"$key\" --version-id \"$version_id\" --region $AWS_REGION" \
                            "Failed to delete delete marker" \
                            "" \
                            "true"
                    fi
                done
            else
                # Fallback without jq using grep and sed
                echo "Processing object versions without jq (limited functionality)..."
                
                # Extract Key and VersionId pairs using grep and sed
                grep -A 3 '"Key":' $TEMP_FILE | grep -v -e '--' -e '^
             | 
                while read -r key_line && read -r version_line; do
                    key=$(echo "$key_line" | sed -n 's/.*"Key": *"\([^"]*\)".*/\1/p')
                    version=$(echo "$version_line" | sed -n 's/.*"VersionId": *"\([^"]*\)".*/\1/p')
                    
                    if [ -n "$key" ] && [ -n "$version" ]; then
                        echo "Deleting object: $key (version $version)"
                        run_command "aws s3api delete-object --bucket $bucket_name --key \"$key\" --version-id \"$version\" --region $AWS_REGION" \
                            "Failed to delete object version" \
                            "" \
                            "true"
                    fi
                done
            fi
        fi
        
        # Clean up temp file
        rm -f $TEMP_FILE
        
        # Step 3: Final check to make sure bucket is empty
        echo "Performing final verification that bucket is empty..."
        run_command "aws s3 rm s3://$bucket_name --recursive --region $AWS_REGION" \
            "Failed during final cleanup check" \
            "Bucket verified empty" \
            "true"
        
        # Step 4: Delete the bucket
        echo "Deleting bucket: $bucket_name"
        run_command "aws s3api delete-bucket --bucket $bucket_name --region $AWS_REGION" \
            "Failed to delete bucket: $bucket_name" \
            "Successfully deleted bucket: $bucket_name"
    else
        echo "S3 bucket not found: $bucket"
    fi
done

echo -e "\n${YELLOW}Step 13: Delete IAM roles and policies${NC}"
# Find IAM roles with the project prefix
roles=$(aws iam list-roles --query "Roles[?starts_with(RoleName, '${PREFIX}')].RoleName" --output text)

if [ -n "$roles" ]; then
    for role_name in $roles; do
        echo "Found IAM role: $role_name"
        
        # Step 1: Remove all attached policies
        echo "Finding and detaching policies for role: $role_name"
        attached_policies=$(aws iam list-attached-role-policies --role-name $role_name --query "AttachedPolicies[].PolicyArn" --output text)
        
        for policy_arn in $attached_policies; do
            echo "Detaching policy: $policy_arn from role: $role_name"
            run_command "aws iam detach-role-policy --role-name $role_name --policy-arn $policy_arn --region $AWS_REGION" \
                "Failed to detach policy: $policy_arn" \
                "Successfully detached policy: $policy_arn" \
                "true"
        done
        
        # Step 2: Delete all inline policies
        echo "Finding and deleting inline policies for role: $role_name"
        inline_policies=$(aws iam list-role-policies --role-name $role_name --query "PolicyNames[]" --output text)
        
        for policy_name in $inline_policies; do
            echo "Deleting inline policy: $policy_name from role: $role_name"
            run_command "aws iam delete-role-policy --role-name $role_name --policy-name $policy_name" \
                "Failed to delete inline policy: $policy_name" \
                "Successfully deleted inline policy: $policy_name" \
                "true"
        done
        
        # Step 3: Check if the role has any instance profiles
        echo "Checking for instance profiles attached to role: $role_name"
        instance_profiles=$(aws iam list-instance-profiles-for-role --role-name $role_name --query "InstanceProfiles[].InstanceProfileName" --output text)
        
        for profile_name in $instance_profiles; do
            echo "Removing role from instance profile: $profile_name"
            run_command "aws iam remove-role-from-instance-profile --instance-profile-name $profile_name --role-name $role_name" \
                "Failed to remove role from instance profile: $profile_name" \
                "Successfully removed role from instance profile: $profile_name" \
                "true"
        done
        
        # Step 4: Delete the role
        echo "Deleting IAM role: $role_name"
        run_command "aws iam delete-role --role-name $role_name" \
            "Failed to delete IAM role: $role_name" \
            "Successfully deleted IAM role: $role_name"
    done
else
    echo "No IAM roles found with prefix: ${PREFIX}"
fi

# Find and delete IAM policies with the project prefix
echo "Finding IAM policies with prefix: ${PREFIX}"
policies=$(aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, '${PREFIX}')].Arn" --output text)

if [ -n "$policies" ]; then
    for policy_arn in $policies; do
        echo "Found IAM policy: $policy_arn"
        
        # Delete policy versions first (except default)
        echo "Finding and deleting non-default versions for policy: $policy_arn"
        policy_versions=$(aws iam list-policy-versions --policy-arn $policy_arn --query "Versions[?!IsDefaultVersion].VersionId" --output text)
        
        for version_id in $policy_versions; do
            echo "Deleting policy version: $version_id"
            run_command "aws iam delete-policy-version --policy-arn $policy_arn --version-id $version_id" \
                "Failed to delete policy version: $version_id" \
                "Successfully deleted policy version: $version_id" \
                "true"
        done
        
        # Delete the policy
        echo "Deleting IAM policy: $policy_arn"
        run_command "aws iam delete-policy --policy-arn $policy_arn" \
            "Failed to delete IAM policy: $policy_arn" \
            "Successfully deleted IAM policy: $policy_arn"
    done
else
    echo "No IAM policies found with prefix: ${PREFIX}"
fi

echo -e "\n${YELLOW}Step 14: Delete VPC and related resources${NC}"
# Lookup VPC by tag name
vpc_filter="Name=tag:Name,Values=${PREFIX}-vpc"
vpc_id=$(resource_exists "vpc" "$vpc_filter")

# If not found by tag name, try with a wildcard tag search
if [ -z "$vpc_id" ]; then
    echo "VPC not found with specific tag, trying alternative search..."
    vpc_filter="Name=tag-key,Values=Name Name=tag-value,Values=*${PROJECT_NAME}*${STAGE}*"
    vpc_id=$(resource_exists "vpc" "$vpc_filter")
fi

if [ -n "$vpc_id" ]; then
    echo "Found VPC: $vpc_id. Starting cleanup of all associated resources..."
    
    # 1. Find and delete any transit gateway attachments
    tgw_attachments=$(aws ec2 describe-transit-gateway-attachments --filters "Name=vpc-id,Values=$vpc_id" --query "TransitGatewayAttachments[].TransitGatewayAttachmentId" --output text --region $AWS_REGION)
    
    for attachment in $tgw_attachments; do
        echo "Found transit gateway attachment: $attachment"
        run_command "aws ec2 delete-transit-gateway-vpc-attachment --transit-gateway-attachment-id $attachment --region $AWS_REGION" \
            "Failed to delete transit gateway attachment: $attachment" \
            "Initiated deletion of transit gateway attachment: $attachment" \
            "true"
    done
    
    # 2. Find and terminate EC2 instances
    instances=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$vpc_id" --query "Reservations[].Instances[].InstanceId" --output text --region $AWS_REGION)
    
    if [ -n "$instances" ]; then
        echo "Found EC2 instances in the VPC. Terminating: $instances"
        run_command "aws ec2 terminate-instances --instance-ids $instances --region $AWS_REGION" \
            "Failed to terminate EC2 instances" \
            "Successfully initiated termination of EC2 instances" \
            "true"
        
        echo "Waiting for instances to terminate..."
        run_command "aws ec2 wait instance-terminated --instance-ids $instances --region $AWS_REGION" \
            "Failed to wait for instance termination" \
            "All instances terminated" \
            "true"
    else
        echo "No EC2 instances found in the VPC."
    fi
    
    # 3. Delete NAT Gateways
    nat_gateways=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_id" --query "NatGateways[?State!='deleted'].NatGatewayId" --output text --region $AWS_REGION)
    
    if [ -n "$nat_gateways" ]; then
        for nat_id in $nat_gateways; do
            echo "Deleting NAT Gateway: $nat_id"
            run_command "aws ec2 delete-nat-gateway --nat-gateway-id $nat_id --region $AWS_REGION" \
                "Failed to delete NAT Gateway: $nat_id" \
                "Successfully initiated deletion of NAT Gateway: $nat_id" \
                "true"
        done
        
        # Wait for NAT gateways to be deleted
        echo "Waiting for NAT gateways to be deleted (this may take a few minutes)..."
        wait_with_message 60 "Waiting for NAT gateway deletion..."
        
        # Check status
        for nat_id in $nat_gateways; do
            for attempt in {1..5}; do
                status=$(aws ec2 describe-nat-gateways --nat-gateway-ids $nat_id --region $AWS_REGION --query "NatGateways[0].State" --output text 2>/dev/null || echo "deleted")
                
                if [ "$status" = "deleted" ] || [ -z "$status" ]; then
                    echo -e "${GREEN}NAT Gateway $nat_id deleted.${NC}"
                    break
                else
                    echo "NAT Gateway $nat_id status: $status. Waiting longer..."
                    wait_with_message 30 "Still waiting for NAT Gateway deletion..."
                fi
            done
        done
    else
        echo "No NAT Gateways found in the VPC."
    fi
    
    # 4. Find and release Elastic IPs
    elastic_ips=$(aws ec2 describe-addresses --region $AWS_REGION --query "Addresses[?AssociationId!=null].AllocationId" --output text)
    
    if [ -n "$elastic_ips" ]; then
        for eip_id in $elastic_ips; do
            # Check if this EIP is associated with the VPC before releasing
            association=$(aws ec2 describe-addresses --allocation-ids $eip_id --region $AWS_REGION --query "Addresses[0].NetworkInterfaceId" --output text 2>/dev/null || echo "")
            
            if [ -n "$association" ]; then
                # Check if this network interface is in our VPC
                eni_vpc=$(aws ec2 describe-network-interfaces --network-interface-ids $association --region $AWS_REGION --query "NetworkInterfaces[0].VpcId" --output text 2>/dev/null || echo "")
                
                if [ "$eni_vpc" = "$vpc_id" ]; then
                    echo "Releasing Elastic IP $eip_id associated with VPC $vpc_id"
                    run_command "aws ec2 release-address --allocation-id $eip_id --region $AWS_REGION" \
                        "Failed to release Elastic IP: $eip_id" \
                        "Successfully released Elastic IP: $eip_id" \
                        "true"
                fi
            fi
        done
    else
        echo "No Elastic IPs found to release."
    fi
    
    # 5. Delete VPC Endpoints
    endpoints=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc_id" --query "VpcEndpoints[].VpcEndpointId" --output text --region $AWS_REGION)
    
    if [ -n "$endpoints" ]; then
        echo "Deleting VPC Endpoints: $endpoints"
        run_command "aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $endpoints --region $AWS_REGION" \
            "Failed to delete VPC endpoints" \
            "Successfully deleted VPC endpoints" \
            "true"
        
        # Wait for endpoints to be deleted
        echo "Waiting for endpoints to be deleted..."
        wait_with_message 30 "Waiting for VPC endpoints to be fully deleted..."
    else
        echo "No VPC Endpoints found."
    fi
    
    # 6. Delete any VPN connections
    vpn_connections=$(aws ec2 describe-vpn-connections --filters "Name=vpc-id,Values=$vpc_id" --query "VpnConnections[?State!='deleted'].VpnConnectionId" --output text --region $AWS_REGION)
    
    if [ -n "$vpn_connections" ]; then
        for vpn_id in $vpn_connections; do
            echo "Deleting VPN Connection: $vpn_id"
            run_command "aws ec2 delete-vpn-connection --vpn-connection-id $vpn_id --region $AWS_REGION" \
                "Failed to delete VPN connection: $vpn_id" \
                "Successfully deleted VPN connection: $vpn_id" \
                "true"
        done
        
        # Wait for VPN connections to be deleted
        echo "Waiting for VPN connections to be deleted..."
        wait_with_message 30 "Waiting for VPN connections to be fully deleted..."
    else
        echo "No VPN Connections found."
    fi
    
    # 7. Delete VPC peering connections
    peering_connections=$(aws ec2 describe-vpc-peering-connections --filters "Name=requester-vpc-info.vpc-id,Values=$vpc_id" --query "VpcPeeringConnections[].VpcPeeringConnectionId" --output text --region $AWS_REGION)
    
    if [ -n "$peering_connections" ]; then
        for peer_id in $peering_connections; do
            echo "Deleting VPC Peering Connection: $peer_id"
            run_command "aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id $peer_id --region $AWS_REGION" \
                "Failed to delete VPC peering connection: $peer_id" \
                "Successfully deleted VPC peering connection: $peer_id" \
                "true"
        done
    else
        echo "No VPC Peering Connections found."
    fi
    
    # 8. Clean up Network interfaces
    echo "Finding and deleting network interfaces..."
    network_interfaces=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
    
    for eni_id in $network_interfaces; do
        echo "Processing Network Interface: $eni_id"
        
        # Check if the ENI has an attachment
        attachment_id=$(aws ec2 describe-network-interfaces --network-interface-ids $eni_id --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text --region $AWS_REGION)
        
        if [ -n "$attachment_id" ] && [ "$attachment_id" != "None" ]; then
            echo "Detaching network interface attachment: $attachment_id"
            run_command "aws ec2 detach-network-interface --attachment-id $attachment_id --force --region $AWS_REGION" \
                "Failed to detach network interface: $attachment_id" \
                "Successfully detached network interface: $attachment_id" \
                "true"
            
            # Wait for detachment to complete
            echo "Waiting for detachment to complete..."
            wait_with_message 15 "Waiting for network interface detachment..."
        fi
        
        # Try to delete the ENI
        echo "Deleting Network Interface: $eni_id"
        run_command "aws ec2 delete-network-interface --network-interface-id $eni_id --region $AWS_REGION" \
            "Failed to delete network interface: $eni_id" \
            "Successfully deleted network interface: $eni_id" \
            "true"
    done
    
    # 9. Delete security groups (except default)
    echo "Finding and deleting security groups..."
    security_groups=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=!default" --query "SecurityGroups[].GroupId" --output text --region $AWS_REGION)
    
    for sg_id in $security_groups; do
        echo "Processing Security Group: $sg_id"
        
        # First remove all ingress rules
        echo "Removing all ingress rules from security group: $sg_id"
        run_command "aws ec2 revoke-security-group-ingress --group-id $sg_id --protocol all --source-group $sg_id --region $AWS_REGION" \
            "" \
            "" \
            "true"
        
        # Then try to delete the security group
        echo "Deleting Security Group: $sg_id"
        
        # Make multiple attempts with increasing wait times
        for attempt in {1..5}; do
            if run_command "aws ec2 delete-security-group --group-id $sg_id --region $AWS_REGION" \
                "" \
                "Successfully deleted security group: $sg_id" \
                "true"; then
                break
            else
                echo "Failed to delete security group on attempt $attempt. Waiting before retry..."
                wait_with_message 10 "Waiting before retrying security group deletion..."
            fi
        done
    done
    
    # 10. Delete Network ACLs (except default)
    echo "Finding and deleting network ACLs..."
    network_acls=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkAcls[?!IsDefault].NetworkAclId" --output text --region $AWS_REGION)
    
    for acl_id in $network_acls; do
        echo "Deleting Network ACL: $acl_id"
        run_command "aws ec2 delete-network-acl --network-acl-id $acl_id --region $AWS_REGION" \
            "Failed to delete Network ACL: $acl_id" \
            "Successfully deleted Network ACL: $acl_id" \
            "true"
    done
    
    # 11. Delete subnets
    echo "Finding and deleting subnets..."
    subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --query "Subnets[].SubnetId" --output text --region $AWS_REGION)
    
    for subnet_id in $subnets; do
        echo "Deleting Subnet: $subnet_id"
        run_command "aws ec2 delete-subnet --subnet-id $subnet_id --region $AWS_REGION" \
            "Failed to delete subnet: $subnet_id" \
            "Successfully deleted subnet: $subnet_id" \
            "true"
    done
    
    # 12. Delete route tables (except the main one)
    echo "Finding and deleting route tables..."
    route_tables=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" --query "RouteTables[?!Associations[?Main]].RouteTableId" --output text --region $AWS_REGION)
    
    for rt_id in $route_tables; do
        # First disassociate any associations
        echo "Finding and removing route table associations for: $rt_id"
        associations=$(aws ec2 describe-route-tables --route-table-ids $rt_id --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" --output text --region $AWS_REGION)
        
        for assoc_id in $associations; do
            echo "Disassociating route table association: $assoc_id"
            run_command "aws ec2 disassociate-route-table --association-id $assoc_id --region $AWS_REGION" \
                "Failed to disassociate route table: $assoc_id" \
                "Successfully disassociated route table: $assoc_id" \
                "true"
        done
        
        # Then delete the route table
        echo "Deleting Route Table: $rt_id"
        run_command "aws ec2 delete-route-table --route-table-id $rt_id --region $AWS_REGION" \
            "Failed to delete route table: $rt_id" \
            "Successfully deleted route table: $rt_id" \
            "true"
    done
    
    # 13. Detach and delete internet gateway
    echo "Finding and deleting internet gateway..."
    igw=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" --query "InternetGateways[0].InternetGatewayId" --output text --region $AWS_REGION)
    
    if [ -n "$igw" ] && [ "$igw" != "None" ]; then
        echo "Detaching Internet Gateway: $igw"
        run_command "aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $vpc_id --region $AWS_REGION" \
            "Failed to detach internet gateway: $igw" \
            "Successfully detached internet gateway: $igw" \
            "true"
        
        echo "Deleting Internet Gateway: $igw"
        run_command "aws ec2 delete-internet-gateway --internet-gateway-id $igw --region $AWS_REGION" \
            "Failed to delete internet gateway: $igw" \
            "Successfully deleted internet gateway: $igw" \
            "true"
    else
        echo "No Internet Gateway found."
    fi
    
    # 14. Wait before trying to delete the VPC
    echo "Waiting 30 seconds before attempting to delete VPC..."
    wait_with_message 30 "Final waiting period before VPC deletion..."
    
    # 15. Delete the VPC
    echo "Deleting VPC: $vpc_id"
    
    # Make multiple attempts with increasing wait times
    for attempt in {1..3}; do
        if run_command "aws ec2 delete-vpc --vpc-id $vpc_id --region $AWS_REGION" \
            "" \
            "Successfully deleted VPC: $vpc_id" \
            "true"; then
            break
        else
            echo "Failed to delete VPC on attempt $attempt. Checking for remaining dependencies..."
            
            # Check for any remaining dependencies
            remaining_sg=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" --query "SecurityGroups[].GroupId" --output text --region $AWS_REGION)
            remaining_subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --query "Subnets[].SubnetId" --output text --region $AWS_REGION)
            remaining_eni=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
            
            if [ -n "$remaining_sg" ] || [ -n "$remaining_subnets" ] || [ -n "$remaining_eni" ]; then
                echo "Found remaining dependencies:"
                [ -n "$remaining_sg" ] && echo "- Security Groups: $remaining_sg"
                [ -n "$remaining_subnets" ] && echo "- Subnets: $remaining_subnets"
                [ -n "$remaining_eni" ] && echo "- Network Interfaces: $remaining_eni"
                
                echo "Attempting more aggressive cleanup..."
                
                # Try to forcefully clean up remaining resources
                if [ -n "$remaining_eni" ]; then
                    for eni_id in $remaining_eni; do
                        echo "Force-detaching network interface: $eni_id"
                        attachment=$(aws ec2 describe-network-interfaces --network-interface-ids $eni_id --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text --region $AWS_REGION 2>/dev/null || echo "")
                        if [ -n "$attachment" ] && [ "$attachment" != "None" ]; then
                            run_command "aws ec2 detach-network-interface --attachment-id $attachment --force --region $AWS_REGION" "" "" "true"
                            wait_with_message 5 "Waiting after force detachment..."
                        fi
                        run_command "aws ec2 delete-network-interface --network-interface-id $eni_id --region $AWS_REGION" "" "" "true"
                    done
                fi
                
                if [ -n "$remaining_sg" ]; then
                    for sg_id in $remaining_sg; do
                        if [ "$sg_id" != "sg-default-vpc" ]; then
                            echo "Force-deleting security group: $sg_id"
                            run_command "aws ec2 delete-security-group --group-id $sg_id --region $AWS_REGION" "" "" "true"
                        fi
                    done
                fi
                
                if [ -n "$remaining_subnets" ]; then
                    for subnet_id in $remaining_subnets; do
                        echo "Force-deleting subnet: $subnet_id"
                        run_command "aws ec2 delete-subnet --subnet-id $subnet_id --region $AWS_REGION" "" "" "true"
                    done
                fi
            fi
            
            wait_with_message 30 "Waiting before next VPC deletion attempt..."
        fi
    done
    
    # Check if VPC was successfully deleted
    vpc_exists=$(aws ec2 describe-vpcs --vpc-ids $vpc_id --region $AWS_REGION 2>/dev/null && echo "true" || echo "false")
    if [ "$vpc_exists" = "true" ]; then
        echo -e "${YELLOW}Warning: VPC $vpc_id may still exist after deletion attempts.${NC}"
        echo "You may need to manually delete the VPC and its dependencies from the AWS Console."
    fi
else
    echo "No VPC found with the specified prefix: ${PREFIX}"
fi

echo -e "\n${YELLOW}Step 15: Cleanup any remaining CloudFormation stacks${NC}"
# Find and delete any CloudFormation stacks with the project prefix
stacks=$(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE --region $AWS_REGION --query "StackSummaries[?contains(StackName, '${PREFIX}')].StackName" --output text)

if [ -n "$stacks" ]; then
    for stack_name in $stacks; do
        echo "Found CloudFormation stack: $stack_name"
        
        # Disable termination protection if enabled
        protection=$(aws cloudformation describe-stacks --stack-name $stack_name --region $AWS_REGION --query "Stacks[0].EnableTerminationProtection" --output text 2>/dev/null || echo "false")
        
        if [ "$protection" = "true" ]; then
            echo "Stack has termination protection enabled. Disabling..."
            run_command "aws cloudformation update-termination-protection --stack-name $stack_name --no-enable-termination-protection --region $AWS_REGION" \
                "Failed to disable termination protection" \
                "Successfully disabled termination protection" \
                "true"
        fi
        
        # Delete the stack
        echo "Deleting CloudFormation stack: $stack_name"
        run_command "aws cloudformation delete-stack --stack-name $stack_name --region $AWS_REGION" \
            "Failed to initiate stack deletion: $stack_name" \
            "Successfully initiated deletion of stack: $stack_name"
        
        # Wait for stack deletion to complete
        echo "Waiting for stack deletion to complete..."
        run_command "aws cloudformation wait stack-delete-complete --stack-name $stack_name --region $AWS_REGION" \
            "Failed to wait for stack deletion" \
            "Stack deletion complete" \
            "true"
    done
else
    echo "No CloudFormation stacks found with prefix: ${PREFIX}"
fi

echo -e "\n${YELLOW}Step 16: Final verification${NC}"
echo "Performing final verification of resource cleanup..."

# Check for remaining resources in random order to ensure nothing was missed
check_remaining_resources() {
    local resource_type=$1
    local check_command=$2
    local resource_count=0
    
    echo -e "${BLUE}Checking for remaining $resource_type...${NC}"
    if [ -n "$check_command" ]; then
        resource_list=$(eval "$check_command")
        if [ -n "$resource_list" ]; then
            resource_count=$(echo "$resource_list" | wc -w)
            echo -e "${YELLOW}Found $resource_count $resource_type still existing:${NC}"
            echo "$resource_list"
            return 1
        else
            echo -e "${GREEN}No $resource_type found.${NC}"
            return 0
        fi
    fi
}

# Define checks for different resource types
lambda_check="aws lambda list-functions --region $AWS_REGION --query \"Functions[?contains(FunctionName, '${PREFIX}')].FunctionName\" --output text"
api_check="aws apigateway get-rest-apis --region $AWS_REGION --query \"items[?contains(name, '${PREFIX}')].id\" --output text"
dynamo_check="aws dynamodb list-tables --region $AWS_REGION --query \"TableNames[?contains(@, '${PREFIX}')]\" --output text"
s3_check="aws s3api list-buckets --query \"Buckets[?contains(Name, '${PREFIX}')].Name\" --output text"
rds_check="aws rds describe-db-instances --region $AWS_REGION --query \"DBInstances[?contains(DBInstanceIdentifier, '${PREFIX}')].DBInstanceIdentifier\" --output text"
cognito_check="aws cognito-idp list-user-pools --max-results 20 --region $AWS_REGION --query \"UserPools[?contains(Name, '${PREFIX}')].Id\" --output text"
secret_check="aws secretsmanager list-secrets --region $AWS_REGION --query \"SecretList[?contains(Name, '${PREFIX}')].Name\" --output text"
logs_check="aws logs describe-log-groups --region $AWS_REGION --query \"logGroups[?contains(logGroupName, '${PREFIX}')].logGroupName\" --output text"
role_check="aws iam list-roles --query \"Roles[?contains(RoleName, '${PREFIX}')].RoleName\" --output text"
policy_check="aws iam list-policies --scope Local --query \"Policies[?contains(PolicyName, '${PREFIX}')].PolicyName\" --output text"

# Create an array of resource types and their check commands
declare -A resource_checks
resource_checks["Lambda functions"]="$lambda_check"
resource_checks["API Gateway APIs"]="$api_check"
resource_checks["DynamoDB tables"]="$dynamo_check"
resource_checks["S3 buckets"]="$s3_check"
resource_checks["RDS instances"]="$rds_check"
resource_checks["Cognito User Pools"]="$cognito_check"
resource_checks["Secrets Manager secrets"]="$secret_check"
resource_checks["CloudWatch Log Groups"]="$logs_check"
resource_checks["IAM roles"]="$role_check"
resource_checks["IAM policies"]="$policy_check"

# Check all resource types
failed_checks=0
for resource_type in "${!resource_checks[@]}"; do
    if ! check_remaining_resources "$resource_type" "${resource_checks[$resource_type]}"; then
        failed_checks=$((failed_checks + 1))
    fi
done

# Final cleanup status
echo -e "\n${BLUE}============================================================${NC}"
if [ $failed_checks -eq 0 ]; then
    echo -e "${GREEN}All resources have been successfully cleaned up!${NC}"
else
    echo -e "${YELLOW}Cleanup completed with $failed_checks resource types still remaining.${NC}"
    echo -e "${YELLOW}Some resources may require manual deletion through the AWS Console.${NC}"
fi
echo -e "${BLUE}============================================================${NC}"

echo -e "\n${GREEN}Summary of cleanup actions:${NC}"
echo "- Cleared Terraform state locks"
echo "- Removed API Gateway resources"
echo "- Deleted Cognito User Pool and related resources"
echo "- Removed Lambda functions and layers"
echo "- Deleted CloudWatch Log Groups"
echo "- Removed Secrets Manager secrets"
echo "- Deleted SNS topics and subscriptions"
echo "- Removed CloudWatch Alarms"
echo "- Deleted RDS instances and related resources"
echo "- Removed DynamoDB tables"
echo "- Emptied and deleted S3 buckets"
echo "- Removed IAM roles and policies"
echo "- Deleted VPC and all associated resources"
echo "- Removed CloudFormation stacks"

echo -e "\n${YELLOW}Note: The Terraform state bucket '${PROJECT_NAME}-terraform-state' was not fully deleted to preserve${NC}"
echo -e "${YELLOW}state files for other environments. Only the ${STAGE}/ folder was cleaned up.${NC}"
echo -e "\n${BLUE}Cleanup process completed. For any remaining resources,${NC}"
echo -e "${BLUE}please check the AWS Management Console.${NC}"