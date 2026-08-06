import logging
import os
import sys
import boto3
import re
from botocore.exceptions import ClientError

sso = boto3.client('identitystore')
identity_store = "d-99674adf84"
if not identity_store or len(identity_store) == 0:
    logging.error("[ERROR] No identity store id provided. Exiting.")
    sys.exit(1)

approval_id = "1234567"
user_names = [
    "dolynkavladzio@gmail.com"
]
group_names = [
    "TestGroup1",
    "TestGroup2",
    "TestGroup3",
    "TestGroup4"
]
if not group_names or len(group_names) == 0 \
    and not user_names or len(user_names) == 0 \
        and not approval_id or len(approval_id) == 0:
    logging.error("[ERROR] No group names or approval id provided. Exiting.")
    sys.exit(1)

NEW_CREATED_GROUPS = []
NOT_CREATED_USERS = []
SKIPPED_MEMBERSHIPS = []
############################################################
# Creating/Getting groups
#############################################################
def creating_getting_groups(group):
    new_group = False
    try:
        # Attempt to get existing group
        response = sso.get_group_id(
            IdentityStoreId=identity_store,
            AlternateIdentifier={
                'UniqueAttribute': {
                    'AttributePath': 'DisplayName',
                    'AttributeValue': group
                }
            }
        )
        group_id = response['GroupId']
        print(f"[INFO] The group '{group}' already exists (ID: {group_id}).")
    except ClientError as e:
        error_code = e.response['Error']['Code']
        # ResourceNotFoundException means we can safely create it
        if error_code == 'ResourceNotFoundException':
            print(f"[INFO] The group '{group}' does not exist. Creating...")
            try:
                create_response = sso.create_group(
                    IdentityStoreId=identity_store,
                    DisplayName=group,
                    Description=f"{approval_id} 2026"
                )
                created_id = create_response['GroupId']
                print(f"[SUCCESS] Successfully created '{group}' (ID: {created_id}).")
                NEW_CREATED_GROUPS.append(group)
                new_group = True
                
            except ClientError as create_error:
                logging.error(f"[ERROR] Failed to create group '{group}': {create_error}")
                sys.exit(1)
        else:
            # Handle real errors (e.g., AccessDeniedException, ValidationException)
            logging.error(f"[ERROR] AWS Error looking up group '{group}': {e}")
            sys.exit(1)
            
    return group_id, new_group
            
############################################################
# Upd group descriptions
#############################################################
def upd_group_descriptions(group_id):
    try:
        # Getting current group's description
        get_group_desc_response = sso.describe_group(
            IdentityStoreId=identity_store,
            GroupId=group_id
        )
        current_group_desc = get_group_desc_response.get('Description', 'No description set')
        print(f">>> The description for the group: {group}\n{current_group_desc}")
        
        if "2026" not in current_group_desc:
            # Case: "2026" doesn't exist -> append to end
            new_group_desc = f"{current_group_desc} {approval_id} 2026".strip()
        elif not f"{approval_id} 2026" in current_group_desc:
            # Case: Match ANY numbers (\d+) before 2026 and insert approval id in between
            # r'(\d+)\s+2026' matches "123456 2026", "888 2026", "42 2026", etc.
            pattern = r'(\d+)\s+2026'
            
            if re.search(pattern, current_group_desc):
                # \1 keeps the dynamic number found, then adds approval id before 2026
                new_group_desc = re.sub(pattern, rf'\1 {approval_id} 2026', current_group_desc)
            else:
                # Fallback if "2026" exists but doesn't have a number directly before it
                new_group_desc = current_group_desc
        else:
            new_group_desc = current_group_desc

        if new_group_desc != current_group_desc:
            print(f">>> Updating the description in the group: {group}...")
            try:
                sso.update_group(
                    IdentityStoreId=identity_store,
                    GroupId=group_id,
                    Operations=[
                        {
                            'AttributePath': 'Description',
                            'AttributeValue': new_group_desc
                        }
                    ]
                )
                print(f"[SUCCESS] Updated description from:\n'{current_group_desc}'\nto:\n'{new_group_desc}'")
            except ClientError as e:
                print(f"[ERROR] The group's description for the group: {group} was not updated")
                sys.exit(1)
        else:
            print("[INFO] No update needed.")
    except ClientError as e:
        logging.error(f"[ERROR] AWS Error updating the desc in the group: '{group}': {e}")
        sys.exit(1)
        
############################################################
# Group assignments
#############################################################
def group_assignments(new_group, group):
    if new_group:
        print(f">>> Initiating group assignments for the new group: {group}...")    

############################################################
# Getting users
#############################################################
def getting_users(user):
    new_user = False
    try:
        response = sso.get_user_id(
            IdentityStoreId=identity_store,
            AlternateIdentifier={
                'UniqueAttribute': {
                    'AttributePath': 'UserName',
                    'AttributeValue': user
                }
            }
        )
        user_id = response['UserId']
        print(f"[INFO] The user '{user}' already exists (ID: {user_id}).\n")
    except Exception as e:
        error_code = e.response['Error']['Code']
        # ResourceNotFoundException means we can safely add it to array NOT_CREATED_USERS
        if error_code == 'ResourceNotFoundException':
            logging.error(f"[WARNING] Failed to get user's id for the user: '{user}'. User does not exist!\n")
            NOT_CREATED_USERS.append(user)
            new_user = True
        else:
            # Handle real errors (e.g., AccessDeniedException, ValidationException)
            logging.error(f"[ERROR] AWS Error looking up user '{group}': {e}")
            sys.exit(1)
            
    return new_user

if __name__ == "__main__":
    for group in group_names:
        print("#############################################################")
        print(f">>> Processing the group: {group}")
        print("#############################################################")
        group_id, new_group = creating_getting_groups(group)
        
        upd_group_descriptions(group_id)
        
        group_assignments(new_group, group)
        
        # USERS
        for user in user_names:
            print("#############################################################")
            print(f">>> Processing the user: {user}")
            print("#############################################################")
            
            new_user = getting_users(user)
            
            if new_user:
                print(f"The user: {user} is going to be created. Creating...")
            else:
                continue
            
            print(f">>> Finished with the user: {user}")
           
        print(f">>> Finished with the group: {group}")

    if NEW_CREATED_GROUPS:  # Evaluates to True ONLY if the list is non-empty
        print("#############################################################")
        print("New created groups:")
        for new_group in NEW_CREATED_GROUPS:
            print(f"- {new_group}")
            
    if NOT_CREATED_USERS:  # Evaluates to True ONLY if the list is non-empty
        print("#############################################################")
        print("Now created users:")
        for missing_user in NOT_CREATED_USERS:
            print(f"- {missing_user}")
