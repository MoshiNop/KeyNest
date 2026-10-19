# Vault Management & Maintenance

KeyNest allows you to open, manage, and synchronize multiple KDBX vaults concurrently. This guide covers multi-vault workflows, vault security audits, master password changes, and key file operations.

---

## 1. Managing Multiple Vaults

You can keep distinct vaults for different security domains (e.g. `Personal.kdbx`, `Work.kdbx`, and `FamilyShared.kdbx`).

### Adding Another Vault
1. Open the side menu or tap the `+` action button on the home screen.
2. Select **Open Vault** or **Create Vault**.
3. Once unlocked, both vaults appear simultaneously on your main screen under their own collapsible section headers.

### Unlocking & Locking Individual Vaults
- **Per-Vault Lock:** Tap the three-dot menu on any vault header and select **Lock Vault** to clear decrypted memory and lock that specific vault.
- **Lock All Vaults:** Tapping **Lock All** in the drawer or pressing `Ctrl+L` (`Cmd+L` on macOS) immediately locks all active vaults.

---

## 2. Vault Health Audit

KeyNest provides an integrated **Vault Health** dashboard that analyzes your vault entries for security vulnerabilities:

1. Open **Settings** → **Vault Health** (or tap the health indicator icon on the vault header).
2. The audit evaluates:
   - **Reused Passwords:** Identifies identical passwords used across multiple unrelated services.
   - **Weak Passwords:** Flags passwords with low entropy or fewer than 12 characters.
   - **Missing 2FA:** Highlights login entries for high-value services that do not yet have a TOTP token attached.
   - **Expiring Credentials:** Displays items with configured expiration dates that require rotation.

---

## 3. Changing Master Password & KDF Parameters

You can rotate your vault's master password at any time without losing any entry data or history:

1. Open the vault header menu and select **Manage Vault** → **Change Master Password**.
2. Enter your **Current Master Password**.
3. Enter your **New Master Password** and re-type to confirm.
4. **(Optional) Configure Key Derivation Function (KDF):**
   - **Argon2id (Recommended):** Provides maximum resistance against GPU/ASIC brute-force attacks. Configurable memory limit (e.g., 64 MB) and iterations.
   - **AES-KDF:** Standard KeePass 2.x transformation rounds for legacy compatibility.
5. Tap **Save Changes**. KeyNest re-encrypts the entire vault file with the new master key and saves it to disk or cloud.

---

## 4. Using Key Files

A Key File provides hardware/file-based secondary authentication for your vault.

### Generating a Key File in KeyNest
1. While creating a vault or changing credentials, select **Create Key File**.
2. KeyNest generates a cryptographically random 256-bit binary key file (`.keyx` or `.key`).
3. Save the file to an external location (e.g. a secure USB drive or offline storage).

### Best Practices for Key Files
- **Never store your key file in the same cloud folder as your `.kdbx` file.** Doing so eliminates the security benefit of two-factor authentication.
- Keep a secure offline backup of the key file. If the file is lost or corrupted, the vault cannot be unlocked.

---

[← Getting Started](getting-started.md) • [User Guide Index](README.md) • [Passwords & Entries →](passwords-and-entries.md)
