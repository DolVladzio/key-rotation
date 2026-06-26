# AWS IAM Key Rotation Script

Automated AWS IAM access key rotation and management tool that handles key lifecycle based on age and count.

## Features

- ✅ Automatic key rotation based on age (45 days threshold)
- ✅ Smart key management (single key vs multiple keys)
- ✅ Access key reporting and tracking
- ✅ Multi-account support via AWS profiles
- ✅ Detailed audit logs saved to reports directory
- ✅ Color-coded console output for easy monitoring

## Requirements

- AWS CLI v2 installed and configured
- AWS IAM permissions to:
  - `iam:ListUsers`
  - `iam:ListAccessKeys`
  - `iam:DeleteAccessKey`
  - `iam:CreateAccessKey`
  - `sts:GetCallerIdentity`
- Valid AWS profiles configured in `~/.aws/config`

## Installation

```bash
# Make it executable
chmod +x key-rotation.sh
```

## Usage

```bash
./key-rotation.sh <profile-name>
```

### Example

```bash
./key-rotation.sh prod-account
./key-rotation.sh staging-account
./key-rotation.sh dev-account
```

## How It Works

### Key Rotation Logic

The script checks each IAM user's access keys and applies different rules based on:

#### Single Key (1 key exists)
- **Always**: 
  - ✅ Create a new key (keep the existing one - never delete)
  - 📝 Log to report file with both old and new key IDs

#### Two Keys (2 keys exist)
- **If any key > 45 days**: 
  - ❌ Delete the oldest key
  - ✅ Create a new key
  - 📝 Log to report file

- **If both keys ≤ 45 days**: 
  - ℹ️ No action taken (no deletion, no new key creation)
  - 📝 Report both key IDs (for manual review and deletion by owner)

### Report Generation

Reports are saved to the `reports/` directory with the following naming format:
```
{ACCOUNT_ID}_key_rotation_{TIMESTAMP}.txt
```

Each report includes:
- Account ID and Profile name
- Timestamp of execution
- List of all processed users
- Access key details (ID, age, actions taken)
- Summary statistics

## Output Examples

### Console Output
```
Fetching AWS account information...
Account ID: 123456789012
Fetching IAM users...
Processing user: john.doe
  [ACTION] Deleting key AKIAIOSFODNN7EXAMPLE (50 days old)
  [ACTION] Creating new access key
Processing user: jane.smith
  [REPORT] Both keys are < 45 days old
Script completed successfully!
Report saved to: reports/123456789012_key_rotation_20260626_143022.txt
```

### Report File Example
```
==========================================
AWS Key Rotation Report
==========================================
Account ID: 123456789012
Profile: prod-account
Date: Thu Jun 26 14:30:22 UTC 2026
Threshold: 45 days
==========================================

User: john.doe
  Keys found: 1
    - AccessKeyId: AKIAIOSFODNN7EXAMPLE (Age: 50 days)
    Status: ROTATED - Deleted old, created new
    New Key: AKIAIOSFODNN7NEWKEY

User: jane.smith
  Keys found: 2
    - AccessKeyId: AKIAIOSFODNN7KEY1 (Age: 20 days)
    - AccessKeyId: AKIAIOSFODNN7KEY2 (Age: 15 days)
    Status: REPORT ONLY - Both keys require review
    Key: AKIAIOSFODNN7KEY1
    Key: AKIAIOSFODNN7KEY2

==========================================
Summary
==========================================
Users processed: 2
Key actions performed: 1
==========================================
```

## Security Considerations

⚠️ **Important**: 
- New access keys are printed in the report file. **Handle with care!**
- Consider using AWS Secrets Manager to securely distribute new keys
- Rotate the `SecretAccessKey` to users securely (never via email or chat)
- Review reports regularly for unauthorized key creation
- Consider implementing MFA for all IAM users
- Monitor CloudTrail for key rotation activities

## Scheduling (Optional)

To run this script on a schedule, use a cron job:

```bash
# Run key rotation daily at 2 AM for prod account
0 2 * * * /home/user/key-rotation/key-rotation.sh prod-account >> /tmp/key-rotation.log 2>&1

# Run weekly for staging
0 3 * * 0 /home/user/key-rotation/key-rotation.sh staging-account >> /tmp/key-rotation.log 2>&1
```

## Troubleshooting

### Error: "Could not get account ID. Check your profile"
```bash
# Verify AWS credentials are configured
aws sts get-caller-identity --profile your-profile

# List available profiles
aws configure list-profiles
```

### Permission Denied
```bash
# Ensure your IAM user has the required permissions
# Check IAM policy includes the required actions mentioned in Requirements
```

### Report Not Generated
```bash
# Check reports directory exists and is writable
ls -la ./reports/
```

## Report Analysis

After running the script on multiple accounts, you can analyze reports:

```bash
# View all reports
ls -lah reports/

# Check key rotation actions in a specific account
grep "ROTATED" reports/123456789012*.txt

# Find users with multiple old keys
grep "REPORT ONLY" reports/*.txt

# Count total keys rotated
grep -c "ROTATED" reports/*.txt | awk -F: '{sum+=$2} END {print "Total rotations:", sum}'
```

## Architecture

```
key-rotation/
├── key-rotation.sh          # Main rotation script
├── README.md                # This file
└── reports/                 # Auto-generated reports
    ├── 123456789012_key_rotation_*.txt
    ├── 987654321098_key_rotation_*.txt
    └── ...
```

## License

MIT License