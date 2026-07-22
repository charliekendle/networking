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
local Schema = require(script.Parent.Parent.Shared.Schema.Schema)
local DefinedRegistry = require(script.Parent.Parent.Shared.Schema.DefinedRegistry)
local Types = require(script.Parent.Parent.Shared.Types)
local Promise = require(script.Parent.Parent.Shared.Utilities.Promise)
local Stats = require(script.Parent.Parent.Shared.Debug.Stats)
local Log = require(script.Parent.Parent.Shared.Utilities.Log)

local Transport = {}

local dispatcher = Dispatcher.new()
local bindStarted: { [string]: boolean } = {}

-- RPC state -------------------------------------------------------------
type PendingInvoke = {
	resolve: (...any) -> (),
	reject: (...any) -> (),
	timeoutThread: thread,
}

local invokeHandlers: { [string]: { [string]: (...any) -> ...any } } = {}
local pendingInvokes: { [number]: PendingInvoke } = {}
local nextInvokeId = 0

local function sendReply(remotes: RemoteRegistry.ChannelRemotes, id: number, ok: boolean, ...: any)
	remotes.Reliable:FireServer("__reply", id, ok, ...)
end

-- Server -> client invoke request: (__invoke, id, requestName, ...args)
local function handleInvokeRequest(channelName: string, id: unknown, requestName: unknown, ...: any)
	if type(id) ~= "number" or not Envelope.isValidEventName(requestName) then
		Log.Warn("Malformed invoke request from server on channel %q", channelName)
		return
	end
	local eventName = requestName :: string

	local remotes = RemoteRegistry.getClient(channelName, Config.Get().DefaultTimeout)
	if remotes == nil then
		return
	end

	local channelHandlers = invokeHandlers[channelName]
	local handler = if channelHandlers then channelHandlers[eventName] else nil
	if handler == nil then
		sendReply(remotes, id :: number, false, `No invoke handler for "{eventName}"`)
		return
	end

	task.spawn(function(...)
		local results = table.pack(pcall(handler, ...))
		if results[1] then
			sendReply(remotes, id :: number, true, table.unpack(results, 2, results.n))
		else
			Log.Error("Invoke handler %q/%q errored: %s", channelName, eventName, tostring(results[2]))
			sendReply(remotes, id :: number, false, "Invoke handler error")
		end
	end, ...)
end

-- Server -> client reply to an Invoke: (__reply, id, ok, ...results)
local function handleReply(id: unknown, ok: unknown, ...: any)
	if type(id) ~= "number" then
		return
	end
	local pending = pendingInvokes[id :: number]
	if pending == nil then
		return
	end
	pendingInvokes[id :: number] = nil
	task.cancel(pending.timeoutThread)
	if ok == true then
		pending.resolve(...)
	else
		pending.reject(if select("#", ...) > 0 then (...) else "Invoke failed")
	end
end

local function onIncoming(channelName: string, kind: Types.PacketKind, eventName: unknown, ...: any)
	if eventName == "__invoke" then
		handleInvokeRequest(channelName, ...)
		return
	elseif eventName == "__reply" then
		handleReply(...)
		return
	end

	if not Envelope.isValidEventName(eventName) then
		Stats.countDrop(channelName)
		Log.Warn("Dropped packet from server on channel %q: invalid event name", channelName)
		return
	end

	local codec = DefinedRegistry.get(channelName, eventName :: string)
	if codec ~= nil then
		local blob = ...
		if select("#", ...) ~= 1 or typeof(blob) ~= "buffer" then
			Stats.countDrop(channelName)
			Log.Warn("Rejected defined event %q from server on channel %q: expected a single buffer", eventName :: string, channelName)
			return
		end
		if buffer.len(blob :: buffer) > Config.Get().MaxPacketBytes then
			Stats.countDrop(channelName)
			Log.Warn("Rejected defined event %q from server on channel %q: payload exceeds MaxPacketBytes", eventName :: string, channelName)
			return
		end
		local decoded, value = pcall(Schema.decode, codec, blob :: buffer)
		if not decoded then
			Stats.countDrop(channelName)
			Log.Warn("Rejected defined event %q from server on channel %q: %s", eventName :: string, channelName, tostring(value))
			return
		end
		if MiddlewareRegistry.hasAny(channelName) then
			local packet: Types.Packet = {
				Channel = channelName,
				Event = eventName :: string,
				Args = { value },
				ArgCount = 1,
				Player = nil,
				Kind = kind,
				Timestamp = os.clock(),
			}
			local result = MiddlewareRegistry.run(packet)
			if result == nil then
				Stats.countDrop(channelName)
				return
			end
			Stats.countReceive(result.Channel, result.Event, result.ArgCount, nil)
			dispatcher:Fire(result.Channel, result.Event, table.unpack(result.Args :: any, 1, result.ArgCount))
			return
		end
		Stats.countReceive(channelName, eventName :: string, 1, nil)
		dispatcher:Fire(channelName, eventName :: string, value)
		return
	end

	local validators = SchemaRegistry.get(channelName, eventName :: string)
	if validators ~= nil and Config.Get().ValidationEnabled then
		local ok, reason = SchemaRegistry.check(validators, ...)
		if not ok then
			Stats.countDrop(channelName)
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
			Stats.countDrop(channelName)
			return
		end
		Stats.countReceive(result.Channel, result.Event, result.ArgCount, nil)
		dispatcher:Fire(result.Channel, result.Event, table.unpack(result.Args :: any, 1, result.ArgCount))
		return
	end

	Stats.countReceive(channelName, eventName :: string, select("#", ...), nil)
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
	Registers a Schema codec for a defined event (server→client direction).
	Called by `channel:Define`.
]=]
function Transport.DefineEvent(channelName: string, eventName: string, codec: Schema.Codec<any>)
	Envelope.assertEventName(eventName)
	DefinedRegistry.set(channelName, eventName, codec)
	Transport.BindChannel(channelName)
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
		Stats.countSend(channelName, eventName, select("#", ...), nil)
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
		Stats.countSend(channelName, eventName, select("#", ...), nil)
		remotes.Unreliable:FireServer(eventName, ...)
	end
