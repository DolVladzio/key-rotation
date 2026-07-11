# Скрипт ротації ключів AWS IAM

Автоматизований інструмент для ротації AWS IAM access keys, який перевіряє вік ключів, створює нові ключі та записує звіти.

## Що робить

- ✅ Працює з IAM користувачами
- ✅ Генерує нові ключі при необхідності
- ✅ Лише деактивує старі ключі за правилами
- ✅ Зберігає детальні звіти у `reports/`
- ✅ Відправляє email сповіщення після ротації

## Перед запуском

1. Налаштуйте AWS профіль: відредагуйте масив `AWS_PROFILES` у `rotation/key-rotation.sh`
```bash
AWS_PROFILES=(
iamfullaccess-111111111111
iamfullaccess-222222222222
iamfullaccess-333333333333
)
```

2. Переконайтеся, що профіль має права:
- `iam:ListUsers`
- `iam:ListAccessKeys`
- `iam:DeleteAccessKey`
- `iam:CreateAccessKey`
- `sts:GetCallerIdentity`

3. Зробіть головний скрипт виконуваним:

```bash
chmod +x rotation/key-rotation.sh
```

4. Підготуйте Gmail app password для SMTP-відправки:

```bash
export GMAIL_APP_PASS="your-app-password"
```

5. Якщо хочете змінити відправника, відредагуйте змінну `email_sender` у `rotation/key-rotation.sh`:

```bash
email_sender="sender-email@privatbank.ua"
```


6. Якщо хочете змінити одержувачів, відредагуйте масив `email_recipients` у `rotation/key-rotation.sh`:

```bash
email_recipients=(
user-1@privatbank.ua
)
```

7. За потреби протестуйте Python-скрипт окремо:

```bash
cd rotation
python3 send-emails.py \
  --sender "sender@gmail.com" \
  --recipient "user1@example.com" \
  --recipient "user2@example.com" \
  --subject "IAM Key Rotation" \
  --body "Key rotation completed." \
  --app-pass "$GMAIL_APP_PASS"
```

## Як запускати

```bash
cd rotation
./key-rotation.sh
```

## Структура проекту

- `rotation/key-rotation.sh` — основний скрипт ротації
- `rotation/send-emails.py` — відправка пошти через Gmail SMTP
- `rotation/reports/` — звіти про виконання

## Увага

- Не передавайте `SecretAccessKey` у відкритих каналах
- Звіти можуть містити ідентифікатори та секретні дані
- Зберігайте `GMAIL_APP_PASS` у безпечному місці

