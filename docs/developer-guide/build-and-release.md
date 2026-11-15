# Build & Release Engineering

This document outlines the build automation, packaging scripts, and production release procedures for KeyNest across all supported desktop, mobile, and web targets. It provides complete instructions for both **signed production releases** and **unsigned/local development variants**.

---

## 1. Cloud Configuration Setup

KeyNest requires a JSON configuration file containing OAuth client credentials for cloud storage providers (Google Drive, Dropbox, OneDrive, WebDAV). All production builds must inject this configuration via `--dart-define-from-file`.

### File Location
Place `cloud_config.json` inside the `keynest/` directory:
```
keynest/cloud_config.json
```

### Configuration Schema Template
Create `keynest/cloud_config.json` with the required keys:
```json
{
  "KEYNEST_GOOGLE_WEB_CLIENT_ID": "your-google-web-client-id.apps.googleusercontent.com",
  "KEYNEST_GOOGLE_DESKTOP_CLIENT_ID": "your-google-desktop-client-id.apps.googleusercontent.com",
  "KEYNEST_GOOGLE_DESKTOP_CLIENT_SECRET": "your-google-desktop-client-secret",
  "KEYNEST_DROPBOX_APP_KEY": "your-dropbox-app-key"
}
```

> [!NOTE]
> `cloud_config.json` is ignored by Git to protect sensitive client credentials. Never commit production secrets to version control.

---

## 2. Pre-Build: Monorepo Dependency Resolution

Before running build commands on any target platform, ensure all packages within the monorepo have their dependencies resolved:

```bash
# From repository root
cd autofill_shared && dart pub get && cd ..
cd autofill_module && flutter pub get && cd ..
cd deps/autofill_service && flutter pub get && cd ../..
cd keynest && flutter pub get && cd ..
```

---

## 3. Release Automation Tooling (`keynest/_tools/`)

KeyNest maintains production release and signing scripts inside [`keynest/_tools/`](../../keynest/_tools/):

| Script | Purpose |
| :--- | :--- |
| `ci-release.sh` | Main CI entry point for coordinating version increments and multi-platform packaging. |
| `release.sh` | Orchestrates local release builds, tag creation, and artifact generation. |
| `upload-android.sh` | Publishes signed AAB / APK bundles to Google Play tracks. |
| `build-ios.sh` / `upload-ios.sh` | Archives Xcode Runner, exports signed IPA, and uploads to Apple App Store Connect / TestFlight. |
| `build-macos.sh` / `upload-macos.sh` | Builds signed and notarized macOS `.app` and `.pkg` bundles. |
| `notarize-macos.sh` | Automates Apple `notarytool` submissions and staple operations. |
| `windows/create_release.sh` | Compiles Windows release binaries and packages MSIX installer. |
| `windows/KeyNestSetup.iss` | Inno Setup configuration for generating the Windows executable installer. |

---

## 4. Platform Build Instructions

All build commands below are executed from the `keynest/` directory:
```bash
cd keynest
```

### 4.1 Android Release Builds

#### 4.1.1 Signing Keystore Setup
KeyNest Gradle configuration reads signing credentials from either `keynest/android/key.properties` or environment variables:

* **Via `keynest/android/key.properties`:**
  ```properties
  storeFile=/path/to/keynest-release.jks
  storePassword=YourStorePassword
  keyAlias=keynest
  keyPassword=YourKeyPassword
  ```
* **Via Environment Variables:**
  ```bash
  export ANDROID_KEYSTORE_PATH="/path/to/keynest-release.jks"
  export ANDROID_KEYSTORE_PASSWORD="YourStorePassword"
  export ANDROID_KEY_ALIAS="keynest"
  export ANDROID_KEY_PASSWORD="YourKeyPassword"
  ```

#### 4.1.2 Signed Google Play Store (`playstore` Flavor)
The canonical production release without application ID suffix (`com.moshinop.keynest`). When `key.properties` or the environment variables are present, Gradle signs the output automatically:

