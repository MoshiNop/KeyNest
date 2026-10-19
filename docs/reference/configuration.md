# Configuration & Environment Reference

This document covers build-time configuration variables, packaging specifications, and localization settings for KeyNest.

---

## 1. Build-Time Environment Flags

When invoking `flutter build` or `flutter run`, you can pass configuration flags via `--dart-define`:

| Flag | Default | Description |
| :--- | :--- | :--- |
| `KEYNEST_ENV` | `production` | Target deployment environment (`development`, `staging`, `production`). |
| `KEYNEST_ENABLE_ANALYTICS` | `false` | Enables anonymous Matomo crash and usage telemetry (opt-in only). |
| `KEYNEST_WEBDAV_TIMEOUT_SEC` | `30` | Timeout threshold in seconds for WebDAV HTTP requests. |

---

## 2. Windows MSIX Configuration (`pubspec.yaml`)

KeyNest defines MSIX packaging metadata directly in `keynest/pubspec.yaml`:

```yaml
msix_config:
  display_name: KeyNest
  publisher_display_name: KeyNest
  identity_name: KeyNest.PasswordManager
  msix_version: 1.7.12.151
  publisher: CN=9A3091A5-8ED6-447B-8681-7F59FF7FE2BE
  logo_path: assets/images/app_icon_squircle.png
  start_menu_icon_path: assets/images/app_icon_squircle.png
  tile_icon_path: assets/images/app_icon_squircle.png
  icons_background_color: transparent
  architecture: x64
  capabilities: 'internetClient'
  store: true
  languages: 'en-us,de,fr,he,id,it,pt-BR,sk,es,zh-CN,zh-TW'
  file_extension: '.kdbx'
```

---

## 3. Localization Configuration (`l10n.yaml`)

KeyNest supports full localization generated from ARB files located in `keynest/lib/l10n/`:

```yaml
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app_localizations.dart
output-dir: lib/l10n-generated
untranslated-messages-file: lib/l10n-generated/untranslated.json
```

---

[← Dependencies](dependencies.md) • [Reference Index](README.md) • [Compatibility Matrix →](compatibility.md)
