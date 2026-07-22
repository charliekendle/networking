# Changelog

All notable changes to this project are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

## [1.1.0] - Unreleased

### Added — Defined events (`Network.Schema` + `channel:Define`)
Addresses the fair criticism that validators were runtime gates only. A Schema codec now does triple duty — wire format, static type, and validation:
- `Network.Schema` codecs: `boolean`, `u8/u16/u32/i16/i32`, `int(min, max)` (auto-picks minimal width, range-checks tighter than the width on decode), `f32/f64` (NaN/±inf rejected on encode AND decode), `str(max)`, `buf(max)`, `vec3/vec2/cframe/color3`, `optional`, `array(codec, max)`, `struct(shape)` (sorted field order, zero key names on the wire), `literals(...)` (1 byte).
- `channel:Define(event, codec) -> EventDef<T>` / `Network.Define` — typed handles: `Fire`/`On`/`FireAll`/`FireExcept`/`FireUnreliable` carry the codec's phantom type for real Luau inference. Payload travels as **one schema-packed buffer** (e.g. a Seq+Power+Direction struct is 15 bytes, zero key overhead).
- Receive path: defined events **skip the runtime validator pass entirely** — decode enforces bounds/finiteness/shape by construction; hostile buffers (truncated, out-of-range, trailing bytes, bad flags) are dropped and striked as Validation violations. Send site errors immediately on out-of-schema values.
- `BufferIO` extracted as the shared writer/reader for Serializer + Schema (internal refactor, no format change).
- Specs: Schema (8, incl. hostile-buffer decode rejection), DefinedEvent (4) — 111 tests total. Playtest fires a typed struct end-to-end plus two hostile buffers that must strike.

Define in a shared module required by both contexts so both sides register the codec. `Expect`/loose `Fire` remain unchanged as the untyped tier.

## [1.0.0] - 2026-07-20

### Added — Step 11 (Docs, examples, benchmarks) & API freeze
- `docs/api-reference.md` — complete API reference for the 1.0 surface.
- `docs/tutorials.md` — 8 tutorials from hello-world to debugging.
- `docs/migration.md` — migrating from raw remotes and Net/Red-style libraries; version policy.
- `CONTRIBUTING.md` — setup, workflow, design rules, release process.
- `examples/` — combat (schema + gate + spatial), shop (validated invokes, both promise styles), security hooks, serialized+compressed snapshots; server and client halves.
- `benchmark/` + `benchmark.project.json` — Signal, Dispatcher, validation, rate limiter, Serializer, and Compression benchmarks.

### Changed
- **API freeze.** 1.x guarantees no breaking changes to documented APIs or wire-format tags without a major bump.

## [0.8.1] - 2026-07-18

### Added
- `Compression` (`Network.Compress`/`Network.Decompress`) — LZW over buffers, 1-byte header, automatic raw fallback when compression wouldn't shrink the input (never grows output beyond input + 1 byte). Decompress rejects corrupt/truncated input. Specs: 5.

### Changed
- Serializer wire format v2: varint (LEB128) lengths/counts and **string interning** — repeated strings (dictionary keys especially) collapse to ~2 bytes after first occurrence. The 100-item benchmark payload dropped from 4309 to ~1.5 KB.

### Fixed
- Middleware chains now snapshot before running: a middleware disconnecting itself (or others) mid-run no longer skips sibling middleware for that packet.
- Invoke rejection reasons are clean strings again ("InvokeTimeout", not "ReplicatedStorage...Transport:338: InvokeTimeout") — internal rethrows use error level 0.

## [0.8.0] - Unreleased

### Added — Step 7 (Request/response)
- `Promise` (`Network.Promise`) — chaining (`AndThen`/`Catch`/`Finally`), flattening, `Await`/`Expect`, cancellation with onCancel hooks. Handlers always run async; handler errors reject the chain.
- Invoke protocol over reserved `__invoke`/`__reply` events on the Reliable remote (correlation IDs; the per-channel RemoteFunction stays unused — RemoteEvent correlation gives clean timeouts and cancellation without engine hang risks).
- Client→server: `channel:Invoke(event, ...)` / `InvokeWithOptions({Timeout, Retries}, ...)` — timeouts reject with `"InvokeTimeout"` and retry with a fresh id (only timeouts retry; an error reply means the server already ran the handler). Server→client: `channel:InvokeClient(player, event, ...)` — always timeout-bounded, never retried, pending invokes rejected with `"PlayerLeft"` on leave.
- Handlers via `channel:OnInvoke(event, handler)` (one per event, may yield, run off the receive path). Server handler errors reply a **sanitized** "Invoke handler error" (real error logged server-side only). Schemas from `Expect` apply to invoke arguments; malformed protocol frames and cross-player reply spoofing are reported as `"Protocol"` violations.
- Global-channel equivalents: `Network.OnInvoke/Invoke/InvokeWithOptions/InvokeClient`.

### Added — Step 8 (Serialization)
- `Serializer` (`Network.Serialize`/`Network.Deserialize`) — packs value trees into one compact buffer: variable-width integers (1/2/4/8 bytes), strings, nested tables (array+dict), buffers, Vector3/Vector2/CFrame (axis-angle)/Color3/UDim2/EnumItems. Errors on Instances, functions, cyclic tables; deserialize errors on truncated/corrupt/unknown-tag input instead of crashing.

### Added — Step 9 (Spatial fire)
- `FireNearby(position, radius, event, ...)` and `FireWithinRadius(originPlayer, radius, event, ...)` on channels, transports, and the Global surface (server-only).

### Added — Step 10 (Debugging)
- `Stats` — always-on counters (total + per-channel Sent/Received/Dropped), rolling average invoke RTT (64-sample window), and a 128-entry packet log recorded only while `DebugMode` is on. `Network.GetStats()` / `Network.GetPacketLog()` on both contexts.
- Specs: Promise (10), Serializer (9), Stats (4) — 94 tests total. Playtest covers invoke happy/error/missing/timeout paths, a server→client invoke, a serialized 100-item snapshot, and a stats dump.

## [0.6.0] - 2026-07-11

### Added — Step 6 (Middleware)
- `MiddlewareRegistry` — ordered inbound chains, global and per-channel. Execution: global (registration order) → channel chain. Verdicts: `"Continue"` (optionally with a replacement packet, which flows downstream) or `"Drop"`. Errors and invalid verdicts **fail closed** (packet dropped + Error log) — a crashed permission check never fails open.
- `Network.Use(middleware)` (global) / `channel:Use(middleware)` (scoped) on both contexts; returns a Connection, safe to disconnect mid-run.
- Pipeline is now rate limit → envelope → schema → **middleware** → dispatch. Packet structs (`Channel/Event/Args/ArgCount/Player/Kind/Timestamp`) are only allocated when at least one middleware is registered — unused middleware costs zero.
- Packets now carry `Kind` ("Event" vs "UnreliableEvent") end-to-end; `Types.Packet` gained `ArgCount` (authoritative arg length, trailing nils preserved).
- Specs: Middleware (7) — 71 tests total. Playtest adds a +100 transform on Combat (`MIDDLEWARE TRANSFORM OK`) and a global packet counter.

## [0.5.0] - 2026-07-11

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
