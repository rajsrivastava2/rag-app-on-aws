#!/bin/bash

# AWS RAG Application Cleanup Script
# This script removes all AWS resources created for the RAG application on AWS

# Set text colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Banner
echo -e "${YELLOW}"
echo "============================================================"
echo "         AWS RAG Application - Complete Cleanup Script       "
echo "============================================================"
echo -e "${NC}"

# Get project configuration
read -p "Enter your project name (default: rag-app): " PROJECT_NAME
PROJECT_NAME=${PROJECT_NAME:-rag-app}

read -p "Enter environment/stage (default: dev): " STAGE
STAGE=${STAGE:-dev}

read -p "Enter AWS region (default: us-east-1): " AWS_REGION
AWS_REGION=${AWS_REGION:-us-east-1}

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

# Check for jq command
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}Warning: jq command not found. Will use alternative methods for JSON processing.${NC}"
    USE_JQ=false
else
    USE_JQ=true
fi

# Clear terraform state lock if it exists
echo -e "\n${YELLOW}Checking for terraform state locks...${NC}"
DYNAMODB_TABLE="${PROJECT_NAME}-${STAGE}-terraform-state-lock"
if aws dynamodb describe-table --table-name $DYNAMODB_TABLE --region $AWS_REGION &> /dev/null; then
    echo "Table $DYNAMODB_TABLE exists. Looking for locks..."
    # Try to find any locks without using jq
    LOCK_ITEMS=$(aws dynamodb scan --table-name $DYNAMODB_TABLE --region $AWS_REGION --output json)
    
    if [[ $USE_JQ == true ]]; then
        LOCK_ID=$(echo "$LOCK_ITEMS" | jq -r '.Items[] | select(.LockID.S | contains("terraform-")) | .LockID.S' 2>/dev/null || echo "")
    else
        # Simple grep fallback
        LOCK_ID=$(echo "$LOCK_ITEMS" | grep -o '"LockID":{"S":"[^"]*"' | grep -o 'terraform-[^"]*' || echo "")
    fi
    
    if [ -n "$LOCK_ID" ]; then
        echo -e "${YELLOW}Found lock in DynamoDB: $LOCK_ID. Removing...${NC}"
        aws dynamodb delete-item --table-name $DYNAMODB_TABLE --key "{\"LockID\":{\"S\":\"$LOCK_ID\"}}" --region $AWS_REGION
        echo -e "${GREEN}Terraform state lock removed.${NC}"
    else
        echo "No terraform locks found in table."
    fi
else
    echo "Terraform state lock table does not exist. Skipping."
fi

# Function to handle Windows Git Bash path issues
fix_path() {
    echo "$1" | sed 's#^/\([a-zA-Z]\)/#\1:/#' | sed 's#^C:/Program Files/Git##'
}

# 1. Delete all files in S3 buckets (to allow bucket deletion)
echo -e "\n${YELLOW}Emptying S3 buckets...${NC}"

BUCKETS=(
    "${PROJECT_NAME}-${STAGE}-documents"
    "${PROJECT_NAME}-${STAGE}-lambda-code"
    "${PROJECT_NAME}-terraform-state"
)

