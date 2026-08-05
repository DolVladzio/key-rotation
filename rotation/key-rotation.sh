#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DAYS_THRESHOLD=45
AWS_PROFILES=(

)
if [[ ${#AWS_PROFILES[@]} -eq 0 ]]; then
    echo -e "${RED}Error: No AWS profiles specified. Please set the 'AWS_PROFILES' array in the script.${NC}"
    exit 1
fi
###################################################################
# Email configuration #
###################################################################
email_sender=""
if [[ -z "$email_sender" ]]; then
    echo -e "${RED}Error: Email sender is not set. Please set the 'email_sender' variable in the script.${NC}"
    exit 1
fi

email_recipients=(
# default recepients

)
if [[ ${#email_recipients[@]} -eq 0 ]]; then
    echo -e "${RED}Error: No email recipients specified. Please set the 'email_recipients' array in the script.${NC}"
    exit 1
else
    for USER in "${email_recipients[@]}"; do
        user=${USER,,}
        if ! [[ "$user" == *@privatbank.ua ]]; then
            echo -e "${RED}[Error]: The email recipient $USER doesn't end with @privatbank.ua${NC}"
            exit 1
        fi
    done
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMAIL_SCRIPT="$SCRIPT_DIR/send-emails.py"
LDAP_INFO_FILE="$SCRIPT_DIR/../json/ldap-info.json"
PYTHON_CMD="$(command -v python3 || command -v python || true)"

if [[ ! -f "$LDAP_INFO_FILE" ]]; then
    echo -e "${YELLOW}Warning: LDAP info file not found: $LDAP_INFO_FILE. Tag-based recipients will not be resolved.${NC}"
fi
####################################################################
# Emails Template
###################################################################
email_title="Rotate Access Key IAM for users"
template_text="Шановні колеги!

Для дотримання вимог Парольної політики у сервісах AWS IAM (https://doc.privatbank.ua/#/doc=6516620&year=2026&folder=ANOTHER_UNDONE), згідно проєкту 23/463-IT Emergency Cyber Security checks and mitigations, повідомляємо про необхідність ротації ключів до технічних IAM користувачів раз у 45днів."

if [[ -z "$template_text" ]]; then
    echo -e "${RED}Error: template_text is not set${NC}"
    exit 1
fi
###################################################################
# Functions
###################################################################
create_new_key_text() {
    local account_id="$1"
    local account_name="$2"
    local user_arn="$3"
    local old_key_id="$4"
    local new_key_pair="$5"

    printf '%s\n\nАкаунт: %s #%s\nIAM user: %s\nСтарий ключ: %s\nНова пара: %s\n\nПісля замінив ключа, повідомте співробітників ІБ зворотнім листом!' \
        "$template_text" "$account_name" "$account_id" "$user_arn" "$old_key_id" "$new_key_pair"
}

leave_existing_key_text() {
    local account_id="$1"
    local account_name="$2"
    local user_arn="$3"
    local old_key_1="$4"
    local old_key_2="$5"

    printf '%s\n\nАкаунт: %s #%s\nIAM user: %s\nСтарий ключ 1: %s\nСтарий ключ 2: %s\nПідкажіть, будь ласка, який ключ можна видалити?' \
        "$template_text" "$account_name" "$account_id" "$user_arn" "$old_key_1" "$old_key_2"
}

write_email_message() {
    local message="$1"
    local report_file="$2"

    echo -e "\nEmail body:" >> "$report_file"
    printf '%s\n' "$message" >> "$report_file"
}

append_unique_recipient() {
    local email="$1"
    local found=0

    for item in "${user_recipients[@]}"; do
        [[ "$item" == "$email" ]] && found=1 && break
    done

    if [[ $found -eq 0 ]]; then
        user_recipients+=("$email")
    fi
}

resolve_ldap_email() {
    local ldap_key="$1"

    if [[ -z "$ldap_key" || ! -f "$LDAP_INFO_FILE" ]]; then
        return 1
    fi

    local email
    email=$(jq -r --arg key "$ldap_key" '.[$key] // empty' "$LDAP_INFO_FILE" 2>/dev/null || true)
    if [[ -n "$email" ]]; then
        printf '%s' "$email"
        return 0
    fi
    return 1
}

send_email_message() {
    local subject="$1"
    local body="$2"
    shift 2
    local recipients=("$@")

    if [[ ${#recipients[@]} -eq 0 ]]; then
        recipients=("${email_recipients[@]}")
    fi

    if [[ -z "$PYTHON_CMD" ]]; then
        echo -e "${RED}Error: Python interpreter not found.${NC}"
        return 1
    fi

    if [[ ! -x "$PYTHON_CMD" && ! -f "$PYTHON_CMD" ]]; then
        echo -e "${RED}Error: Python interpreter is not executable: $PYTHON_CMD${NC}"
        return 1
    fi

    if [[ ! -f "$EMAIL_SCRIPT" ]]; then
        echo -e "${RED}Error: Email script not found: $EMAIL_SCRIPT${NC}"
        return 1
    fi

    local cmd=("$PYTHON_CMD" "$EMAIL_SCRIPT" --sender "$email_sender" --subject "$subject" --body "$body")

    for recipient in "${recipients[@]}"; do
        cmd+=(--recipient "$recipient")
    done

    for replyTo_recipient in "${recipients[@]}"; do
        cmd+=(--replyTo "$replyTo_recipient")
    done

    if [[ -n "$PROFILE" ]]; then
        AWS_PROFILE="$PROFILE" "${cmd[@]}"
    else
        "${cmd[@]}"
    fi
}

send_user_email() {
    local subject="$1"
    local body="$2"

    if [[ ${send_notifications:-0} -eq 0 ]]; then
        echo -e "${YELLOW}      [INFO] Email notification skipped for user $USER because OWNER/CUSTOMER recipients could not be resolved${NC}"
        return 0
    fi

    send_email_message "$subject" "$body" "${user_recipients[@]}"
}

if [[ -z "$AWS_PROFILES" ]]; then
    echo -e "${RED}Error: AWS_PROFILES is not set${NC}"
    exit 1
fi

for PROFILE in "${AWS_PROFILES[@]}"; do
    echo -e "${BLUE}Processing AWS profile: $PROFILE${NC}"
    echo -e "${BLUE}Fetching AWS account information...${NC}"
    
    ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>/dev/null)
    if [[ -z "$ACCOUNT_ID" ]]; then
        echo -e "${RED}Error: Could not get account ID. Check your profile: $PROFILE${NC}"
        exit 1
    fi
    
    ACCOUNT_NAME=$(jq -r ".\"$ACCOUNT_ID\"" ../json/accounts-info.json 2>/dev/null || echo "Unknown")
    if [[ -z "$ACCOUNT_NAME" || "$ACCOUNT_NAME" == "Unknown" ]]; then
        echo -e "${YELLOW}Warning: Could not get account name for account ID $ACCOUNT_ID.${NC}"
    fi

    REPORT_DIR="./reports/$ACCOUNT_ID"
    if ! [ -d "$REPORT_DIR" ]; then
        mkdir -p "$REPORT_DIR"
    fi

    echo -e "${GREEN}Account: $ACCOUNT_NAME ($ACCOUNT_ID)${NC}"
    REPORT_FILE="$REPORT_DIR/$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "=========================================="
        echo "Account: $ACCOUNT_NAME ($ACCOUNT_ID)"
        echo "Profile: $PROFILE"
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
        
        echo -e "\tIAM юзер: arn:aws:iam::$ACCOUNT_ID:user/$USER" >> "$REPORT_FILE"
        echo -e "\tКлючів знайдено: $KEY_COUNT" >> "$REPORT_FILE"

        # Retrieve OWNER and CUSTOMER tags
        echo -e "${BLUE}      [INFO] Retrieving OWNER and CUSTOMER tags for user $USER...${NC}"
        echo -e "\tTags:" >> "$REPORT_FILE"
        TAGS=$(aws iam list-user-tags --user-name "$USER" \
                --profile "$PROFILE" \
                --query 'Tags[*].[Key,Value]' \
                --output text 2>/dev/null || true)
        
        owner_customer_tags_found=0
        tag_recipients_added=0

        if [[ -z "$TAGS" ]]; then
            echo -e "${YELLOW}      [WARNING] Could not retrieve tags for user $USER${NC}"
            echo "    WARNING: Tags unavailable" >> "$REPORT_FILE"
        else
            while IFS=$'\t' read -r TAG_KEY TAG_VALUE; do
                TAG_KEY_UPPER="${TAG_KEY^^}"
                if [[ "$TAG_KEY_UPPER" == *OWNER* || "$TAG_KEY_UPPER" == *CUSTOMER* ]]; then
                    echo -e "\t    $TAG_KEY: $TAG_VALUE" >> "$REPORT_FILE"
                    owner_customer_tags_found=1
                fi
            done <<< "$TAGS"

            if [[ $owner_customer_tags_found -eq 1 ]]; then
                echo -e "${GREEN}      [INFO] Tags retrieved successfully${NC}"
            else
                echo -e "${YELLOW}      [WARNING] OWNER/CUSTOMER related tags not found for user $USER${NC}"
                echo "    WARNING: OWNER/CUSTOMER related tags not found" >> "$REPORT_FILE"
            fi
        fi

        user_recipients=("${email_recipients[@]}")
        if [[ -n "$TAGS" && -f "$LDAP_INFO_FILE" ]]; then
            while IFS=$'\t' read -r TAG_KEY TAG_VALUE; do
                TAG_KEY_UPPER="${TAG_KEY^^}"
                if [[ "$TAG_KEY_UPPER" == *OWNER* || "$TAG_KEY_UPPER" == *CUSTOMER* ]]; then
                    LDAP_EMAIL="$(resolve_ldap_email "$TAG_VALUE")"
                    if [[ -n "$LDAP_EMAIL" ]]; then
                        append_unique_recipient "$LDAP_EMAIL"
                        tag_recipients_added=1
                    else
                        echo -e "${YELLOW}      [WARNING] Could not resolve LDAP tag value '$TAG_VALUE' to email${NC}"
                        echo "    WARNING: Unresolved LDAP tag value '$TAG_VALUE'" >> "$REPORT_FILE"
                    fi
                fi
            done <<< "$TAGS"
        fi

        if [[ $owner_customer_tags_found -eq 0 ]]; then
            echo -e "${YELLOW}      [WARNING] Missing OWNER/CUSTOMER tags for user $USER; skipping email notification${NC}"
            echo "    WARNING: Missing OWNER/CUSTOMER tags; skipping notifications" >> "$REPORT_FILE"
            send_notifications=0
        elif [[ $tag_recipients_added -eq 0 ]]; then
            echo -e "${YELLOW}      [WARNING] OWNER/CUSTOMER tags found but no LDAP recipients resolved for user $USER; skipping email notification${NC}"
            echo "    WARNING: No LDAP recipients resolved from tag values; skipping notifications" >> "$REPORT_FILE"
            send_notifications=0
        else
            send_notifications=1
        fi

        if [[ ${#user_recipients[@]} -eq 0 ]]; then
            user_recipients=("${email_recipients[@]}")
        fi
        
        # Process keys
        echo -e "\tAccess Keys:" >> "$REPORT_FILE"
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
                LAST_USED_AGE_SECONDS=$(( NOW_TIMESTAMP - LAST_USED_TS ))
                LAST_USED_AGE_DAYS=$(( LAST_USED_AGE_SECONDS / 86400 ))
                LAST_USED_AGE_HOURS=$(( (LAST_USED_AGE_SECONDS % 86400) / 3600 ))
                LAST_USED_AGE_MINUTES=$(( (LAST_USED_AGE_SECONDS % 3600) / 60 ))

                if [[ $LAST_USED_AGE_DAYS -gt 0 ]]; then
                    LAST_USED_STATUS="($LAST_USED_AGE_DAYS days ago)"
                elif [[ $LAST_USED_AGE_HOURS -gt 0 ]]; then
                    LAST_USED_STATUS="($LAST_USED_AGE_HOURS hours ago)"
                elif [[ $LAST_USED_AGE_MINUTES -gt 0 ]]; then
                    LAST_USED_STATUS="($LAST_USED_AGE_MINUTES minutes ago)"
                else
                    LAST_USED_STATUS="(just now)"
                fi
            fi

            echo -e "\t\t- AccessKeyId: $KEY_ID (${AGE_DAYS} days old, LastUsed: $LAST_USED_STATUS)" >> "$REPORT_FILE"
            echo -e "${YELLOW}      [ACTION] Creating new access key(Keeping existing one)${NC}"
            NEW_KEY=$(aws iam create-access-key --user-name "$USER" --profile "$PROFILE" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
            if [[ -z "$NEW_KEY" ]]; then
                echo -e "\t\t    ${RED}      [ERROR] Failed to create new access key${NC}"
                echo -e "\t\t    Status: ERROR - Failed to create new access key" >> "$REPORT_FILE"
                exit 1
            fi

            read -r -a NEW_KEY_FIELDS <<< "$NEW_KEY"
            NEW_KEY_ID="${NEW_KEY_FIELDS[0]}"
            NEW_KEY_SECRET="${NEW_KEY_FIELDS[1]}"

            EMAIL_BODY=$(create_new_key_text "$ACCOUNT_ID" "$ACCOUNT_NAME" "arn:aws:iam::$ACCOUNT_ID:user/$USER" "$KEY_ID" "$NEW_KEY")

            echo -e "\t\tStatus: NEW KEY CREATED" >> "$REPORT_FILE"
            echo -e "\t\tНова пара: $NEW_KEY_ID $NEW_KEY_SECRET" >> "$REPORT_FILE"
            write_email_message "$EMAIL_BODY" "$REPORT_FILE"

            if ! send_user_email "$email_title" "$EMAIL_BODY"; then
                echo -e "${RED}      [ERROR] Failed to send email notification${NC}"
                echo -e "\t\tStatus: ERROR - Failed to send email notification" >> "$REPORT_FILE"
                exit 1
            else
                echo -e "${GREEN}      [INFO] Email notification flow completed${NC}"
            fi

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
                    LAST_USED_AGE_SECONDS=$(( NOW_TIMESTAMP - LAST_USED_TS ))
                    LAST_USED_AGE_DAYS=$(( LAST_USED_AGE_SECONDS / 86400 ))
                    LAST_USED_AGE_HOURS=$(( (LAST_USED_AGE_SECONDS % 86400) / 3600 ))
                    LAST_USED_AGE_MINUTES=$(( (LAST_USED_AGE_SECONDS % 3600) / 60 ))

                    if [[ $LAST_USED_AGE_DAYS -gt 0 ]]; then
                        LAST_USED_STATUS="($LAST_USED_AGE_DAYS days ago)"
                    elif [[ $LAST_USED_AGE_HOURS -gt 0 ]]; then
                        LAST_USED_STATUS="($LAST_USED_AGE_HOURS hours ago)"
                    elif [[ $LAST_USED_AGE_MINUTES -gt 0 ]]; then
                        LAST_USED_STATUS="($LAST_USED_AGE_MINUTES minutes ago)"
                    else
                        LAST_USED_STATUS="(just now)"
                    fi
                fi

                echo -e "\t\t- AccessKeyId: $KEY_ID (${CREATE_AGE_DAYS} days old, LastUsed: $LAST_USED_STATUS)" >> "$REPORT_FILE"

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
                    echo -e "\tStatus: ERROR - Failed to delete key $ELIGIBLE_KEY" >> "$REPORT_FILE"
                    exit 1
                fi

                echo -e "${YELLOW}      [ACTION] Creating new access key${NC}"
                NEW_KEY=$(aws iam create-access-key --user-name "$USER" --profile "$PROFILE" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
                if [[ -z "$NEW_KEY" ]]; then
                    echo -e "${RED}      [ERROR] Failed to create new access key${NC}"
                    echo -e "\tStatus: ERROR - Failed to create new access key" >> "$REPORT_FILE"
                    exit 1
                fi

                read -r -a NEW_KEY_FIELDS <<< "$NEW_KEY"
                NEW_KEY_ID="${NEW_KEY_FIELDS[0]}"
                NEW_KEY_SECRET="${NEW_KEY_FIELDS[1]}"
                EMAIL_BODY=$(create_new_key_text "$ACCOUNT_ID" "$ACCOUNT_NAME" "arn:aws:iam::$ACCOUNT_ID:user/$USER" "$ELIGIBLE_KEY" "$NEW_KEY")

                echo -e "\tStatus: ROTATED - Deleted old key and created new key" >> "$REPORT_FILE"
                echo -e "\tDeleted Key: $ELIGIBLE_KEY" >> "$REPORT_FILE"
                echo -e "\tНова пара $NEW_KEY_ID $NEW_KEY_SECRET" >> "$REPORT_FILE"
                write_email_message "$EMAIL_BODY" "$REPORT_FILE"
                
                if ! send_user_email "$email_title" "$EMAIL_BODY"; then
                    echo -e "${RED}      [ERROR] Failed to send email notification${NC}"
                    echo -e "\tStatus: ERROR - Failed to send email notification" >> "$REPORT_FILE"
                    exit 1
                else
                    echo -e "${GREEN}      [INFO] Email notification flow completed${NC}"
                fi
                
                KEY_ACTIONS=$((KEY_ACTIONS + 1))
            else
                echo -e "${BLUE}      [REPORT] No keys are eligible for deletion${NC}"
                echo -e "\tStatus: REVIEW ONLY - No deletion performed" >> "$REPORT_FILE"
                EMAIL_BODY=$(leave_existing_key_text "$ACCOUNT_ID" "$ACCOUNT_NAME" "arn:aws:iam::$ACCOUNT_ID:user/$USER" "${KEYS_DATA[0]%%|*}" "${KEYS_DATA[1]%%|*}")

                write_email_message "$EMAIL_BODY" "$REPORT_FILE"

                if ! send_user_email "$email_title" "$EMAIL_BODY"; then
                    echo -e "${RED}      [ERROR] Failed to send email notification${NC}"
                    echo -e "\tStatus: ERROR - Failed to send email notification" >> "$REPORT_FILE"
                    exit 1
                else
                    echo -e "${GREEN}      [INFO] Email notification flow completed${NC}"
                fi
            fi
        else
            echo -e "${YELLOW}      [WARNING] Unsupported key count: $KEY_COUNT. Skipping advanced rotation logic.${NC}"
            echo -e "\tStatus: SKIPPED - Unsupported key count" >> "$REPORT_FILE"
            for KEY_INFO in "${KEYS_DATA[@]}"; do
                IFS='|' read -r KEY_ID CREATE_DATE LAST_USED <<< "$KEY_INFO"
                echo -e "\tKey: $KEY_ID" >> "$REPORT_FILE"
            done
        fi

        echo "" >> "$REPORT_FILE"
        PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
        echo "--------------------------------------------------------------------------" >> "$REPORT_FILE"
    done

    {
        echo "=========================================="
        echo "Users processed: $PROCESSED_COUNT"
        echo "Key actions performed: $KEY_ACTIONS"
        echo "=========================================="
    } >> "$REPORT_FILE"

    echo -e "${GREEN}Script completed successfully!${NC}"
    echo -e "${GREEN}Report saved to: $REPORT_FILE${NC}"
    echo -e "${GREEN}Successfully finished aws --profile $PROFILE${NC}"
done