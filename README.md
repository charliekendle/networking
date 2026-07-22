# Networking

Production-grade, type-safe networking for Roblox. Channels, middleware, validation, security, and debugging built in — installed with a single Wally dependency.

> **Status: 1.0 — stable.** Full docs in [docs/api-reference.md](docs/api-reference.md), tutorials in [docs/tutorials.md](docs/tutorials.md), migration notes in [docs/migration.md](docs/migration.md). 1.x guarantees no breaking changes to documented APIs or the wire format without a major bump.

## Installation

```toml
# wally.toml
[dependencies]
Networking = "charliekendle/networking@1.0.0"
```

```lua
local Network = require(ReplicatedStorage.Packages.Networking)
```

## Quick Start

```lua
-- Server
local Combat = Network.Channel("Combat")

Combat:Expect("Damage", Network.Validators.numberRange(0, 100))
Combat:On("Damage", function(player, amount)
	-- amount is guaranteed a finite number 0..100; anything else was
	-- dropped (and logged) before this handler could run
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

## Live API (1.0.0)

### Channels

| Member | Context | Description |
| --- | --- | --- |
| `Network.Channel(name)` | both | Memoized channel accessor. Server: creates remotes eagerly. Client: discovery defers to first use. |
| `channel:On/Once/Off` | both | Same semantics as the Global versions below, scoped to the channel. |
| `channel:Fire/FireUnreliable` | both | Server: `(player, event, ...)`. Client: `(event, ...)`. |
| `channel:FireAll/FireAllUnreliable/FireExcept/FireList` | server | Broadcast family, scoped to the channel. |
| `channel:Expect(event, ...validators)` | both | Positional schema for incoming packets; failures dropped + logged before handlers. Register server-side for security. |
| `channel:Use(middleware)` | both | Inbound middleware scoped to the channel. |
| `channel:OnInvoke(event, handler)` | both | Answer invokes. Server handler `(player, ...) -> ...reply`; client `(...) -> ...reply`. May yield. |
| `channel:Invoke(event, ...)` | client | Request/response; returns a Promise. `InvokeWithOptions({Timeout, Retries}, ...)` to override defaults. |
| `channel:InvokeClient(player, event, ...)` | server | Invoke a client; always timeout-bounded, never retried. |
| `channel:FireNearby(position, radius, event, ...)` | server | Fire to players within `radius` studs of a position. |
| `channel:FireWithinRadius(player, radius, event, ...)` | server | Fire to players near another player (origin included). |

### Validation

`Network.Expect(event, ...validators)` is the Global-channel equivalent of `channel:Expect`. Rules: extra arguments beyond the schema are always rejected; trailing `optional(...)` validators express optional arguments; the first failure drops the packet with a positional reason in the log. Gate: `Config.ValidationEnabled` (default on).

`Network.Validators`: `any` `boolean` `string` `number`* `numberRaw` `integer` `table` `buffer` `optional` `literal` `union` `array`(+max len) `dict` `interface` `strictInterface` `numberMin` `numberMax` `numberRange`* `integerRange` `stringMaxLength` `match` `enumItem` `instance` `instanceIsA` `vector3`* `vector2`* `cframe`* `color3` `udim2`* `custom`

\* rejects NaN/±inf — exploiters cannot smuggle non-finite numbers through a validated event.

### Middleware

`Network.Use(fn)` registers a global inbound middleware (every channel); `channel:Use(fn)` scopes one. Order: global chain (registration order), then the channel chain. A middleware receives a `Packet` (`Channel`, `Event`, `Args`, `ArgCount`, `Player?`, `Kind`, `Timestamp`) and returns a verdict:

```lua
Combat:Use(function(packet)
	if packet.Player and not canFight(packet.Player) then
		return "Drop" -- permission gate: packet never reaches handlers
	end
	return "Continue"
end)

Combat:Use(function(packet)
	packet.Args[1] = math.floor(packet.Args[1] :: any)
	return "Continue", packet -- transform: replacement flows downstream
end)
```

Middleware that errors (or returns garbage) **drops the packet — fail closed**. A crashed permission check never fails open. Unused middleware costs nothing: the pipeline skips Packet allocation entirely when no chain applies.

### Request/response

```lua
-- Server
Shop:OnInvoke("GetCatalog", function(player, category)
	return CatalogService:GetItems(category) -- may yield
end)