for BUCKET in "${BUCKETS[@]}"; do
    echo -e "Checking if bucket exists: ${BUCKET}"
    if aws s3api head-bucket --bucket ${BUCKET} --region ${AWS_REGION} 2>/dev/null; then
        echo -e "Emptying bucket: ${BUCKET}"
        
        # For terraform state bucket, only remove objects related to the current stage
        if [[ $BUCKET == *"terraform-state"* ]]; then
            echo "This is a terraform state bucket. Removing only objects for stage: ${STAGE}"
            # Remove objects for the specific stage
            aws s3 rm "s3://${BUCKET}/${STAGE}/" --recursive --region ${AWS_REGION}
            
            # We'll skip full deletion for terraform state bucket since it may contain state for other stages
            continue
        fi
        
        # First, remove all objects using s3 rm
        echo "Removing all objects..."
        aws s3 rm "s3://${BUCKET}" --recursive --region ${AWS_REGION}
        
        # Disable bucket versioning first to make cleanup easier
        echo "Disabling bucket versioning..."
        aws s3api put-bucket-versioning --bucket ${BUCKET} --versioning-configuration Status=Suspended --region ${AWS_REGION}
        
        # Now handle any remaining versions with a more robust approach
        echo "Removing all object versions..."
        
        # Create a temporary file for version processing
        TEMP_FILE=$(mktemp)
        
        # Get all versions including delete markers
        aws s3api list-object-versions --bucket ${BUCKET} --output json --region ${AWS_REGION} > $TEMP_FILE
        
        # Process versions first - handle parsing issues with text processing instead of jq
        # This approach handles spaces in keys and special characters better
        if [ -s "$TEMP_FILE" ]; then
            # Extract version information without jq
            grep -A 2 '"Key":' $TEMP_FILE | grep -v '\-\-' | 
            while read -r LINE1 && read -r LINE2; do
                # Extract key and version ID using pattern matching
                KEY=$(echo $LINE1 | grep -o '"Key": *"[^"]*"' | cut -d'"' -f4)
                VERSION=$(echo $LINE2 | grep -o '"VersionId": *"[^"]*"' | cut -d'"' -f4)
                
                if [ -n "$KEY" ] && [ -n "$VERSION" ] && [ "$VERSION" != "null" ]; then
                    echo "Deleting object: $KEY (version $VERSION)"
                    aws s3api delete-object --bucket ${BUCKET} --key "$KEY" --version-id "$VERSION" --region ${AWS_REGION}
                elif [ -n "$KEY" ]; then
                    echo "Deleting object: $KEY (version null)"
                    aws s3api delete-object --bucket ${BUCKET} --key "$KEY" --region ${AWS_REGION}
                fi
            done
            
            # Now handle delete markers
            grep -A 2 '"Key":' $TEMP_FILE | grep -B 1 '"DeleteMarker": true' | grep -v '\-\-' |
            while read -r LINE1 && read -r LINE2; do
                # Extract key and version ID for delete markers
                KEY=$(echo $LINE1 | grep -o '"Key": *"[^"]*"' | cut -d'"' -f4)
                VERSION=$(echo $LINE2 | grep -o '"VersionId": *"[^"]*"' | cut -d'"' -f4)
                
                if [ -n "$KEY" ] && [ -n "$VERSION" ]; then
                    echo "Deleting delete marker: $KEY (version $VERSION)"
                    aws s3api delete-object --bucket ${BUCKET} --key "$KEY" --version-id "$VERSION" --region ${AWS_REGION}
                fi
            done
        fi
        
        # Clean up temp file
        rm -f $TEMP_FILE
        
        # Final sweep to make sure everything is gone
        echo "Final sweep to remove any remaining objects..."
        aws s3 rm "s3://${BUCKET}" --recursive --region ${AWS_REGION}
    else
        echo "Bucket ${BUCKET} not found or cannot be accessed"
    fi
done

# 2. Remove all API Gateway resources
echo -e "\n${YELLOW}Deleting API Gateway resources...${NC}"
API_ID=$(aws apigateway get-rest-apis --query "items[?name=='${PROJECT_NAME}-${STAGE}-api'].id" --output text --region $AWS_REGION)

if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
    echo "Found API Gateway: $API_ID. Deleting..."
    aws apigateway delete-rest-api --rest-api-id $API_ID --region $AWS_REGION
    echo -e "${GREEN}API Gateway deleted.${NC}"
else
    echo "No API Gateway found."
fi

# 3. Delete all Lambda functions
echo -e "\n${YELLOW}Deleting Lambda functions...${NC}"
LAMBDA_FUNCTIONS=(
    "${PROJECT_NAME}-${STAGE}-auth-handler"
    "${PROJECT_NAME}-${STAGE}-document-processor"
    "${PROJECT_NAME}-${STAGE}-query-processor"
    "${PROJECT_NAME}-${STAGE}-upload-handler"
    "${PROJECT_NAME}-${STAGE}-db-init"
)

for FUNCTION in "${LAMBDA_FUNCTIONS[@]}"; do
    echo "Deleting Lambda function: $FUNCTION"
    aws lambda delete-function --function-name $FUNCTION --region $AWS_REGION || echo "Function $FUNCTION not found or already deleted"
done

# 4. Delete CloudWatch Log Groups
echo -e "\n${YELLOW}Deleting CloudWatch Log Groups...${NC}"
LOG_GROUPS=(
    "/aws/lambda/${PROJECT_NAME}-${STAGE}-auth-handler"
    "/aws/lambda/${PROJECT_NAME}-${STAGE}-document-processor"
    "/aws/lambda/${PROJECT_NAME}-${STAGE}-query-processor"
    "/aws/lambda/${PROJECT_NAME}-${STAGE}-upload-handler"
    "/aws/lambda/${PROJECT_NAME}-${STAGE}-db-init"
    "/aws/apigateway/${PROJECT_NAME}-${STAGE}-api"
)

for LOG_GROUP in "${LOG_GROUPS[@]}"; do
    echo "Deleting Log Group: $LOG_GROUP"
    # Fix for Windows Git Bash path issues
    FIXED_PATH=$(fix_path "$LOG_GROUP")
    aws logs delete-log-group --log-group-name "$FIXED_PATH" --region $AWS_REGION || echo "Log Group $LOG_GROUP not found or already deleted"
done

