# Two-Factor Authentication (TOTP)

KeyNest includes a built-in time-based one-time password (TOTP) engine compatible with RFC 6238 and RFC 4226. This eliminates the need for a separate authenticator app like Google Authenticator or Authy.

---

## 1. Adding a TOTP Token to an Entry

You can attach two-factor authentication directly to any Login entry or create a dedicated **2FA Token** entry.

### Method A: Scanning a QR Code with Your Camera
1. Open an existing entry and tap **Edit** → **Add TOTP** (or tap the QR scan icon).
2. Point your camera at the 2FA QR code displayed on your screen by the service.
3. KeyNest automatically parses the `otpauth://` URI, extracting the secret key, issuer, digits (usually 6), algorithm (SHA-1 / SHA-256), and period (usually 30s).
4. Save the entry. The animated countdown timer begins immediately.

### Method B: Manual Secret Key Entry
If a QR code is not available:
1. Select **Enter Key Manually**.
2. Paste the base32 secret seed (e.g. `JBSWY3DPEHPK3PXP`).
3. Set the issuer name and tap **Save**.

---

## 2. Using TOTP Tokens

- **Countdown Progress Ring:** Each TOTP token displays a circular progress timer indicating the remaining validity window (default 30 seconds).
- **One-Tap Copy:** Tap the 6-digit code or the copy icon to copy the current token to your clipboard.
- **Auto-Clearing Clipboard:** By default, KeyNest clears your clipboard after 45 seconds to prevent token leaks.
- **Autofill Integration:** When logging into a website via autofill, KeyNest can automatically provide the current TOTP token when the browser requests the 2FA verification field.

---

## 3. Importing Google Authenticator Migrations

If you are migrating from Google Authenticator:

1. In Google Authenticator, export your accounts via **Transfer accounts** → **Export accounts**. A batch QR code is generated.
2. In KeyNest, open **Settings** → **Import** → **Google Authenticator QR**.
3. Scan the export QR code.
4. KeyNest decodes the migration protocol buffer and creates individual 2FA entries in your selected vault.

---

[← Passwords & Entries](passwords-and-entries.md) • [User Guide Index](README.md) • [Autofill Integration →](autofill.md)
