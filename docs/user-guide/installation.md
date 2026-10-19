# Installation & Supported Platforms

KeyNest is a cross-platform password manager engineered with Flutter. This guide covers installation options and system requirements across all supported platforms.

---

## Platform Support Matrix

| Platform | Minimum Supported Version | Distribution Formats | Status |
| :--- | :--- | :--- | :--- |
| **Android** | Android 8.0 (API Level 26)+ | APK, Google Play Store / AAB | Production |
| **iOS** | iOS 15.0+ | Apple App Store / TestFlight | Production |
| **Windows** | Windows 10 (Build 19041+) / Windows 11 | MSIX Package, Portable ZIP | Production |
| **macOS** | macOS 11.0 (Big Sur)+ | macOS App Bundle (.app), DMG | Production |
| **Linux** | Ubuntu 20.04+, Debian 11+, Fedora 36+ | Debian Package (.deb), Tarball (.tar.gz) | Production |
| **Web** | Modern Evergreen Browsers (Chrome, Firefox, Safari, Edge) | Static Progressive Web App (PWA) | Production / Offline Capable |

---

## 1. Android Installation

### Direct APK Download
1. Download the latest release `.apk` from the GitHub Releases page.
2. If installing via browser, allow **Install unknown apps** for your browser when prompted in Android Settings.
3. Open the APK file to complete installation.

### System Permissions
- **Camera:** Required only if you scan QR codes to add 2FA/TOTP authenticator tokens.
- **Biometrics:** Used for Fingerprint / Face Unlock via Android BiometricPrompt.
- **Storage / Storage Access Framework (SAF):** Used to open and persist `.kdbx` vault files on local storage or SD cards without broad storage permissions.

---

## 2. iOS Installation

### Prerequisites
- iOS 15.0 or later on an iPhone or iPad.

### Installation
- Install KeyNest from TestFlight or the App Store.
- During initial launch, grant Face ID / Touch ID permission when prompted if you wish to use biometric unlock.
- To enable system autofill in Safari and third-party apps, follow the steps in the [Autofill Guide](autofill.md#ios-setup).

---

## 3. Windows Installation

### MSIX Package (Recommended)
1. Download `keynest-windows-x64.msix` from GitHub Releases.
2. Double-click the `.msix` file.
3. Click **Install**. Windows App Installer handles automated installation, Start Menu shortcut creation, and sandbox registration.

### Portable Executable
1. Download `keynest-windows-portable.zip`.
2. Extract the archive to any folder (e.g. `C:\Tools\KeyNest\`).
3. Run `keynest.exe`. No admin rights required.

---

## 4. Linux Installation

### Debian / Ubuntu (.deb)
```bash
sudo dpkg -i keynest-linux-amd64.deb
sudo apt-get install -f   # Resolves any missing GTK or runtime libraries
```

### Standalone Tarball (.tar.gz)
```bash
tar -xzf keynest-linux-x64.tar.gz
cd keynest
./keynest
```

### Linux Runtime Dependencies
Ensure standard desktop libraries are installed:
```bash
# Ubuntu/Debian
sudo apt install libgtk-3-0 libsecret-1-0 libayatana-appindicator3-1
```

---

## 5. Web Version

You can run KeyNest directly in your web browser without local installation:
- Open the hosted instance in any modern browser supporting Web Crypto APIs and WebAssembly.
- Web vaults can be opened from local files or synced with supported cloud storage providers (Google Drive, WebDAV).
- Vault encryption and decryption run entirely in your local browser sandbox.

---

[← User Guide Index](README.md) • [Getting Started →](getting-started.md)
