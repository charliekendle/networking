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

local IS_SERVER = RunService:IsServer()

-- Context-conditional transport (same pattern as the entry point).
local Transport: any = if IS_SERVER
	then require(script.Parent.Parent.Parent.Server.Transport)
	else require(script.Parent.Parent.Parent.Client.Transport)

export type Connection = Dispatcher.Connection

export type Channel = {
	Name: string,

	Expect: (self: Channel, eventName: string, ...Types.Validator) -> (),
	Use: (self: Channel, middleware: Types.Middleware) -> Connection,
	On: (self: Channel, eventName: string, callback: (...any) -> ()) -> Connection,
	Once: (self: Channel, eventName: string, callback: (...any) -> ()) -> Connection,
	Off: (self: Channel, eventName: string) -> (),

	-- Server: (player, eventName, ...) / Client: (eventName, ...)
	Fire: (self: Channel, ...any) -> (),
	FireUnreliable: (self: Channel, ...any) -> (),

	-- Server-only
	FireAll: (self: Channel, eventName: string, ...any) -> (),
	FireAllUnreliable: (self: Channel, eventName: string, ...any) -> (),
	FireExcept: (self: Channel, excluded: Player | { Player }, eventName: string, ...any) -> (),
	FireList: (self: Channel, list: { Player }, eventName: string, ...any) -> (),
}

local ChannelClass = {}
ChannelClass.__index = ChannelClass

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