# 5. Delete DynamoDB tables
echo -e "\n${YELLOW}Deleting DynamoDB tables...${NC}"
TABLES=(
    "${PROJECT_NAME}-${STAGE}-metadata"
    "${PROJECT_NAME}-${STAGE}-terraform-state-lock"
)

for TABLE in "${TABLES[@]}"; do
    echo "Deleting table: $TABLE"
    aws dynamodb delete-table --table-name $TABLE --region $AWS_REGION || echo "Table $TABLE not found or already deleted"
done

# 6. Delete RDS instance and related resources
echo -e "\n${YELLOW}Deleting RDS resources...${NC}"
DB_INSTANCE="${PROJECT_NAME}-${STAGE}-postgres"
DB_PARAM_GROUP="${PROJECT_NAME}-${STAGE}-postgres-params"
DB_SUBNET_GROUP="${PROJECT_NAME}-${STAGE}-db-subnet-group"

# Delete RDS instance
echo "Deleting RDS instance: $DB_INSTANCE"
aws rds delete-db-instance --db-instance-identifier $DB_INSTANCE --skip-final-snapshot --delete-automated-backups --region $AWS_REGION || echo "RDS instance $DB_INSTANCE not found or already deleted"

# Wait for RDS instance to be deleted before removing parameter group
echo "Waiting for RDS instance deletion to complete..."
aws rds wait db-instance-deleted --db-instance-identifier $DB_INSTANCE --region $AWS_REGION || echo "Failed to wait for RDS instance deletion, continuing anyway"

# Delete parameter group
echo "Deleting DB parameter group: $DB_PARAM_GROUP"
aws rds delete-db-parameter-group --db-parameter-group-name $DB_PARAM_GROUP --region $AWS_REGION || echo "Parameter group $DB_PARAM_GROUP not found or already deleted"

# Delete subnet group
echo "Deleting DB subnet group: $DB_SUBNET_GROUP"
aws rds delete-db-subnet-group --db-subnet-group-name $DB_SUBNET_GROUP --region $AWS_REGION || echo "Subnet group $DB_SUBNET_GROUP not found or already deleted"

# 7. Delete Cognito resources
echo -e "\n${YELLOW}Deleting Cognito resources...${NC}"
USER_POOL_ID=$(aws cognito-idp list-user-pools --max-results 20 --query "UserPools[?Name=='${PROJECT_NAME}-${STAGE}-user-pool'].Id" --output text --region $AWS_REGION)

if [ -n "$USER_POOL_ID" ] && [ "$USER_POOL_ID" != "None" ]; then
    echo "Found Cognito User Pool: $USER_POOL_ID. Deleting..."
    
    # Delete domain first
    DOMAIN="${PROJECT_NAME}-${STAGE}-auth"
    aws cognito-idp delete-user-pool-domain --domain $DOMAIN --user-pool-id $USER_POOL_ID --region $AWS_REGION || echo "Domain $DOMAIN not found or already deleted"
    
    # Delete user pool clients
    CLIENT_IDS=$(aws cognito-idp list-user-pool-clients --user-pool-id $USER_POOL_ID --query "UserPoolClients[].ClientId" --output text --region $AWS_REGION)
    for CLIENT_ID in $CLIENT_IDS; do
        echo "Deleting User Pool Client: $CLIENT_ID"
        aws cognito-idp delete-user-pool-client --user-pool-id $USER_POOL_ID --client-id $CLIENT_ID --region $AWS_REGION || echo "Client $CLIENT_ID not found or already deleted"
    done
    
    # Delete user pool
    aws cognito-idp delete-user-pool --user-pool-id $USER_POOL_ID --region $AWS_REGION || echo "User Pool $USER_POOL_ID not found or already deleted"
    echo -e "${GREEN}Cognito User Pool deleted.${NC}"
else
    echo "No Cognito User Pool found."
fi

# 8. Delete Secrets Manager secrets
echo -e "\n${YELLOW}Deleting Secrets Manager secrets...${NC}"
SECRETS=(
    "${PROJECT_NAME}-${STAGE}-db-credentials"
    "${PROJECT_NAME}-${STAGE}-gemini-api-key"
)

for SECRET in "${SECRETS[@]}"; do
    echo "Deleting secret: $SECRET"
    aws secretsmanager delete-secret --secret-id $SECRET --force-delete-without-recovery --region $AWS_REGION || echo "Secret $SECRET not found or already deleted"
done

# 9. Delete SNS topics
echo -e "\n${YELLOW}Deleting SNS topics...${NC}"
TOPIC_ARN=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':${PROJECT_NAME}-${STAGE}-alerts')].TopicArn" --output text --region $AWS_REGION)

