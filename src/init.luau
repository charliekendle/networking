--!strict
--[=[
	@class Network

	Package entry point. Context-aware: the same require works on server and
	client, with signatures differing where the contexts genuinely differ:

	```lua
	-- Server
	Network.On("Damage", function(player, amount) end)
	Network.Fire(player, "Knockback", direction)
	Network.FireAll("RoundStarted", roundId)

	-- Client
	Network.On("Knockback", function(direction) end)
	Network.Fire("Damage", 25)
	```

	Top-level Fire/On operate on the built-in "Global" channel. Isolated
	channels with the same surface: `Network.Channel("Combat")`.
]=]

local RunService = game:GetService("RunService")

local Config = require(script.Shared.Config)
local Signal = require(script.Shared.Signals.Signal)
local Log = require(script.Shared.Utilities.Log)

-- Re-exported types. Consumers: `local Networking = require(...)` then
-- `type Packet = Networking.Packet` etc.
local Types = require(script.Shared.Types)
export type NetworkConfig = Types.NetworkConfig
export type PartialNetworkConfig = Types.PartialNetworkConfig
export type Packet = Types.Packet
export type Middleware = Types.Middleware
export type MiddlewareResult = Types.MiddlewareResult
export type Validator = Types.Validator
export type Connection = Types.Connection
export type LogLevel = Types.LogLevel
export type SecurityReport = Types.SecurityReport
export type AuditEntry = Types.AuditEntry
export type ViolationKind = Types.ViolationKind
export type Signal<T...> = Signal.Signal<T...>

local IS_SERVER = RunService:IsServer()
local GLOBAL_CHANNEL = "Global"

-- Context-conditional require: only the transport for the running context is
-- loaded. Typed loosely here; the public wrappers below carry the real types.
local ServerTransport = if IS_SERVER then require(script.Server.Transport) :: any else nil
local ClientTransport = if not IS_SERVER then require(script.Client.Transport) :: any else nil

local ChannelModule = require(script.Shared.Channels.Channel)
export type Channel = ChannelModule.Channel

local Validators = require(script.Shared.Validation.Validators)
local Promise = require(script.Shared.Utilities.Promise)
local Serializer = require(script.Shared.Serialization.Serializer)
local Compression = require(script.Shared.Compression.Compression)
local Stats = require(script.Shared.Debug.Stats)
export type StatsSnapshot = Stats.StatsSnapshot
export type PacketLogEntry = Stats.PacketLogEntry
export type Promise = Promise.Promise
export type InvokeOptions = Types.InvokeOptions

local Network = {}

--[=[
	@prop Version string
	@within Network
]=]
Network.Version = "1.0.0"

--[=[
	@prop Signal SignalConstructor
	@within Network
	Exposed so games can reuse the package's signal implementation.
]=]
Network.Signal = Signal

--[=[
	@prop Promise PromiseConstructor
	@within Network
	The package's promise implementation (`Promise.new/resolve/reject/is`),
	exposed for reuse.
]=]
Network.Promise = Promise

--[=[
	@prop Validators Validators
	@within Network
	Composable runtime validators for use with Expect. See Validators.
]=]
Network.Validators = Validators

--[=[
	@prop ConfigChanged Signal<NetworkConfig>
	@within Network
]=]
Network.ConfigChanged = Config.Changed

--[=[
	Applies a partial configuration. See Config for keys and defaults.
]=]
function Network.Configure(patch: PartialNetworkConfig)
	Config.Set(patch)
end

--[=[
	Returns a read-only snapshot of the active configuration.
]=]
function Network.GetConfig(): NetworkConfig
	return Config.Get()
end

--[=[
	Returns the isolated channel with this name, creating it on first access.
	Memoized — the same name always returns the same object:

	```lua
	local Combat = Network.Channel("Combat")
	Combat:On("Damage", function(player, amount) end)
	Combat:Fire(player, "Knockback", direction)
	```

	Events are scoped to their channel: "Ping" on Combat and "Ping" on
	Trading never interact. On the server, referencing a channel creates its
	remotes immediately; on the client, discovery defers to first use.
]=]
function Network.Channel(name: string): Channel
	return ChannelModule.get(name)
end

--[=[
	@prop OnSuspiciousActivity Signal<SecurityReport>
	@within Network
	@server
	Fires when a player's consecutive dropped packets (rate limit,
	validation failure, malformed envelope) reach
	`Config.RateLimit.PunishThreshold`. The package never kicks or bans on
	its own — that decision is the game's, taken here:

	```lua
	Network.OnSuspiciousActivity:Connect(function(report)
		warn(`{report.Player.Name}: {report.Kind} x{report.Strikes} on {report.Channel} — {report.Reason}`)
		-- report.Player:Kick("Network abuse detected")
	end)
	```
]=]
Network.OnSuspiciousActivity = (
	if IS_SERVER then ServerTransport.OnSuspiciousActivity else Signal.new()
) :: Signal.Signal<SecurityReport>

