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

DAYS_THRESHOLD=45
PROFILE="${1:-}"

if [[ -z "$PROFILE" ]]; then
    echo -e "${RED}Error: AWS profile name is required${NC}"
    echo "Usage: $0 <profile-name>"
    exit 1
fi

echo -e "${BLUE}Fetching AWS account information...${NC}"
ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>/dev/null)

if [[ -z "$ACCOUNT_ID" ]]; then
    echo -e "${RED}Error: Could not get account ID. Check your profile: $PROFILE${NC}"
    exit 1
fi

REPORT_DIR="./reports/$ACCOUNT_ID"
# Create reports directory if it doesn't exist
if ! [ -d "$REPORT_DIR" ]; then
    mkdir -p "$REPORT_DIR"
fi

echo -e "${GREEN}Account ID: $ACCOUNT_ID${NC}"
REPORT_FILE="$REPORT_DIR/$(date +%Y%m%d_%H%M%S).txt"

{
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
else
    echo -e "${GREEN}Found $(echo "$USERS" | wc -w) users${NC}"
fi

# Process each user
PROCESSED_COUNT=0
KEY_ACTIONS=0

for USER in $USERS; do
    echo -e "${BLUE}Processing user: $USER${NC}"
    
    # Get access keys for the user
    KEYS=$(aws iam list-access-keys --user-name "$USER" --profile "$PROFILE" --query 'AccessKeyMetadata[*].[AccessKeyId,CreateDate]' --output text 2>/dev/null || true)
    
    if [[ -z "$KEYS" ]]; then
        echo -e "${BLUE}      [REPORT] No keys found${NC}"
        continue
    fi
    
    # Count keys
    KEY_COUNT=$(echo "$KEYS" | wc -l)
    
    echo "  IAM юзер: arn:aws:iam::$ACCOUNT_ID:user/$USER" >> "$REPORT_FILE"
    echo "  Ключів знайдено: $KEY_COUNT" >> "$REPORT_FILE"

    # Retrieve OWNER and CUSTOMER tags
    echo -e "${BLUE}      [INFO] Retrieving OWNER and CUSTOMER tags for user $USER...${NC}"
    echo "  Tags:" >> "$REPORT_FILE"
    TAGS=$(aws iam list-user-tags --user-name "$USER" \
            --profile "$PROFILE" \
            --query 'Tags[*].[Key,Value]' \
            --output text 2>/dev/null || true)
    
    if [[ -z "$TAGS" ]]; then
        echo -e "${YELLOW}      [WARNING] Could not retrieve tags for user $USER${NC}"
        echo "    WARNING: Tags unavailable" >> "$REPORT_FILE"
    else
        MATCHED=0
        while IFS=$'\t' read -r TAG_KEY TAG_VALUE; do
            if [[ "${TAG_KEY^^}" == "OWNER" || "${TAG_KEY^^}" == "CUSTOMER" ]]; then
                echo "    $TAG_KEY: $TAG_VALUE" >> "$REPORT_FILE"
                MATCHED=1
            fi
        done <<< "$TAGS"

        if [[ $MATCHED -eq 1 ]]; then
            echo -e "${GREEN}      [INFO] Tags retrieved successfully${NC}"
        else
            echo -e "${YELLOW}      [WARNING] OWNER/CUSTOMER tags not found for user $USER${NC}"
            echo "    WARNING: OWNER/CUSTOMER tags not found" >> "$REPORT_FILE"
        fi
    fi
    
    # Process keys
    echo "  Access Keys:" >> "$REPORT_FILE"
    KEYS_DATA=()
    while IFS=$'\t' read -r KEY_ID CREATE_DATE; do
        # Get last used data for each key
        LAST_USED=$(aws iam get-access-key-last-used --access-key-id "$KEY_ID" --profile "$PROFILE" --query 'AccessKeyLastUsed.LastUsedDate' --output text 2>/dev/null || echo "None")
        if [[ "$LAST_USED" == "None" || "$LAST_USED" == "null" || -z "$LAST_USED" ]]; then
            LAST_USED="Never"
        fi
        KEYS_DATA+=("$KEY_ID|$CREATE_DATE|$LAST_USED")
    done <<< "$KEYS"

    # Single key: never delete, always create a new one
    if [[ $KEY_COUNT -eq 1 ]]; then
        IFS='|' read -r KEY_ID CREATE_DATE LAST_USED <<< "${KEYS_DATA[0]}"
        CREATE_TIMESTAMP=$(date -d "$CREATE_DATE" +%s)
        NOW_TIMESTAMP=$(date +%s)
        AGE_DAYS=$(( (NOW_TIMESTAMP - CREATE_TIMESTAMP) / 86400 ))

        if [[ "$LAST_USED" == "Never" ]]; then
            LAST_USED_STATUS="Never"
        else
            LAST_USED_TS=$(date -d "$LAST_USED" +%s)
            LAST_USED_AGE_DAYS=$(( (NOW_TIMESTAMP - LAST_USED_TS) / 86400 ))
            LAST_USED_STATUS="($LAST_USED_AGE_DAYS days ago)"
        fi

        echo "    - AccessKeyId: $KEY_ID (${AGE_DAYS} days old, LastUsed: $LAST_USED_STATUS)" >> "$REPORT_FILE"
        echo -e "${YELLOW}      [ACTION] Creating new access key (keeping existing one)${NC}"
        NEW_KEY=$(aws iam create-access-key --user-name "$USER" --profile "$PROFILE" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
        if [[ -z "$NEW_KEY" ]]; then
            echo -e "${RED}      [ERROR] Failed to create new access key${NC}"
            echo "      Status: ERROR - Failed to create new access key" >> "$REPORT_FILE"
            exit 1
        fi

        echo "      Status: NEW KEY CREATED" >> "$REPORT_FILE"
        echo "      New Key: $NEW_KEY" >> "$REPORT_FILE"
        KEY_ACTIONS=$((KEY_ACTIONS + 1))

    elif [[ $KEY_COUNT -eq 2 ]]; then
        NOW_TIMESTAMP=$(date +%s)
        ELIGIBLE_KEY=""
        ELIGIBLE_AGE=0
        DELETE_REASON=""

        for KEY_INFO in "${KEYS_DATA[@]}"; do
            IFS='|' read -r KEY_ID CREATE_DATE LAST_USED <<< "$KEY_INFO"
            CREATE_TIMESTAMP=$(date -d "$CREATE_DATE" +%s)
            CREATE_AGE_DAYS=$(( (NOW_TIMESTAMP - CREATE_TIMESTAMP) / 86400 ))

            if [[ "$LAST_USED" == "Never" ]]; then
                LAST_USED_STATUS="Never"
                LAST_USED_AGE_DAYS=99999
            else
                LAST_USED_TS=$(date -d "$LAST_USED" +%s)
                LAST_USED_AGE_DAYS=$(( (NOW_TIMESTAMP - LAST_USED_TS) / 86400 ))
                LAST_USED_STATUS="($LAST_USED_AGE_DAYS days ago)"
            fi

            echo "    - AccessKeyId: $KEY_ID (${CREATE_AGE_DAYS} days old, LastUsed: $LAST_USED_STATUS)" >> "$REPORT_FILE"

            if [[ $CREATE_AGE_DAYS -gt $DAYS_THRESHOLD && "$LAST_USED" == "Never" ]]; then
                if [[ $CREATE_AGE_DAYS -gt $ELIGIBLE_AGE ]]; then
                    ELIGIBLE_KEY="$KEY_ID"
                    ELIGIBLE_AGE=$CREATE_AGE_DAYS
                fi
                DELETE_REASON="created > ${DAYS_THRESHOLD} days and never used"
            elif [[ $CREATE_AGE_DAYS -gt $DAYS_THRESHOLD && "$LAST_USED" != "Never" && $LAST_USED_AGE_DAYS -gt $DAYS_THRESHOLD ]]; then
                if [[ $CREATE_AGE_DAYS -gt $ELIGIBLE_AGE ]]; then
                    ELIGIBLE_KEY="$KEY_ID"
                    ELIGIBLE_AGE=$CREATE_AGE_DAYS
                fi
                DELETE_REASON="created > ${DAYS_THRESHOLD} days and last used > ${DAYS_THRESHOLD} days ago"
            fi
        done

        if [[ -n "$ELIGIBLE_KEY" ]]; then
            echo -e "${YELLOW}      [ACTION] Deleting old key $ELIGIBLE_KEY ($DELETE_REASON)${NC}"
            if ! aws iam delete-access-key --user-name "$USER" --access-key-id "$ELIGIBLE_KEY" --profile "$PROFILE"; then
                echo -e "${RED}      [ERROR] Failed to delete key $ELIGIBLE_KEY${NC}"
                echo "      Status: ERROR - Failed to delete key $ELIGIBLE_KEY" >> "$REPORT_FILE"
                exit 1
            fi

            echo -e "${YELLOW}      [ACTION] Creating new access key${NC}"
            NEW_KEY=$(aws iam create-access-key --user-name "$USER" --profile "$PROFILE" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
            if [[ -z "$NEW_KEY" ]]; then
                echo -e "${RED}      [ERROR] Failed to create new access key${NC}"
                echo "      Status: ERROR - Failed to create new access key" >> "$REPORT_FILE"
                exit 1
            fi

            echo "      Status: ROTATED - Deleted old key and created new key" >> "$REPORT_FILE"
            echo "      Deleted Key: $ELIGIBLE_KEY" >> "$REPORT_FILE"
            echo "      New Key: $NEW_KEY" >> "$REPORT_FILE"
            KEY_ACTIONS=$((KEY_ACTIONS + 1))
        else
            echo -e "${BLUE}      [REPORT] No keys are eligible for deletion${NC}"
            echo "      Status: REVIEW ONLY - No deletion performed" >> "$REPORT_FILE"
        fi
    else
        echo -e "${YELLOW}      [WARNING] Unsupported key count: $KEY_COUNT. Skipping advanced rotation logic.${NC}"
        echo "      Status: SKIPPED - Unsupported key count" >> "$REPORT_FILE"
        for KEY_INFO in "${KEYS_DATA[@]}"; do
            IFS='|' read -r KEY_ID CREATE_DATE LAST_USED <<< "$KEY_INFO"
            echo "      Key: $KEY_ID" >> "$REPORT_FILE"
        done
    fi

    echo "" >> "$REPORT_FILE"
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
done

# Final summary
{
    echo "=========================================="
    echo "Users processed: $PROCESSED_COUNT"
    echo "Key actions performed: $KEY_ACTIONS"
    echo "=========================================="
} >> "$REPORT_FILE"

echo -e "${GREEN}Script completed successfully!${NC}"
echo -e "${GREEN}Report saved to: $REPORT_FILE${NC}"