* **Signed Android App Bundle (AAB - Recommended for Google Play submission):**
  ```bash
  flutter build appbundle --release \
    --flavor playstore \
    --dart-define-from-file=cloud_config.json
  ```
  *Output:* `build/app/outputs/bundle/playstoreRelease/app-playstore-release.aab`

* **Signed Universal Release APK:**
  ```bash
  flutter build apk --release \
    --flavor playstore \
    --dart-define-from-file=cloud_config.json
  ```
  *Output:* `build/app/outputs/flutter-apk/app-playstore-release.apk`

* **Signed Split APKs per ABI:**
  ```bash
  flutter build apk --release \
    --flavor playstore \
    --split-per-abi \
    --dart-define-from-file=cloud_config.json
  ```
  *Outputs:*
  * `build/app/outputs/flutter-apk/app-playstore-arm64-v8a-release.apk`
  * `build/app/outputs/flutter-apk/app-playstore-armeabi-v7a-release.apk`
  * `build/app/outputs/flutter-apk/app-playstore-x86_64-release.apk`

* **Signed Architecture-Specific APKs:**
  ```bash
  # 64-bit ARM (arm64-v8a)
  flutter build apk --release --flavor playstore --target-platform android-arm64 --dart-define-from-file=cloud_config.json

  # 32-bit ARM (armeabi-v7a)
  flutter build apk --release --flavor playstore --target-platform android-arm --dart-define-from-file=cloud_config.json

  # 64-bit Intel/AMD (x86_64)
  flutter build apk --release --flavor playstore --target-platform android-x64 --dart-define-from-file=cloud_config.json
  ```

#### 4.1.3 Unsigned & Debug-Signed Fallback Android Builds
* **Unsigned Build with Debug Signing Fallback:**
  ```bash
  flutter build apk --release \
    --flavor playstore \
    -PallowDebugSigningFallback=true \
    --dart-define-from-file=cloud_config.json
  ```

* **Manual Post-Signing with `apksigner`:**
  ```bash
  # 1. Zipalign unaligned APK
  zipalign -v -p 4 app-playstore-release-unsigned.apk app-playstore-release-aligned.apk

  # 2. Sign with apksigner (v1, v2, and v3 schemes)
  apksigner sign --ks /path/to/keynest-release.jks \
    --ks-key-alias keynest \
    --ks-pass pass:YourStorePassword \
    --key-pass pass:YourKeyPassword \
    --out app-playstore-release-signed.apk \
    app-playstore-release-aligned.apk

  # 3. Verify signature
  apksigner verify --verbose app-playstore-release-signed.apk
  ```

#### 4.1.4 Sideload / Direct Distribution (`sideload` Flavor)
Packaged with `.sideload` package suffix for direct GitHub release or web download:
```bash
# Signed Universal APK
flutter build apk --release \
  --flavor sideload \
  -t lib/env/production.dart \
  --dart-define-from-file=cloud_config.json

# Signed 64-bit ARM APK
flutter build apk --release \
  --flavor sideload \
  --target-platform android-arm64 \
  -t lib/env/production.dart \
  --dart-define-from-file=cloud_config.json
```
*Output:* `build/app/outputs/flutter-apk/app-sideload-release.apk`

#### 4.1.5 F-Droid (`fdroid` Flavor)
Uses `lib/env/fdroid.dart` target with stripped proprietary libraries:
```bash
flutter build apk --release \
  --flavor fdroid \
  -t lib/env/fdroid.dart \
  --dart-define-from-file=cloud_config.json
```
*Output:* `build/app/outputs/flutter-apk/app-fdroid-release.apk`

#### 4.1.6 Other Store Flavors (Signed)
* **Amazon Appstore (`amazon` Flavor):**
  ```bash
  flutter build apk --release --flavor amazon -t lib/env/production.dart --dart-define-from-file=cloud_config.json
  ```
