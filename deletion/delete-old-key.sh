#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

JSON_FILE="./user-key-info.json"

if [[ ! -f "$JSON_FILE" ]]; then
    echo -e "${RED}Error: JSON file not found: $JSON_FILE${NC}"
    exit 1
fi

jq -r '.[] | @base64' "$JSON_FILE" | while read -r entry; do
    _jq() {
        echo "$entry" | base64 --decode | jq -r "$1"
    }

    USER_ARN=$(_jq '.user_arn')
    ACCESS_KEY_ID=$(_jq '.user_key_id')

    if [[ -z "$USER_ARN" || -z "$ACCESS_KEY_ID" ]]; then
        echo -e "${YELLOW}Required envs are missing${NC}"
        exit 1
    fi

    if [[ "$USER_ARN" != arn:aws:iam::*:user/* ]]; then
        echo -e "${RED}Error: invalid user_arn: $USER_ARN${NC}"
        continue
    fi

    USERNAME="${USER_ARN##*/}"
    ACCOUNT_ID="$(echo "$USER_ARN" | awk -F':' '{print $5}')"
    PROFILE="iamfullaccess-${ACCOUNT_ID}"

    echo -e "${BLUE}Deleting access key $ACCESS_KEY_ID for user $USERNAME in account $ACCOUNT_ID${NC}"

    if ! aws iam delete-access-key \
        --user-name "$USERNAME" \
        --access-key-id "$ACCESS_KEY_ID" \
        --profile "$PROFILE"; then
        echo -e "${RED}Error: Failed to delete access key $ACCESS_KEY_ID for user $USERNAME${NC}"
    fi
    echo -e "${GREEN}Successfully deleted access key $ACCESS_KEY_ID for user $USERNAME in account $ACCOUNT_ID${NC}"
    echo ""
done
echo ""
echo -e "${GREEN}All requested access keys processed.${NC}"
