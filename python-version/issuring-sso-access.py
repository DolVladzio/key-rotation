import logging
import os
import sys
import time
import boto3
import re
import json
from botocore.exceptions import ClientError
# SSO config
sso = boto3.client('identitystore')
sso_admin = boto3.client("sso-admin")
identity_store = "d-99674adf84"
sso_instance_arn = "arn:aws:sso:::instance/ssoins-69871e4b7efde7cd"
# JSON required files
perm_sets_file = "./json/perm-sets.json"
accounts_list_info_file = "./json/accounts-list-info.json"

if not sso_instance_arn or not identity_store or not perm_sets_file or not accounts_list_info_file:
    logging.error("[ERROR] No identity store id, sso instance arn, perm sets file or accounts list file provided. Exiting.")
    sys.exit(1)

approval_id = ""
user_names = [
    ""
]
group_names = [
    ""
]
if not group_names or len(group_names) == 0 \
    and not user_names or len(user_names) == 0 \
        and not approval_id or len(approval_id) == 0:
    logging.error("[ERROR] No group names, user names or approval id provided. Exiting.")
    sys.exit(1)

NEW_CREATED_GROUPS = []
NOT_CREATED_USERS = []
SKIPPED_MEMBERSHIPS = {}
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
                group_id = create_response['GroupId']
                print(f"[SUCCESS] Successfully created '{group}' (ID: {group_id}).")
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
# Analyzing group name to get account id and perm set name
#############################################################
def preparing_group_assignments(group, accounts_list_info_file):
    try:
        with open(accounts_list_info_file, "r") as f:
            accounts_map = json.load(f)
    except FileNotFoundError:
        accounts_map = {}
    except json.JSONDecodeError as e:
        logging.error(f"[ERROR] Invalid JSON in {accounts_list_info_file}: {e}")
        sys.exit(1)

    best_match = None
    best_account_name = None
    for account_name, account_id in accounts_map.items():
        account_name_lower = account_name.lower()
        prefix = account_name_lower + '-'
        if group.startswith(prefix):
            if best_match is None or len(account_name_lower) > len(best_match):
                best_match = account_name_lower
                best_account_name = account_name
                best_account_id = account_id

    if not best_match:
        logging.error(f"[ERROR] Account name prefix for group '{group}' was not found in {accounts_list_info_file}.")
        sys.exit(1)

    perm_set_name = group[len(best_account_name) + 1:]
    if not perm_set_name:
        logging.error(f"[ERROR] Group name '{group}' does not include a permission set after the account name '{best_account_name}'.")
        sys.exit(1)

    print(f"\n[SUCCESS] For account '{best_account_name}' found id: {best_account_id} in the json file!")
    return best_account_id, perm_set_name
############################################################
# Getting perm set arn
#############################################################
def get_perm_set_arn(perm_set, sso_instance_arn, perm_sets_file):
    # Load existing local cache
    try:
        with open(perm_sets_file, "r") as f:
            perm_set_map = json.load(f)
    except FileNotFoundError:
        perm_set_map = {}
    except json.JSONDecodeError as e:
        logging.error(f"[ERROR] Invalid JSON in {perm_sets_file}: {e}")
        sys.exit(1)

    # If found in JSON, return directly
    if perm_set in perm_set_map:
        print(f"\n[SUCCESS] Permission set: {perm_set} is found in the json file!")
        return perm_set_map[perm_set]

    # If NOT in JSON, fetch all from AWS and update local JSON cache
    print(f"\n[INFO] '{perm_set}' not in local JSON. Fetching from AWS...")
    paginator = sso_admin.get_paginator('list_permission_sets')

    for page in paginator.paginate(InstanceArn=sso_instance_arn):
        for arn in page['PermissionSets']:
            details = sso_admin.describe_permission_set(
                InstanceArn=sso_instance_arn, PermissionSetArn=arn
            )
            name = details['PermissionSet']['Name']
            perm_set_map[name] = arn

    # Save updated mapping back to JSON
    try:
        with open(perm_sets_file, "w") as f:
            json.dump(perm_set_map, f, indent=4)
    except IOError as e:
        logging.error(f"[ERROR] Could not write permission set cache to {perm_sets_file}: {e}")
        sys.exit(1)

    return perm_set_map.get(perm_set)
############################################################
# Group assignments
#############################################################
def group_assignments(group_id, group, target_account_id, permission_set_arn):
    if not all([sso_instance_arn, target_account_id, permission_set_arn]):
        logging.error("[ERROR] Missing SSO assignment configuration. Set sso_instance_arn, target_account_id, and permission_set_arn.")
        sys.exit(1)

    try:
        response = sso_admin.create_account_assignment(
            InstanceArn=sso_instance_arn,
            TargetId=target_account_id,
            TargetType='AWS_ACCOUNT',
            PermissionSetArn=permission_set_arn,
            PrincipalType='GROUP',
            PrincipalId=group_id
        )
        creation_status = response['AccountAssignmentCreationStatus']
        request_id = creation_status['RequestId']
        status = creation_status['Status']
        print(f"[INFO] Account assignment request created (ID: {request_id}). Status: {status}")

        while status not in ('SUCCEEDED', 'FAILED', 'EXCEPTION'):
            time.sleep(5)
            describe_response = sso_admin.describe_account_assignment_creation_status(
                InstanceArn=sso_instance_arn,
                AccountAssignmentCreationRequestId=request_id
            )
            creation_status = describe_response['AccountAssignmentCreationStatus']
            status = creation_status['Status']
            print(f"[INFO] Assignment request {request_id} current status: {status}")

        if status == 'SUCCEEDED':
            print(f"[SUCCESS] Group assignment for '{group}' succeeded.")
        else:
            failure_reason = creation_status.get('FailureReason', 'Unknown failure reason')
            logging.error(f"[ERROR] Group assignment for '{group}' ended with status {status}: {failure_reason}\n")
            sys.exit(1)

    except ClientError as e:
        logging.error(f"[ERROR] Unexpected AWS error creating the assignment: {e}")
        sys.exit(1)
