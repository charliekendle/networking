--!strict
--[=[
	@class Channel

	An isolated, named slice of the network. Each channel gets its own remote
	trio (see RemoteRegistry), so traffic, listeners, and — in later steps —
	middleware, validators, and rate limits are scoped per channel:

	```lua
	local Combat = Network.Channel("Combat")

	-- Server
	Combat:On("Damage", function(player, amount) end)
	Combat:Fire(player, "Knockback", direction)
	Combat:FireAll("RoundStarted", roundId)

	-- Client
	Combat:Fire("Damage", 25)
	Combat:On("Knockback", function(direction) end)
	```

	`Network.Channel(name)` is memoized — calling it twice with the same name
	from anywhere in the codebase returns the same object, so channels can be
	grabbed ad hoc without a registry module of your own.

	An event name only has meaning *within* its channel: "Ping" on Combat and
	"Ping" on Trading never touch each other.
]=]

local RunService = game:GetService("RunService")

local Envelope = require(script.Parent.Parent.Core.Envelope)
local Dispatcher = require(script.Parent.Parent.Core.Dispatcher)
local Types = require(script.Parent.Parent.Types)
local Promise = require(script.Parent.Parent.Utilities.Promise)
local Schema = require(script.Parent.Parent.Schema.Schema)

local IS_SERVER = RunService:IsServer()

-- Context-conditional transport (same pattern as the entry point).
local Transport: any = if IS_SERVER
	then require(script.Parent.Parent.Parent.Server.Transport)
	else require(script.Parent.Parent.Parent.Client.Transport)

export type Connection = Dispatcher.Connection

--[=[
	@interface EventDef
	@within Channel
	Typed handle returned by `channel:Define(event, codec)`. Fire/On carry
	the codec's phantom type, so payloads are statically checked; on the
	wire the payload is one schema-packed buffer.
]=]
export type EventDef<T> = {
	Name: string,
	Channel: string,

	-- Server callback: (player, value). Client callback: (value).
	On: ((self: EventDef<T>, callback: (player: Player, value: T) -> ()) -> Connection) & ((self: EventDef<T>, callback: (value: T) -> ()) -> Connection),
	Once: ((self: EventDef<T>, callback: (player: Player, value: T) -> ()) -> Connection) & ((self: EventDef<T>, callback: (value: T) -> ()) -> Connection),
	Off: (self: EventDef<T>) -> (),

	-- Server: Fire(player, value). Client: Fire(value).
	Fire: ((self: EventDef<T>, player: Player, value: T) -> ()) & ((self: EventDef<T>, value: T) -> ()),
	FireUnreliable: ((self: EventDef<T>, player: Player, value: T) -> ()) & ((self: EventDef<T>, value: T) -> ()),

	-- Server-only
	FireAll: (self: EventDef<T>, value: T) -> (),
	FireAllUnreliable: (self: EventDef<T>, value: T) -> (),
	FireExcept: (self: EventDef<T>, excluded: Player | { Player }, value: T) -> (),
}

export type Channel = {
	Name: string,

	Define: <T>(self: Channel, eventName: string, codec: Schema.Codec<T>) -> EventDef<T>,
	Expect: (self: Channel, eventName: string, ...Types.Validator) -> (),
	Use: (self: Channel, middleware: Types.Middleware) -> Connection,
	On: (self: Channel, eventName: string, callback: (...any) -> ()) -> Connection,
	Once: (self: Channel, eventName: string, callback: (...any) -> ()) -> Connection,
	Off: (self: Channel, eventName: string) -> (),

	-- Server: (player, eventName, ...) / Client: (eventName, ...)
	Fire: (self: Channel, ...any) -> (),
	FireUnreliable: (self: Channel, ...any) -> (),

	-- Request/response. Client: Invoke(event, ...). Server: InvokeClient(player, event, ...).
	OnInvoke: (self: Channel, eventName: string, handler: (...any) -> ...any) -> (),
	Invoke: (self: Channel, eventName: string, ...any) -> Promise.Promise,
	InvokeWithOptions: (self: Channel, options: Types.InvokeOptions, eventName: string, ...any) -> Promise.Promise,
	InvokeClient: (self: Channel, player: Player, eventName: string, ...any) -> Promise.Promise,

	-- Server-only
	FireAll: (self: Channel, eventName: string, ...any) -> (),
	FireAllUnreliable: (self: Channel, eventName: string, ...any) -> (),
	FireExcept: (self: Channel, excluded: Player | { Player }, eventName: string, ...any) -> (),
	FireList: (self: Channel, list: { Player }, eventName: string, ...any) -> (),
	FireNearby: (self: Channel, position: Vector3, radius: number, eventName: string, ...any) -> (),
	FireWithinRadius: (self: Channel, origin: Player, radius: number, eventName: string, ...any) -> (),
}

local EventDefClass = {}
EventDefClass.__index = EventDefClass

local function encodePayload(self: any, value: any): buffer
	return Schema.encode(self._codec, value)
end

