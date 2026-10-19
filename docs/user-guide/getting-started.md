# Getting Started with KeyNest

This guide walks you through creating your first vault, opening an existing KeePass database, and navigating the KeyNest user interface.

---

## 1. Creating a New Vault

When you launch KeyNest for the first time, you will be greeted by the welcome screen offering two choices: **Create New Vault** or **Open Existing Vault**.

1. Select **Create New Vault**.
2. **Choose a Storage Location:**
   - **Local Storage:** Keep the `.kdbx` file directly on your device filesystem.
   - **Cloud Storage:** Connect directly to Google Drive, WebDAV (Nextcloud / ownCloud), Dropbox, or OneDrive.
3. **Name your Vault:** Enter a descriptive name (e.g. `Personal`, `Work`).
4. **Set a Master Password:**
   - Enter a strong, memorable passphrase.
   - KeyNest includes a real-time entropy estimator (`zxcvbn`) that indicates password strength and estimated crack time.
   - **Crucial Warning:** KeyNest cannot recover or reset a forgotten master password. Store a secure offline backup of your passphrase.
5. **(Optional) Attach a Key File:**
   - You can create or attach a secondary key file for composite two-factor vault authentication (something you know + something you have).
6. Tap **Create Vault**. KeyNest derives encryption keys using Argon2id or AES-KDF and initializes your new KDBX 4.x vault.

---

## 2. Opening an Existing Vault

If you already use KeePass, KeePassXC, or another KDBX-compatible manager:

1. Tap **Open Existing Vault**.
2. Select your vault source:
   - **Local File / Document Picker:** Browse for your `.kdbx` file. On Android, this uses the Storage Access Framework (SAF) to preserve persistent read/write permissions.
   - **Cloud Storage:** Authenticate with your cloud provider and choose your `.kdbx` file.
3. Enter your Master Password.
4. If your vault requires a Key File, select **Select Key File** before unlocking.
5. Tap **Unlock Vault**.

---

## 3. Interface Overview

KeyNest's interface is structured into four main operational areas:

```text
┌────────────────────────────────────────────────────────┐
│  [≡] KeyNest           [Search / Quick Filter]     [+] │  ← Top App Bar & Quick Add
├────────────────────────────────────────────────────────┤
│  [All (142)] [Logins (98)] [Cards (4)] [Notes (12)]   │  ← Category Filter Chips
├────────────────────────────────────────────────────────┤
│  ▼ Personal Vault (Google Drive)                       │  ← Vault Header & Sync Status
│    ├── 🔑 github.com (octocat)                         │
│    ├── 🔑 google.com (user@gmail.com) [2FA Active]     │  ← Entry List with Visual Badges
│    └── 💳 Chase Sapphire Visa (•••• 4321)              │
│                                                        │
├────────────────────────────────────────────────────────┤
│  [ Vaults ]       [ Generator ]      [ Settings ]      │  ← Navigation Bar
└────────────────────────────────────────────────────────┘
```

- **Vault Section:** Expand or collapse individual vaults. Each header displays a compact storage badge (e.g., Google Drive, SAF, Local, WebDAV) and quick sync status.
- **Filter Chips:** Instantly filter your credential list by archetype: **Logins**, **Payment Cards**, **Secure Notes**, **Identities**, or **2FA Tokens**.
- **Search Bar:** Real-time incremental search across entry titles, usernames, URLs, and notes.

---

## 4. Enabling Biometric Unlock

After opening your vault with your master password:

1. Navigate to **Settings** → **Security**.
2. Toggle on **Biometric Unlock** (Fingerprint / Face Unlock / Touch ID / Windows Hello).
3. Confirm with your biometric sensor.
4. On subsequent app launches, you can unlock your vault instantly with a biometric scan.

---

[← Installation](installation.md) • [User Guide Index](README.md) • [Vault Management →](vault-management.md)