* **Huawei AppGallery (`huawei` Flavor):**
  ```bash
  flutter build apk --release --flavor huawei -t lib/env/production.dart --dart-define-from-file=cloud_config.json
  ```
* **Samsung Galaxy Store (`samsungapps` Flavor):**
  ```bash
  flutter build apk --release --flavor samsungapps -t lib/env/production.dart --dart-define-from-file=cloud_config.json
  ```
* **Internal / Dev Track (`playstoredev` Flavor):**
  ```bash
  flutter build appbundle --release --flavor playstoredev -t lib/env/production.dart --dart-define-from-file=cloud_config.json
  ```

---

### 4.2 Windows Desktop & Installers

#### 4.2.1 Windows Executable (`keynest.exe`)
* **Build Unsigned Binary:**
  ```bash
  flutter build windows --release \
    --dart-define-from-file=cloud_config.json
  ```
  *Output Binary:* `build/windows/x64/runner/Release/keynest.exe`  
  *Distribution Bundle:* The entire `build/windows/x64/runner/Release/` directory (includes runtime DLLs and `data/` asset folder).

* **Sign Binary with `signtool.exe` (Signed):**
  ```powershell
  signtool sign `
    /tr http://timestamp.digicert.com `
    /td sha256 `
    /fd sha256 `
    /f "path\to\certificate.pfx" `
    /p "YourCertPassword" `
    "build\windows\x64\runner\Release\keynest.exe"
  ```
  *Verify Signature:*
  ```powershell
  signtool verify /pa /v "build\windows\x64\runner\Release\keynest.exe"
  ```

#### 4.2.2 Windows MSIX Package
* **Signed MSIX Packaging (Direct via `dart run msix:create`):**
  ```bash
  # 1. Compile Windows release binary
  flutter build windows --release \
    --dart-define-from-file=cloud_config.json

  # 2. Package and sign MSIX
  dart run msix:create \
    --certificate-path "path/to/certificate.pfx" \
    --certificate-password "YourCertPassword" \
    --publisher "CN=KeyNest" \
    --dart-define-from-file=cloud_config.json
  ```
  *Output:* `build/windows/x64/runner/Release/keynest.msix`

* **Unsigned MSIX Packaging:**
  ```bash
  dart run msix:create \
    --dart-define-from-file=cloud_config.json
  ```

* **Manual MSIX Signing with `signtool.exe`:**
  ```powershell
  signtool sign `
    /fd SHA256 `
    /a `
    /f "path\to\certificate.pfx" `
    /p "YourCertPassword" `
    /tr http://timestamp.digicert.com `
    /td SHA256 `
    "build\windows\x64\runner\Release\keynest.msix"
  ```

#### 4.2.3 Windows Inno Setup EXE Installer
* **Compile Installer:**
  ```powershell
  & "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" _tools/windows/KeyNestSetup.iss
  ```
  *Output:* `build/keynest/windows/setup/KeyNest-setup-x64.exe`

* **Sign Inno Setup Installer (Signed):**
  ```powershell
  signtool sign `
    /tr http://timestamp.digicert.com `
    /td sha256 `
    /fd sha256 `
    /f "path\to\certificate.pfx" `
    /p "YourCertPassword" `
    "build\keynest\windows\setup\KeyNest-setup-x64.exe"
  ```

---

### 4.3 macOS Desktop Builds (macOS Host Only)

#### 4.3.1 macOS Application Bundle (`.app`)
* **Build Unsigned Application Bundle:**
  ```bash
  flutter build macos --release \
    --dart-define-from-file=cloud_config.json
  ```
  *Output:* `build/macos/Build/Products/Release/keynest.app`

* **Sign Application Bundle (`codesign`):**
  ```bash
  codesign --deep --force --verify --verbose \
    --options runtime \
    --sign "Developer ID Application: Your Name (TEAM_ID)" \
    build/macos/Build/Products/Release/keynest.app
  ```

#### 4.3.2 macOS Signed & Notarized PKG Installer
KeyNest includes dedicated tooling to produce signed, notarized PKG distributions:
```bash
# 1. Build release with production environment
./_tools/build-macos.sh -t lib/env/production.dart

