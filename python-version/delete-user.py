import logging
import os
import sys
import time
import boto3
import re
import json
from datetime import datetime
from botocore.exceptions import ClientError
# SSO config
sso = boto3.client('identitystore')
identity_store = "d-99674adf84"

USERS = [

]
APPROVAL_ID = ""

if not identity_store or not USERS or not APPROVAL_ID:
    logging.error("[ERROR] No identity store id, user names or approval id provided. Exiting.")
    sys.exit(1)
############################################################
# Getting users
############################################################
def getting_users(user_name):
    user_id = None
    try:
        response = sso.get_user_id(
            IdentityStoreId=identity_store,
            AlternateIdentifier={
                'UniqueAttribute': {
                    'AttributePath': 'UserName',
                    'AttributeValue': user_name
                }
            }
        )
        user_id = response['UserId']
        print(f"[INFO] The user '{user_name}' already exists (ID: {user_id}).\n")
    except ClientError as e:
        error_code = e.response['Error']['Code']
        # ResourceNotFoundException means the user does not exist
        if error_code == 'ResourceNotFoundException':
            logging.error(f"[WARNING] Failed to get user's id for the user: '{user_name}'. User does not exist!\n")
            return None
        else:
            # Handle real AWS errors (e.g., AccessDeniedException, ValidationException)
            logging.error(f"[ERROR] AWS Error looking up user '{user_name}': {e}")
            sys.exit(1)
    except Exception as e:
        logging.error(f"[ERROR] Unexpected error looking up user '{user_name}': {e}")
        sys.exit(1)
        
    return user_id
############################################################
# Creating users
#############################################################
def deleting_users(user_id, user_name):
    if not user_id:
        logging.info(f"[INFO] No user id for '{user_name}', skipping deletion.")
        return None

    try:
        payload = {
            'IdentityStoreId': identity_store,
            'UserId': user_id
        }
        resp = sso.delete_user(**payload)
        print(f"[SUCCESS] User: '{user_name}' was deleted")
        # Log deleted user to delete-users-doc.txt
        entry = f"[{datetime.now().date().isoformat()}] {user_name} - https://doc.{APPROVAL_ID}\n"
        try:
            with open('delete-users-doc.txt', 'a') as docf:
                docf.write(entry)
        except Exception as e:
            logging.error(f"[ERROR] Failed to write delete user entry to file: {e}")
    except ClientError as e:
        logging.error(f"[ERROR] Failed to delete the user '{user_name}': {e}")
        return None

    return user_id

if __name__ == "__main__":
    for USER in USERS:
        user_name = USER.lower()
        print("#############################################################")
        print(f">>> Processing the user: {user_name}")
        print("#############################################################")

        user_id = getting_users(user_name)

        deleting_users(user_id, user_name)

        print(f">>> Finished with the user: {user_name} (ID: {user_id})")
