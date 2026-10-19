# Testing Strategy & Test Suite Guide

This document describes KeyNest's testing methodology, test categorization, mock generation, and continuous integration pipeline.

---

## 1. Test Architecture

The KeyNest repository contains over 300 automated unit, widget, and integration tests located under `keynest/test/` and `keynest/integration_test/`:

```text
keynest/test/
├── app_data_test.dart                                 # AppData settings, auto-lock, and theme state
├── duplicate_detector_test.dart                       # Credential deduplication and password matching
├── file_source_local_test.dart                        # File I/O abstractions and stream readers
├── keynest_android_autofill_fixes_test.dart           # Android autofill payload formatting & matching
├── keynest_autofill_engine_test.dart                  # eTLD+1 domain matcher and credential selection
├── keynest_key_file_test.dart                         # Key file generation, parsing, and composite keys
├── keynest_vault_header_storage_badge_layout_test.dart# UI layout, badge positioning, and responsiveness
├── keynest_vault_health_test.dart                     # Password audit, reuse detection, and health scores
├── master_password_change_test.dart                   # Master password rotation and KDF transitions
├── password_generator_test.dart                       # Password entropy, CSPRNG, character filters
├── password_list_filter_test.dart                     # Category chips and search filtering logic
├── ui/screens/entry_view_model_test.dart              # EntryViewModel data bindings & dirty state tracking
└── util/
    ├── test_util.dart                                 # Test vault fixtures, mock factories, harness setup
    └── test_util.mocks.dart                           # Mockito generated mock implementations
```

---

## 2. Running Tests

### Running the Entire Test Suite
```bash
cd keynest
flutter test
```

### Running Specific Tests
```bash
# Run vault health tests
flutter test test/keynest_vault_health_test.dart

# Run master password change tests
flutter test test/master_password_change_test.dart
```

### Running with Code Coverage
```bash
flutter test --coverage
# Generates coverage/lcov.info
```

---

## 3. Mock Generation with Mockito

KeyNest uses `@GenerateMocks` in `test/util/test_util.dart` to generate type-safe mocks for complex subsystems (`KdbxBloc`, `CloudStorageProvider`, `AnalyticsBloc`):

```bash
cd keynest
flutter pub run build_runner build --delete-conflicting-outputs
```

---

## 4. Continuous Integration (CI)

Every commit and pull request triggers GitHub Actions workflows defined in `.github/workflows/`:
- **Static Analysis (`analyze.yaml`):** Runs `flutter analyze` against root and sub-packages.
- **Unit Testing (`unit_test.yaml`):** Executes the full `flutter test` suite across Linux runners.
- **Platform Builds (`windows.yaml`, `ios.yaml`, `linux.yml`, `main.yml`):** Validates compilation and artifact packaging across all target platforms.

---

[← Cloud Integrations](cloud-integrations.md) • [Developer Guide Index](README.md) • [Build & Release →](build-and-release.md)
