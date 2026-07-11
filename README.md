# Networking

Production-grade, type-safe networking for Roblox. Channels, middleware, validation, security, and debugging built in — installed with a single Wally dependency.

> **Status: pre-release (0.1.x).** The foundation (config, signals, logging, tooling, CI) is complete. Core transport and channels are in active development. API surface below marks what's live vs planned.

## Installation

```toml
# wally.toml
[dependencies]
Networking = "charliekendle/networking@0.1.0"
```

```lua
local Network = require(ReplicatedStorage.Packages.Networking)
```

## Quick Start (target API)

```lua
-- Server
local Combat = Network.Channel("Combat")

Combat:On("Damage", function(player, amount)
	-- validated, rate-limited, middleware-processed before you ever see it
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

## Live API (0.1.0)

| Member | Description |
| --- | --- |
| `Network.Configure(patch)` | Deep-merge partial config (debug, logging, validation, security, rate limits, timeouts). Unknown keys and invalid values error immediately. |
| `Network.GetConfig()` | Read-only snapshot of active config. |
| `Network.ConfigChanged` | Signal fired with the new snapshot after every change. |
| `Network.Signal` | The package's strict-typed signal implementation, exposed for reuse. |
| `Network.Version` | SemVer string. |

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
- [ ] **Step 2 — Core transport**: remote creation/discovery, packet envelope, `Fire`/`On`/`Once`/`Off`
- [ ] **Step 3 — Channels**: isolated channel instances with per-channel remotes
- [ ] **Step 4 — Validation**: schema validators (`t`-style), automatic packet rejection
- [ ] **Step 5 — Security**: rate limiting, abuse detection, permissions, audit log, suspicious-activity hooks
- [ ] **Step 6 — Middleware**: global + per-channel chains
- [ ] **Step 7 — Request/response**: `Invoke`, promises, timeouts, retries, cancellation
- [ ] **Step 8 — Serialization & compression**: Roblox datatypes, buffers, optional compression
- [ ] **Step 9 — Spatial fire**: `FireNearby`, `FireWithinRadius`, `FireExcept`
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

Tests live in `tests/` as harness-agnostic spec modules; run `tests/runner.server.luau` inside the built test place (or via `run-in-roblox`).

## License

MIT — see [LICENSE](LICENSE).
