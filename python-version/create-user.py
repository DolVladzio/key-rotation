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
# JSON required files
users_json = "./json/users.json"

NOT_CREATED_USERS = []

if not identity_store or not users_json:
    logging.error("[ERROR] No identity store id or users json file provided. Exiting.")
    sys.exit(1)

############################################################
# Getting users
############################################################
def getting_users(user_name):
    new_user = False
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
            logging.error(f"[WARNING] Failed to get user's id for the user: '{user_name}'. User does not exist! Creating...\n")
            if user_name not in NOT_CREATED_USERS:
                NOT_CREATED_USERS.append(user_name)
            new_user = True
        else:
            # Handle real AWS errors (e.g., AccessDeniedException, ValidationException)
            logging.error(f"[ERROR] AWS Error looking up user '{user_name}': {e}")
            sys.exit(1)
    except Exception as e:
        logging.error(f"[ERROR] Unexpected error looking up user '{user_name}': {e}")
        sys.exit(1)
        
    return new_user, user_id
############################################################
# Creating users
#############################################################
def create_user_from_record(record):
    user_name = record.get('USER_NAME') or record.get('user_name')
    GIVEN = record.get('GIVEN_NAME') or record.get('given_name') or ''
    FAMILY = record.get('FAMILY_NAME') or record.get('family_name') or ''
    employee_number = record.get('EMPLOYEE_NUMBER') or record.get('employee_number')

    given = GIVEN.capitalize()
    family = FAMILY.capitalize()

    if not user_name:
        logging.error(f"[ERROR] Skipping record with missing USER_NAME: {record}")
        return None

    try:
        payload = {
            'IdentityStoreId': identity_store,
            'UserName': user_name,
            'Name': {
                'GivenName': given,
                'FamilyName': family
            },
            'DisplayName': f"{given} {family}".strip(),
            'Emails': [
                {
                    'Value': user_name,
                    'Type': 'work',
                    'Primary': True
                },
            ],
        }
        resp = sso.create_user(**payload)
        user_id = resp.get('UserId')
        print(f"[SUCCESS] Created user '{user_name}' (ID: {user_id})")
    except ClientError as e:
        logging.error(f"[ERROR] Failed to create user '{user_name}': {e}")
        return None

    # Update employee number if provided
    if employee_number and user_id:
        try:
            sso.update_user(
                IdentityStoreId=identity_store,
                UserId=user_id,
                Operations=[
                    {
                        'AttributePath': 'aws:identitystore:enterprise',
                        "AttributeValue": {
                            "employeeNumber": str(employee_number)
                        }
                    }
                ]
            )
            print(f"[SUCCESS] Updated EmployeeNumber for user '{user_name}' to '{employee_number}'\n")
        except ClientError as e:
            logging.error(f"[ERROR] Failed to update EmployeeNumber for '{user_name}': {e}")

    return user_id

if __name__ == "__main__":
    # Read users file and create/update users as needed
    try:
        with open(users_json, 'r') as f:
            users_map = json.load(f)
    except FileNotFoundError:
        logging.error(f"[ERROR] Users file not found: {users_json}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        logging.error(f"[ERROR] Invalid JSON in {users_json}: {e}")
        sys.exit(1)

    for record in users_map:
        user_name = (record.get('USER_NAME') or record.get('user_name') or '').lower()
        print("#############################################################")
        print(f">>> Processing the user: {user_name}")
        print("#############################################################")

        new_user, user_id = getting_users(user_name)

        if new_user:
            user_id = create_user_from_record(record)
            # Log created user to new-users-doc.txt
            if user_id:
                approval_id = record.get('APPROVAL_ID') or record.get('approval_id') or ''
                entry = f"[{datetime.now().date().isoformat()}] {user_name} - https://doc.{approval_id}\n"
                try:
                    with open('new-users-doc.txt', 'a') as docf:
                        docf.write(entry)
                except Exception as e:
                    logging.error(f"[ERROR] Failed to write new user entry to file: {e}")

        print(f">>> Finished with the user: {user_name} (ID: {user_id})")

        print("#############################################################")