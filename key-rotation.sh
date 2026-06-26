#!/bin/bash

set -euo pipefail

# AWS Key Rotation Script
# Usage: ./key-rotation.sh <profile-name>
# This script rotates AWS IAM access keys based on age and count

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DAYS_THRESHOLD=45
REPORT_DIR="./reports"
PROFILE="${1:-}"

# Validate input
if [[ -z "$PROFILE" ]]; then
    echo -e "${RED}Error: AWS profile name is required${NC}"
    echo "Usage: $0 <profile-name>"
    exit 1
fi

# Create reports directory if it doesn't exist
if ! [ -d "$REPORT_DIR" ]; then
    mkdir -p "$REPORT_DIR"
fi

# Get AWS account ID
echo -e "${BLUE}Fetching AWS account information...${NC}"
ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>/dev/null)

if [[ -z "$ACCOUNT_ID" ]]; then
    echo -e "${RED}Error: Could not get account ID. Check your profile: $PROFILE${NC}"
    exit 1
fi

echo -e "${GREEN}Account ID: $ACCOUNT_ID${NC}"

# Report file
REPORT_FILE="$REPORT_DIR/${ACCOUNT_ID}_key_rotation_$(date +%Y%m%d_%H%M%S).txt"

# Initialize report
{
    echo "=========================================="
    echo "AWS Key Rotation Report"
    echo "=========================================="
    echo "Account ID: $ACCOUNT_ID"
    echo "Profile: $PROFILE"
    echo "Date: $(date)"
    echo "=========================================="
    echo ""
} > "$REPORT_FILE"

# Get all IAM users
echo -e "${BLUE}Fetching IAM users...${NC}"
USERS=$(aws iam list-users --profile "$PROFILE" --query 'Users[*].UserName' --output text)

if [[ -z "$USERS" ]]; then
    echo -e "${YELLOW}No IAM users found in this account${NC}"
    echo "No users found" >> "$REPORT_FILE"
    exit 0
fi

# Process each user
PROCESSED_COUNT=0
KEY_ACTIONS=0

for USER in $USERS; do
    echo -e "${BLUE}Processing user: $USER${NC}"
    
    # Get access keys for the user
    KEYS=$(aws iam list-access-keys --user-name "$USER" --profile "$PROFILE" --query 'AccessKeyMetadata[*].[AccessKeyId,CreateDate]' --output text 2>/dev/null || true)
    
    if [[ -z "$KEYS" ]]; then
        continue
    fi
    
    # Count keys
    KEY_COUNT=$(echo "$KEYS" | wc -l)
    
    echo "  Keys found: $KEY_COUNT" >> "$REPORT_FILE"
    echo "  User: $USER" >> "$REPORT_FILE"
    
    # Process keys
    KEYS_DATA=()
    while IFS=$'\t' read -r KEY_ID CREATE_DATE; do
        KEYS_DATA+=("$KEY_ID:$CREATE_DATE")
    done <<< "$KEYS"
    
    # Calculate key ages and perform actions
    if [[ $KEY_COUNT -eq 1 ]]; then
        # Single key: Never delete, always create a new one
        for KEY_INFO in "${KEYS_DATA[@]}"; do
            IFS=':' read -r KEY_ID CREATE_DATE <<< "$KEY_INFO"
            
            CREATE_TIMESTAMP=$(date -d "$CREATE_DATE" +%s)
            NOW_TIMESTAMP=$(date +%s)
            AGE_DAYS=$(( (NOW_TIMESTAMP - CREATE_TIMESTAMP) / 86400 ))
            
            echo "    - AccessKeyId: $KEY_ID (Age: ${AGE_DAYS} days)" >> "$REPORT_FILE"
            
            echo -e "${YELLOW}      [ACTION] Creating new access key (keeping existing one)${NC}"
            NEW_KEY=$(aws iam create-access-key --user-name "$USER" --profile "$PROFILE" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
            
            echo "      Status: NEW KEY CREATED" >> "$REPORT_FILE"
            echo "      Existing Key: $KEY_ID" >> "$REPORT_FILE"
            echo "      New Key: $NEW_KEY" >> "$REPORT_FILE"
            KEY_ACTIONS=$((KEY_ACTIONS + 1))
        done
        
    elif [[ $KEY_COUNT -eq 2 ]]; then
        # Two keys: Check if any is > 45 days
        OLDEST_KEY=""
        OLDEST_AGE=0
        NOW_TIMESTAMP=$(date +%s)
        HAS_OLD_KEY=false
        
        # Find the oldest key and check if any key is > 45 days
        for KEY_INFO_INNER in "${KEYS_DATA[@]}"; do
            IFS=':' read -r KEY_ID_INNER CREATE_DATE_INNER <<< "$KEY_INFO_INNER"
            CREATE_TIMESTAMP_INNER=$(date -d "$CREATE_DATE_INNER" +%s)
            AGE_DAYS_INNER=$(( (NOW_TIMESTAMP - CREATE_TIMESTAMP_INNER) / 86400 ))
            
            echo "    - AccessKeyId: $KEY_ID_INNER (Age: ${AGE_DAYS_INNER} days)" >> "$REPORT_FILE"
            
            if [[ $AGE_DAYS_INNER -gt $OLDEST_AGE ]]; then
                OLDEST_AGE=$AGE_DAYS_INNER
                OLDEST_KEY=$KEY_ID_INNER
            fi
            
            if [[ $AGE_DAYS_INNER -gt $DAYS_THRESHOLD ]]; then
                HAS_OLD_KEY=true
            fi
        done
        
        if [[ "$HAS_OLD_KEY" == true ]]; then
            # At least one key is > 45 days: Delete oldest and create new one
            echo -e "${YELLOW}      [ACTION] Deleting old key $OLDEST_KEY (${OLDEST_AGE} days old)${NC}"
            aws iam delete-access-key --user-name "$USER" --access-key-id "$OLDEST_KEY" --profile "$PROFILE"
            
            echo -e "${YELLOW}      [ACTION] Creating new access key${NC}"
            NEW_KEY=$(aws iam create-access-key --user-name "$USER" --profile "$PROFILE" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
            
            echo "      Status: ROTATED - Deleted old, created new" >> "$REPORT_FILE"
            echo "      New Key: $NEW_KEY" >> "$REPORT_FILE"
            KEY_ACTIONS=$((KEY_ACTIONS + 1))
        else
            # Both keys are < 45 days: Report both key IDs
            echo -e "${BLUE}      [REPORT] Both keys are < ${DAYS_THRESHOLD} days old${NC}"
            echo "      Status: REVIEW NEEDED - Both keys are active" >> "$REPORT_FILE"
            for KEY_INFO_INNER in "${KEYS_DATA[@]}"; do
                IFS=':' read -r KEY_ID_INNER CREATE_DATE_INNER <<< "$KEY_INFO_INNER"
                echo "      Key: $KEY_ID_INNER" >> "$REPORT_FILE"
            done
        fi
    fi
    
    echo "" >> "$REPORT_FILE"
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
done

# Final summary
{
    echo "=========================================="
    echo "Summary"
    echo "=========================================="
    echo "Users processed: $PROCESSED_COUNT"
    echo "Key actions performed: $KEY_ACTIONS"
    echo "=========================================="
} >> "$REPORT_FILE"

echo -e "${GREEN}Script completed successfully!${NC}"
echo -e "${GREEN}Report saved to: $REPORT_FILE${NC}"
echo -e "${BLUE}Report contents:${NC}"
cat "$REPORT_FILE"

