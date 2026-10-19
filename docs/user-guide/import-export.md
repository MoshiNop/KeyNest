# Import & Export Workflows

KeyNest provides robust import and export capabilities, making it easy to migrate your credentials from other password managers or create secure plaintext and encrypted backups.

---

## 1. Supported Importers

KeyNest includes a dedicated visual CSV importer with automatic column detection and customizable field mapping:

| Source Manager | Supported File Types | Extracted Fields |
| :--- | :--- | :--- |
| **Bitwarden** | CSV, JSON | Title, Username, Password, URL, TOTP, Notes, Custom Fields, Folders. |
| **1Password** | CSV, 1PIF | Title, Username, Password, Website, One-Time Password, Secure Notes. |
| **KeePass / KeePassXC** | Native `.kdbx` (3.x/4.x), XML | Complete vault fidelity, entry history, icons, custom fields. |
| **Google Chrome / Chromium** | CSV | Title/Name, URL, Username, Password. |
| **Custom CSV** | Any standard `.csv` | Interactive column-by-column mapping interface. |

---

## 2. Importing Credentials into KeyNest

### Step-by-Step CSV Import
1. Export your password file from your existing manager (e.g. Bitwarden → Settings → Export Vault → `.csv`).
2. Open KeyNest, navigate to **Settings** → **Import**, and select **Import CSV File**.
3. Choose your exported `.csv` file.
4. **Field Mapping Preview:**
   - KeyNest automatically scans the header row and maps columns such as `Title`, `Username`, `Password`, `URL`, and `TOTP`.
   - If your CSV contains custom columns (e.g., `PIN`, `Security Question`), you can manually assign them to custom attributes or notes.
5. Select the destination vault and target group.
6. Tap **Import Entries**. KeyNest processes the records, creates the corresponding entries, and upgrades any sensitive custom fields to protected values.
7. **Security Reminder:** Permanently delete the unencrypted `.csv` file from your computer or phone after completing the import.

---

## 3. Exporting Your Vault

You can export your credentials at any time:

### Export Formats
1. **Standard KDBX Vault (`.kdbx`):**
   - The safest and recommended export option. Generates a fully encrypted, standard KeePass 4 database with a master password of your choosing.
2. **KeePass XML (`.xml`):**
   - Creates an unencrypted or standard XML representation of your vault tree.
3. **Plain CSV (`.csv`):**
   - Creates a plain text spreadsheet with titles, usernames, passwords, and URLs.

### Exporting Steps
1. Tap the three-dot menu on your vault header and select **Manage Vault** → **Export Vault**.
2. Select your desired format.
3. If exporting to `.kdbx`, set a master password for the new exported file.
4. Choose a destination folder on your device.

> **Warning:** Plain CSV and XML exports are unencrypted. Anyone with access to the file can read all of your passwords. Store them only on encrypted offline media.

---

[← Cloud Storage & Sync](cloud-storage.md) • [User Guide Index](README.md) • [Troubleshooting →](troubleshooting.md)
