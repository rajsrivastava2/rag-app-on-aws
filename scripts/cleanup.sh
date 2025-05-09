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
PROJECT_NAME=${PROJECT_NAME:-rag-app}
STAGE=${STAGE:-dev}
AWS_REGION=${AWS_REGION:-us-east-1}

# Standard prefix for resources
PREFIX="${PROJECT_NAME}-${STAGE}"

echo -e "\n${YELLOW}This script will DELETE ALL resources for:"
echo -e "  Project: ${PROJECT_NAME}"
echo -e "  Stage: ${STAGE}"
echo -e "  Region: ${AWS_REGION}${NC}"
echo -e "${RED}WARNING: This action is IRREVERSIBLE and will delete ALL data!${NC}"

# Proceed with confirmation unless AUTO_CONFIRM is true
if [[ "$AUTO_CONFIRM" != "true" ]]; then
    read -p "Are you sure you want to proceed? (yes/no): " CONFIRMATION
    if [[ $CONFIRMATION != "yes" ]]; then
        echo "Cleanup cancelled."
        exit 0
    fi
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
            # Check if S3 bucket exists - fixed to return just the bucket name
            if aws s3api head-bucket --bucket "$identifier" --region $AWS_REGION 2>/dev/null; then
                id="$identifier"  # Return just the bucket name
                exists=true
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
handle_lambda_eni_for_sg() {
    local sg_id="$1"
    local attached_enis="$2"
    
    for eni in $attached_enis; do
        eni_desc=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].Description" --output text)
        eni_status=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].Status" --output text)
        echo "ENI $eni info: $eni_desc (Status: $eni_status)"
        
        if [[ $eni_desc == *"Lambda"* ]]; then
            echo "This is a Lambda ENI. The Lambda function may have already been detached or deleted."
            echo "Attempting to force-detach the ENI if possible..."
            
            # Check if ENI has an attachment
            attachment_id=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null)
            
            if [ -n "$attachment_id" ] && [ "$attachment_id" != "None" ]; then
                echo "Found attachment: $attachment_id. Attempting to force-detach..."
                aws ec2 detach-network-interface --attachment-id $attachment_id --force --region $AWS_REGION 2>/dev/null || echo "Could not detach ENI attachment"
                
                # Wait a bit for the detachment to process
                echo "Waiting for detachment to process..."
                sleep 10
            fi
            
            # We'll also try to directly delete the ENI if possible
            echo "Attempting to delete the ENI directly..."
            aws ec2 delete-network-interface --network-interface-id $eni --region $AWS_REGION 2>/dev/null || echo "Could not delete ENI directly"
        fi
    done
    
    # Wait a bit for AWS to process any changes before next attempt
    sleep 10
}

# Function to find and clean up Lambda ENIs
cleanup_lambda_enis() {
    echo -e "\n${YELLOW}Finding and cleaning up Lambda ENIs...${NC}"
    
    # Find all Lambda ENIs across the account
    lambda_enis=$(aws ec2 describe-network-interfaces --filters "Name=description,Values=*Lambda*" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
    
    if [ -n "$lambda_enis" ]; then
        echo "Found Lambda ENIs: $lambda_enis"
        
        for eni in $lambda_enis; do
            eni_desc=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].Description" --output text)
            eni_status=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].Status" --output text)
            vpc_id=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].VpcId" --output text)
            
            # Only proceed if this ENI is in our project's VPC or has our project prefix in description
            if [[ $eni_desc == *"${PREFIX}"* ]]; then
                echo "Processing ENI $eni: $eni_desc (Status: $eni_status, VPC: $vpc_id)"
                
                # Extract Lambda function name from ENI description if possible
                lambda_name=$(echo $eni_desc | grep -o "${PREFIX}-[^-]*-[^-]*" || echo "")
                
                if [ -n "$lambda_name" ]; then
                    echo "ENI belongs to Lambda function: $lambda_name"
                    echo "Checking if Lambda function still exists..."
                    
                    # Check if Lambda function still exists
                    if aws lambda get-function --function-name "$lambda_name" --region $AWS_REGION &>/dev/null; then
                        echo "Lambda function exists. Removing VPC configuration..."
                        aws lambda update-function-configuration --function-name "$lambda_name" --vpc-config SubnetIds=[],SecurityGroupIds=[] --region $AWS_REGION \
                            || echo "Failed to update Lambda function configuration."
                    else
                        echo "Lambda function no longer exists or can't be accessed. Will try to detach ENI directly."
                    fi
                fi
                
                # Regardless of Lambda function status, try to detach/delete the ENI directly
                echo "Attempting to handle ENI directly..."
                
                # Get attachment info
                attachment_id=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null)
                
                if [ -n "$attachment_id" ] && [ "$attachment_id" != "None" ]; then
                    echo "ENI has attachment: $attachment_id. Attempting to force-detach..."
                    aws ec2 detach-network-interface --attachment-id $attachment_id --force --region $AWS_REGION --no-cli-pager 2>/dev/null \
                        || echo "Failed to detach ENI attachment. This may require manual intervention."
                    
                    # Wait for detachment to complete
                    echo "Waiting for detachment to complete..."
                    sleep 10
                fi
                
                # Try to delete the ENI directly (this may fail if ENI is managed by AWS)
                echo "Attempting to delete ENI directly..."
                aws ec2 delete-network-interface --network-interface-id $eni --region $AWS_REGION --no-cli-pager 2>/dev/null \
                    || echo "Failed to delete ENI directly. This may require manual intervention."
            else
                echo "Skipping ENI $eni as it doesn't appear to be related to our project."
            fi
        done
        
        # Wait for AWS to process ENI changes
        echo "Waiting for AWS to process ENI changes..."
        wait_with_message 60 "Waiting for AWS to process ENI operations..."
    else
        echo "No Lambda ENIs found."
    fi
}