if [ -n "$TOPIC_ARN" ] && [ "$TOPIC_ARN" != "None" ]; then
    echo "Found SNS topic: $TOPIC_ARN. Deleting..."
    aws sns delete-topic --topic-arn $TOPIC_ARN --region $AWS_REGION || echo "Topic $TOPIC_ARN not found or already deleted"
    echo -e "${GREEN}SNS topic deleted.${NC}"
else
    echo "No SNS topic found."
fi

# 10. Delete all IAM roles and policies created for the project
echo -e "\n${YELLOW}Deleting IAM roles and policies...${NC}"

# Get all IAM roles with the project prefix
IAM_ROLES=$(aws iam list-roles --query "Roles[?starts_with(RoleName, '${PROJECT_NAME}-${STAGE}')].RoleName" --output text)

for ROLE_NAME in $IAM_ROLES; do
    echo "Processing role: $ROLE_NAME"
    
    # Get attached managed policies
    ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name $ROLE_NAME --query "AttachedPolicies[].PolicyArn" --output text)
    
    # Detach all managed policies
    for POLICY_ARN in $ATTACHED_POLICIES; do
        echo "Detaching policy $POLICY_ARN from role $ROLE_NAME"
        aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN || echo "Failed to detach policy $POLICY_ARN"
    done
    
    # Get inline policies
    INLINE_POLICIES=$(aws iam list-role-policies --role-name $ROLE_NAME --query "PolicyNames[]" --output text)
    
    # Delete all inline policies
    for POLICY_NAME in $INLINE_POLICIES; do
        echo "Deleting inline policy $POLICY_NAME from role $ROLE_NAME"
        aws iam delete-role-policy --role-name $ROLE_NAME --policy-name $POLICY_NAME || echo "Failed to delete inline policy $POLICY_NAME"
    done
    
    # Delete the role
    echo "Deleting role: $ROLE_NAME"
    aws iam delete-role --role-name $ROLE_NAME || echo "Failed to delete role $ROLE_NAME"
done

# Get all customer managed policies with the project prefix
IAM_POLICIES=$(aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, '${PROJECT_NAME}-${STAGE}')].Arn" --output text)

# Delete all policies
for POLICY_ARN in $IAM_POLICIES; do
    echo "Deleting policy: $POLICY_ARN"
    aws iam delete-policy --policy-arn $POLICY_ARN || echo "Failed to delete policy $POLICY_ARN"
done

# 11. Wait for resources to be fully released before trying to delete VPC
echo -e "\n${YELLOW}Waiting for resources to be fully released (90 seconds)...${NC}"
sleep 90

# 12. Delete VPC resources in proper order
echo -e "\n${YELLOW}Finding VPC resources...${NC}"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT_NAME}-${STAGE}-vpc" --query "Vpcs[0].VpcId" --output text --region $AWS_REGION)

