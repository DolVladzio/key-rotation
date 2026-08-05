import argparse
import os
import sys
import boto3
from botocore.exceptions import ClientError
from email.message import EmailMessage

AWS_REGION = os.getenv("AWS_DEFAULT_REGION")

def parse_args():
    parser = argparse.ArgumentParser(description="Send email through AWS SES API.")
    parser.add_argument("--sender", default=os.getenv("SES_SENDER"), help="Verified SES Sender email address")
    parser.add_argument("--recipient", action="append", help="Recipient email address. Repeat for multiple recipients.")
    parser.add_argument("--subject", default=os.getenv("EMAIL_SUBJECT", "Rotate Access Key IAM for users"), help="Email subject")
    parser.add_argument("--body", default=os.getenv("EMAIL_BODY", "Hello Team,\n\nThis is an automated message."), help="Email body text")
    parser.add_argument("--replyTo", action="append", help="Reply-To email address. Repeat for multiple addresses.")
    return parser.parse_args()

def build_message(sender: str, recipients: list[str], replyTo: list[str], subject: str, body_text: str) -> EmailMessage:
    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = sender
    message["To"] = ", ".join(recipients)

    if replyTo:
        message["Reply-To"] = ", ".join(replyTo)

    message.set_content(body_text)
    return message

def send_via_ses(sender: str, recipients: list[str], replyTo: list[str], subject: str, body_text: str):
    if not sender:
        raise ValueError("Sender address must be provided via --sender or SES_SENDER environment variable.")
    if not recipients:
        raise ValueError("At least one recipient must be provided.")

    message = build_message(sender, recipients, replyTo, subject, body_text)

    ses_client = boto3.client('ses', region_name=AWS_REGION)

    try:
        print(f"Sending email via AWS SES API...")
        response = ses_client.send_raw_email(
            Source=sender,
            Destinations=recipients,
            RawMessage={
                'Data': message.as_bytes()
            }
        )
        print(f"Email sent! Message ID: {response['MessageId']}")

    except ClientError as exc:
        raise RuntimeError(f"AWS SES API Error: {exc.response['Error']['Message']}") from exc
    except Exception as exc:
        raise RuntimeError(f"Failed to send email via SES: {exc}") from exc

def main():
    args = parse_args()
    recipients = args.recipient or []

    reply_to_list = args.replyTo or []

    env_recipients = os.getenv("EMAIL_RECIPIENTS", "")
    if env_recipients:
        recipients.extend([email.strip() for email in env_recipients.split(",") if email.strip()])

    if not recipients:
        raise ValueError("No recipients provided. Use --recipient or set EMAIL_RECIPIENTS environment variable.")

    send_via_ses(
        sender=args.sender,
        recipients=recipients,
        replyTo=reply_to_list,
        subject=args.subject,
        body_text=args.body,
    )

if __name__ == "__main__":
    try:
        main()
        print("Process completed successfully.")
    except Exception as exc:
        print(f"An error occurred: {exc}")
        sys.exit(1)