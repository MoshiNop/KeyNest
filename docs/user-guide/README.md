# KeyNest User Guide

Welcome to the **KeyNest User Guide**. This documentation provides step-by-step instructions for everyday users, from creating your first encrypted vault to configuring cloud synchronization and autofill on mobile devices.

---

## Guide Index

| Topic | Description | Link |
| :--- | :--- | :--- |
| **Installation** | Platform installation instructions for Android, iOS, Windows, macOS, Linux, and Web. | [Read Guide](installation.md) |
| **Getting Started** | Setting up your first vault, choosing a strong master password, and exploring the interface. | [Read Guide](getting-started.md) |
| **Vault Management** | Managing multiple vaults, health audits, changing master passwords, and key files. | [Read Guide](vault-management.md) |
| **Passwords & Entries** | Organizing entries, archetypes (logins, cards, notes, records), and the password generator. | [Read Guide](passwords-and-entries.md) |
| **Two-Factor Authentication (TOTP)** | Setting up TOTP tokens, QR code scanning via camera, and migration imports. | [Read Guide](totp.md) |
| **Autofill Integration** | Enabling and using native autofill on Android and iOS credential provider extensions. | [Read Guide](autofill.md) |
| **Cloud Storage & Sync** | Connecting Google Drive, WebDAV (Nextcloud / ownCloud), Dropbox, and OneDrive. | [Read Guide](cloud-storage.md) |
| **Import & Export** | Migrating from Bitwarden, 1Password, KeePass, or Chrome CSV, and exporting backups. | [Read Guide](import-export.md) |
| **Troubleshooting** | Solutions for sync conflicts, vault unlock issues, biometric errors, and common questions. | [Read Guide](troubleshooting.md) |

---

## Core Security Concepts

KeyNest is built upon the open **KeePass KDBX format** (supporting both KDBX 3.1 and KDBX 4.x). Understanding two key principles will help you keep your credentials secure:

1. **Zero-Knowledge Architecture:**
   - Your master password and encryption keys never leave your device.
   - Cloud storage providers only ever see an encrypted `.kdbx` file. Even if your cloud account is compromised, your vault cannot be decrypted without your master password and/or key file.
2. **Local Vault Ownership:**
   - There is no centralized "KeyNest account". You own your data file directly.
   - You can store your vault offline on your device, sync it via your own private WebDAV server (such as Nextcloud), or use trusted cloud providers.

---

[← Back to Documentation Index](../README.md) • [Proceed to Installation →](installation.md)
