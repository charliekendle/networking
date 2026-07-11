# Changelog

All notable changes to this project are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

## [0.5.0] - Unreleased

### Added — Step 5 (Security)
- `RateLimiter` — token bucket per `(player, channel)`: capacity = `MaxPacketsPerSecond + BurstAllowance`, lazy refill, live-tunable via Config. Per-channel buckets mean spam on one channel can't starve another. Auto-cleanup on PlayerRemoving.
- `SecurityMonitor` — consecutive-strike tracking (any dropped packet strikes; a clean packet resets), `OnSuspiciousActivity` hook firing every `PunishThreshold` violations, bounded 256-entry audit log (ring buffer), violation logging throttled to 1/sec/player so the limiter can't be turned into console spam.
- Server receive pipeline is now: rate limit → envelope → schema validation → dispatch, with every drop reported. The package never kicks/bans on its own — punishment is the game's decision in the hook.
- `Network.OnSuspiciousActivity` (server), `Network.GetAuditLog()` (server). Gates: `Config.SecurityEnabled` (master), `Config.RateLimit.Enabled`.
- Specs: RateLimiter (4), SecurityMonitor (5) — 64 tests total. Playtest fires a 200-packet burst and reports how many passed.

## [0.4.0] - 2026-07-11

### Added — Step 4 (Validation)
- `Validators` — composable runtime validators: primitives (`boolean`/`string`/`number`/`integer`/`table`/`buffer`/`any`), combinators (`optional`/`literal`/`union`/`array`/`dict`/`interface`/`strictInterface`/`custom`), constraints (`numberRange`/`integerRange`/`numberMin`/`numberMax`/`stringMaxLength`/`match`), Roblox datatypes (`vector3`/`vector2`/`cframe`/`color3`/`udim2`/`enumItem`/`instance`/`instanceIsA`). `number` and all datatype validators reject NaN/±inf by design.
- `SchemaRegistry` — positional schemas per `(channel, event)`; allocation-free vararg checking; extra arguments always rejected; trailing `optional(...)` expresses optional args.
- `Network.Expect(event, ...validators)` / `channel:Expect(event, ...validators)` — packets failing the schema are dropped and logged before handlers run. Gated by `Config.ValidationEnabled`.
- Specs: Validators (9), SchemaRegistry (6) — 55 tests total. Playtest sends one valid + three invalid `ValidatedPing`s to demonstrate live rejection.

## [0.3.0] - 2026-07-11

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
