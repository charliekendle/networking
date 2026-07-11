# Changelog

All notable changes to this project are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

## [Unreleased]

### Added
- Step 1 (Foundation): package scaffolding, Rojo/Wally/Rokit tooling, CI workflows.
- `Types` — shared public type definitions.
- `Config` — centralized runtime configuration with deep-merge, validation, and change signal.
- `Signal` — strict-typed signal implementation with thread reuse (Connect/Once/Wait/Fire).
- `Log` — level-gated logger respecting `Config.LogLevel`.
- `TableUtil` — deepCopy / deepMerge / readonly helpers.