function EventDefClass.On(self: any, callback: (...any) -> ()): Connection
	return Transport.On(self.Channel, self.Name, callback)
end

function EventDefClass.Once(self: any, callback: (...any) -> ()): Connection
	return Transport.Once(self.Channel, self.Name, callback)
end

function EventDefClass.Off(self: any)
	Transport.Off(self.Channel, self.Name)
end

function EventDefClass.Fire(self: any, ...: any)
	if IS_SERVER then
		local player, value = ...
		Transport.Fire(self.Channel, player, self.Name, encodePayload(self, value))
	else
		local value = ...
		Transport.Fire(self.Channel, self.Name, encodePayload(self, value))
	end
end

function EventDefClass.FireUnreliable(self: any, ...: any)
	if IS_SERVER then
		local player, value = ...
		Transport.FireUnreliable(self.Channel, player, self.Name, encodePayload(self, value))
	else
		local value = ...
		Transport.FireUnreliable(self.Channel, self.Name, encodePayload(self, value))
	end
end

function EventDefClass.FireAll(self: any, value: any)
	assert(IS_SERVER, "EventDef:FireAll is server-only")
	Transport.FireAll(self.Channel, self.Name, encodePayload(self, value))
end

function EventDefClass.FireAllUnreliable(self: any, value: any)
	assert(IS_SERVER, "EventDef:FireAllUnreliable is server-only")
	Transport.FireAllUnreliable(self.Channel, self.Name, encodePayload(self, value))
end

function EventDefClass.FireExcept(self: any, excluded: Player | { Player }, value: any)
	assert(IS_SERVER, "EventDef:FireExcept is server-only")
	Transport.FireExcept(self.Channel, excluded, self.Name, encodePayload(self, value))
end

local ChannelClass = {}
ChannelClass.__index = ChannelClass

--[=[
	Defines a typed event: the Schema codec becomes the wire format, the
	static type, and the validation in one. Returns an `EventDef<T>` whose
	Fire/On are fully typed. Define in a **shared module** required by both
	server and client so both sides register the codec:

	```lua
	local S = Network.Schema
	local Attack = Combat:Define("Attack", S.struct({
		Direction = S.vec3,
		Power = S.int(0, 100),
	}))

	Attack:On(function(player, value) end) -- value typed, bounds guaranteed
	Attack:Fire({ Direction = dir, Power = 55 }) -- client, typed, 1 packed buffer
	```

	Incoming payloads that don't decode cleanly (wrong size, out-of-range,
	non-finite, extra bytes) are dropped and striked; defined events skip
	the runtime validator pass entirely because decode enforces the schema
	by construction.
]=]
function ChannelClass.Define<T>(self: any, eventName: string, codec: Schema.Codec<T>): EventDef<T>
	Envelope.assertEventName(eventName)
	Transport.DefineEvent(self.Name, eventName, codec)
	local def = setmetatable({
		Name = eventName,
		Channel = self.Name,
		_codec = codec,
	}, EventDefClass)
	return (def :: any) :: EventDef<T>
end

--[=[
	Registers a positional argument schema for incoming `event` packets on
	this channel. Packets failing it are dropped and logged before handlers
	run. Register on the **server** for security; client registration is a
	development aid.

	```lua
	Combat:Expect("Damage", V.numberRange(0, 100))
	Shop:Expect("Purchase", V.string, V.optional(V.integer))
	```
]=]
function ChannelClass.Expect(self: any, eventName: string, ...: Types.Validator)
	Transport.Expect(self.Name, eventName, { ... })
end

--[=[
	Registers inbound middleware scoped to this channel. Runs after the
	global chain, after rate limiting and validation, before dispatch.
	Return "Drop" to reject a packet, or "Continue" (optionally with a
	replacement packet) to pass it on. Errors drop the packet (fail closed).

	```lua
	Combat:Use(function(packet)
		if packet.Player and not canFight(packet.Player) then
			return "Drop"
		end
		return "Continue"
	end)
	```
]=]
function ChannelClass.Use(self: any, middleware: Types.Middleware): Connection
	return Transport.Use(self.Name, middleware)
end

--[=[
	Listens for `event` on this channel.
	Server callback: `(player, ...args)`. Client callback: `(...args)`.
	Never yields.
]=]
function ChannelClass.On(self: any, eventName: string, callback: (...any) -> ()): Connection
	return Transport.On(self.Name, eventName, callback)
end

--[=[
	Like On, but disconnects after the first packet.
]=]
function ChannelClass.Once(self: any, eventName: string, callback: (...any) -> ()): Connection
	return Transport.Once(self.Name, eventName, callback)
end

--[=[
	Disconnects every listener of `event` on this channel.
]=]
function ChannelClass.Off(self: any, eventName: string)
	Transport.Off(self.Name, eventName)
end

--[=[
	Reliable fire on this channel.
	Server: `channel:Fire(player, eventName, ...)`.
	Client: `channel:Fire(eventName, ...)` (first use may yield briefly
	during remote discovery).
]=]
function ChannelClass.Fire(self: any, ...: any)
	Transport.Fire(self.Name, ...)