-- Client
Shop:Invoke("GetCatalog", "Weapons")
	:AndThen(function(items) render(items) end)
	:Catch(function(reason) warn(reason) end)

local ok, items = Shop:Invoke("GetCatalog", "Weapons"):Await()
```

Rides reserved `__invoke`/`__reply` protocol frames with correlation IDs (never the engine RemoteFunction, so timeouts and cancellation are clean). Rejections: the server's error string, `"InvokeTimeout"`, or `"ChannelNotFound"`. Only timeouts retry (an error reply means the handler already ran); server→client invokes are always timeout-bounded so a silent client can't hang server logic. Server handler errors reach the client as a sanitized `"Invoke handler error"` — real errors log server-side only. `Expect` schemas apply to invoke arguments. `Network.Promise` is exposed for reuse.

### Serialization

```lua
Shop:Fire(player, "Snapshot", Network.Serialize(bigInventoryTable))
-- receiving side
local inventory = Network.Deserialize(blob)
```

Packs a value tree into one compact buffer: variable-width ints, varint lengths, **interned strings** (repeated dictionary keys cost ~2 bytes after the first), nested tables, Vector3/CFrame/Color3/UDim2/EnumItems, buffers. Dramatically smaller than generic argument serialization for large payloads. Errors on Instances/functions/cycles; deserialize rejects corrupt input (pcall it for remote-supplied buffers).

For repetitive payloads (~1 KB+), layer LZW on top: `Network.Compress(blob)` / `Network.Decompress(blob)`. Automatic raw fallback means output never exceeds input + 1 byte on incompressible data.

### Debugging

`Network.GetStats()` — total and per-channel Sent/Received/Dropped counters plus rolling average invoke RTT. `Network.GetPacketLog()` — last 128 packets (direction, channel, event, arg count, player), recorded only while `DebugMode` is on.

### Security

Every incoming packet runs the server pipeline **rate limit → envelope → schema → middleware → dispatch**; any drop is a strike, a clean packet resets strikes, and `PunishThreshold` consecutive strikes fires the hook. The package never kicks or bans on its own:

```lua
Network.OnSuspiciousActivity:Connect(function(report)
	-- report: Player, Channel, Event?, Kind ("RateLimit"|"Validation"|"Envelope"), Reason, Strikes
	report.Player:Kick("Network abuse detected")
end)

local entries = Network.GetAuditLog() -- most recent 256 drops, oldest first
```

Rate limiting is a token bucket per player **per channel** (defaults: 60 packets/s + 20 burst) — a flood on one channel can't starve legitimate traffic on another. All limits live-tunable via `Network.Configure`; gates: `SecurityEnabled`, `RateLimit.Enabled`. Violation logging is throttled to once per second per player.

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
- [x] **Step 4 — Validation**: schema validators (`t`-style), automatic packet rejection
- [x] **Step 5 — Security**: rate limiting, abuse detection, audit log, suspicious-activity hooks (permissions middleware arrives with Step 6)
- [x] **Step 6 — Middleware**: global + per-channel chains, transforms, fail-closed error handling
- [x] **Step 7 — Request/response**: `Invoke`, promises, timeouts, retries, cancellation
- [x] **Step 8 — Serialization & compression**: value trees → compact buffers (varints, string interning, Roblox datatypes) + LZW with raw fallback
- [x] **Step 9 — Spatial fire**: `FireNearby`, `FireWithinRadius`
- [x] **Step 10 — Debugging**: statistics, packet log, invoke RTT tracking
- [x] **Step 11 — Docs & examples**: full API reference, tutorials, migration guide, benchmarks
- [x] **1.0.0** — API freeze

## Development

Toolchain via [Rokit](https://github.com/rojo-rbx/rokit):

```bash
rokit install
rojo sourcemap default.project.json --output sourcemap.json  # analysis
rojo build test.project.json --output test.rbxl              # test place (F8 units, F5 e2e)
rojo build benchmark.project.json --output benchmark.rbxl    # benchmark place (F8)
stylua src tests && selene src tests                          # format + lint
```

Tests live in `tests/` as harness-agnostic spec modules; build the test place and press **Run** (F8) in Studio to execute them. Press **Play** (F5) instead to also run the end-to-end play test in `playtest/` — the client fires 3 Pings, the server replies with Pongs, and the client prints `ALL PONGS RECEIVED` on success.

## License

MIT — see [LICENSE](LICENSE).