# 2. Sign installer package
productsign --sign "Developer ID Installer: Your Name (TEAM_ID)" \
  build/macos/pkg/KeyNest-unsigned.pkg \
  build/macos/pkg/KeyNest.pkg

# 3. Notarize bundle with Apple notarytool
xcrun notarytool submit build/macos/pkg/KeyNest.pkg \
  --keychain-profile "AC_PASSWORD" \
  --wait

# 4. Staple notarization ticket
xcrun stapler staple build/macos/pkg/KeyNest.pkg
```
*Output:* `build/macos/pkg/KeyNest.pkg`

---

### 4.4 iOS Release Builds (macOS Host Only)

#### 4.4.1 iOS Release Archive / IPA
* **Signed Release IPA (App Store & TestFlight):**
  ```bash
  flutter build ipa --release \
    --export-options-plist=ios/ExportOptions.plist \
    --dart-define-from-file=cloud_config.json
  ```
  *Output:* `build/ios/ipa/keynest.ipa`

* **Unsigned Release Archive (CI / No Codesign):**
  ```bash
  flutter build ipa --release \
    --no-codesign \
    --dart-define-from-file=cloud_config.json
  ```
  *Output:* `build/ios/archive/Runner.xcarchive`

#### 4.4.2 iOS Autofill Extension Framework
KeyNest utilizes a native iOS Credential Provider Extension. If compiling the extension framework independently:
```bash
# From repository root
cd autofill_module
./build_ios_framework.sh
```
*Output:* `autofill_module/build/ios/framework/`

---

### 4.5 Linux Desktop Builds (Linux Host)

#### 4.5.1 Linux Release Bundle
```bash
flutter build linux --release \
  --dart-define-from-file=cloud_config.json
```
*Output:* `build/linux/x64/release/bundle/`

#### 4.5.2 Compressed Tarball & GPG Cryptographic Signing
```bash
# 1. Create distribution tarball
tar czvf keynest-linux-x64.tar.gz -C build/linux/x64/release/bundle .

# 2. Sign tarball with GPG (Detached ASCII-armored signature)
gpg --armor --detach-sign keynest-linux-x64.tar.gz
# Generates: keynest-linux-x64.tar.gz.asc

# 3. Generate SHA-256 checksum
sha256sum keynest-linux-x64.tar.gz > keynest-linux-x64.tar.gz.sha256

# 4. Verify GPG signature
gpg --verify keynest-linux-x64.tar.gz.asc keynest-linux-x64.tar.gz
```

---

### 4.6 Web Release Builds

```bash
flutter build web --release \
  --dart-define-from-file=cloud_config.json
