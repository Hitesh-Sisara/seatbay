# Security policy

Seatbay handles sensitive things: Claude sign-in data inside backups, S3 keys, an encryption
passphrase and API keys. Please report security problems privately.

## Reporting a vulnerability

Use GitHub's private reporting: **Security → Report a vulnerability** on
[the repository](https://github.com/Hitesh-Sisara/seatbay/security/advisories/new). Please include the
Seatbay version, macOS version, what an attacker can do and how to reproduce it. You'll get a reply
within a few days, and a fix and advisory as soon as possible.

Please don't open a public issue for a vulnerability, and don't include real keys, passphrases or
backups in a report.

## Supported versions

Security fixes go into the latest release.

## How Seatbay protects your data

- Nothing is sent anywhere except backups you upload to your own S3-compatible bucket and the
  connection test to an API you configure. There is no telemetry.
- Backups are encrypted on your Mac before upload with AES-256-GCM; the key comes from your
  passphrase via PBKDF2-HMAC-SHA256 (600,000 rounds, random salt per file).
- S3 keys and the passphrase are stored in `secrets.json` with `0600` permissions. API keys live in
  the instance's own data folder, and Claude seals them with your keychain when it starts.
- Instance apps and Seatbay itself are ad-hoc signed and not notarized; build from source if you
  prefer to verify what you run.
