# Contributing to KeyNest

Thank you for your interest in contributing to KeyNest! As an open-source password manager, maintaining high code quality, security rigor, and test coverage is essential.

---

## 1. Development Principles

- **Security & Privacy First:** Zero-knowledge guarantees must always be preserved. Cryptographic operations must follow industry standards, and sensitive credentials must remain protected in memory using `ProtectedValue`.
- **Zero Regressions:** Any bug fix or feature addition must include accompanying unit or widget tests.
- **Cross-Platform Compatibility:** Changes must not break desktop (Windows, macOS, Linux) or mobile (Android, iOS) builds.

---

## 2. Local Setup & Workflow

1. Fork the repository and clone your fork locally:
   ```bash
   git clone --recursive https://github.com/<your-username>/keynest.git
   cd keynest
   ```
2. Follow the setup instructions in the [Development Setup Guide](docs/developer-guide/development-setup.md).
3. Create a feature branch from `master` (or `main`):
   ```bash
   git checkout -b feature/my-new-feature
   ```

---

## 3. Code Standards & Testing

Before submitting a pull request, ensure all linting and tests pass:

```bash
cd keynest

# 1. Format code according to Dart conventions
dart format --set-exit-if-changed lib test

# 2. Run static analysis
flutter analyze

# 3. Run the complete test suite
flutter test
```

If you modify data models or test fixtures that use code generation:
```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

---

## 4. Submitting Pull Requests

1. Commit your changes with clear, descriptive commit messages adhering to conventional commit formatting (e.g. `feat: add export option`, `fix: handle WebDAV timeout`).
2. Push your branch to your fork:
   ```bash
   git push origin feature/my-new-feature
   ```
3. Open a Pull Request against the upstream repository.
4. Provide a clear description in your PR outlining:
   - The problem being addressed or feature being implemented.
   - Any manual or automated tests conducted.
   - Screenshots or recordings for user interface modifications.

---

## 5. Reporting Issues

- For bug reports or feature requests, open an issue on the GitHub Issues page.
- Search existing issues first to avoid duplicates.
- Provide device details, operating system version, KeyNest version, and reproducible steps.
- **Security Vulnerabilities:** Do not report security vulnerabilities in public issues. Refer to [SECURITY.md](SECURITY.md).
