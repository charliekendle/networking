# Networking

Production-grade, type-safe networking for Roblox. Channels, middleware, validation, security, and debugging built in — installed with a single Wally dependency.

> **Status: pre-release (0.3.x).** Foundation, core transport, and channels are complete — `Fire`/`On` works end-to-end server↔client, reliable and unreliable, on the Global channel and on isolated named channels. Validation and security are next.

## Installation

```toml
# wally.toml
[dependencies]
Networking = "charliekendle/networking@0.3.0"
```

```lua
local Network = require(ReplicatedStorage.Packages.Networking)
```

## Quick Start

```lua
-- Server
local Combat = Network.Channel("Combat")

Combat:On("Damage", function(player, amount)
	-- event-name-sanitized before it reaches you; schema validation lands in Step 4
end)

Combat:Fire(player, "Knockback", direction)
Combat:FireAll("RoundStarted", roundId)
```

```lua
-- Client
local Combat = Network.Channel("Combat")

Combat:Fire("Damage", 25)

Combat:On("Knockback", function(direction)
end)
```

Each channel owns its remotes; event names are scoped per channel ("Ping" on Combat and "Ping" on Trading never interact). `Network.Channel(name)` is memoized — grab it anywhere, no registry module needed. The same `Fire`/`On` family also exists top-level on `Network`, operating on the built-in `Global` channel.

## Live API (0.3.0)

### Channels

| Member | Context | Description |
| --- | --- | --- |
| `Network.Channel(name)` | both | Memoized channel accessor. Server: creates remotes eagerly. Client: discovery defers to first use. |
| `channel:On/Once/Off` | both | Same semantics as the Global versions below, scoped to the channel. |
| `channel:Fire/FireUnreliable` | both | Server: `(player, event, ...)`. Client: `(event, ...)`. |
| `channel:FireAll/FireAllUnreliable/FireExcept/FireList` | server | Broadcast family, scoped to the channel. |

### Global channel

| Member | Context | Description |
| --- | --- | --- |
| `Network.On(event, cb)` | both | Listen. Server cb: `(player, ...)`. Client cb: `(...)`. Never yields. Returns Connection. |
| `Network.Once(event, cb)` | both | As On; auto-disconnects after first packet. |
| `Network.Off(event)` | both | Disconnect all listeners for the event. |
| `Network.Fire(...)` | both | Reliable send. Server: `(player, event, ...)`. Client: `(event, ...)` — first use of a channel may yield briefly during remote discovery. |
| `Network.FireUnreliable(...)` | both | Unreliable send (may drop, never resent). Same signatures as Fire. |
| `Network.FireAll(event, ...)` | server | Reliable broadcast to all players. |
| `Network.FireAllUnreliable(event, ...)` | server | Unreliable broadcast. |
| `Network.FireExcept(excluded, event, ...)` | server | Broadcast excluding a Player or `{Player}`. |
| `Network.FireList(players, event, ...)` | server | Send to an explicit player list. |
| `Network.Configure(patch)` | both | Deep-merge partial config. Unknown keys and invalid values error immediately. |
| `Network.GetConfig()` | both | Read-only snapshot of active config. |
| `Network.ConfigChanged` | both | Signal fired with the new snapshot after every change. |
| `Network.Signal` | both | The package's strict-typed signal implementation, exposed for reuse. |
| `Network.Version` | both | SemVer string. |

Event names: 1–100 chars, `__` prefix reserved for protocol traffic. Incoming packets failing these rules are dropped and logged before they can reach your handlers.

### Configuration

```lua
Network.Configure({
	DebugMode = true,
	LogLevel = "Debug", -- "Debug" | "Info" | "Warn" | "Error" | "None"
	ValidationEnabled = true,
	SecurityEnabled = true,
	DefaultTimeout = 10,
	DefaultRetries = 2,
	RateLimit = {
		Enabled = true,
		MaxPacketsPerSecond = 60,
		BurstAllowance = 20,
		PunishThreshold = 5,
	},
})
```

### Signal

```lua
local Signal = Network.Signal

local damaged = Signal.new() :: Network.Signal<Player, number>

local connection = damaged:Connect(function(player, amount) end)
damaged:Once(function(player, amount) end)
local player, amount = damaged:Wait()
damaged:Fire(somePlayer, 25)
connection:Disconnect()
```

Zero thread allocation for non-yielding handlers; a handler that errors never breaks other handlers.

## Roadmap

- [x] **Step 1 — Foundation**: tooling, CI, `Types`, `Config`, `Signal`, `Log`, test harness
- [x] **Step 2 — Core transport**: remote creation/discovery, envelope, `Fire`/`On`/`Once`/`Off`, `FireAll`/`FireExcept`/`FireList`, unreliable variants
- [x] **Step 3 — Channels**: isolated channel instances with per-channel remotes
- [ ] **Step 4 — Validation**: schema validators (`t`-style), automatic packet rejection
- [ ] **Step 5 — Security**: rate limiting, abuse detection, permissions, audit log, suspicious-activity hooks
- [ ] **Step 6 — Middleware**: global + per-channel chains
- [ ] **Step 7 — Request/response**: `Invoke`, promises, timeouts, retries, cancellation
- [ ] **Step 8 — Serialization & compression**: Roblox datatypes, buffers, optional compression
- [ ] **Step 9 — Spatial fire**: `FireNearby`, `FireWithinRadius`
- [ ] **Step 10 — Debugging**: packet inspector, live monitor, statistics
- [ ] **Step 11 — Docs & examples**: full API reference, tutorials, migration guide
- [ ] **1.0.0** — API freeze

## Development

Toolchain via [Rokit](https://github.com/rojo-rbx/rokit):

```bash
rokit install
rojo sourcemap default.project.json --output sourcemap.json  # analysis
rojo build test.project.json --output test.rbxl              # test place
stylua src tests && selene src tests                          # format + lint
```

Tests live in `tests/` as harness-agnostic spec modules; build the test place and press **Run** (F8) in Studio to execute them. Press **Play** (F5) instead to also run the end-to-end play test in `playtest/` — the client fires 3 Pings, the server replies with Pongs, and the client prints `ALL PONGS RECEIVED` on success.

## License

MIT — see [LICENSE](LICENSE).