# If first attempt doesn't find the VPC, try with a wildcard tag search
if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
    echo "VPC not found with specific tag, trying alternative search..."
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag-key,Values=Name" "Name=tag-value,Values=*${PROJECT_NAME}*${STAGE}*" --query "Vpcs[0].VpcId" --output text --region $AWS_REGION)
fi

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    echo "Found VPC: $VPC_ID. Deleting associated resources..."
    
    # Terminate any EC2 instances in the VPC first
    INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" --query "Reservations[].Instances[].InstanceId" --output text --region $AWS_REGION)
    if [ -n "$INSTANCE_IDS" ]; then
        echo "Terminating EC2 instances in the VPC..."
        aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region $AWS_REGION || echo "Failed to terminate instances"
        echo "Waiting for instances to terminate..."
        aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region $AWS_REGION || echo "Failed to wait for instances to terminate"
    fi
    
    # Delete Network Interfaces with proper handling for managed attachments
    echo "Looking for Network Interfaces..."
    ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
    for ENI_ID in $ENI_IDS; do
        echo "Checking Network Interface: $ENI_ID"
        
        # Get status and attachment info
        ENI_INFO=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID --region $AWS_REGION)
        STATUS=$(echo "$ENI_INFO" | grep -o '"Status": "[^"]*"' | cut -d'"' -f4)
        ATTACH_ID=$(echo "$ENI_INFO" | grep -o '"AttachmentId": "[^"]*"' | cut -d'"' -f4)
        
        # Skip if in use by a service
        if [[ "$STATUS" == "in-use" ]]; then
            # Check if this is a managed attachment
            if [[ -n "$ATTACH_ID" ]] && [[ "$ATTACH_ID" == ela-attach-* ]]; then
                echo "Skipping managed attachment: $ATTACH_ID"
                continue
            fi
            
            # Force detachment if possible
            if [ -n "$ATTACH_ID" ]; then
                echo "Attempting to force detach: $ATTACH_ID"
                aws ec2 detach-network-interface --attachment-id $ATTACH_ID --force --region $AWS_REGION || echo "Could not detach $ATTACH_ID"
                # Wait for detachment
                echo "Waiting 15 seconds for detachment to complete..."
                sleep 15
            fi
        fi
        
        # Now try to delete the ENI
        echo "Attempting to delete Network Interface: $ENI_ID"
        aws ec2 delete-network-interface --network-interface-id $ENI_ID --region $AWS_REGION || echo "Could not delete network interface $ENI_ID (might still be in use)"
    done
    
    # Delete NAT gateways
    NAT_GATEWAY_IDS=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query "NatGateways[?State!='deleted'].NatGatewayId" --output text --region $AWS_REGION)
    for NAT_ID in $NAT_GATEWAY_IDS; do
        echo "Deleting NAT Gateway: $NAT_ID"
        aws ec2 delete-nat-gateway --nat-gateway-id $NAT_ID --region $AWS_REGION || echo "Failed to delete NAT Gateway $NAT_ID"
    done
    
    # Wait for NAT gateways to be deleted
    if [ -n "$NAT_GATEWAY_IDS" ]; then
        echo "Waiting for NAT Gateways to be deleted (up to 180 seconds)..."
        sleep 180
    fi
    
    # Release Elastic IPs (first list, then release)
    echo "Finding and releasing Elastic IPs associated with the VPC..."
    EIP_ALLOC_IDS=$(aws ec2 describe-addresses --region $AWS_REGION --query "Addresses[].AllocationId" --output text)
    for EIP_ID in $EIP_ALLOC_IDS; do
        echo "Releasing Elastic IP: $EIP_ID"
        aws ec2 release-address --allocation-id $EIP_ID --region $AWS_REGION || echo "Failed to release EIP $EIP_ID"
    done
    
    # Delete VPC endpoints
    ENDPOINTS=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query "VpcEndpoints[].VpcEndpointId" --output text --region $AWS_REGION)
    for ENDPOINT in $ENDPOINTS; do
        echo "Deleting VPC Endpoint: $ENDPOINT"
        aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $ENDPOINT --region $AWS_REGION || echo "Failed to delete endpoint $ENDPOINT"
    done
    
    # Wait for endpoints to be fully deleted
    echo "Waiting for endpoints to be fully deleted (30 seconds)..."
    sleep 30
    
    # Try to clean up remaining dependencies
    echo "Attempting to clean up remaining network dependencies..."
    
    # Find and close any active VPN connections
    VPN_CONN_IDS=$(aws ec2 describe-vpn-connections --filters "Name=vpc-id,Values=$VPC_ID" --query "VpnConnections[?State!='deleted'].VpnConnectionId" --output text --region $AWS_REGION)
    for VPN_CONN_ID in $VPN_CONN_IDS; do
        echo "Deleting VPN Connection: $VPN_CONN_ID"
        aws ec2 delete-vpn-connection --vpn-connection-id $VPN_CONN_ID --region $AWS_REGION || echo "Failed to delete VPN connection $VPN_CONN_ID"
    done
    
    # Find and delete any VPC peering connections
    PEERING_IDS=$(aws ec2 describe-vpc-peering-connections --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" --query "VpcPeeringConnections[].VpcPeeringConnectionId" --output text --region $AWS_REGION)
    for PEER_ID in $PEERING_IDS; do
        echo "Deleting VPC Peering Connection: $PEER_ID"
        aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id $PEER_ID --region $AWS_REGION || echo "Failed to delete VPC peering connection $PEER_ID"
    done
    
    # Delete security groups (except default)
    SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=!default" --query "SecurityGroups[].GroupId" --output text --region $AWS_REGION)
    for SG_ID in $SG_IDS; do
        echo "Deleting Security Group: $SG_ID"
        aws ec2 delete-security-group --group-id $SG_ID --region $AWS_REGION || echo "Failed to delete security group $SG_ID"
    done
    
    # Delete Network ACLs (except default)
    NACL_IDS=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkAcls[?!IsDefault].NetworkAclId" --output text --region $AWS_REGION)
    for NACL_ID in $NACL_IDS; do
        echo "Deleting Network ACL: $NACL_ID"
        aws ec2 delete-network-acl --network-acl-id $NACL_ID --region $AWS_REGION || echo "Failed to delete Network ACL $NACL_ID"
    done
    
    # Retry to delete subnets multiple times with delays
    for RETRY in {1..3}; do
        echo "Attempt $RETRY to delete subnets..."
        SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region $AWS_REGION)
        
        if [ -z "$SUBNET_IDS" ]; then
            echo "No subnets found."
            break
        fi
        
        for SUBNET_ID in $SUBNET_IDS; do
            echo "Deleting Subnet: $SUBNET_ID"
            aws ec2 delete-subnet --subnet-id $SUBNET_ID --region $AWS_REGION || echo "Failed to delete subnet $SUBNET_ID"
        done
        
        if [ $RETRY -lt 3 ]; then
            echo "Waiting 30 seconds before next subnet deletion attempt..."
            sleep 30
        fi
    done
    
    # Delete route tables (except the main one)
    RT_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query "RouteTables[?!Associations[?Main]].RouteTableId" --output text --region $AWS_REGION)
    for RT_ID in $RT_IDS; do
        echo "Checking if Route Table $RT_ID has associations..."
        RT_ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-ids $RT_ID --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" --output text --region $AWS_REGION)
        
        for ASSOC_ID in $RT_ASSOC_IDS; do
            echo "Disassociating Route Table Association: $ASSOC_ID"
            aws ec2 disassociate-route-table --association-id $ASSOC_ID --region $AWS_REGION || echo "Failed to disassociate route table association $ASSOC_ID"
        done
        
        echo "Deleting Route Table: $RT_ID"
        aws ec2 delete-route-table --route-table-id $RT_ID --region $AWS_REGION || echo "Failed to delete route table $RT_ID"
    done
    
    # Detach and delete internet gateway
    IG_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[0].InternetGatewayId" --output text --region $AWS_REGION)
    if [ -n "$IG_ID" ] && [ "$IG_ID" != "None" ]; then
        echo "Detaching Internet Gateway: $IG_ID"
        aws ec2 detach-internet-gateway --internet-gateway-id $IG_ID --vpc-id $VPC_ID --region $AWS_REGION || echo "Failed to detach internet gateway"
        
        echo "Deleting Internet Gateway: $IG_ID"
        aws ec2 delete-internet-gateway --internet-gateway-id $IG_ID --region $AWS_REGION || echo "Failed to delete internet gateway $IG_ID"
    fi
    
    # Wait one last time before trying to delete the VPC
    echo "Waiting 30 seconds before attempting to delete VPC..."
    sleep 30
    
    # Multiple attempts to delete the VPC
    for RETRY in {1..3}; do
        echo "Attempt $RETRY to delete VPC: $VPC_ID"
        aws ec2 delete-vpc --vpc-id $VPC_ID --region $AWS_REGION
        
        # Check if successful
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}VPC successfully deleted!${NC}"
            break
        else
            echo "Failed to delete VPC. Checking remaining dependencies..."
            
            # Check for remaining dependencies
            REMAINING_ENI=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $AWS_REGION)
            REMAINING_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=!default" --query "SecurityGroups[].GroupId" --output text --region $AWS_REGION)
            REMAINING_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[].SubnetId" --output text --region $AWS_REGION)
            
            if [ -n "$REMAINING_ENI" ]; then
                echo "Remaining network interfaces: $REMAINING_ENI"
                # Try more aggressively to remove ENIs
                for ENI_ID in $REMAINING_ENI; do
                    echo "Force-detaching network interface: $ENI_ID"
                    ATTACHMENT=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text --region $AWS_REGION)
                    if [ -n "$ATTACHMENT" ] && [ "$ATTACHMENT" != "None" ]; then
                        aws ec2 detach-network-interface --attachment-id $ATTACHMENT --force --region $AWS_REGION || echo "Could not detach $ATTACHMENT"
                        sleep 10
                    fi
                    aws ec2 delete-network-interface --network-interface-id $ENI_ID --region $AWS_REGION || echo "Could not delete network interface $ENI_ID"
                done
            fi
            
            if [ -n "$REMAINING_SG" ]; then
                echo "Remaining security groups: $REMAINING_SG"
                for SG_ID in $REMAINING_SG; do
                    echo "Deleting security group: $SG_ID"
                    aws ec2 delete-security-group --group-id $SG_ID --region $AWS_REGION || echo "Failed to delete security group $SG_ID"
                done
            fi
            
            if [ -n "$REMAINING_SUBNETS" ]; then
                echo "Remaining subnets: $REMAINING_SUBNETS"
                for SUBNET_ID in $REMAINING_SUBNETS; do
                    echo "Deleting subnet: $SUBNET_ID"
                    aws ec2 delete-subnet --subnet-id $SUBNET_ID --region $AWS_REGION || echo "Failed to delete subnet $SUBNET_ID"
                done
            fi
            
            if [ $RETRY -lt 3 ]; then
                echo "Waiting 30 seconds before next VPC deletion attempt..."
                sleep 30
            fi
        fi
    done
    
    # Final check if VPC still exists
    VPC_CHECK=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --region $AWS_REGION 2>/dev/null || echo "")
    if [ -z "$VPC_CHECK" ]; then
        echo -e "${GREEN}VPC and related resources successfully deleted.${NC}"
    else
        echo -e "${YELLOW}VPC deletion may have failed. You may need to manually delete VPC $VPC_ID and its dependencies.${NC}"
    fi
