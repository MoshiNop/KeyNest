# Autofill Integration

KeyNest integrates directly with the native operating system autofill frameworks on Android and iOS, allowing you to fill logins and credentials across web browsers and native apps without copying and pasting.

---

## 1. Android Autofill Setup

KeyNest implements an Android Autofill Service compatible with Android 8.0 (API Level 26) through Android 15+.

### Enabling Android Autofill
1. Open KeyNest and navigate to **Settings** → **Autofill**.
2. Tap **Enable Android Autofill Service**.
3. Android system settings will open. Select **KeyNest** as your preferred autofill provider and confirm the system dialog.

### How Android Autofill Works
- When you tap a username or password input in Chrome, Firefox, or any third-party app, Android requests matching credentials from KeyNest.
- **Biometric Prompt:** If your vault is locked, KeyNest displays a quick biometric prompt or PIN request.
- **Domain Matching:** KeyNest matches the app package or web domain using public suffix rules (`eTLD+1`), ensuring credentials for `accounts.google.com` match `google.com` while strictly preventing phishing attacks from fake subdomains.
- Tap the suggested credential card to instantly fill username and password fields.

---

## 2. iOS Credential Provider Setup

On iOS, KeyNest provides an Apple `ASCredentialProviderViewController` extension that integrates with Safari and native iOS apps.

### Enabling iOS Autofill
1. Open iOS **Settings** → **Passwords** → **Password Options** (or **Autofill & Passwords** on newer iOS versions).
2. Enable **AutoFill Passwords and Passkeys**.
3. Under **Use Passwords From**, select **KeyNest**.
4. Disable iCloud Keychain or other providers if you want KeyNest to be your exclusive provider, or keep both enabled.

### How iOS Autofill Works
- When an input field appears on Safari or in an app, the iOS QuickType bar displays matching credentials from your KeyNest vaults.
- Authenticate with Face ID / Touch ID to autofill.
- The extension runs in a dedicated lightweight sandboxed process, utilizing mirrored vault caches stored in a secure shared App Group container.

---

## 3. Keyboard Shortcuts for Desktop Autofill

On Windows, macOS, and Linux, KeyNest supports quick clipboard shortcuts and global hotkeys:

- `Ctrl + Shift + U` / `Cmd + Shift + U`: Copy username of selected entry.
- `Ctrl + Shift + P` / `Cmd + Shift + P`: Copy password of selected entry.
- `Ctrl + Shift + T` / `Cmd + Shift + T`: Copy current TOTP token.
- `Ctrl + L` / `Cmd + L`: Immediately lock all active vaults.

---

[← Two-Factor Authentication (TOTP)](totp.md) • [User Guide Index](README.md) • [Cloud Storage & Sync →](cloud-storage.md)