--[=[
	@server
	Returns the bounded security audit log (most recent 256 dropped-packet
	entries, oldest first). Each entry: Time, UserId, PlayerName, Channel,
	Event?, Kind, Reason.
]=]
function Network.GetAuditLog(): { AuditEntry }
	assert(IS_SERVER, "GetAuditLog is server-only")
	return ServerTransport.GetAuditLog()
end

--[=[
	Registers the handler answering `event` invokes on the Global channel.
	Server handler: `(player, ...args) -> ...reply`. Client handler:
	`(...args) -> ...reply`.
]=]
function Network.OnInvoke(eventName: string, handler: (...any) -> ...any)
	if IS_SERVER then
		ServerTransport.OnInvoke(GLOBAL_CHANNEL, eventName, handler)
	else
		ClientTransport.OnInvoke(GLOBAL_CHANNEL, eventName, handler)
	end
end

--[=[
	@client
	Invokes `event` on the server (Global channel); returns a Promise.

	```lua
	Network.Invoke("GetServerTime"):AndThen(function(now) end)
	local ok, now = Network.Invoke("GetServerTime"):Await()
	```
]=]
function Network.Invoke(eventName: string, ...: any): Promise
	assert(not IS_SERVER, "Network.Invoke is client-only; use InvokeClient on the server")
	return ClientTransport.Invoke(GLOBAL_CHANNEL, eventName, nil, ...)
end

--[=[
	@client
	As Invoke, with explicit `{ Timeout: number?, Retries: number? }`.
]=]
function Network.InvokeWithOptions(options: InvokeOptions, eventName: string, ...: any): Promise
	assert(not IS_SERVER, "Network.InvokeWithOptions is client-only")
	return ClientTransport.Invoke(GLOBAL_CHANNEL, eventName, options, ...)
end

--[=[
	@server
	Invokes `event` on one client (Global channel); returns a Promise
	bounded by the default timeout.
]=]
function Network.InvokeClient(player: Player, eventName: string, ...: any): Promise
	assert(IS_SERVER, "Network.InvokeClient is server-only")
	return ServerTransport.InvokeClient(GLOBAL_CHANNEL, player, eventName, nil, ...)
end

--[=[
	Registers **global** inbound middleware — runs for every channel, before
	any per-channel chain. Runs after rate limiting and schema validation,
	immediately before dispatch. Return "Drop" to reject, "Continue" to pass
	(optionally with a replacement packet). Errors drop the packet (fail
	closed). Returns a Connection.

	```lua
	Network.Use(function(packet)
		print(`{packet.Kind} {packet.Channel}/{packet.Event} ({packet.ArgCount} args)`)
		return "Continue"
	end)
	```
]=]
function Network.Use(middleware: Middleware): Connection
	if IS_SERVER then
		return ServerTransport.Use(nil, middleware)
	end
	return ClientTransport.Use(nil, middleware)
end

--[=[
	Registers a positional argument schema for incoming `event` packets on
	the Global channel. Packets failing it are dropped and logged before
	your handler runs.

	```lua
	local V = Network.Validators
	Network.Expect("Damage", V.numberRange(0, 100))
	Network.Expect("Purchase", V.string, V.optional(V.integer))
	```
]=]
function Network.Expect(eventName: string, ...: Validator)
	if IS_SERVER then
		ServerTransport.Expect(GLOBAL_CHANNEL, eventName, { ... })
	else
		ClientTransport.Expect(GLOBAL_CHANNEL, eventName, { ... })
	end
end

--[=[
	Listens for `event` on the Global channel.
	Server callback: `(player: Player, ...args)`. Client callback: `(...args)`.
	Never yields.
]=]
function Network.On(eventName: string, callback: (...any) -> ()): Connection
	if IS_SERVER then
		return ServerTransport.On(GLOBAL_CHANNEL, eventName, callback)
	end
	return ClientTransport.On(GLOBAL_CHANNEL, eventName, callback)
end

--[=[
	Like On, but disconnects after the first packet.
]=]
function Network.Once(eventName: string, callback: (...any) -> ()): Connection
	if IS_SERVER then
		return ServerTransport.Once(GLOBAL_CHANNEL, eventName, callback)
	end
	return ClientTransport.Once(GLOBAL_CHANNEL, eventName, callback)
end

--[=[
	Disconnects every listener of `event` on the Global channel.
]=]
function Network.Off(eventName: string)
	if IS_SERVER then
		ServerTransport.Off(GLOBAL_CHANNEL, eventName)
	else
		ClientTransport.Off(GLOBAL_CHANNEL, eventName)
	end
end

