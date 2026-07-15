import argparse
import os
import smtplib
import sys
from email.message import EmailMessage

SMTP_HOST = "mail.internal.privatbank.ua"  # e.g., "10.20.30.40"
SMTP_PORT = 25  # Port 25 is the corporate standard for internal relays


def parse_args():
    parser = argparse.ArgumentParser(description="Send email through Internal SMTP Relay.")
    # Your work email will be the sender now
    parser.add_argument("--sender", help="Sender email address")
    parser.add_argument("--recipient", action="append", help="Recipient email address.")
    parser.add_argument("--subject", help="Email subject")
    parser.add_argument("--body", help="Email body text")
    return parser.parse_args()


def build_message(sender: str, recipients: list[str], subject: str, body_text: str) -> EmailMessage:
    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = sender
    message["To"] = ", ".join(recipients)
    message.set_content(body_text)
    return message


def send_via_internal_smtp(sender: str, recipients: list[str], subject: str, body_text: str):
    message = build_message(sender, recipients, subject, body_text)

    try:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=10) as server:
            server.send_message(message)
            
    except Exception as exc:
        raise RuntimeError(f"Failed to send email via Internal Relay: {exc}") from exc


def main():
    args = parse_args()
    recipients = args.recipient or []
    env_recipients = os.getenv("EMAIL_RECIPIENTS", "")
    if env_recipients:
        recipients.extend([email.strip() for email in env_recipients.split(",") if email.strip()])

    if not recipients:
        raise ValueError("No recipients provided. Use --recipient or set EMAIL_RECIPIENTS environment variable.")

    send_via_internal_smtp(
        sender=args.sender,
        recipients=recipients,
        subject=args.subject,
        body_text=args.body,
    )


if __name__ == "__main__":
    try:
        main()
        print("Notification sent successfully via internal relay.")
    except Exception as exc:
        print(f"An error occurred: {exc}")
        sys.exit(1)