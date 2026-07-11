--!strict
--[=[
	@class ClientTransport

	Client side of the core transport.

	Listener binding (`On`/`Once`) never blocks: registration is instant and a
	background task connects the receive path once the server's remotes appear.
	Outbound `Fire` yields until discovery completes (bounded by
	`Config.DefaultTimeout`) and drops with an error log on expiry — a game
	that fires before the server created the channel gets a clear message, not
	a silent hang.
]=]

local RunService = game:GetService("RunService")

local Config = require(script.Parent.Parent.Shared.Config)
local Dispatcher = require(script.Parent.Parent.Shared.Core.Dispatcher)
local Envelope = require(script.Parent.Parent.Shared.Core.Envelope)
local RemoteRegistry = require(script.Parent.Parent.Shared.Core.RemoteRegistry)
local MiddlewareRegistry = require(script.Parent.Parent.Shared.Middleware.MiddlewareRegistry)
local SchemaRegistry = require(script.Parent.Parent.Shared.Validation.SchemaRegistry)
local Types = require(script.Parent.Parent.Shared.Types)
local Log = require(script.Parent.Parent.Shared.Utilities.Log)

local Transport = {}

local dispatcher = Dispatcher.new()
local bindStarted: { [string]: boolean } = {}

local function onIncoming(channelName: string, kind: Types.PacketKind, eventName: unknown, ...: any)
	if not Envelope.isValidEventName(eventName) then
		Log.Warn("Dropped packet from server on channel %q: invalid event name", channelName)
		return
	end

	local validators = SchemaRegistry.get(channelName, eventName :: string)
	if validators ~= nil and Config.Get().ValidationEnabled then
		local ok, reason = SchemaRegistry.check(validators, ...)
		if not ok then
			Log.Warn(
				"Rejected %q from server on channel %q: %s",
				eventName :: string,
				channelName,
				reason or "validation failed"
			)
			return
		end
	end

	if MiddlewareRegistry.hasAny(channelName) then
		local packet: Types.Packet = {
			Channel = channelName,
			Event = eventName :: string,
			Args = table.pack(...) :: any,
			ArgCount = select("#", ...),
			Player = nil,
			Kind = kind,
			Timestamp = os.clock(),
		}
		local result = MiddlewareRegistry.run(packet)
		if result == nil then
			return
		end
		dispatcher:Fire(result.Channel, result.Event, table.unpack(result.Args :: any, 1, result.ArgCount))
		return
	end

	dispatcher:Fire(channelName, eventName :: string, ...)
end

--[=[
	Starts (once) the background task that discovers a channel's remotes and
	connects the receive path. Non-yielding.
]=]
function Transport.BindChannel(channelName: string)
	if bindStarted[channelName] then
		return
	end
	bindStarted[channelName] = true

	task.spawn(function()
		local remotes = RemoteRegistry.getClient(channelName, nil)
		if remotes == nil then
			-- nil timeout waits indefinitely; only reachable if discovery
			-- failed structurally (wrong instance types).
			Log.Error("Channel %q discovery failed", channelName)
			return
		end
		remotes.Reliable.OnClientEvent:Connect(function(eventName, ...)
			onIncoming(channelName, "Event", eventName, ...)
		end)
		remotes.Unreliable.OnClientEvent:Connect(function(eventName, ...)
			onIncoming(channelName, "UnreliableEvent", eventName, ...)
		end)
	end)
end

local function resolveRemotes(channelName: string): RemoteRegistry.ChannelRemotes?
	local remotes = RemoteRegistry.getClient(channelName, Config.Get().DefaultTimeout)
	if remotes == nil then
		Log.Error(
			"Fire on channel %q dropped: remotes not found within %.1fs (has the server created this channel?)",
			channelName,
			Config.Get().DefaultTimeout
		)
	end
	return remotes
end

--[=[
	Listens for `event` from the server. Callback receives `(...args)`.
	Never yields.
]=]
function Transport.On(channelName: string, eventName: string, callback: (...any) -> ()): Dispatcher.Connection
	Envelope.assertEventName(eventName)
	Transport.BindChannel(channelName)
	return dispatcher:On(channelName, eventName, callback)
end

--[=[
	Like On, but disconnects after the first packet.
]=]
function Transport.Once(channelName: string, eventName: string, callback: (...any) -> ()): Dispatcher.Connection
	Envelope.assertEventName(eventName)
	Transport.BindChannel(channelName)
	return dispatcher:Once(channelName, eventName, callback)
end

--[=[
	Disconnects every listener of `event` on this channel.
]=]
function Transport.Off(channelName: string, eventName: string)
	dispatcher:Off(channelName, eventName)
end

--[=[
	Registers inbound middleware (server→client direction).
	`channelName = nil` → global. Returns a Connection.
]=]
function Transport.Use(channelName: string?, middleware: Types.Middleware): MiddlewareRegistry.Connection
	return MiddlewareRegistry.use(channelName, middleware)
end

--[=[
	Registers a positional argument schema for incoming `event` packets on
	this channel (server→client). Mainly a development aid on the client —
	the security-critical direction is the server's registry.
]=]
function Transport.Expect(channelName: string, eventName: string, validators: { Types.Validator })
	Envelope.assertEventName(eventName)
	SchemaRegistry.set(channelName, eventName, validators)
end

--[=[
	Fires `event` to the server (reliable). May yield briefly on the first
	call to a channel while remotes are discovered.
]=]
function Transport.Fire(channelName: string, eventName: string, ...: any)
	Envelope.assertEventName(eventName)
	local remotes = resolveRemotes(channelName)
	if remotes then
		remotes.Reliable:FireServer(eventName, ...)
	end
end

--[=[
	Fires `event` to the server (unreliable — may drop, never resent).
]=]
function Transport.FireUnreliable(channelName: string, eventName: string, ...: any)
	Envelope.assertEventName(eventName)
	local remotes = resolveRemotes(channelName)
	if remotes then
		remotes.Unreliable:FireServer(eventName, ...)
	end
end

assert(RunService:IsClient() or RunService:IsStudio(), "ClientTransport required outside the client")

return Transport