else
    echo "No VPC found."
fi

# 13. Delete S3 buckets (after emptying them)
echo -e "\n${YELLOW}Deleting S3 buckets...${NC}"

BUCKETS=(
    "${PROJECT_NAME}-${STAGE}-documents"
    "${PROJECT_NAME}-${STAGE}-lambda-code"
)

for BUCKET in "${BUCKETS[@]}"; do
    echo "Deleting bucket: $BUCKET"
    # Check if bucket exists before attempting to delete
    if aws s3api head-bucket --bucket ${BUCKET} --region ${AWS_REGION} 2>/dev/null; then
        # Disable versioning first
        echo "Disabling bucket versioning..."
        aws s3api put-bucket-versioning --bucket ${BUCKET} --versioning-configuration Status=Suspended --region ${AWS_REGION}
        
        # Empty bucket again completely - ensure it's really empty
        echo "Final cleanup of bucket contents..."
        
        # Remove all objects
        aws s3 rm s3://${BUCKET} --recursive --region ${AWS_REGION}
        
        # Create a temporary file for version processing
        TEMP_FILE=$(mktemp)
        
        # Get all versions and delete markers
        aws s3api list-object-versions --bucket ${BUCKET} --output json --region ${AWS_REGION} > $TEMP_FILE
        
        # Remove all versions with simpler parsing
        if [ -s "$TEMP_FILE" ]; then
            # Process versions and delete markers more carefully
            echo "Processing versions in $BUCKET"
            
            # First try to use aws s3api delete-objects for bulk deletion (faster)
            # Create a JSON file for delete-objects
            DELETE_FILE=$(mktemp)
            echo '{"Objects":[' > $DELETE_FILE
            
            # Add version info
            grep -A 5 '"Key":' $TEMP_FILE | grep -e '"Key":' -e '"VersionId":' | 
            while read -r LINE1 && read -r LINE2; do
                KEY=$(echo $LINE1 | sed -n 's/.*"Key": *"\([^"]*\)".*/\1/p')
                VERSION=$(echo $LINE2 | sed -n 's/.*"VersionId": *"\([^"]*\)".*/\1/p')
                
                if [ -n "$KEY" ] && [ -n "$VERSION" ]; then
                    echo "{\"Key\":\"$KEY\",\"VersionId\":\"$VERSION\"}," >> $DELETE_FILE
                fi
            done
            
            # Finalize JSON
            # Remove last comma and add closing brackets
            sed -i '$ s/,$//' $DELETE_FILE 2>/dev/null || sed -i '' '$ s/,$//' $DELETE_FILE
            echo ']}' >> $DELETE_FILE
            
            # Use bulk delete if we have objects
            if [ $(wc -l < $DELETE_FILE) -gt 3 ]; then
                echo "Bulk deleting objects..."
                aws s3api delete-objects --bucket ${BUCKET} --delete file://$DELETE_FILE --region ${AWS_REGION} || echo "Bulk delete failed, trying individual deletion"
            else
                echo "No versions found for bulk deletion"
            fi
            
            # Fallback to individual deletion for any remaining objects
            echo "Checking for any remaining objects..."
            aws s3 rm s3://${BUCKET} --recursive --region ${AWS_REGION}
            
            # Clean up temp files
            rm -f $DELETE_FILE
        fi
        
        rm -f $TEMP_FILE
        
        # Try to delete the bucket
        echo "Attempting to delete bucket: $BUCKET"
        if aws s3api delete-bucket --bucket $BUCKET --region $AWS_REGION; then
            echo -e "${GREEN}Successfully deleted bucket: $BUCKET${NC}"
        else
            echo -e "${YELLOW}Failed to delete bucket: $BUCKET. You may need to delete it manually.${NC}"
        fi
    else
        echo "Bucket $BUCKET does not exist or cannot be accessed"
    fi
