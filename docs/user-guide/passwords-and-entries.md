# Passwords, Entries & Archetypes

KeyNest supports rich credential management beyond simple username/password pairs. This guide covers entry archetypes, custom fields, organization via groups/tags, and the password generator.

---

## 1. Supported Entry Archetypes

Every entry in KeyNest belongs to an archetype that customizes its fields, visual icon, and autofill behavior:

| Archetype | Icon | Primary Fields | Best Used For |
| :--- | :--- | :--- | :--- |
| **Login** | 🔑 | Title, Username, Password, Website URL, TOTP, Notes | Websites, apps, email accounts, online services. |
| **Payment Card** | 💳 | Cardholder Name, Card Number, Expiry Date, CVV, Card PIN, Billing Address | Credit cards, debit cards, virtual cards. |
| **Secure Note** | 📝 | Title, Secure Text Content, Attachments | Recovery phrases, software licenses, server configs, secrets. |
| **Structured Record** | 🗂️ | Title, Custom Categorized Fields, Key-Value Pairs | Passports, Wi-Fi credentials, SSH keys, API keys. |
| **2FA Token** | ⏱️ | Issuer, Account Name, Secret Seed, Algorithm, Digits | Standalone TOTP authenticator tokens. |

---

## 2. Protected Fields & Custom Attributes

In KeyNest, any sensitive field is automatically protected in memory and stored using encrypted streams in the KDBX file:

### Adding Custom Fields
1. Open an existing entry and tap **Edit** (or tap **Add Custom Field**).
2. Choose a field kind:
   - **Text:** Plain text field (e.g. `Account Number`, `Security Question`).
   - **Hidden / Secret:** Obfuscated field for secrets (e.g. `PIN`, `API Secret`, `Passphrase`).
   - **Authenticator / TOTP:** Secret seed for two-factor authentication.
3. Custom fields sync seamlessly with desktop KeePass and KeePassXC applications.

---

## 3. Organizing Entries with Folders and Tags

### Folders & Groups
- KeyNest preserves the full hierarchical folder tree of KDBX files.
- To move an entry, open it, tap **Move to Group**, and choose the destination folder.
- You can create new subfolders or rename existing groups directly from the side navigation drawer.

### Custom Categories & Filter Chips
- Quick-filter chips at the top of the screen let you filter entries by archetype (**Logins**, **Cards**, **Notes**, **2FA**) regardless of which folder they reside in.

---

## 4. Built-in Password Generator

KeyNest includes a cryptographically secure pseudo-random number generator (CSPRNG) for creating strong, unique passwords:

1. Tap the **Generator** icon in the navigation bar or tap the dice icon next to any password input field.
2. **Customizable Options:**
   - **Length:** Slider from 8 to 128 characters.
   - **Character Sets:** Uppercase (`A-Z`), Lowercase (`a-z`), Digits (`0-9`), and Symbols (`!@#$%^&*`).
   - **Avoid Ambiguous Characters:** Omits easily confused glyphs such as `1`, `l`, `I`, `0`, `O`.
   - **Passphrase Mode:** Generates human-friendly multi-word passphrases (e.g. `correct-horse-battery-staple`).
3. View the real-time entropy calculation and tap **Use Password** to insert it directly into your entry.

---

[← Vault Management](vault-management.md) • [User Guide Index](README.md) • [Two-Factor Authentication (TOTP) →](totp.md)