# Function to handle Lambda functions with VPC access
handle_lambda_vpc_dependencies() {
    local vpc_id="$1"
    
    echo -e "\n${YELLOW}Identifying Lambda functions with VPC access...${NC}"
    
    # Find all Lambda functions with VPC configuration
    local vpc_lambdas=$(aws lambda list-functions --region $AWS_REGION --query "Functions[?VpcConfig.VpcId=='$vpc_id'].FunctionName" --output text)
    
    if [ -n "$vpc_lambdas" ]; then
        echo "Found Lambda functions with VPC access: $vpc_lambdas"
        
        for func in $vpc_lambdas; do
            echo "Updating Lambda function $func to remove VPC configuration..."
            
            # Update the function to remove VPC configuration
            run_command "aws lambda update-function-configuration --function-name $func --vpc-config SubnetIds=[],SecurityGroupIds=[] --region $AWS_REGION" \
                "Failed to remove VPC configuration from Lambda function: $func" \
                "Successfully removed VPC configuration from Lambda function: $func" \
                "true"
        done
        
        # Wait for the Lambda ENIs to be deleted (this can take some time)
        echo "Waiting for Lambda ENIs to be deleted..."
        wait_with_message 90 "Waiting for Lambda ENIs to be cleaned up (this may take a few minutes)..."
        
        # Check if ENIs are still around
        local remaining_enis=$(aws ec2 describe-network-interfaces --filters "Name=description,Values=*Lambda*" "Name=vpc-id,Values=$vpc_id" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
        
        if [ -n "$remaining_enis" ]; then
            echo -e "${YELLOW}Some Lambda ENIs still exist. Waiting longer for AWS to clean them up...${NC}"
            echo "Remaining ENIs: $remaining_enis"
            wait_with_message 120 "Extended wait for Lambda ENI cleanup..."
        fi
    else
        echo "No Lambda functions with VPC access found."
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

echo -e "\n${YELLOW}Step 4.5: Cleanup Lambda ENIs${NC}"
cleanup_lambda_enis

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
    # Check if function exists before trying to delete it
    function_name=$(aws lambda list-functions --region $AWS_REGION --query "Functions[?starts_with(FunctionName, '$func')].FunctionName" --output text 2>/dev/null || echo "")
    
    if [ -n "$function_name" ]; then
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
layer_versions=$(aws lambda list-layers --region $AWS_REGION --query "Layers[?starts_with(LayerName, '${PREFIX}')]" --output json 2>/dev/null)

if [ -n "$layer_versions" ] && [ "$layer_versions" != "[]" ]; then
    if [ $USE_JQ = true ]; then
        # Process with jq if available
        layer_names=$(echo $layer_versions | jq -r '.[].LayerName')
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
    log_group_exists=$(aws logs describe-log-groups --log-group-name-prefix "$log_group" --region $AWS_REGION --query "logGroups[0].logGroupName" --output text 2>/dev/null || echo "")
    
    if [ -n "$log_group_exists" ] && [ "$log_group_exists" != "None" ]; then
        echo "Found Log Group: $log_group_exists"
        run_command "aws logs delete-log-group --log-group-name \"$log_group_exists\" --region $AWS_REGION" \
            "Failed to delete Log Group: $log_group_exists" \
            "Successfully deleted Log Group: $log_group_exists"
    else
        echo "Log Group not found: $log_group"
    fi
done

# Delete API Gateway log group
api_log_group="/aws/apigateway/${PREFIX}-api"
log_group_exists=$(aws logs describe-log-groups --log-group-name-prefix "$api_log_group" --region $AWS_REGION --query "logGroups[0].logGroupName" --output text 2>/dev/null || echo "")

if [ -n "$log_group_exists" ] && [ "$log_group_exists" != "None" ]; then
    echo "Found API Gateway Log Group: $log_group_exists"
    run_command "aws logs delete-log-group --log-group-name \"$log_group_exists\" --region $AWS_REGION" \
        "Failed to delete API Gateway Log Group: $log_group_exists" \
        "Successfully deleted API Gateway Log Group: $log_group_exists"
else
    echo "API Gateway Log Group not found: $api_log_group"
fi

# Delete VPC flow logs group if it exists
vpc_flow_log_group="/aws/vpc/flowlogs/${PREFIX}"
log_group_exists=$(aws logs describe-log-groups --log-group-name-prefix "$vpc_flow_log_group" --region $AWS_REGION --query "logGroups[0].logGroupName" --output text 2>/dev/null || echo "")

if [ -n "$log_group_exists" ] && [ "$log_group_exists" != "None" ]; then
    echo "Found VPC Flow Log Group: $log_group_exists"
    run_command "aws logs delete-log-group --log-group-name \"$log_group_exists\" --region $AWS_REGION" \
        "Failed to delete VPC Flow Log Group: $log_group_exists" \
        "Successfully deleted VPC Flow Log Group: $log_group_exists"
else
    echo "VPC Flow Log Group not found: $vpc_flow_log_group"
fi

echo -e "\n${YELLOW}Step 7: Delete Secrets Manager secrets${NC}"
SECRETS=(
    "${PREFIX}-db-credentials"
    "${PREFIX}-gemini-api-key"
)

for secret in "${SECRETS[@]}"; do
    # Check if secret exists before trying to delete it
    secret_exists=$(aws secretsmanager list-secrets --region $AWS_REGION --query "SecretList[?Name=='$secret'].Name" --output text 2>/dev/null || echo "")
    
    if [ -n "$secret_exists" ]; then
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
db_exists=$(aws rds describe-db-instances --region $AWS_REGION --query "DBInstances[?DBInstanceIdentifier=='$DB_INSTANCE'].DBInstanceIdentifier" --output text 2>/dev/null || echo "")

if [ -n "$db_exists" ]; then
    echo "Found RDS instance: $db_exists"
    
    # 1. Disable deletion protection first if enabled
    protection=$(aws rds describe-db-instances --db-instance-identifier $db_exists --region $AWS_REGION --query "DBInstances[0].DeletionProtection" --output text)
    
    if [ "$protection" = "true" ]; then
        echo "RDS instance has deletion protection enabled. Disabling..."
        run_command "aws rds modify-db-instance --db-instance-identifier $db_exists --no-deletion-protection --apply-immediately --region $AWS_REGION" \
            "Failed to disable deletion protection for RDS instance: $db_exists" \
            "Successfully disabled deletion protection for RDS instance: $db_exists"
        
        # Wait for the modification to complete
        echo "Waiting for modification to complete..."
        run_command "aws rds wait db-instance-available --db-instance-identifier $db_exists --region $AWS_REGION" \
            "Failed to wait for RDS instance modification" \
            "RDS instance modification completed"
    fi
    
    # 2. Delete DB instance, skipping final snapshot and deleting automated backups
    echo "Deleting RDS instance: $db_exists"
    run_command "aws rds delete-db-instance --db-instance-identifier $db_exists --skip-final-snapshot --delete-automated-backups --region $AWS_REGION" \
        "Failed to delete RDS instance: $db_exists" \
        "Successfully initiated deletion of RDS instance: $db_exists"
    
    # Wait for DB instance to be deleted before continuing
    echo "Waiting for RDS instance deletion to complete (this may take several minutes)..."
    wait_with_message 60 "Waiting for RDS instance deletion (checking every 60 seconds)..."
    
    # We'll use a loop to check status with increasing wait times
    for attempt in {1..10}; do
        status=$(aws rds describe-db-instances --db-instance-identifier $db_exists --region $AWS_REGION --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null || echo "deleted")
        
        if [ "$status" = "deleted" ] || [ -z "$status" ]; then
            echo -e "${GREEN}RDS instance deletion completed.${NC}"
            break
        else
            echo "RDS instance status: $status. Waiting longer..."
            wait_time=$((30 + $attempt * 30))  # Increasing wait time with each attempt
            wait_with_message $wait_time "Still waiting for RDS deletion to complete..."
        fi
    done
else
    echo "RDS instance not found: $DB_INSTANCE"
fi

# Delete parameter group (regardless of whether instance was found)
param_group_exists=$(aws rds describe-db-parameter-groups --region $AWS_REGION --query "DBParameterGroups[?DBParameterGroupName=='$DB_PARAM_GROUP'].DBParameterGroupName" --output text 2>/dev/null || echo "")

if [ -n "$param_group_exists" ]; then
    echo "Found DB parameter group: $param_group_exists"
    run_command "aws rds delete-db-parameter-group --db-parameter-group-name $param_group_exists --region $AWS_REGION" \
        "Failed to delete DB parameter group: $param_group_exists" \
        "Successfully deleted DB parameter group: $param_group_exists" \
        "true"
else
    echo "DB parameter group not found: $DB_PARAM_GROUP"
fi

# Delete subnet group (regardless of whether instance was found)
subnet_group_exists=$(aws rds describe-db-subnet-groups --region $AWS_REGION --query "DBSubnetGroups[?DBSubnetGroupName=='$DB_SUBNET_GROUP'].DBSubnetGroupName" --output text 2>/dev/null || echo "")

if [ -n "$subnet_group_exists" ]; then
    echo "Found DB subnet group: $subnet_group_exists"
    run_command "aws rds delete-db-subnet-group --db-subnet-group-name $subnet_group_exists --region $AWS_REGION" \
        "Failed to delete DB subnet group: $subnet_group_exists" \
        "Successfully deleted DB subnet group: $subnet_group_exists" \
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
    table_exists=$(aws dynamodb list-tables --region $AWS_REGION --query "TableNames[?contains(@, '$table')]" --output text 2>/dev/null || echo "")
    
    if [ -n "$table_exists" ]; then
        echo "Found DynamoDB table: $table_exists"
        run_command "aws dynamodb delete-table --table-name $table_exists --region $AWS_REGION" \
            "Failed to delete DynamoDB table: $table_exists" \
            "Successfully deleted DynamoDB table: $table_exists"
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
    # Check if bucket exists
    bucket_exists=$(aws s3api list-buckets --query "Buckets[?Name=='$bucket'].Name" --output text 2>/dev/null || echo "")
    
    if [ -n "$bucket_exists" ]; then
        echo "Found S3 bucket: $bucket_exists"
        
        # Check if bucket versioning is enabled
        versioning=$(aws s3api get-bucket-versioning --bucket $bucket_exists --region $AWS_REGION --query "Status" --output text 2>/dev/null || echo "")
        
        # Disable versioning first if enabled
        if [ "$versioning" = "Enabled" ]; then
            echo "Bucket versioning is enabled. Suspending..."
            run_command "aws s3api put-bucket-versioning --bucket $bucket_exists --versioning-configuration Status=Suspended --region $AWS_REGION" \
                "Failed to suspend bucket versioning for: $bucket_exists" \
                "Successfully suspended versioning for bucket: $bucket_exists" \
                "true"
        fi
        
        # Special handling for terraform state bucket
        if [[ $bucket == *"terraform-state"* ]]; then
            echo "This is a terraform state bucket. Will only remove objects for stage: ${STAGE}"
            echo "Deleting objects under stage prefix: ${STAGE}/"
            run_command "aws s3 rm s3://$bucket_exists/$STAGE/ --recursive --region $AWS_REGION" \
                "Failed to delete terraform state objects" \
                "Successfully deleted terraform state objects" \
                "true"
            
            # Don't delete the terraform state bucket, just move on
            echo "Skipping deletion of terraform state bucket to preserve other environments"
            continue
        fi
        
        echo "Emptying bucket: $bucket_exists"
        
        # Step 1: Remove all standard objects first
        run_command "aws s3 rm s3://$bucket_exists --recursive --region $AWS_REGION" \
            "Failed to delete standard objects from bucket: $bucket_exists" \
            "Deleted standard objects from bucket: $bucket_exists" \
            "true"
        
        # Step 2: Delete all versions and delete markers if versioning was enabled
        if [ "$versioning" = "Enabled" ] || [ "$versioning" = "Suspended" ]; then
            echo "Checking for object versions and delete markers..."
            
            if [ $USE_JQ = true ]; then
                # Use jq to process versions
                versions_json=$(aws s3api list-object-versions --bucket $bucket_exists --region $AWS_REGION --output json 2>/dev/null)
                
                # Process versions
                version_keys=$(echo "$versions_json" | jq -r '.Versions[]? | "\(.Key)|\(.VersionId)"' 2>/dev/null || echo "")
                for version_info in $version_keys; do
                    IFS='|' read -r key version_id <<< "$version_info"
                    if [ -n "$key" ] && [ -n "$version_id" ]; then
                        echo "Deleting version: $key ($version_id)"
                        run_command "aws s3api delete-object --bucket $bucket_exists --key \"$key\" --version-id \"$version_id\" --region $AWS_REGION" \
                            "" "" "true"
                    fi
                done
                
                # Process delete markers
                marker_keys=$(echo "$versions_json" | jq -r '.DeleteMarkers[]? | "\(.Key)|\(.VersionId)"' 2>/dev/null || echo "")
                for marker_info in $marker_keys; do
                    IFS='|' read -r key version_id <<< "$marker_info"
                    if [ -n "$key" ] && [ -n "$version_id" ]; then
                        echo "Deleting delete marker: $key ($version_id)"
                        run_command "aws s3api delete-object --bucket $bucket_exists --key \"$key\" --version-id \"$version_id\" --region $AWS_REGION" \
                            "" "" "true"
                    fi
                done
            else
                # Alternative approach without jq
                echo "Processing without jq - this may not delete all versions"
                aws s3api list-object-versions --bucket $bucket_exists --region $AWS_REGION --output text | \
                grep -E 'VERSIONS|DELETE' | while read -r line; do
                    key=$(echo "$line" | awk '{print $4}')
                    version_id=$(echo "$line" | awk '{print $6}')
                    if [ -n "$key" ] && [ -n "$version_id" ]; then
                        echo "Deleting object: $key ($version_id)"
                        aws s3api delete-object --bucket $bucket_exists --key "$key" --version-id "$version_id" --region $AWS_REGION >/dev/null 2>&1
                    fi
                done
            fi
        fi
        
        # Step 3: Final check to make sure bucket is empty
        echo "Performing final verification that bucket is empty..."
        run_command "aws s3 rm s3://$bucket_exists --recursive --region $AWS_REGION" \
            "Failed during final cleanup check" \
            "Bucket verified empty" \
            "true"
        
        # Step 4: Delete the bucket
        echo "Deleting bucket: $bucket_exists"
        run_command "aws s3api delete-bucket --bucket $bucket_exists --region $AWS_REGION" \
            "Failed to delete bucket: $bucket_exists" \
            "Successfully deleted bucket: $bucket_exists"
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

echo -e "\n${YELLOW}Step 14: Clean up specific security groups${NC}"
# List of specific security groups to target
SECURITY_GROUPS=(
    "${PREFIX}-bastion-sg"   # Bastion host security group
    "${PREFIX}-db-sg"        # Database security group 
    "${PREFIX}-lambda-sg"    # Lambda function security group
)

# Get the VPC ID for filtering
vpc_id=$(aws ec2 describe-vpcs --region $AWS_REGION --filters "Name=tag:Name,Values=${PREFIX}-vpc" --query "Vpcs[0].VpcId" --output text 2>/dev/null)

if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
    echo "Looking up VPC with alternative methods..."
    vpc_id=$(aws ec2 describe-vpcs --region $AWS_REGION --query "Vpcs[?Tags[?Value=='${PREFIX}-vpc']].VpcId" --output text 2>/dev/null)
    
    if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
        echo "Attempting to find VPC ID from existing resources..."
        # Try to find the VPC ID by looking up a known security group
        sg_info=$(aws ec2 describe-security-groups --region $AWS_REGION --filters "Name=group-name,Values=${PREFIX}-*" --query "SecurityGroups[0].VpcId" --output text 2>/dev/null)
        if [ -n "$sg_info" ] && [ "$sg_info" != "None" ]; then
            vpc_id=$sg_info
        fi
    fi
fi

if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
    echo -e "${RED}Could not find a VPC. Proceeding with security group cleanup without VPC filtering.${NC}"
    # Build a list of SG IDs without VPC filtering
    echo "Looking up security groups by name..."
    SG_IDS=()
    for sg_name in "${SECURITY_GROUPS[@]}"; do
        if [[ $sg_name == *"*"* ]]; then
            # Handle wildcard pattern
            pattern=${sg_name//\*/}
            found_sgs=$(aws ec2 describe-security-groups --region $AWS_REGION --query "SecurityGroups[?contains(GroupName, '$pattern')].GroupId" --output text)
            for sg in $found_sgs; do
                SG_IDS+=("$sg")
            done
        else
            # Exact match
            sg_id=$(aws ec2 describe-security-groups --region $AWS_REGION --filters "Name=group-name,Values=$sg_name" --query "SecurityGroups[0].GroupId" --output text)
            if [ -n "$sg_id" ] && [ "$sg_id" != "None" ]; then
                SG_IDS+=("$sg_id")
            fi
        fi
    done
else
    echo -e "${GREEN}Found VPC: $vpc_id${NC}"
    # Build a list of SG IDs with VPC filtering
    echo "Looking up security groups in VPC $vpc_id..."
    SG_IDS=()
    for sg_name in "${SECURITY_GROUPS[@]}"; do
        if [[ $sg_name == *"*"* ]] || [[ $sg_name == default ]]; then
            # Handle wildcard pattern or special cases
            pattern=${sg_name//\*/}
            found_sgs=$(aws ec2 describe-security-groups --region $AWS_REGION --filters "Name=vpc-id,Values=$vpc_id" --query "SecurityGroups[?contains(GroupName, '$pattern')].GroupId" --output text)
            for sg in $found_sgs; do
                SG_IDS+=("$sg")
            done
        else
            # Exact match
            sg_id=$(aws ec2 describe-security-groups --region $AWS_REGION --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=$sg_name" --query "SecurityGroups[0].GroupId" --output text)
            if [ -n "$sg_id" ] && [ "$sg_id" != "None" ]; then
                SG_IDS+=("$sg_id")
            fi
        fi
    done
fi

# Show found security group IDs
echo -e "\n${BLUE}Found Security Groups:${NC}"
for sg_id in "${SG_IDS[@]}"; do
    sg_info=$(aws ec2 describe-security-groups --group-ids $sg_id --region $AWS_REGION --query "SecurityGroups[0].[GroupId, GroupName]" --output text 2>/dev/null)
    echo "$sg_info"
done

# Special checks for dependencies
echo -e "\n${YELLOW}Checking for security group dependencies...${NC}"
for sg_id in "${SG_IDS[@]}"; do
    # Skip empty IDs
    if [ -z "$sg_id" ]; then
        continue
    fi
    
    # Check if this SG is referenced by other SGs
    echo "Checking references to: $sg_id"
    references=$(aws ec2 describe-security-group-references --group-id $sg_id --region $AWS_REGION --query "SecurityGroupReferenceSet[].ReferencingSecurityGroups[].GroupId" --output text 2>/dev/null || echo "")
    
    if [ -n "$references" ]; then
        echo "Security group $sg_id is referenced by: $references"
        for ref_sg in $references; do
            echo "Will need to handle reference from $ref_sg to $sg_id"
        done
    fi
done

# Build a dependency map to determine deletion order
echo -e "\n${YELLOW}Building dependency map for proper deletion order...${NC}"
declare -A DEPENDS_ON
for sg_id in "${SG_IDS[@]}"; do
    # Skip empty IDs
    if [ -z "$sg_id" ]; then
        continue
    fi
    
    # Check for dependencies in ingress rules
    ingress_deps=$(aws ec2 describe-security-groups --group-ids $sg_id --region $AWS_REGION --query "SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId" --output text 2>/dev/null || echo "")
    
    if [ -n "$ingress_deps" ]; then
        DEPENDS_ON[$sg_id]=$ingress_deps
        echo "SG $sg_id depends on: $ingress_deps"
    fi
done

# First pass: Remove all cross-references between security groups
echo -e "\n${YELLOW}First pass: Removing security group cross-references...${NC}"
for sg_id in "${SG_IDS[@]}"; do
    # Skip empty IDs
    if [ -z "$sg_id" ]; then
        continue
    fi
    
    echo "Processing security group: $sg_id"
    
    # Get all ingress rules that reference other security groups
    ingress_sg_rules=$(aws ec2 describe-security-groups --group-ids $sg_id --query "SecurityGroups[0].IpPermissions[?UserIdGroupPairs[0].GroupId != null]" --output json --region $AWS_REGION 2>/dev/null || echo "[]")
    
    # Check if we got valid rules
    if [ "$ingress_sg_rules" != "[]" ] && [ "$ingress_sg_rules" != "null" ]; then
        echo "Removing ingress rules referencing other security groups..."
        run_command "aws ec2 revoke-security-group-ingress --group-id $sg_id --ip-permissions '$ingress_sg_rules' --region $AWS_REGION" \
            "Failed to remove ingress rules" \
            "Successfully removed ingress rules referencing other security groups" \
            "true"
    fi
    
    # Get all egress rules that reference other security groups
    egress_sg_rules=$(aws ec2 describe-security-groups --group-ids $sg_id --query "SecurityGroups[0].IpPermissionsEgress[?UserIdGroupPairs[0].GroupId != null]" --output json --region $AWS_REGION 2>/dev/null || echo "[]")
    
    # Check if we got valid rules
    if [ "$egress_sg_rules" != "[]" ] && [ "$egress_sg_rules" != "null" ]; then
        echo "Removing egress rules referencing other security groups..."
        run_command "aws ec2 revoke-security-group-egress --group-id $sg_id --ip-permissions '$egress_sg_rules' --region $AWS_REGION" \
            "Failed to remove egress rules" \
            "Successfully removed egress rules referencing other security groups" \
            "true"
    fi
done

# Wait for AWS to process the changes
wait_with_message 5 "Waiting for AWS to process rule removals..."

# Second pass: Remove all remaining rules
echo -e "\n${YELLOW}Second pass: Removing all remaining rules...${NC}"
for sg_id in "${SG_IDS[@]}"; do
    # Skip empty IDs
    if [ -z "$sg_id" ]; then
        continue
    fi
    
    # Skip default SG - we don't want to modify default SG rules
    sg_name=$(aws ec2 describe-security-groups --group-ids $sg_id --region $AWS_REGION --query "SecurityGroups[0].GroupName" --output text 2>/dev/null)
    if [ "$sg_name" = "default" ]; then
        echo "Skipping rule removal for default security group: $sg_id"
        continue
    fi
    
    echo "Removing all remaining rules from: $sg_id"
    
    # Get all remaining ingress rules
    remaining_ingress=$(aws ec2 describe-security-groups --group-ids $sg_id --query "SecurityGroups[0].IpPermissions" --output json --region $AWS_REGION 2>/dev/null || echo "[]")
    
    if [ "$remaining_ingress" != "[]" ] && [ "$remaining_ingress" != "null" ]; then
        echo "Removing remaining ingress rules..."
        run_command "aws ec2 revoke-security-group-ingress --group-id $sg_id --ip-permissions '$remaining_ingress' --region $AWS_REGION" \
            "Failed to remove remaining ingress rules" \
            "Successfully removed all ingress rules" \
            "true"
    fi
    
    # Get all remaining egress rules (except the default "allow all outbound" rule)
    remaining_egress=$(aws ec2 describe-security-groups --group-ids $sg_id --query "SecurityGroups[0].IpPermissionsEgress[?!(IpProtocol == '-1' && CidrIp == '0.0.0.0/0')]" --output json --region $AWS_REGION 2>/dev/null || echo "[]")
    
    if [ "$remaining_egress" != "[]" ] && [ "$remaining_egress" != "null" ]; then
        echo "Removing remaining egress rules..."
        run_command "aws ec2 revoke-security-group-egress --group-id $sg_id --ip-permissions '$remaining_egress' --region $AWS_REGION" \
            "Failed to remove custom egress rules" \
            "Successfully removed custom egress rules" \
            "true"
    else
        echo "No custom egress rules found."
    fi
done

# Wait for AWS to process the changes
wait_with_message 5 "Waiting for AWS to process rule removals..."

# Third pass: Delete the security groups (except default)
# Third pass: Delete the security groups (except default)
echo -e "\n${YELLOW}Third pass: Deleting security groups...${NC}"
for sg_id in "${SG_IDS[@]}"; do
    # Skip empty IDs
    if [ -z "$sg_id" ]; then
        continue
    fi
    
    # Skip default SG - AWS doesn't allow deleting the default SG
    sg_name=$(aws ec2 describe-security-groups --group-ids $sg_id --region $AWS_REGION --query "SecurityGroups[0].GroupName" --output text 2>/dev/null)
    if [ "$sg_name" = "default" ]; then
        echo "Skipping deletion of default security group: $sg_id"
        continue
    fi
    
    echo "Deleting security group: $sg_id (Name: $sg_name)"
    
    # Make multiple attempts with increasing wait times
    deletion_succeeded=false
    for attempt in {1..5}; do
        # Check if the security group still exists before attempting to delete
        sg_exists=$(aws ec2 describe-security-groups --group-ids $sg_id --region $AWS_REGION 2>&1)
        if [ $? -ne 0 ]; then
            echo "Security group $sg_id no longer exists."
            deletion_succeeded=true
            break
        fi
        
        # Try to delete the security group
        if aws ec2 delete-security-group --group-id $sg_id --region $AWS_REGION 2>/dev/null; then
            echo -e "${GREEN}Successfully deleted security group: $sg_id${NC}"
            deletion_succeeded=true
            break
        else
            echo "Failed to delete security group on attempt $attempt. Investigating dependencies..."
            
            # Look for network interfaces attached to this security group
            attached_enis=$(aws ec2 describe-network-interfaces --filters "Name=group-id,Values=$sg_id" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
            
            if [ -n "$attached_enis" ]; then
                echo "Security group is attached to these network interfaces: $attached_enis"
                
                # If we're at the last attempt, print more detailed information to help with manual cleanup
                if [ $attempt -eq 5 ]; then
                    echo -e "${YELLOW}After 5 attempts, security group still has attachments. Details:${NC}"
                    for eni in $attached_enis; do
                        eni_desc=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].Description" --output text)
                        subnet_id=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].SubnetId" --output text)
                        attach_info=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].Attachment" --output json)
                        requester_id=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].RequesterId" --output text)
                        
                        echo "ENI: $eni"
                        echo "  Description: $eni_desc"
                        echo "  Subnet: $subnet_id"
                        echo "  Requester ID: $requester_id"
                        echo "  Attachment info: $attach_info"
                        echo ""
                    done
                    echo "You may need to manually delete these resources from the AWS Console."
                    echo "This is common with Lambda ENIs, which can take time to be fully released by AWS."
                fi
            fi
            
            # Wait longer between each attempt
            wait_seconds=$((30 * attempt))
            wait_with_message $wait_seconds "Waiting before retry attempt #$((attempt+1))..."
        fi
    done
    
    if [ "$deletion_succeeded" = false ]; then
        echo -e "${YELLOW}Warning: Unable to delete security group $sg_id after multiple attempts.${NC}"
        echo "You may need to check AWS console and manually delete this security group."
        echo "Consider running this cleanup script again after 15-30 minutes, as AWS may still be releasing resources."
    fi
done

echo -e "\n${GREEN}Security group cleanup process completed!${NC}"
echo "Any remaining security groups may require manual deletion through the AWS Console."


echo -e "\n${YELLOW}Step 15: Delete VPC and related resources${NC}"
# Lookup VPC by tag name
vpc_filter="Name=tag:Name,Values=${PREFIX}-vpc"
vpc_id=$(aws ec2 describe-vpcs --region $AWS_REGION --filters "$vpc_filter" --query "Vpcs[0].VpcId" --output text 2>/dev/null)

# If not found by tag name, try with a wildcard tag search
if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
    echo "VPC not found with specific tag, trying alternative search..."
    vpc_id=$(aws ec2 describe-vpcs --region $AWS_REGION --query "Vpcs[?Tags[?Value=='${PREFIX}-vpc']].VpcId" --output text 2>/dev/null)
fi

# If still not found, try finding any VPC that might be related to the project
if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
    echo "Checking for any VPC with resources matching our project..."
    
    # Look for subnets with project prefix in name
    subnet_check=$(aws ec2 describe-subnets --region $AWS_REGION --filters "Name=tag:Name,Values=*${PREFIX}*" --query "Subnets[0].VpcId" --output text 2>/dev/null)
    
    if [ -n "$subnet_check" ] && [ "$subnet_check" != "None" ]; then
        vpc_id=$subnet_check
        echo "Found VPC ($vpc_id) with subnets matching our project prefix"
    fi
fi

if [ -n "$vpc_id" ] && [ "$vpc_id" != "None" ]; then
    echo "Found VPC: $vpc_id. Starting cleanup of all associated resources..."
    
    vpc_lambda_enis=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" "Name=description,Values=*Lambda*" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
    
    if [ -n "$vpc_lambda_enis" ]; then
        echo -e "${YELLOW}Warning: There are still Lambda ENIs in this VPC after earlier cleanup attempts.${NC}"
        echo "This is a known issue with AWS Lambda VPC integration, where ENIs may take time to be fully released."
        echo "The script will continue, but VPC deletion may fail. If it does, wait 15-30 minutes and try again."
        
        # Print detailed information about remaining ENIs for debugging
        echo "Remaining Lambda ENIs:"
        for eni in $vpc_lambda_enis; do
            eni_info=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].[Description,Status,SubnetId]" --output text)
            echo "ENI $eni: $eni_info"
        done
    fi

    vpc_enis=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" "Name=description,Values=*Lambda*" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)

    if [ -n "$vpc_enis" ]; then
        echo "Found Lambda ENIs in the VPC: $vpc_enis"
        echo "Attempting to handle Lambda ENIs directly..."
        
        for eni in $vpc_enis; do
            eni_desc=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].Description" --output text)
            eni_status=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].Status" --output text)
            echo "ENI $eni info: $eni_desc (Status: $eni_status)"
            
            # Check for attachment
            attachment_id=$(aws ec2 describe-network-interfaces --network-interface-ids $eni --region $AWS_REGION --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null)
            
            if [ -n "$attachment_id" ] && [ "$attachment_id" != "None" ]; then
                echo "Attempting to force-detach ENI attachment: $attachment_id"
                aws ec2 detach-network-interface --attachment-id $attachment_id --force --region $AWS_REGION 2>/dev/null || echo "Failed to detach ENI"
                sleep 5
            fi
        done
        
        # Wait for ENI detachment to complete
        echo "Waiting for ENI detachments to complete..."
        wait_with_message 60 "Waiting for network interface detachments..."
    fi

    # First handle any Lambda functions with VPC access
    handle_lambda_vpc_dependencies "$vpc_id"

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

    # 2. Delete any load balancers in this VPC
    echo "Checking for load balancers in the VPC..."
    lb_arns=$(aws elbv2 describe-load-balancers --region $AWS_REGION --query "LoadBalancers[?VpcId=='$vpc_id'].LoadBalancerArn" --output text)
    
    if [ -n "$lb_arns" ]; then
        for lb_arn in $lb_arns; do
            echo "Deleting load balancer: $lb_arn"
            run_command "aws elbv2 delete-load-balancer --load-balancer-arn $lb_arn --region $AWS_REGION" \
                "Failed to delete load balancer" \
                "Successfully deleted load balancer" \
                "true"
        done
        # Wait for load balancers to be fully deleted
        sleep 20
    else
        echo "No load balancers found in the VPC."
    fi
    
    # 3. Check for and delete any VPC Lattice service networks
    echo "Checking for VPC Lattice service networks..."
    service_networks=$(aws vpc-lattice list-service-networks --region $AWS_REGION --query "items[?vpcId=='$vpc_id'].id" --output text 2>/dev/null || echo "")
    
    if [ -n "$service_networks" ]; then
        for sn_id in $service_networks; do
            echo "Deleting VPC Lattice service network: $sn_id"
            
            # First detach any services from the network
            services=$(aws vpc-lattice list-services-for-service-network --service-network-identifier $sn_id --region $AWS_REGION --query "items[].id" --output text 2>/dev/null || echo "")
            for svc_id in $services; do
                echo "Detaching service $svc_id from service network"
                run_command "aws vpc-lattice disassociate-service --service-identifier $svc_id --service-network-identifier $sn_id --region $AWS_REGION" "" "" "true"
            done
            
            # Then delete the service network
            run_command "aws vpc-lattice delete-service-network --service-network-identifier $sn_id --region $AWS_REGION" \
                "Failed to delete VPC Lattice service network" \
                "Successfully deleted VPC Lattice service network" \
                "true"
        done
        # Wait for service networks to be deleted
        sleep 10
    fi
    
    # 4. Delete NAT Gateways
    nat_gateways=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_id" --query "NatGateways[?State!='deleted'].NatGatewayId" --output text --region $AWS_REGION)
    
    if [ -n "$nat_gateways" ]; then
        for nat_id in $nat_gateways; do
            echo "Deleting NAT Gateway: $nat_id"
            run_command "aws ec2 delete-nat-gateway --nat-gateway-id $nat_id --region $AWS_REGION" \
                "Failed to delete NAT Gateway: $nat_id" \
                "Successfully initiated deletion of NAT Gateway: $nat_id" \
                "true"
        done
        
        # Wait for NAT gateways to be deleted - this can take a while
        echo "Waiting for NAT gateways to be deleted (this may take a few minutes)..."
        wait_with_message 60 "Waiting for NAT gateway deletion..."
        
        # Verify NAT gateway deletion
        for attempt in {1..5}; do
            active_nats=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_id" --query "NatGateways[?State!='deleted' && State!='deleting'].NatGatewayId" --output text --region $AWS_REGION)
            if [ -z "$active_nats" ]; then
                echo "All NAT gateways have been deleted."
                break
            else
                echo "NAT gateways still being deleted. Waiting longer..."
                wait_with_message 30 "Continuing to wait..."
            fi
        done
    else
        echo "No NAT Gateways found in the VPC."
    fi
    
    # 5. Find and release Elastic IPs
    echo "Finding and releasing Elastic IPs associated with VPC resources..."
    
    # Get all ENIs in the VPC
    enis=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
    
    for eni in $enis; do
        eips=$(aws ec2 describe-addresses --filters "Name=network-interface-id,Values=$eni" --query "Addresses[].AllocationId" --output text --region $AWS_REGION)
        
        for eip in $eips; do
            if [ -n "$eip" ]; then
                echo "Releasing Elastic IP: $eip"
                run_command "aws ec2 release-address --allocation-id $eip --region $AWS_REGION" \
                    "Failed to release Elastic IP" \
                    "Successfully released Elastic IP" \
                    "true"
            fi
        done
    done
    
    # 6. Delete VPC Endpoints
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

    # 7. Check for and delete Transit Gateway VPC attachments
    echo "Checking for Transit Gateway attachments..."
    tgw_attachments=$(aws ec2 describe-transit-gateway-vpc-attachments --region $AWS_REGION --query "TransitGatewayVpcAttachments[?VpcId=='$vpc_id'].TransitGatewayAttachmentId" --output text 2>/dev/null || echo "")
    
    if [ -n "$tgw_attachments" ]; then
        for attachment in $tgw_attachments; do
            echo "Deleting Transit Gateway attachment: $attachment"
            run_command "aws ec2 delete-transit-gateway-vpc-attachment --transit-gateway-attachment-id $attachment --region $AWS_REGION" \
                "Failed to delete Transit Gateway attachment" \
                "Successfully initiated deletion of Transit Gateway attachment" \
                "true"
        done
        
        # Wait for TGW attachments to be deleted
        echo "Waiting for Transit Gateway attachments to be deleted..."
        wait_with_message 30 "Waiting for TGW attachments to be deleted..."
    fi
    
    # 8. Find and handle special network interfaces (like Elastic Load Balancer interfaces)
    echo "Finding and identifying network interfaces with special attachments..."
    
    # First, get all network interfaces in the VPC
    network_interfaces=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
    
    if [ -n "$network_interfaces" ]; then
        # Check each interface to classify it for handling
        for eni_id in $network_interfaces; do
            # Get the description and attachment information
            eni_desc=$(aws ec2 describe-network-interfaces --network-interface-ids $eni_id --query "NetworkInterfaces[0].Description" --output text --region $AWS_REGION)
            attachment_id=$(aws ec2 describe-network-interfaces --network-interface-ids $eni_id --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text --region $AWS_REGION)
            
            echo "Processing Network Interface: $eni_id - Description: $eni_desc"
            
            # Check if this is an AWS service-managed ENI
            if [[ $eni_desc == *"ELB"* ]] || [[ $eni_desc == *"Amazon"* ]] || [[ $eni_desc == *"AWS"* ]] || [[ $attachment_id == *"ela-attach"* ]]; then
                echo "This appears to be an AWS service-managed ENI. Identifying the service..."
                
                if [[ $eni_desc == *"ELB"* ]]; then
                    echo "This appears to be an Elastic Load Balancer ENI."
                    echo "Try to find and delete the associated load balancer first."
                elif [[ $attachment_id == *"ela-attach"* ]]; then
                    echo "This has an AWS Elastic Network Interface attachment which cannot be detached directly."
                    echo "Need to identify and remove the service using this interface."
                fi
                
                # Try to identify VPC Endpoint interfaces
                # Look for any VPC Gateway Endpoint that might be using this ENI
                if [[ $eni_desc == *"endpoint"* ]] || [[ $eni_desc == *"Endpoint"* ]]; then
                    endpoints=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc_id" --query "VpcEndpoints[].VpcEndpointId" --output text --region $AWS_REGION)
                    if [ -n "$endpoints" ]; then
                        echo "Found VPC Endpoints that might be associated with this ENI. Attempting to delete them again."
                        run_command "aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $endpoints --region $AWS_REGION" "" "" "true"
                        wait_with_message 20 "Waiting after endpoint deletion attempt..."
                    fi
                fi
                
                # Continue to the next ENI as we can't directly manage this one
                continue
            fi
            
            # For standard ENIs, attempt to detach and delete
            if [ -n "$attachment_id" ] && [ "$attachment_id" != "None" ]; then
                echo "Attempting to detach standard network interface: $eni_id"
                run_command "aws ec2 detach-network-interface --attachment-id $attachment_id --force --region $AWS_REGION" \
                    "Failed to detach network interface" \
                    "Successfully detached network interface" \
                    "true"
                
                # Wait for detachment to complete
                echo "Waiting for detachment to complete..."
                sleep 15
            fi
            
            # Try to delete the ENI
            echo "Attempting to delete Network Interface: $eni_id"
            run_command "aws ec2 delete-network-interface --network-interface-id $eni_id --region $AWS_REGION" \
                "Failed to delete network interface: $eni_id" \
                "Successfully deleted network interface: $eni_id" \
                "true"
        done
    else
        echo "No Network Interfaces found."
    fi
    
    # 9. Delete VPC peering connections
    echo "Finding and deleting VPC peering connections..."
    # Check both as requester and accepter
    peering_connections=$(aws ec2 describe-vpc-peering-connections --region $AWS_REGION --query "VpcPeeringConnections[?VpcId=='$vpc_id' || AccepterVpcInfo.VpcId=='$vpc_id' || RequesterVpcInfo.VpcId=='$vpc_id'].VpcPeeringConnectionId" --output text)
    
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
    
    # 10. Delete security groups (except default)
    echo "Finding and deleting security groups..."
    security_groups=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=!default" --query "SecurityGroups[].GroupId" --output text --region $AWS_REGION)

    if [ -n "$security_groups" ]; then
        # First pass: Remove all references between security groups to break dependencies
        echo "First removing security group cross-references to break dependencies..."
        for sg_id in $security_groups; do
            echo "Removing rules from security group: $sg_id"
            
            # Get all ingress rules that reference other security groups
            ingress_sg_rules=$(aws ec2 describe-security-groups --group-ids $sg_id --query "SecurityGroups[0].IpPermissions[?UserIdGroupPairs[0].GroupId != null]" --output json --region $AWS_REGION 2>/dev/null || echo "[]")
            
            # Check if we got valid rules
            if [ "$ingress_sg_rules" != "[]" ] && [ "$ingress_sg_rules" != "null" ]; then
                echo "Removing ingress rules referencing other security groups..."
                run_command "aws ec2 revoke-security-group-ingress --group-id $sg_id --ip-permissions '$ingress_sg_rules' --region $AWS_REGION" \
                    "" \
                    "Successfully removed ingress rules referencing other security groups" \
                    "true"
            fi
            
            # Get all egress rules that reference other security groups
            egress_sg_rules=$(aws ec2 describe-security-groups --group-ids $sg_id --query "SecurityGroups[0].IpPermissionsEgress[?UserIdGroupPairs[0].GroupId != null]" --output json --region $AWS_REGION 2>/dev/null || echo "[]")
            
            # Check if we got valid rules
            if [ "$egress_sg_rules" != "[]" ] && [ "$egress_sg_rules" != "null" ]; then
                echo "Removing egress rules referencing other security groups..."
                run_command "aws ec2 revoke-security-group-egress --group-id $sg_id --ip-permissions '$egress_sg_rules' --region $AWS_REGION" \
                    "" \
                    "Successfully removed egress rules referencing other security groups" \
                    "true"
            fi
        done
        
        # Second pass: Remove all remaining rules
        echo "Removing all remaining rules from security groups..."
        for sg_id in $security_groups; do
            # Get all remaining ingress rules
            remaining_ingress=$(aws ec2 describe-security-groups --group-ids $sg_id --query "SecurityGroups[0].IpPermissions" --output json --region $AWS_REGION 2>/dev/null || echo "[]")
            
            if [ "$remaining_ingress" != "[]" ] && [ "$remaining_ingress" != "null" ]; then
                echo "Removing remaining ingress rules from $sg_id..."
                run_command "aws ec2 revoke-security-group-ingress --group-id $sg_id --ip-permissions '$remaining_ingress' --region $AWS_REGION" \
                    "" \
                    "Successfully removed all ingress rules" \
                    "true"
            fi
            
            # Get all remaining egress rules (except the default "allow all outbound" rule)
            remaining_egress=$(aws ec2 describe-security-groups --group-ids $sg_id --query "SecurityGroups[0].IpPermissionsEgress[?!(IpProtocol == '-1' && CidrIp == '0.0.0.0/0')]" --output json --region $AWS_REGION 2>/dev/null || echo "[]")
            
            if [ "$remaining_egress" != "[]" ] && [ "$remaining_egress" != "null" ]; then
                echo "Removing remaining egress rules from $sg_id..."
                run_command "aws ec2 revoke-security-group-egress --group-id $sg_id --ip-permissions '$remaining_egress' --region $AWS_REGION" \
                    "" \
                    "Successfully removed custom egress rules" \
                    "true"
            fi
        done
        
        # Third pass: Delete the security groups
        echo "Deleting security groups..."
        for sg_id in $security_groups; do
            echo "Deleting security group: $sg_id"
            
            # Make multiple attempts with increasing wait times
            deletion_succeeded=false
            for attempt in {1..3}; do
                if run_command "aws ec2 delete-security-group --group-id $sg_id --region $AWS_REGION" \
                    "" \
                    "Successfully deleted security group: $sg_id" \
                    "true"; then
                    deletion_succeeded=true
                    break
                else
                    echo "Failed to delete security group on attempt $attempt. Waiting before retry..."
                    wait_with_message $((5 * attempt)) "Waiting before retry..."
                    
                    # Check if the security group still has dependencies
                    dependencies=$(aws ec2 describe-security-group-references --group-id $sg_id --region $AWS_REGION --query "SecurityGroupReferenceSet[].ReferencingSecurityGroups[].GroupId" --output text 2>/dev/null || echo "")
                    
                    if [ -n "$dependencies" ]; then
                        echo "Security group $sg_id is referenced by: $dependencies"
                        for dep_sg in $dependencies; do
                            echo "Attempting to remove references from $dep_sg to $sg_id..."
                            # Try to remove any remaining references
                            dep_rules=$(aws ec2 describe-security-groups --group-ids $dep_sg --query "SecurityGroups[0].IpPermissions[?UserIdGroupPairs[?GroupId=='$sg_id']]" --output json --region $AWS_REGION 2>/dev/null || echo "[]")
                            if [ "$dep_rules" != "[]" ] && [ "$dep_rules" != "null" ]; then
                                run_command "aws ec2 revoke-security-group-ingress --group-id $dep_sg --ip-permissions '$dep_rules' --region $AWS_REGION" "" "" "true"
                            fi
                        done
                    fi
                fi
            done
            
            if [ "$deletion_succeeded" = false ]; then
                echo -e "${YELLOW}Warning: Unable to delete security group $sg_id after multiple attempts.${NC}"
            fi
        done
    else
        echo "No non-default security groups found in VPC."
    fi
    
    # 11. Identify dependencies first for problem subnets
    echo "Checking for dependencies on subnets..."
    subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --query "Subnets[].SubnetId" --output text --region $AWS_REGION)
    
    for subnet_id in $subnets; do
        # Check what might be using this subnet
        echo "Analyzing subnet dependencies for: $subnet_id"
        
        # Look for ENIs in the subnet
        subnet_enis=$(aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=$subnet_id" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
        
        if [ -n "$subnet_enis" ]; then
            echo "Found network interfaces in subnet: $subnet_enis"
            for eni_id in $subnet_enis; do
                eni_desc=$(aws ec2 describe-network-interfaces --network-interface-ids $eni_id --query "NetworkInterfaces[0].Description" --output text --region $AWS_REGION)
                echo "ENI $eni_id: $eni_desc"
                
                # Try a more forceful delete of managed ENIs
                if [[ $eni_desc == *"ELB"* ]] || [[ $eni_desc == *"load balancer"* ]]; then
                    echo "Looking for ELBs that might own this ENI..."
                    elbs=$(aws elbv2 describe-load-balancers --region $AWS_REGION --query "LoadBalancers[?VpcId=='$vpc_id'].LoadBalancerArn" --output text)
                    for elb in $elbs; do
                        echo "Forcefully deleting ELB: $elb"
                        run_command "aws elbv2 delete-load-balancer --load-balancer-arn $elb --region $AWS_REGION" "" "" "true"
                    done
                fi
                
                # For Interface VPC Endpoints, try again with a stronger approach
                if [[ $eni_desc == *"endpoint"* ]] || [[ $eni_desc == *"Endpoint"* ]]; then
                    endpoints=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc_id" --query "VpcEndpoints[].VpcEndpointId" --output text --region $AWS_REGION)
                    for endpoint in $endpoints; do
                        echo "Forcefully deleting VPC endpoint: $endpoint"
                        run_command "aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $endpoint --region $AWS_REGION" "" "" "true"
                    done
                    wait_with_message 15 "Waiting after endpoint deletion attempt..."
                fi
            done
        fi
        
        # Check for RDS instances in this subnet
        rds_instances=$(aws rds describe-db-instances --region $AWS_REGION --query "DBInstances[?DBSubnetGroup.Subnets[?SubnetIdentifier=='$subnet_id']].DBInstanceIdentifier" --output text 2>/dev/null || echo "")
        if [ -n "$rds_instances" ]; then
            echo "Found RDS instances using subnet: $rds_instances"
            echo "Manually delete these RDS instances first."
        fi
    done
    
    # 12. Wait a bit to allow any background deletions to complete
    echo "Waiting for background operations to complete..."
    wait_with_message 30 "Waiting before trying subnet deletion again..."
    
    # 13. Try to delete subnets again
    echo "Attempting to delete subnets..."
    subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --query "Subnets[].SubnetId" --output text --region $AWS_REGION)
    
    for subnet_id in $subnets; do
        echo "Deleting Subnet: $subnet_id"
        run_command "aws ec2 delete-subnet --subnet-id $subnet_id --region $AWS_REGION" \
            "Failed to delete subnet: $subnet_id" \
            "Successfully deleted subnet: $subnet_id" \
            "true"
    done
    
    # 14. Delete route tables (except the main one)
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
    
    # 15. Delete Network ACLs (except default)
    echo "Finding and deleting network ACLs..."
    network_acls=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkAcls[?!IsDefault].NetworkAclId" --output text --region $AWS_REGION)
    
    for acl_id in $network_acls; do
        echo "Deleting Network ACL: $acl_id"
        run_command "aws ec2 delete-network-acl --network-acl-id $acl_id --region $AWS_REGION" \
            "Failed to delete Network ACL: $acl_id" \
            "Successfully deleted Network ACL: $acl_id" \
            "true"
    done
    
    # 16. Detach and delete internet gateway
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
    
    # 17. Find any left subnets and try a final time
    remaining_subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --query "Subnets[].SubnetId" --output text --region $AWS_REGION)
    
    if [ -n "$remaining_subnets" ]; then
        echo "Some subnets still exist. Making final attempt to delete them..."
        for subnet_id in $remaining_subnets; do
            echo "Final attempt to delete subnet: $subnet_id"
            run_command "aws ec2 delete-subnet --subnet-id $subnet_id --region $AWS_REGION" "" "" "true"
        done
    fi
    
    # 18. Try to force delete any remaining ENIs
    remaining_enis=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
    
    if [ -n "$remaining_enis" ]; then
        echo "Network interfaces still exist. This is typically due to AWS managed services."
        echo "Interfaces owned by AWS services must be deleted by removing the service."
        
        # Display information about remaining ENIs to help debugging
        for eni_id in $remaining_enis; do
            eni_info=$(aws ec2 describe-network-interfaces --network-interface-ids $eni_id --region $AWS_REGION --query "NetworkInterfaces[0].[Description,InterfaceType,RequesterId]" --output text)
            echo "ENI $eni_id info: $eni_info"
            
            # For each remaining ENI, check what specific AWS service might be using it
            requester_id=$(aws ec2 describe-network-interfaces --network-interface-ids $eni_id --region $AWS_REGION --query "NetworkInterfaces[0].RequesterId" --output text)
            
            if [[ $requester_id == *"amazon-elb"* ]]; then
                echo "This appears to be an ELB interface. Check for and delete any remaining ELBs."
            elif [[ $requester_id == *"amazon-vpc"* ]]; then
                echo "This appears to be a VPC service interface (possibly for VPC endpoints)."
            fi
        done
        
        echo "Waiting for any background processes to complete before VPC deletion attempt..."
        wait_with_message 60 "Final waiting period..."
    fi
    
    # 19. Wait before trying to delete the VPC
    echo "Waiting before attempting to delete VPC..."
    wait_with_message 30 "Final waiting period before VPC deletion..."
    
    # 20. Delete the VPC
    echo "Attempting to delete VPC: $vpc_id"
    run_command "aws ec2 delete-vpc --vpc-id $vpc_id --region $AWS_REGION" \
        "Failed to delete VPC: $vpc_id" \
        "Successfully deleted VPC: $vpc_id" \
        "true"
    
    # 21. If VPC deletion failed, provide detailed information about remaining dependencies
    vpc_exists=$(aws ec2 describe-vpcs --vpc-ids $vpc_id --region $AWS_REGION 2>/dev/null && echo "true" || echo "false")
    if [ "$vpc_exists" = "true" ]; then
        echo -e "${YELLOW}WARNING: Could not delete VPC automatically. The following resources may still be attached:${NC}"
        
        # Check remaining resources
        echo "1. Checking for remaining network interfaces..."
        remaining_enis=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --query "NetworkInterfaces[].[NetworkInterfaceId,Description,Status]" --output text --region $AWS_REGION)
        if [ -n "$remaining_enis" ]; then
            echo "Remaining network interfaces:"
            echo "$remaining_enis"
            
            # Add ENI details for debugging
            for eni_id in $(echo "$remaining_enis" | awk '{print $1}'); do
                eni_detail=$(aws ec2 describe-network-interfaces --network-interface-ids $eni_id --region $AWS_REGION --query "NetworkInterfaces[0].[InterfaceType,RequesterId,SubnetId]" --output text)
                echo "ENI $eni_id details: $eni_detail"
            done
        fi
        
        echo "2. Checking for remaining subnets..."
        remaining_subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --query "Subnets[].[SubnetId,AvailabilityZone]" --output text --region $AWS_REGION)
        if [ -n "$remaining_subnets" ]; then
            echo "Remaining subnets:"
            echo "$remaining_subnets"
        fi
        
        echo "3. Checking for remaining security groups..."
        remaining_sgs=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" --query "SecurityGroups[].[GroupId,GroupName]" --output text --region $AWS_REGION)
        if [ -n "$remaining_sgs" ]; then
            echo "Remaining security groups:"
            echo "$remaining_sgs"
        fi
        
        echo "4. Checking for remaining VPC endpoints..."
        remaining_endpoints=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc_id" --query "VpcEndpoints[].[VpcEndpointId,VpcEndpointType]" --output text --region $AWS_REGION)
        if [ -n "$remaining_endpoints" ]; then
            echo "Remaining VPC endpoints:"
            echo "$remaining_endpoints"
        fi
        
        echo -e "\n${YELLOW}Manual steps required:${NC}"
        echo "1. Go to the AWS Management Console"
        echo "2. Navigate to VPC Dashboard"
        echo "3. Check for resources in the following order:"
        echo "   a. VPC Endpoints (look under 'Endpoints')"
        echo "   b. Network Interfaces (under EC2 → Network Interfaces)"
        echo "   c. Elastic Load Balancers (under EC2 → Load Balancers)"
        echo "   d. NAT Gateways (under VPC → NAT Gateways)"
        echo "   e. VPC Lattice Services (under VPC → VPC Lattice)"
        echo "   f. Transit Gateway Attachments (under VPC → Transit Gateway Attachments)"
        echo "4. Delete any remaining resources in the AWS Console"
        echo "5. Then try to delete the VPC again from the console"
        echo ""
        echo "The most common cause of VPC deletion failures is AWS-managed network interfaces from services like:"
        echo "- AWS PrivateLink"
        echo "- Interface VPC Endpoints"
        echo "- Elastic Load Balancers"
        echo "- Lambda functions with VPC access"
        echo "- RDS instances"
        echo "- ElastiCache clusters"
        echo "These must be deleted from their respective service consoles, not directly as network interfaces."
        echo ""
        echo -e "${YELLOW}NOTE: For future VPC cleanup, consider using the AWS CLI nuke tool for more thorough resource removal:${NC}"
        echo "https://github.com/rebuy-de/aws-nuke"
    else
        echo -e "${GREEN}VPC successfully deleted!${NC}"
    fi
else
    echo "No VPC found with the specified prefix: ${PREFIX}"
fi

echo -e "\n${YELLOW}Step 16: Cleanup any remaining CloudFormation stacks${NC}"
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

echo -e "\n${YELLOW}Step 17: Final verification${NC}"
echo "Performing final verification of resource cleanup..."

# Check for remaining resources
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
echo "- Removed Security Groups"
echo "- Deleted VPC and all associated resources"
echo "- Removed CloudFormation stacks"

echo -e "\n${YELLOW}Note: The Terraform state bucket '${PROJECT_NAME}-terraform-state' was not fully deleted to preserve${NC}"
echo -e "${YELLOW}state files for other environments. Only the ${STAGE}/ folder was cleaned up.${NC}"
echo -e "\n${BLUE}Cleanup process completed. For any remaining resources,${NC}"
echo -e "${BLUE}please check the AWS Management Console.${NC}"