--[=[
	Reliable fire on the Global channel.
	Server: `Network.Fire(player, eventName, ...)`.
	Client: `Network.Fire(eventName, ...)` (may yield briefly on first use
	of a channel while remotes are discovered).
]=]
function Network.Fire(...: any)
	if IS_SERVER then
		ServerTransport.Fire(GLOBAL_CHANNEL, ...)
	else
		ClientTransport.Fire(GLOBAL_CHANNEL, ...)
	end
end

--[=[
	Unreliable fire on the Global channel (may drop, never resent — use for
	high-frequency cosmetic state). Same signatures as Fire.
]=]
function Network.FireUnreliable(...: any)
	if IS_SERVER then
		ServerTransport.FireUnreliable(GLOBAL_CHANNEL, ...)
	else
		ClientTransport.FireUnreliable(GLOBAL_CHANNEL, ...)
	end
end

--[=[
	@server
	Reliable fire to every connected player.
]=]
function Network.FireAll(eventName: string, ...: any)
	assert(IS_SERVER, "FireAll is server-only")
	ServerTransport.FireAll(GLOBAL_CHANNEL, eventName, ...)
end

--[=[
	@server
	Unreliable fire to every connected player.
]=]
function Network.FireAllUnreliable(eventName: string, ...: any)
	assert(IS_SERVER, "FireAllUnreliable is server-only")
	ServerTransport.FireAllUnreliable(GLOBAL_CHANNEL, eventName, ...)
end

--[=[
	@server
	Reliable fire to every player except `excluded` (Player or {Player}).
]=]
function Network.FireExcept(excluded: Player | { Player }, eventName: string, ...: any)
	assert(IS_SERVER, "FireExcept is server-only")
	ServerTransport.FireExcept(GLOBAL_CHANNEL, excluded, eventName, ...)
end

--[=[
	@server
	Reliable fire to every player in `list`.
]=]
function Network.FireList(list: { Player }, eventName: string, ...: any)
	assert(IS_SERVER, "FireList is server-only")
	ServerTransport.FireList(GLOBAL_CHANNEL, list, eventName, ...)
end

--[=[
	@server
	Reliable fire to every player whose character is within `radius` studs
	of `position`.
]=]
function Network.FireNearby(position: Vector3, radius: number, eventName: string, ...: any)
	assert(IS_SERVER, "FireNearby is server-only")
	ServerTransport.FireNearby(GLOBAL_CHANNEL, position, radius, eventName, ...)
end

--[=[
	@server
	Reliable fire to every player within `radius` studs of `origin`'s
	character (origin included).
]=]
function Network.FireWithinRadius(origin: Player, radius: number, eventName: string, ...: any)
	assert(IS_SERVER, "FireWithinRadius is server-only")
	ServerTransport.FireWithinRadius(GLOBAL_CHANNEL, origin, radius, eventName, ...)
end

--[=[
	Packs a value tree (tables, numbers, strings, Vector3/CFrame/Color3/
	UDim2/EnumItems, buffers...) into one compact buffer — dramatically
	smaller on the wire than Roblox's generic argument serialization for
	large payloads. Errors on Instances, functions, and cyclic tables.

	```lua
	Shop:Fire(player, "Snapshot", Network.Serialize(bigTable))
	```
]=]
function Network.Serialize(value: unknown): buffer
	return Serializer.serialize(value)
end

--[=[
	Reverses Serialize. Errors on corrupt/truncated buffers — wrap in pcall
	when the buffer came from a remote peer.
]=]
function Network.Deserialize(blob: buffer): unknown
	return Serializer.deserialize(blob)
end

--[=[
	LZW-compresses a buffer (or string). 1-byte header; automatically stores
	raw when compression wouldn't shrink the input, so output is never more
	than input + 1 byte. Worth it for repetitive payloads ~1 KB and up —
	typically layered over Serialize:

	```lua
	Shop:Fire(player, "Snapshot", Network.Compress(Network.Serialize(bigTable)))
	```
]=]
function Network.Compress(input: buffer | string): buffer
	return Compression.compress(input)
end

--[=[
	Reverses Compress. Errors on corrupt input — pcall it for
	remote-supplied buffers.
]=]
function Network.Decompress(input: buffer): buffer
	return Compression.decompress(input)
end

--[=[
	Returns a statistics snapshot for this context: total/per-channel
	Sent/Received/Dropped counters and the rolling average invoke RTT.
]=]
function Network.GetStats(): StatsSnapshot
	return Stats.getSnapshot()
end

--[=[
	Returns the recent packet log (up to 128 entries, oldest first).
	Only populated while `DebugMode` is on.
]=]
function Network.GetPacketLog(): { PacketLogEntry }
	return Stats.getPacketLog()
end

Log.Debug("Networking v%s loaded", Network.Version)

return Network