end

--[=[
	Unreliable fire on this channel (may drop, never resent). Same
	signatures as Fire.
]=]
function ChannelClass.FireUnreliable(self: any, ...: any)
	Transport.FireUnreliable(self.Name, ...)
end

--[=[
	Registers the handler answering `event` invokes on this channel.
	Server handler: `(player, ...args) -> ...reply`. Client handler:
	`(...args) -> ...reply`. May yield. One handler per event.
]=]
function ChannelClass.OnInvoke(self: any, eventName: string, handler: (...any) -> ...any)
	Transport.OnInvoke(self.Name, eventName, handler)
end

--[=[
	@client
	Invokes `event` on the server; returns a Promise. Uses config default
	timeout/retries — see InvokeWithOptions to override.

	```lua
	Shop:Invoke("GetCatalog", "Weapons"):AndThen(function(items) end)
	```
]=]
function ChannelClass.Invoke(self: any, eventName: string, ...: any): Promise.Promise
	assert(not IS_SERVER, "Channel:Invoke is client-only; use InvokeClient on the server")
	return Transport.Invoke(self.Name, eventName, nil, ...)
end

--[=[
	@client
	As Invoke, with explicit `{ Timeout: number?, Retries: number? }`.
]=]
function ChannelClass.InvokeWithOptions(self: any, options: Types.InvokeOptions, eventName: string, ...: any): Promise.Promise
	assert(not IS_SERVER, "Channel:InvokeWithOptions is client-only")
	return Transport.Invoke(self.Name, eventName, options, ...)
end

--[=[
	@server
	Invokes `event` on one client; returns a Promise. Always bounded by a
	timeout (default Config.DefaultTimeout) — a client that never answers
	cannot hang server logic. No retries in this direction.
]=]
function ChannelClass.InvokeClient(self: any, player: Player, eventName: string, ...: any): Promise.Promise
	assert(IS_SERVER, "Channel:InvokeClient is server-only")
	return Transport.InvokeClient(self.Name, player, eventName, nil, ...)
end

--[=[
	@server
	Reliable fire to every connected player.
]=]
function ChannelClass.FireAll(self: any, eventName: string, ...: any)
	assert(IS_SERVER, "Channel:FireAll is server-only")
	Transport.FireAll(self.Name, eventName, ...)
end

--[=[
	@server
	Unreliable fire to every connected player.
]=]
function ChannelClass.FireAllUnreliable(self: any, eventName: string, ...: any)
	assert(IS_SERVER, "Channel:FireAllUnreliable is server-only")
	Transport.FireAllUnreliable(self.Name, eventName, ...)
end

--[=[
	@server
	Reliable fire to every player except `excluded` (Player or {Player}).
]=]
function ChannelClass.FireExcept(self: any, excluded: Player | { Player }, eventName: string, ...: any)
	assert(IS_SERVER, "Channel:FireExcept is server-only")
	Transport.FireExcept(self.Name, excluded, eventName, ...)
end

--[=[
	@server
	Reliable fire to every player in `list`.
]=]
function ChannelClass.FireList(self: any, list: { Player }, eventName: string, ...: any)
	assert(IS_SERVER, "Channel:FireList is server-only")
	Transport.FireList(self.Name, list, eventName, ...)
end

--[=[
	@server
	Reliable fire to every player whose character is within `radius` studs
	of `position`.
]=]
function ChannelClass.FireNearby(self: any, position: Vector3, radius: number, eventName: string, ...: any)
	assert(IS_SERVER, "Channel:FireNearby is server-only")
	Transport.FireNearby(self.Name, position, radius, eventName, ...)
end

--[=[
	@server
	Reliable fire to every player within `radius` studs of `origin`'s
	character (origin included).
]=]
function ChannelClass.FireWithinRadius(self: any, origin: Player, radius: number, eventName: string, ...: any)
	assert(IS_SERVER, "Channel:FireWithinRadius is server-only")
	Transport.FireWithinRadius(self.Name, origin, radius, eventName, ...)
end

local Channel = {}

local channels: { [string]: Channel } = {}

--[=[
	Returns the channel with this name, creating it on first access.
	Memoized: same name always returns the same object.

	Server: creates the channel's remotes immediately, so clients can
	discover them without racing. Client: discovery is deferred until the
	first listener/fire.
]=]
function Channel.get(name: string): Channel
	Envelope.assertChannelName(name)

	local existing = channels[name]
	if existing then
		return existing
	end

	local self = setmetatable({ Name = name }, ChannelClass)
	local channel = (self :: any) :: Channel
	channels[name] = channel

	if IS_SERVER then
		-- Eager creation: a channel referenced anywhere server-side exists
		-- for clients before they can possibly fire at it.
		Transport.BindChannel(name)
	end

	return channel
end

--[=[
	True if the value is a Channel created by this module.
]=]
function Channel.is(value: unknown): boolean
	return type(value) == "table" and getmetatable(value :: any) == ChannelClass
end

return Channel