```
*Output:* `build/web/`

---

## 5. Build Commands Quick Reference Matrix

| Platform | Flavor / Variant | Signing Type | Command | Output Artifact |
| :--- | :--- | :--- | :--- | :--- |
| **Android** | `playstore` | **Signed** (AAB) | `flutter build appbundle --release --flavor playstore --dart-define-from-file=cloud_config.json` | `build/app/outputs/bundle/playstoreRelease/app-playstore-release.aab` |
| **Android** | `playstore` | **Signed** (Universal APK) | `flutter build apk --release --flavor playstore --dart-define-from-file=cloud_config.json` | `build/app/outputs/flutter-apk/app-playstore-release.apk` |
| **Android** | `playstore` | **Signed** (ARM 64-bit) | `flutter build apk --release --flavor playstore --target-platform android-arm64 --dart-define-from-file=cloud_config.json` | `build/app/outputs/flutter-apk/app-playstore-release.apk` |
| **Android** | `playstore` | **Signed** (Split ABI) | `flutter build apk --release --flavor playstore --split-per-abi --dart-define-from-file=cloud_config.json` | `build/app/outputs/flutter-apk/app-playstore-*-release.apk` |
| **Android** | `playstore` | **Unsigned** / Debug Key | `flutter build apk --release --flavor playstore -PallowDebugSigningFallback=true --dart-define-from-file=cloud_config.json` | `build/app/outputs/flutter-apk/app-playstore-release.apk` |
| **Android** | `sideload` | **Signed** (Universal APK) | `flutter build apk --release --flavor sideload -t lib/env/production.dart --dart-define-from-file=cloud_config.json` | `build/app/outputs/flutter-apk/app-sideload-release.apk` |
| **Android** | `fdroid` | **Signed** (F-Droid APK) | `flutter build apk --release --flavor fdroid -t lib/env/fdroid.dart --dart-define-from-file=cloud_config.json` | `build/app/outputs/flutter-apk/app-fdroid-release.apk` |
| **Windows** | Portable | **Signed** (EXE) | `signtool sign /tr http://timestamp.digicert.com /td sha256 /fd sha256 /f cert.pfx /p pwd build/windows/x64/runner/Release/keynest.exe` | `build/windows/x64/runner/Release/keynest.exe` |
| **Windows** | Portable | **Unsigned** (EXE) | `flutter build windows --release --dart-define-from-file=cloud_config.json` | `build/windows/x64/runner/Release/keynest.exe` |
| **Windows** | MSIX Package | **Signed** (MSIX) | `dart run msix:create --certificate-path cert.pfx --certificate-password pwd --publisher "CN=KeyNest" --dart-define-from-file=cloud_config.json` | `build/windows/x64/runner/Release/keynest.msix` |
| **Windows** | MSIX Package | **Unsigned** (MSIX) | `dart run msix:create --dart-define-from-file=cloud_config.json` | `build/windows/x64/runner/Release/keynest.msix` |
| **Windows** | Inno Setup | **Signed** (EXE Setup) | `signtool sign /tr http://timestamp.digicert.com /td sha256 /fd sha256 /f cert.pfx /p pwd build/keynest/windows/setup/KeyNest-setup-x64.exe` | `build/keynest/windows/setup/KeyNest-setup-x64.exe` |
| **macOS** | Desktop | **Signed** (.app) | `codesign --deep --force --verify --verbose --options runtime --sign "Developer ID Application: ..." build/macos/Build/Products/Release/keynest.app` | `build/macos/Build/Products/Release/keynest.app` |
| **macOS** | Desktop | **Signed & Notarized** (.pkg) | `./_tools/build-macos.sh -t lib/env/production.dart && productsign ... && xcrun notarytool submit ...` | `build/macos/pkg/KeyNest.pkg` |
| **iOS** | App Store | **Signed** (IPA) | `flutter build ipa --release --export-options-plist=ios/ExportOptions.plist --dart-define-from-file=cloud_config.json` | `build/ios/ipa/keynest.ipa` |
| **iOS** | CI / Export | **Unsigned** (Archive) | `flutter build ipa --release --no-codesign --dart-define-from-file=cloud_config.json` | `build/ios/archive/Runner.xcarchive` |
| **Linux** | Desktop | **Signed** (GPG Tarball) | `tar czvf keynest-linux-x64.tar.gz -C build/linux/x64/release/bundle . && gpg --armor --detach-sign keynest-linux-x64.tar.gz` | `keynest-linux-x64.tar.gz.asc` |
| **Web** | Web Release | N/A | `flutter build web --release --dart-define-from-file=cloud_config.json` | `build/web/` |

---

[← Testing Guide](testing.md) • [Developer Guide Index](README.md) • [Reference Index →](../reference/README.md)