############################################################
# Getting users
#############################################################
def getting_users(user):
    new_user = False
    user_id = None
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
    except ClientError as e:
        error_code = e.response['Error']['Code']
        # ResourceNotFoundException means the user does not exist
        if error_code == 'ResourceNotFoundException':
            logging.error(f"[WARNING] Failed to get user's id for the user: '{user}'. User does not exist!\n")
            if user not in NOT_CREATED_USERS:
                NOT_CREATED_USERS.append(user)
            new_user = True
        else:
            # Handle real AWS errors (e.g., AccessDeniedException, ValidationException)
            logging.error(f"[ERROR] AWS Error looking up user '{user}': {e}")
            sys.exit(1)
    except Exception as e:
        logging.error(f"[ERROR] Unexpected error looking up user '{user}': {e}")
        sys.exit(1)
        
    return new_user, user_id
############################################################
# Group Memberships
#############################################################
def get_group_membership_id(user_id, user, group, grop_id):
    try:
        response = sso.get_group_membership_id(
            IdentityStoreId=identity_store,
            GroupId=grop_id,
            MemberId={
                'UserId': user_id
            }
        )
        membership_id = response['MembershipId']
        print(f"[INFO] The user '{user}' was found in the group: {group}(MembershipId: {membership_id}).\n")
    except ClientError as e:
        error_code = e.response['Error']['Code']
        if error_code == 'ResourceNotFoundException':
            print(f"[WARNING] Failed to get membership id! Creating the membership...")
            try:
                response = sso.create_group_membership(
                    IdentityStoreId=identity_store,
                    GroupId=grop_id,
                    MemberId={
                        'UserId': user_id
                    }
                )
                membership_id = response['MembershipId']
                print(f"[SUCCESS] Successfully created the membership:\n\tUser: '{user}\n\tGroup: {group}'\n\tMembership ID: ({membership_id}).\n")
            except Exception as e:
                SKIPPED_MEMBERSHIPS[user] = group
                logging.error(f"[ERROR] Failed to create an membership '{user}': {group}")
        else:
            # Handle real AWS errors (e.g., AccessDeniedException, ValidationException)
            logging.error(f"[ERROR] AWS Error looking up the membership id '{group}': {e}")
            sys.exit(1)
    except Exception as e:
        logging.error(f"[ERROR] Unexpected error looking up the membership id '{group}': {e}")
        sys.exit(1)
        
    return membership_id

if __name__ == "__main__":
    for GROUP in group_names:
        group = GROUP.lower()
        print("#############################################################")
        print(f">>> Processing the group: {group}")
        print("#############################################################")
        group_id, new_group = creating_getting_groups(group)
        
        upd_group_descriptions(group_id)
        # Launching this when a new group is created
        if new_group:
            target_account_id, perm_set_name = preparing_group_assignments(group, accounts_list_info_file)
            permission_set_arn = get_perm_set_arn(perm_set_name, sso_instance_arn, perm_sets_file)
            if not permission_set_arn:
                logging.error(f"[ERROR] Permission set '{perm_set_name}' was not found.")
                sys.exit(1)
            group_assignments(group_id, group, target_account_id, permission_set_arn)
        
        # USERS
        for USER in user_names:
            user = USER.lower()
            print("#############################################################")
            print(f">>> Processing the user: {user}")
            print("#############################################################")
            
            new_user, user_id = getting_users(user)

            if not new_user and user_id is not None:
                get_group_membership_id(user_id, user, group, group_id)
            else:
                print(f"[INFO] Skipping group membership for missing user '{user}'.\n")
            
            print(f">>> Finished with the user: {user}")
            print("#############################################################")
           
        print(f">>> Finished with the group: {group}")

    if NEW_CREATED_GROUPS:  # Evaluates to True ONLY if the list is non-empty
        print("\nNew created groups:")
        for new_group in NEW_CREATED_GROUPS:
            print(f"- {new_group}")
            
    if NOT_CREATED_USERS:  # Evaluates to True ONLY if the list is non-empty
        print("\nNot created users:")
        for missing_user in NOT_CREATED_USERS:
            print(f"- {missing_user}")
            
    if SKIPPED_MEMBERSHIPS:  # Evaluates to True ONLY if the list is non-empty
        print("\nSkipped memberships:")
        for skipped_membership in SKIPPED_MEMBERSHIPS:
            print(f"- {skipped_membership}")
