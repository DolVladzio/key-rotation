import argparse
import os
import smtplib
import sys
from email.message import EmailMessage

SMTP_HOST = "smtp.gmail.com"
SMTP_PORT = 465


def parse_args():
    parser = argparse.ArgumentParser(description="Send email through Gmail SMTP.")
    parser.add_argument("--sender", default=os.getenv("GMAIL_USER"), help="Sender email address")
    parser.add_argument("--recipient", action="append", help="Recipient email address. Repeat for multiple recipients.")
    parser.add_argument("--subject", default=os.getenv("EMAIL_SUBJECT", "Rotate Access Key IAM for users"), help="Email subject")
    parser.add_argument("--body", default=os.getenv("EMAIL_BODY", "Hello Team,\n\nThis is an automated message."), help="Email body text")
    parser.add_argument("--app-pass", default=os.getenv("GMAIL_APP_PASS"), help="Gmail App Password for SMTP authentication")
    return parser.parse_args()


def build_message(sender: str, recipients: list[str], subject: str, body_text: str) -> EmailMessage:
    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = sender
    message["To"] = ", ".join(recipients)
    message.set_content(body_text)
    return message


def send_via_smtp(sender: str, recipients: list[str], subject: str, body_text: str, app_pass: str):
    if not sender:
        raise ValueError("Sender address must be provided via --sender or GMAIL_USER environment variable.")
    if not recipients:
        raise ValueError("At least one recipient must be provided via --recipient or EMAIL_RECIPIENTS environment variable.")
    if not app_pass:
        raise ValueError("Gmail app password must be provided via --app-pass or GMAIL_APP_PASS environment variable.")

    message = build_message(sender, recipients, subject, body_text)

    try:
        with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT) as server:
            server.login(sender, app_pass)
            server.send_message(message)
    except smtplib.SMTPAuthenticationError as exc:
        raise RuntimeError(
            "SMTP authentication failed. Check your Gmail app password and ensure 2FA is enabled. "
            f"Original error: {exc}"
        ) from exc
    except Exception as exc:
        raise RuntimeError(f"Failed to send email via SMTP: {exc}") from exc


def main():
    args = parse_args()
    recipients = args.recipient or []
    env_recipients = os.getenv("EMAIL_RECIPIENTS", "")
    if env_recipients:
        recipients.extend([email.strip() for email in env_recipients.split(",") if email.strip()])

    if not recipients:
        raise ValueError("No recipients provided. Use --recipient or set EMAIL_RECIPIENTS environment variable.")

    send_via_smtp(
        sender=args.sender,
        recipients=recipients,
        subject=args.subject,
        body_text=args.body,
        app_pass=args.app_pass,
    )


if __name__ == "__main__":
    try:
        main()
        print("Email sent successfully.")
    except Exception as exc:
        print(f"An error occurred: {exc}")
        sys.exit(1)
