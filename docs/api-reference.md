# API Reference

Complete surface for `charliekendle/networking` 1.0. Everything is `--!strict` typed; types shown here are re-exported from the package root (`Networking.Channel`, `Networking.Packet`, etc.).

Context legend: **[S]** server-only · **[C]** client-only · **[SC]** both (behaviour may differ by context).

---

## Network (package root)

```lua
local Network = require(ReplicatedStorage.Packages.Networking)
```

### Core

| Member | Context | Signature |
| --- | --- | --- |
| `Network.Version` | SC | `string` — SemVer. |
| `Network.Channel(name)` | SC | `(string) -> Channel`. Memoized accessor; see [Channel](#channel). |
| `Network.Configure(patch)` | SC | Deep-merges a partial [config](#configuration). Unknown keys/invalid values error. |
| `Network.GetConfig()` | SC | Read-only (deep-frozen) config snapshot. |
| `Network.ConfigChanged` | SC | `Signal<NetworkConfig>` — fires after every change. |

### Events (Global channel)

The functions below are the Global-channel versions of the identically named [Channel](#channel) methods.

| Member | Context |
| --- | --- |
| `Network.On(event, callback) -> Connection` | SC |
| `Network.Once(event, callback) -> Connection` | SC |
| `Network.Off(event)` | SC |
| `Network.Fire(player, event, ...)` | S |
| `Network.Fire(event, ...)` | C |
| `Network.FireUnreliable(...)` | SC (same signatures as Fire) |
| `Network.FireAll(event, ...)` / `FireAllUnreliable` | S |
| `Network.FireExcept(playerOrList, event, ...)` | S |
| `Network.FireList(players, event, ...)` | S |
| `Network.FireNearby(position, radius, event, ...)` | S |
| `Network.FireWithinRadius(originPlayer, radius, event, ...)` | S |

### Request/response (Global channel)

| Member | Context |
| --- | --- |
| `Network.OnInvoke(event, handler)` | SC |
| `Network.Invoke(event, ...) -> Promise` | C |
| `Network.InvokeWithOptions({Timeout?, Retries?}, event, ...) -> Promise` | C |
| `Network.InvokeClient(player, event, ...) -> Promise` | S |

### Validation & middleware

| Member | Context |
| --- | --- |
| `Network.Validators` | SC — see [Validators](#validators). |
| `Network.Expect(event, ...validators)` | SC — Global-channel schema. |
| `Network.Use(middleware) -> Connection` | SC — **global** middleware (every channel). |

### Security

| Member | Context |
| --- | --- |
| `Network.OnSuspiciousActivity` | S — `Signal<SecurityReport>`. |
| `Network.GetAuditLog() -> {AuditEntry}` | S — last 256 drops, oldest first. |

### Serialization & compression

| Member | Context |
| --- | --- |
| `Network.Serialize(value) -> buffer` | SC |
| `Network.Deserialize(buffer) -> unknown` | SC — errors on corrupt input; pcall remote-supplied buffers. |
| `Network.Compress(bufferOrString) -> buffer` | SC |
| `Network.Decompress(buffer) -> buffer` | SC — errors on corrupt input. |

### Debugging

| Member | Context |
| --- | --- |
| `Network.GetStats() -> StatsSnapshot` | SC |
| `Network.GetPacketLog() -> {PacketLogEntry}` | SC — populated only while `DebugMode` is on. |

### Utilities

| Member | Context |
| --- | --- |
| `Network.Signal` | SC — signal constructor (`Signal.new/is`). |
| `Network.Promise` | SC — promise constructor (`Promise.new/resolve/reject/is`). |

---

## Channel

Obtained via `Network.Channel(name)`. Memoized: the same name returns the same object everywhere. Server-side access creates the channel's remotes eagerly; client discovery defers to first use. Event names are scoped per channel.

Channel names: 1–100 chars, no `__` prefix, no `/ \ .` characters.

```lua
local Combat = Network.Channel("Combat")
```

| Method | Context | Notes |
| --- | --- | --- |
| `channel:On(event, callback) -> Connection` | SC | Server cb: `(player, ...)`. Client cb: `(...)`. Never yields. |
| `channel:Once(event, callback) -> Connection` | SC | Disconnects after first packet. |
| `channel:Off(event)` | SC | Disconnects all listeners of the event. |
| `channel:Fire(player, event, ...)` | S | Reliable to one player. |
| `channel:Fire(event, ...)` | C | Reliable to server. First use may yield during remote discovery (bounded by `DefaultTimeout`). |
| `channel:FireUnreliable(...)` | SC | May drop, never resent. Use for high-frequency cosmetic state. |
| `channel:FireAll(event, ...)` | S | All players. `FireAllUnreliable` variant. |
| `channel:FireExcept(playerOrList, event, ...)` | S | All except a Player or `{Player}`. |
| `channel:FireList(players, event, ...)` | S | Explicit list. |
| `channel:FireNearby(position, radius, event, ...)` | S | Players whose character root is within `radius` studs. |
| `channel:FireWithinRadius(origin, radius, event, ...)` | S | Around another player's character (origin included). |
| `channel:Expect(event, ...validators)` | SC | Positional schema; see [Validation](#validation-rules). |
| `channel:Use(middleware) -> Connection` | SC | Channel-scoped inbound middleware. |
| `channel:OnInvoke(event, handler)` | SC | Server handler `(player, ...) -> ...reply`; client `(...) -> ...reply`. May yield. One per event. |
| `channel:Invoke(event, ...) -> Promise` | C | Config default timeout/retries. |
| `channel:InvokeWithOptions(options, event, ...) -> Promise` | C | `{Timeout: number?, Retries: number?}`. |
| `channel:InvokeClient(player, event, ...) -> Promise` | S | Always timeout-bounded; never retried. |

---

## Configuration

Defaults shown. All keys live-tunable via `Network.Configure`; per-key validation with loud errors on typos.

```lua
{
	DebugMode = false,          -- enables the packet log + Debug prints
	LogLevel = "Warn",          -- "Debug" | "Info" | "Warn" | "Error" | "None"
	ValidationEnabled = true,   -- Expect schemas enforced
	SecurityEnabled = true,     -- rate limiting + strikes + audit
	CompressionEnabled = false, -- reserved; Compress/Decompress are explicit calls
	DefaultTimeout = 10,        -- seconds: invoke timeout, client remote discovery
	DefaultRetries = 0,         -- client->server invoke resends after timeout
	RemoteFolderName = "_Networking",
	RateLimit = {
		Enabled = true,
		MaxPacketsPerSecond = 60, -- refill rate per player per channel
		BurstAllowance = 20,      -- extra bucket depth
		PunishThreshold = 5,      -- consecutive strikes before the hook fires
	},
}
```

---

## Validation rules

`Expect(event, v1, v2, ...)` registers one validator per positional argument.

- **More args than validators → reject.** Nothing can be smuggled past a schema.
- Fewer args: missing slots validate as `nil` — trailing `optional(...)` expresses optional arguments.
- First failure drops the packet, logged with a positional reason (`arg #2: expected 0..100, got 999`).
- Schemas apply to **both** `Fire`d events and `Invoke` arguments for that event name.
- Server-side registration is the security boundary; client-side is a development aid.

### Validators

All of shape `(value: unknown) -> (boolean, string?)`. Compose freely; plain functions of that shape are valid validators.

**Primitives:** `any` · `boolean` · `string` · `number`¹ · `numberRaw` · `integer`¹ · `table` · `buffer`

**Combinators:** `optional(v)` · `literal(x)` · `union(v1, v2, ...)` · `array(v, maxLength?)`² · `dict(keyV, valueV)` · `interface(shape)` (loose) · `strictInterface(shape)` (extra fields rejected — prefer on remotes) · `custom(fn, name?)`

**Constraints:** `numberMin(n)`¹ · `numberMax(n)`¹ · `numberRange(min, max)`¹ · `integerRange(min, max)`¹ · `stringMaxLength(n)` · `match(pattern)`

**Roblox datatypes:** `enumItem(enum)` · `instance` · `instanceIsA(className)` · `vector3`¹ · `vector2`¹ · `cframe`¹ · `color3` · `udim2`¹

¹ Rejects NaN/±inf (including per-component). ² Rejects holes and non-array keys.

---

## Middleware

`(packet: Packet) -> ("Continue" | "Drop", Packet?)`

- Order per packet: **global chain** (registration order) → **channel chain**.
- Runs **after** rate limit + envelope + schema, immediately before dispatch.
- `"Continue", replacementPacket` swaps the packet downstream (or mutate and return the same one).
- Errors and invalid verdicts **drop the packet (fail closed)** with an Error log.
- Zero cost when no chain applies (Packet is only allocated if `hasAny`).
- Registration returns a Connection; safe to disconnect mid-run (takes effect next packet).

### Packet

```lua
{
	Channel: string,
	Event: string,
	Args: { unknown },
	ArgCount: number,  -- authoritative length (trailing nils preserved)
	Player: Player?,   -- sender on the server; nil on the client
	Kind: "Event" | "UnreliableEvent" | "Invoke" | "Reply",
	Timestamp: number, -- os.clock() at receipt
}
```

---

## Security model

Server receive pipeline per packet: **rate limit → envelope → schema → middleware → dispatch.** Every drop:

- increments the sender's **consecutive** strike count (a clean packet resets to 0 — a single lag-spike trip never flags anyone);
- appends an [AuditEntry](#types) to a 256-entry ring buffer;
- logs, throttled to once per second per player.

At `PunishThreshold` consecutive strikes, `OnSuspiciousActivity` fires with a [SecurityReport](#types) and the counter resets (sustained abuse re-fires every N violations). **The package never kicks or bans** — that decision is the game's:

```lua
Network.OnSuspiciousActivity:Connect(function(report)
	if report.Kind == "RateLimit" and report.Strikes >= 5 then
		report.Player:Kick("Network abuse detected")
	end
end)
```

Rate limiting: token bucket per `(player, channel)` — capacity `MaxPacketsPerSecond + BurstAllowance`, lazy refill, live-tunable. Invoke protocol frames count against the same buckets. Malformed protocol frames and cross-player reply spoofing report as `Kind = "Protocol"`.

---

## Promise

```lua
local promise = Shop:Invoke("GetCatalog", "Weapons")
```

| Method | Notes |
| --- | --- |
| `:AndThen(onResolved?, onRejected?) -> Promise` | Handlers run async; returned promises flatten; handler errors reject the next link. |
| `:Catch(onRejected) -> Promise` | `AndThen(nil, fn)`; also receives cancellations. |
| `:Finally(callback) -> Promise` | Runs on settle either way; values pass through. |
| `:Await() -> (ok: boolean, ...)` | Yields. `true, ...values` or `false, ...reason`. |
| `:Expect() -> ...` | Yields; errors on rejection. |
| `:Cancel()` | Pending only: runs onCancel hooks, settles rejected with `"Promise cancelled"`. Cancelling an invoke abandons the request. |
| `:GetStatus()` | `"Pending" | "Resolved" | "Rejected" | "Cancelled"` |

Constructors: `Promise.new(function(resolve, reject, onCancel) end)`, `Promise.resolve(...)`, `Promise.reject(...)`, `Promise.is(value)`.

Invoke rejection reasons (exact strings): server error replies (`"Invalid arguments"`, `"No invoke handler for \"X\""`, `"Invoke handler error"`), `"InvokeTimeout"`, `"ChannelNotFound"`, `"PlayerLeft"` (server-side, target left).

---

## Serialization & compression

`Serialize` packs a value tree into one buffer: variable-width integers (1/2/4/8 bytes), varint lengths, **interned strings** (repeats cost ~2 bytes), nested tables (array + dict parts), Vector3/Vector2 (f32), CFrame (position + axis-angle, f32), Color3 (3 bytes), UDim2, EnumItems, nested buffers.

Errors on: Instances, functions, threads, cyclic tables. Metatables are ignored. `Deserialize` bounds-checks every read and rejects unknown tags — pcall it for remote-supplied buffers.

`Compress` is LZW (16-bit codes) with a 1-byte header and automatic raw fallback: output never exceeds input + 1 byte. Worth layering over `Serialize` for repetitive payloads ~1 KB+.

---

## Statistics

`GetStats()` snapshot:

```lua
{
	Sent: number, Received: number, Dropped: number, -- totals, always live
	PerChannel: { [string]: { Sent, Received, Dropped } },
	AverageInvokeRtt: number?, -- seconds, 64-sample rolling window
	PacketLogEnabled: boolean,
}
```

`GetPacketLog()` — up to 128 entries `{Time, Direction: "Send"|"Receive", Channel, Event, ArgCount, Player?}`, oldest first, recorded only while `DebugMode` is on.

---

## Types

Re-exported from the package root:

`NetworkConfig` · `PartialNetworkConfig` · `Channel` · `Connection` · `Packet` · `Middleware` · `MiddlewareResult` · `Validator` · `InvokeOptions` · `Promise` · `Signal<T...>` · `LogLevel` · `ViolationKind` (`"RateLimit" | "Validation" | "Envelope" | "Protocol"`) · `StatsSnapshot` · `PacketLogEntry` ·

`SecurityReport`: `{Player, Channel, Event: string?, Kind: ViolationKind, Reason: string, Strikes: number}`

`AuditEntry`: `{Time: number (os.time), UserId, PlayerName, Channel, Event: string?, Kind, Reason}`

---

## Wire details (for the curious)

- One folder per channel under `ReplicatedStorage._Networking` containing `Reliable` (RemoteEvent), `Unreliable` (UnreliableRemoteEvent), `Function` (RemoteFunction, reserved).
- Event wire format: `(eventName: string, ...args)` — no wrapper table.
- Invoke frames: `(__invoke, id, eventName, ...args)` / `(__reply, id, ok, ...results)` over the Reliable remote. `__`-prefixed names are reserved; user code cannot register or fire them, and peers sending unknown `__` names are dropped.
