# Changelog

All notable changes to this project are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

## [0.3.0] - Unreleased

### Added — Step 3 (Channels)
- `Channel` — isolated named channels with the full transport surface (`On`/`Once`/`Off`, `Fire`/`FireUnreliable`, server-only `FireAll`/`FireAllUnreliable`/`FireExcept`/`FireList`).
- `Network.Channel(name)` — memoized accessor; same name returns the same object everywhere. Server access creates the channel's remotes eagerly so clients never race discovery.
- Channel name validation (instance-safe, `__` reserved, 1–100 chars).
- Channel spec (5 tests, 40 total); playtest extended to prove channel isolation (same event name on Global and Combat never cross).

## [0.2.0] - 2026-07-11

### Added — Step 2 (Core transport)
- `Envelope` — wire format rules: `(eventName, ...args)` positional, name length limits, `__` reserved prefix, channel-name instance safety.
- `RemoteRegistry` — lazy server-side creation and client-side discovery of per-channel remote trios (`Reliable` RemoteEvent / `Unreliable` UnreliableRemoteEvent / `Function` RemoteFunction) under `ReplicatedStorage._Networking`.
- `Dispatcher` — `(channel, event) → Signal` routing table shared by both transports.
- `Server/Transport` — `On`/`Once`/`Off`, `Fire`, `FireUnreliable`, `FireAll`, `FireAllUnreliable`, `FireExcept`, `FireList`. Incoming packets with invalid event names are dropped and logged before dispatch.
- `Client/Transport` — `On`/`Once`/`Off` (never yield; receive path binds in the background), `Fire`/`FireUnreliable` (bounded discovery wait via `Config.DefaultTimeout`, drops with an error log on expiry).
- Context-aware public API on the entry point operating on the built-in `Global` channel: `Network.On/Once/Off/Fire/FireUnreliable/FireAll/FireAllUnreliable/FireExcept/FireList`.
- Specs: Envelope, Dispatcher, RemoteRegistry, ServerTransport (24 tests total).
- Play-mode end-to-end test scripts (`playtest/`) wired into `test.project.json`.

## [0.1.0] - 2026-07-11

### Added — Step 1 (Foundation)
- Package scaffolding, Rojo/Wally/Rokit tooling, CI workflows (lint, analyze, release).
- `Types` — shared public type definitions.
- `Config` — centralized runtime configuration with deep-merge, validation, and change signal.
- `Signal` — strict-typed signal implementation with thread reuse (Connect/Once/Wait/Fire).
- `Log` — level-gated logger respecting `Config.LogLevel`.
- `TableUtil` — deepCopy / deepMerge / deepFreeze helpers.
- Harness-agnostic test specs + minimal TestKit runner.
