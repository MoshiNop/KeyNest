# Cloud Storage & Synchronization

KeyNest supports seamless synchronization across your devices by integrating directly with industry-standard cloud storage providers and self-hosted servers.

---

## Supported Storage Providers

| Provider | Authentication Type | Conflict Resolution | Best For |
| :--- | :--- | :--- | :--- |
| **WebDAV** | Basic / Digest HTTP Auth | Automatic 3-Way Merge | Nextcloud, ownCloud, mailbox.org, custom NAS. |
| **Google Drive** | OAuth 2.0 PKCE | Automatic 3-Way Merge | Android and cross-platform users with Google accounts. |
| **Dropbox** | OAuth 2.0 PKCE | Automatic 3-Way Merge | Multi-device Dropbox sync. |
| **OneDrive** | Microsoft Graph OAuth | Automatic 3-Way Merge | Microsoft 365 and Windows desktop users. |
| **Local / SAF** | Storage Access Framework / File System | Local File Locking | Strictly offline or custom third-party sync (Syncthing). |

---

## 1. Connecting a Cloud Provider

### Connecting WebDAV (Nextcloud / ownCloud)
1. In KeyNest, tap **Open Vault** → **WebDAV**.
2. Enter your WebDAV Server URL (e.g. `https://cloud.example.com/remote.php/webdav/`).
3. Enter your username and password (or dedicated App Password generated from Nextcloud Security settings).
4. Browse your remote files and select your `.kdbx` vault file.
5. Enter your vault master password to unlock.

### Connecting Google Drive
1. Select **Open Vault** → **Google Drive**.
2. Authenticate through the secure browser prompt. KeyNest requests scoped access strictly limited to application files or files you explicitly open.
3. Select your `.kdbx` file from your Drive storage.

---

## 2. How Synchronization Works

KeyNest uses an intelligent **Three-Way Merge Engine** to handle changes made across multiple devices:

1. **Local Working Copy:**
   - When you open a cloud vault, KeyNest maintains a local cached copy on your device so you can view and edit passwords even when offline.
2. **Background Sync:**
   - When network connectivity is available, KeyNest periodically checks the remote file's modification timestamp and ETag.
3. **Automatic Conflict Merging:**
   - If changes occurred both locally and remotely (e.g., you added a password on your phone while offline, and updated another password on your laptop), KeyNest performs a **three-way merge** on the underlying KDBX XML tree.
   - Non-conflicting additions, edits, and deletions are merged automatically without creating duplicate files or discarding data.
   - If an entry was concurrently edited on both devices, KeyNest retains the newer modification and archives the previous state in the entry's KDBX history.

---

## 3. Offline Mode & Network Resilience

- If you lose internet access, KeyNest continues to function normally using your local vault cache.
- Any modifications you make are queued locally. Once your device reconnects to Wi-Fi or cellular data, KeyNest uploads your changes and merges any remote updates.

---

[← Autofill Integration](autofill.md) • [User Guide Index](README.md) • [Import & Export →](import-export.md)