done

# Note about terraform state bucket
echo -e "\n${YELLOW}Note about terraform state bucket:${NC}"
echo "The terraform state bucket (${PROJECT_NAME}-terraform-state) was not fully deleted to preserve"
echo "state files for other environments. Only the ${STAGE} folder was cleaned."
echo "If you want to delete the entire bucket, you can run:"
echo "aws s3 rb s3://${PROJECT_NAME}-terraform-state --force"

# 14. Final verification and reporting
echo -e "\n${YELLOW}Performing final verification...${NC}"

# Check if any Lambda functions still exist
REMAINING_LAMBDAS=$(aws lambda list-functions --query "Functions[?starts_with(FunctionName, '${PROJECT_NAME}-${STAGE}')].FunctionName" --output text --region $AWS_REGION)
if [ -n "$REMAINING_LAMBDAS" ]; then
    echo -e "${YELLOW}Some Lambda functions may still exist:${NC}"
    echo "$REMAINING_LAMBDAS"
    echo "You may need to manually delete these functions."
fi

# Check if any CloudWatch log groups still exist
FIXED_PATH="/aws/lambda/${PROJECT_NAME}-${STAGE}"
FIXED_PATH=$(fix_path "$FIXED_PATH")
REMAINING_LOGS=$(aws logs describe-log-groups --log-group-name-prefix "$FIXED_PATH" --query "logGroups[*].logGroupName" --output text --region $AWS_REGION 2>/dev/null || echo "")
if [ -n "$REMAINING_LOGS" ]; then
    echo -e "${YELLOW}Some CloudWatch log groups may still exist:${NC}"
    echo "$REMAINING_LOGS"
    echo "You may need to manually delete these log groups."
