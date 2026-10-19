# KeyNest Screenshot Repository & Gallery Manifest

This directory holds official screenshots of KeyNest across supported desktop and mobile platforms.

When image files matching the manifest filenames below are added to this folder and committed to Git, they automatically render in the screenshot gallery on the root [README.md](../../../README.md) on GitHub.

---

## Screenshot Manifest & Naming Conventions

The root README and User Guides expect the following standardized filenames:

| Filename | Expected Dimension | Mode | README Section | Subject / Description |
| :--- | :--- | :--- | :--- | :--- |
| `vaults-dark.png` | 1280 × 800 px (16:10) | Dark | Screenshot Showcase | Main multi-vault dashboard showing unlocked vaults, quick search, and category chips. |
| `vaults-light.png` | 1280 × 800 px (16:10) | Light | User Guide | Vault list in high-contrast light theme. |
| `password-details.png` | 1280 × 800 px or 1080 × 2400 px | Dark | Screenshot Showcase | Entry details screen with protected fields, custom attributes, TOTP counter, and notes. |
| `totp-authenticator.png` | 1080 × 2400 px (Mobile) | Dark | Screenshot Showcase | TOTP authenticator card with countdown progress ring and one-tap copy button. |
| `autofill-suggestions.png` | 1080 × 2400 px (Mobile) | Dark | Screenshot Showcase | Android Autofill bottom sheet or iOS QuickType bar matching web/app credentials. |
| `cloud-vaults.png` | 1280 × 800 px (16:10) | Dark | Screenshot Showcase | Cloud storage configuration screen showing Google Drive, WebDAV, and Dropbox providers. |

---

## Guidelines for Capturing Screenshots

1. **Synthetic / Mock Data Only:**
   - **Never** capture screenshots containing real personal credentials, private keys, passwords, email addresses, or proprietary URLs.
   - Use mock domain names such as `example.com`, `mycompany.test`, or standard demonstration records.
2. **Standardized Dimensions:**
   - **Desktop (macOS / Windows / Linux):** Capture at `1280 × 800 px` or `1920 × 1080 px` at standard 1x or 2x display scaling.
   - **Mobile (Android / iOS):** Capture on standard modern device viewports (e.g. `1080 × 2400 px` or `1170 × 2532 px`).
3. **Format & Compression:**
   - Save in 24-bit PNG format (`.png`).
   - Run lossless compression (e.g., `pngquant --quality=85-95` or `oxipng`) before committing to keep repository clone sizes small.
4. **Theme Consistency:**
   - Standardize default README showcase images on KeyNest's primary Dark Mode palette.

---

## How to Add or Update Screenshots

1. Capture your screenshot following the guidelines above.
2. Name the file exactly as listed in the [Manifest](#screenshot-manifest--naming-conventions) (e.g. `vaults-dark.png`).
3. Place the image in this directory:
   ```bash
   cp /path/to/my-capture.png docs/assets/screenshots/vaults-dark.png
   ```
4. Commit and push:
   ```bash
   git add docs/assets/screenshots/
   git commit -m "docs: add official dashboard screenshot"
   git push
   ```
5. GitHub will immediately display the screenshot on the repository homepage.