end

--[=[
	Registers the handler answering `event` invokes from the server on this
	channel. `handler(...args)` returns the reply values; it may yield. One
	handler per event.
]=]
function Transport.OnInvoke(channelName: string, eventName: string, handler: (...any) -> ...any)
	Envelope.assertEventName(eventName)
	assert(type(handler) == "function", "OnInvoke expects a function")
	Transport.BindChannel(channelName)

	local channelHandlers = invokeHandlers[channelName]
	if channelHandlers == nil then
		channelHandlers = {}
		invokeHandlers[channelName] = channelHandlers
	end
	assert(channelHandlers[eventName] == nil, `Invoke handler for "{eventName}" already registered on channel "{channelName}"`)
	channelHandlers[eventName] = handler
end

local function invokeOnce(channelName: string, eventName: string, timeout: number, values: { n: number, [number]: any }): Promise.Promise
	return Promise.new(function(resolve, reject, onCancel)
		local remotes = resolveRemotes(channelName)
		if remotes == nil then
			reject("ChannelNotFound")
			return
		end

		nextInvokeId += 1
		local id = nextInvokeId
		local startedAt = os.clock()

		pendingInvokes[id] = {
			resolve = function(...)
				Stats.recordRtt(os.clock() - startedAt)
				resolve(...)
			end,
			reject = reject,
			timeoutThread = task.delay(timeout, function()
				pendingInvokes[id] = nil
				reject("InvokeTimeout")
			end),
		}
		onCancel(function()
			local pending = pendingInvokes[id]
			if pending then
				pendingInvokes[id] = nil
				task.cancel(pending.timeoutThread)
			end
		end)
		remotes.Reliable:FireServer("__invoke", id, eventName, table.unpack(values, 1, values.n))
	end)
end

--[=[
	Invokes `event` on the server. Returns a Promise resolving with the
	server handler's reply, or rejecting with:
	- the server's error string ("Invalid arguments", "No invoke handler
	  for ...", "Invoke handler error")
	- "InvokeTimeout" after `options.Timeout` (default Config.DefaultTimeout)
	- "ChannelNotFound" if remote discovery failed

	After a timeout, the request is resent up to `options.Retries` times
	(default Config.DefaultRetries). Only timeouts retry — an error reply
	means the server already processed the request. Cancelling the promise
	abandons the request.
]=]
function Transport.Invoke(channelName: string, eventName: string, options: Types.InvokeOptions?, ...: any): Promise.Promise
	Envelope.assertEventName(eventName)
	local config = Config.Get()
	local timeout = (if options then options.Timeout else nil) or config.DefaultTimeout
	local retries = (if options then options.Retries else nil) or config.DefaultRetries
	local values = table.pack(...)

	local function attempt(remaining: number): Promise.Promise
		return invokeOnce(channelName, eventName, timeout, values):Catch(function(reason)
			if reason == "InvokeTimeout" and remaining > 0 then
				Log.Debug("Invoke %q/%q timed out; retrying (%d left)", channelName, eventName, remaining)
				return attempt(remaining - 1)
			end
			error(reason, 0)
		end)
	end

	return attempt(retries)
end

assert(RunService:IsClient() or RunService:IsStudio(), "ClientTransport required outside the client")

return Transport