fi

# Check if RDS instance still exists
RDS_STATUS=$(aws rds describe-db-instances --db-instance-identifier "${PROJECT_NAME}-${STAGE}-postgres" --query "DBInstances[0].DBInstanceStatus" --output text --region $AWS_REGION 2>/dev/null || echo "")
if [ -n "$RDS_STATUS" ] && [ "$RDS_STATUS" != "None" ]; then
    echo -e "${YELLOW}RDS instance ${PROJECT_NAME}-${STAGE}-postgres still exists with status: $RDS_STATUS${NC}"
    echo "It might be in the process of being deleted. Please check the AWS Console."
fi

# Check if VPC still exists
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    VPC_EXISTS=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query "Vpcs[0].VpcId" --output text --region $AWS_REGION 2>/dev/null || echo "")
    if [ -n "$VPC_EXISTS" ] && [ "$VPC_EXISTS" != "None" ]; then
        echo -e "${YELLOW}VPC $VPC_ID still exists${NC}"
        echo "It might have dependencies that prevent deletion. Here are some possible dependencies:"
        
        # Check for remaining ENIs
        REMAINING_ENIS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[*].NetworkInterfaceId" --output text --region $AWS_REGION)
        if [ -n "$REMAINING_ENIS" ]; then
            echo "- Network Interfaces: $REMAINING_ENIS"
        fi
        
        # Check for remaining security groups
        REMAINING_SGS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[*].GroupId" --output text --region $AWS_REGION)
        if [ -n "$REMAINING_SGS" ]; then
            echo "- Security Groups: $REMAINING_SGS"
        fi
        
        echo "You may need to manually delete these resources before deleting the VPC."
    fi
fi

# Check if S3 buckets still exist
for BUCKET in "${BUCKETS[@]}"; do
    if aws s3api head-bucket --bucket ${BUCKET} --region ${AWS_REGION} 2>/dev/null; then
        echo -e "${YELLOW}S3 bucket ${BUCKET} still exists${NC}"
        echo "You may need to manually delete it using the AWS console or CLI."
    fi
done

echo -e "\n${GREEN}==================================================${NC}"
echo -e "${GREEN}    Cleanup Process Completed                     ${NC}"
echo -e "${GREEN}==================================================${NC}"
echo -e "${YELLOW}Resources that were targeted for deletion:${NC}"
echo "- API Gateway: ${PROJECT_NAME}-${STAGE}-api"
echo "- Lambda functions for ${PROJECT_NAME}-${STAGE}"
echo "- CloudWatch log groups for ${PROJECT_NAME}-${STAGE}"
echo "- DynamoDB tables: ${PROJECT_NAME}-${STAGE}-metadata, ${PROJECT_NAME}-${STAGE}-terraform-state-lock" 
echo "- RDS PostgreSQL instance: ${PROJECT_NAME}-${STAGE}-postgres"
echo "- Cognito User Pool: ${PROJECT_NAME}-${STAGE}-user-pool"
echo "- Secrets: ${PROJECT_NAME}-${STAGE}-db-credentials, ${PROJECT_NAME}-${STAGE}-gemini-api-key"
echo "- SNS Topics: ${PROJECT_NAME}-${STAGE}-alerts"
echo "- IAM roles and policies for ${PROJECT_NAME}-${STAGE}"
echo "- VPC and related resources for ${PROJECT_NAME}-${STAGE}"
echo "- S3 buckets: ${PROJECT_NAME}-${STAGE}-documents, ${PROJECT_NAME}-${STAGE}-lambda-code"
echo "- ${STAGE} folder in ${PROJECT_NAME}-terraform-state bucket"
echo -e "\n${YELLOW}Note: Some resources may take time to fully delete.${NC}"
echo -e "${YELLOW}Check the AWS Console to verify all resources have been removed.${NC}"