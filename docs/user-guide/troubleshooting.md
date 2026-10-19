# Troubleshooting & Common Questions

This guide addresses common issues, diagnostic procedures, and error messages encountered while using KeyNest.

---

## 1. Vault Unlock Failures

### "Invalid Credentials / Master Password Incorrect"
- **Caps Lock:** Ensure Caps Lock is not inadvertently enabled on desktop.
- **Key File:** If the vault was created with a Key File, the vault cannot be unlocked by master password alone. Tap **Select Key File** and select your `.key` or `.keyx` file before unlocking.
- **Argon2 Resource Constraints:** On older mobile devices, vaults created with exceptionally high Argon2 memory parameters (e.g. 512 MB+) on desktop computers may run out of memory. If this occurs, open the vault on desktop, adjust Argon2 memory to 64 MB or 128 MB in vault settings, save, and retry.

---

## 2. Cloud Storage & Synchronization Issues

### "Conflict Detected / Remote File Modified"
- KeyNest automatically merges concurrent changes using its 3-way merge engine.
- If you notice a red sync indicator on the vault header, tap the three-dot menu and select **Sync Now** to force a synchronization cycle.
- If network connectivity was lost during an upload, KeyNest will retry automatically on the next network transition.

### "WebDAV 401 Unauthorized"
- If connecting to Nextcloud or ownCloud with Two-Factor Authentication (2FA) enabled on your cloud account, you must generate an **App Password** in Nextcloud (Settings → Security → Devices & Sessions) instead of using your primary account password.
- Verify whether your server requires HTTPS and an explicit port (e.g. `https://cloud.example.com:443/remote.php/webdav/`).

---

## 3. Autofill Issues

### Android: Autofill Does Not Suggest Credentials
1. Confirm KeyNest is set as the active Autofill Service:
   - Android **Settings** → **System** → **Languages & input** → **Autofill service** → select **KeyNest**.
2. Verify the entry's **Website URL** field:
   - KeyNest matches based on effective Top-Level Domain (e.g., `https://github.com/login` matches `github.com`).
   - If an entry has no URL or an invalid URL, KeyNest cannot associate it with the web page.

### iOS: Autofill Extension Shows Blank or "Locked"
- Open the main KeyNest app and unlock your vault at least once using Face ID or master password. This populates the secure shared App Group container that the iOS extension reads.

---

## 4. Biometric Unlock Fails

- If biometric unlock repeatedly fails or prompts for master password:
  - This is standard OS security behavior after device restarts, biometric hardware reconfiguration, or multiple failed attempts.
  - Enter your master password once to re-authenticate and refresh the secure cryptographic token in hardware keystore.

---

[← Import & Export](import-export.md) • [User Guide Index](README.md) • [Developer Guide Index →](../developer-guide/README.md)
