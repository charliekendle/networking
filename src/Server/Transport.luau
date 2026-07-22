--!strict
--[=[
	@class ServerTransport

	Server side of the core transport. Binds a channel's remotes on first use,
	sanity-checks every incoming packet before dispatch, and exposes the
	outbound Fire family.

	Incoming packets with a non-string / reserved / oversized event name are
	dropped and logged — they cannot reach user code. Full schema validation
	and rate limiting layer on top of this in later steps.
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Parent.Shared.Config)
local Dispatcher = require(script.Parent.Parent.Shared.Core.Dispatcher)
local Envelope = require(script.Parent.Parent.Shared.Core.Envelope)
local RemoteRegistry = require(script.Parent.Parent.Shared.Core.RemoteRegistry)
local SchemaRegistry = require(script.Parent.Parent.Shared.Validation.SchemaRegistry)
local Schema = require(script.Parent.Parent.Shared.Schema.Schema)
local DefinedRegistry = require(script.Parent.Parent.Shared.Schema.DefinedRegistry)
local MiddlewareRegistry = require(script.Parent.Parent.Shared.Middleware.MiddlewareRegistry)
local RateLimiter = require(script.Parent.Parent.Shared.Security.RateLimiter)
local SecurityMonitor = require(script.Parent.Parent.Shared.Security.SecurityMonitor)
local Promise = require(script.Parent.Parent.Shared.Utilities.Promise)
local Stats = require(script.Parent.Parent.Shared.Debug.Stats)
local Types = require(script.Parent.Parent.Shared.Types)
local Log = require(script.Parent.Parent.Shared.Utilities.Log)

local Transport = {}

local dispatcher = Dispatcher.new()
local boundChannels: { [string]: boolean } = {}

-- RPC state -------------------------------------------------------------
type PendingInvoke = {
	player: Player,
	resolve: (...any) -> (),
	reject: (...any) -> (),
	timeoutThread: thread,
}

local invokeHandlers: { [string]: { [string]: (player: Player, ...any) -> ...any } } = {}
local pendingInvokes: { [number]: PendingInvoke } = {}
local nextInvokeId = 0

local function isPlayer(value: unknown): boolean
	return typeof(value) == "Instance" and (value :: Instance):IsA("Player")
end

local function sendReply(channelName: string, player: Player, id: number, ok: boolean, ...: any)
	RemoteRegistry.getServer(channelName).Reliable:FireClient(player, "__reply", id, ok, ...)
end

-- Client -> server invoke request: (__invoke, id, requestName, ...args)
local function handleInvokeRequest(channelName: string, player: Player, id: unknown, requestName: unknown, ...: any)
	if type(id) ~= "number" or not Envelope.isValidEventName(requestName) then
		if Config.Get().SecurityEnabled then
			SecurityMonitor.reportViolation(player, channelName, nil, "Protocol", "malformed invoke request")
		end
		return
	end
	local eventName = requestName :: string

	-- Schemas registered via Expect apply to invoke arguments too.
	local validators = SchemaRegistry.get(channelName, eventName)
	if validators ~= nil and Config.Get().ValidationEnabled then
		local ok, reason = SchemaRegistry.check(validators, ...)
		if not ok then
			if Config.Get().SecurityEnabled then
				SecurityMonitor.reportViolation(player, channelName, eventName, "Validation", reason or "invalid invoke arguments")
			end
			sendReply(channelName, player, id :: number, false, "Invalid arguments")
			return
		end
	end

	local channelHandlers = invokeHandlers[channelName]
	local handler = if channelHandlers then channelHandlers[eventName] else nil
	if handler == nil then
		sendReply(channelName, player, id :: number, false, `No invoke handler for "{eventName}"`)
		return
	end

	if Config.Get().SecurityEnabled then
		SecurityMonitor.reportSuccess(player)
	end

	-- Handlers may yield; never block the receive path.
	task.spawn(function(...)
		local results = table.pack(pcall(handler, player, ...))
		if results[1] then
			sendReply(channelName, player, id :: number, true, table.unpack(results, 2, results.n))
		else
			Log.Error("Invoke handler %q/%q errored: %s", channelName, eventName, tostring(results[2]))
			-- Sanitized: internal error details never leak to the client.
			sendReply(channelName, player, id :: number, false, "Invoke handler error")
		end
	end, ...)
end

-- Client -> server reply to an InvokeClient: (__reply, id, ok, ...results)
local function handleReply(channelName: string, player: Player, id: unknown, ok: unknown, ...: any)
	if type(id) ~= "number" then
		if Config.Get().SecurityEnabled then
			SecurityMonitor.reportViolation(player, channelName, nil, "Protocol", "malformed invoke reply")
		end
		return
	end

	local pending = pendingInvokes[id :: number]
	if pending == nil then
		-- Late reply after timeout/cancel — normal, ignore quietly.
		Log.Debug("Ignoring reply for unknown invoke id %d from %s", id :: number, player.Name)
		return
	end
	if pending.player ~= player then
		-- Someone answering an invoke addressed to another player.
		if Config.Get().SecurityEnabled then
			SecurityMonitor.reportViolation(player, channelName, nil, "Protocol", "invoke reply for another player")
		end
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

local function onIncoming(channelName: string, kind: Types.PacketKind, player: Player, eventName: unknown, ...: any)
	local config = Config.Get()
	local securityOn = config.SecurityEnabled

	-- 1. Rate limit — cheapest check first, runs before any parsing.
	if securityOn and config.RateLimit.Enabled then
		if not RateLimiter.check(player, channelName) then
			Stats.countDrop(channelName)
			SecurityMonitor.reportViolation(player, channelName, nil, "RateLimit", "packet rate exceeded")
			return
		end
	end

	-- 2. Protocol traffic (reserved names) — intercepted before the
	-- envelope check, which rejects "__" names from user space.
	if eventName == "__invoke" then
		handleInvokeRequest(channelName, player, ...)
		return
	elseif eventName == "__reply" then
		handleReply(channelName, player, ...)
		return
	end

	-- 3. Envelope — event name must be a sane string.
	if not Envelope.isValidEventName(eventName) then
		Stats.countDrop(channelName)
		if securityOn then
			SecurityMonitor.reportViolation(player, channelName, nil, "Envelope", "invalid event name")
		else
			Log.Warn("Dropped packet from %s on channel %q: invalid event name", player.Name, channelName)
		end
		return
	end

	-- 4a. Defined events: the payload must be exactly one buffer that
	-- decodes cleanly under the registered codec. Decode IS the validation —
	-- bounds, finiteness, and shape are enforced by construction, so the
	-- runtime validator pass below is skipped entirely.
	local codec = DefinedRegistry.get(channelName, eventName :: string)
	if codec ~= nil then
		local blob = ...
		if select("#", ...) ~= 1 or typeof(blob) ~= "buffer" then
			Stats.countDrop(channelName)
			if securityOn then
				SecurityMonitor.reportViolation(
					player,
					channelName,
					eventName :: string,
					"Validation",
					"defined event expects a single buffer"
				)
			end
			return
		end
		if buffer.len(blob :: buffer) > config.MaxPacketBytes then
			Stats.countDrop(channelName)
			if securityOn then
				SecurityMonitor.reportViolation(
					player,
					channelName,
					eventName :: string,
					"Validation",
					`payload exceeds MaxPacketBytes ({buffer.len(blob :: buffer)} > {config.MaxPacketBytes})`
				)
			end
			return
		end
		local decoded, value = pcall(Schema.decode, codec, blob :: buffer)
		if not decoded then
			Stats.countDrop(channelName)
			if securityOn then
				SecurityMonitor.reportViolation(
					player,
					channelName,
					eventName :: string,
					"Validation",
					tostring(value)
				)
			end
			return
		end
		if securityOn then
			SecurityMonitor.reportSuccess(player)
		end
		if MiddlewareRegistry.hasAny(channelName) then
			local packet: Types.Packet = {
				Channel = channelName,
				Event = eventName :: string,
				Args = { value },
				ArgCount = 1,
				Player = player,
				Kind = kind,
				Timestamp = os.clock(),
			}
			local result = MiddlewareRegistry.run(packet)
			if result == nil then
				Stats.countDrop(channelName)
				return
			end
			Stats.countReceive(result.Channel, result.Event, result.ArgCount, player.Name)
			dispatcher:Fire(result.Channel, result.Event, player, table.unpack(result.Args :: any, 1, result.ArgCount))
			return
		end
		Stats.countReceive(channelName, eventName :: string, 1, player.Name)
		dispatcher:Fire(channelName, eventName :: string, player, value)
		return
	end

	-- 4b. Schema validation (loose events).
	local validators = SchemaRegistry.get(channelName, eventName :: string)
	if validators ~= nil and config.ValidationEnabled then
		local ok, reason = SchemaRegistry.check(validators, ...)
		if not ok then
			Stats.countDrop(channelName)
			if securityOn then
				SecurityMonitor.reportViolation(
					player,
					channelName,
					eventName :: string,
					"Validation",
					reason or "validation failed"
				)
			else
				Log.Warn(
					"Rejected %q from %s on channel %q: %s",
					eventName :: string,
					player.Name,
					channelName,
					reason or "validation failed"
				)
			end
			return
		end
	end

	if securityOn then
		SecurityMonitor.reportSuccess(player)
	end

	-- 5. Middleware (global then channel chain). Packet allocation only
	-- happens when at least one middleware is registered.
	if MiddlewareRegistry.hasAny(channelName) then
		local packet: Types.Packet = {
			Channel = channelName,
			Event = eventName :: string,
			Args = table.pack(...) :: any,
			ArgCount = select("#", ...),
			Player = player,
			Kind = kind,
			Timestamp = os.clock(),
		}
		local result = MiddlewareRegistry.run(packet)
		if result == nil then
			Stats.countDrop(channelName)
			return
		end
		Stats.countReceive(result.Channel, result.Event, result.ArgCount, player.Name)
		dispatcher:Fire(result.Channel, result.Event, player, table.unpack(result.Args :: any, 1, result.ArgCount))
		return
	end

	Stats.countReceive(channelName, eventName :: string, select("#", ...), player.Name)
	dispatcher:Fire(channelName, eventName :: string, player, ...)
end

--[=[
	Ensures a channel's remotes exist and its receive path is connected.
	Idempotent; called implicitly by every public function.
]=]
function Transport.BindChannel(channelName: string): RemoteRegistry.ChannelRemotes
	local remotes = RemoteRegistry.getServer(channelName)
	if not boundChannels[channelName] then
		boundChannels[channelName] = true
		remotes.Reliable.OnServerEvent:Connect(function(player, eventName, ...)
			onIncoming(channelName, "Event", player, eventName, ...)
		end)
		remotes.Unreliable.OnServerEvent:Connect(function(player, eventName, ...)
			onIncoming(channelName, "UnreliableEvent", player, eventName, ...)
		end)
	end
	return remotes
end

--[=[
	Listens for `event` from clients. Callback receives `(player, ...args)`.
]=]
function Transport.On(channelName: string, eventName: string, callback: (Player, ...any) -> ()): Dispatcher.Connection
	Envelope.assertEventName(eventName)
	Transport.BindChannel(channelName)
	return dispatcher:On(channelName, eventName, callback :: (...any) -> ())
end

--[=[
	Like On, but disconnects after the first packet.
]=]
function Transport.Once(channelName: string, eventName: string, callback: (Player, ...any) -> ()): Dispatcher.Connection
	Envelope.assertEventName(eventName)
	Transport.BindChannel(channelName)
	return dispatcher:Once(channelName, eventName, callback :: (...any) -> ())
end

--[=[
	Disconnects every listener of `event` on this channel.
]=]
function Transport.Off(channelName: string, eventName: string)
	dispatcher:Off(channelName, eventName)
end

--[=[
	@prop OnSuspiciousActivity Signal<SecurityReport>
	@within ServerTransport
	Re-exported SecurityMonitor hook. Fires when a player's consecutive
	violations reach `Config.RateLimit.PunishThreshold`.
]=]
Transport.OnSuspiciousActivity = SecurityMonitor.OnSuspiciousActivity

--[=[
	@prop OnViolation Signal<SecurityReport>
	@within ServerTransport
	Fires on every dropped packet (no thresholding). See SecurityMonitor.
]=]
Transport.OnViolation = SecurityMonitor.OnViolation

--[=[
	Per-channel rate-limit override. Partial keys fall back to the global
	config; nil clears. See RateLimiter.
]=]
function Transport.SetRateLimit(channelName: string, limits: RateLimiter.ChannelLimits?)
	RateLimiter.setChannelLimits(channelName, limits)
end

--[=[
	Returns the bounded security audit log (most recent 256 entries,
	oldest first). See SecurityMonitor.
]=]
Transport.GetAuditLog = SecurityMonitor.getAuditLog

--[=[
	Registers a Schema codec for a defined event. The receive path then
	requires the payload to be a single buffer decoding cleanly under the
	codec; failures are dropped and striked. Called by `channel:Define`.
]=]
function Transport.DefineEvent(channelName: string, eventName: string, codec: Schema.Codec<any>)
	Envelope.assertEventName(eventName)
	DefinedRegistry.set(channelName, eventName, codec)
	Transport.BindChannel(channelName)
end

--[=[
	Registers inbound middleware. `channelName = nil` → global (all
	channels). Runs after rate limiting and validation, before dispatch.
	Returns a Connection.
]=]
function Transport.Use(channelName: string?, middleware: Types.Middleware): MiddlewareRegistry.Connection
	return MiddlewareRegistry.use(channelName, middleware)
end

--[=[
	Registers a positional argument schema for incoming `event` packets on
	this channel. Packets failing it are dropped and logged before your
	handler runs. Trailing `optional(...)` validators express optional args;
	extra arguments beyond the schema are always rejected.

	```lua
	Transport.Expect("Combat", "Damage", { Validators.numberRange(0, 100) })
	```
]=]
function Transport.Expect(channelName: string, eventName: string, validators: { Types.Validator })
	Envelope.assertEventName(eventName)
	SchemaRegistry.set(channelName, eventName, validators)
end

--[=[
	Fires `event` to one player (reliable).
]=]
function Transport.Fire(channelName: string, player: Player, eventName: string, ...: any)
	assert(isPlayer(player), "Fire: first argument must be a Player")
	Envelope.assertEventName(eventName)
	Stats.countSend(channelName, eventName, select("#", ...), player.Name)
	Transport.BindChannel(channelName).Reliable:FireClient(player, eventName, ...)
end

--[=[
	Fires `event` to one player (unreliable — may drop, never resent; use for
	high-frequency cosmetic state).
]=]
function Transport.FireUnreliable(channelName: string, player: Player, eventName: string, ...: any)
	assert(isPlayer(player), "FireUnreliable: first argument must be a Player")
	Envelope.assertEventName(eventName)
	Stats.countSend(channelName, eventName, select("#", ...), player.Name)
	Transport.BindChannel(channelName).Unreliable:FireClient(player, eventName, ...)
end

--[=[
	Fires `event` to every connected player (reliable).
]=]
function Transport.FireAll(channelName: string, eventName: string, ...: any)
	Envelope.assertEventName(eventName)
	Stats.countSend(channelName, eventName, select("#", ...), nil)
	Transport.BindChannel(channelName).Reliable:FireAllClients(eventName, ...)
end

--[=[
	Fires `event` to every connected player (unreliable).
]=]
function Transport.FireAllUnreliable(channelName: string, eventName: string, ...: any)
	Envelope.assertEventName(eventName)
	Stats.countSend(channelName, eventName, select("#", ...), nil)
	Transport.BindChannel(channelName).Unreliable:FireAllClients(eventName, ...)
end

--[=[
	Fires `event` to every player except `excluded` (a Player or array of Players).
]=]
function Transport.FireExcept(channelName: string, excluded: Player | { Player }, eventName: string, ...: any)
	Envelope.assertEventName(eventName)
	local remotes = Transport.BindChannel(channelName)

	local excludedSet: { [Player]: boolean } = {}
	if isPlayer(excluded) then
		excludedSet[excluded :: Player] = true
	else
		assert(type(excluded) == "table", "FireExcept: excluded must be a Player or array of Players")
		for _, player in excluded :: { Player } do
			assert(isPlayer(player), "FireExcept: excluded array must contain only Players")
			excludedSet[player] = true
		end
	end

	for _, player in Players:GetPlayers() do
		if not excludedSet[player] then
			remotes.Reliable:FireClient(player, eventName, ...)
		end
	end
end

local function characterPosition(player: Player): Vector3?
	local character = player.Character
	if character == nil then
		return nil
	end
	local root = character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

--[=[
	Fires `event` to every player whose character is within `radius` studs
	of `position` (reliable). Characterless players never receive.
]=]
function Transport.FireNearby(channelName: string, position: Vector3, radius: number, eventName: string, ...: any)
	assert(typeof(position) == "Vector3", "FireNearby: position must be a Vector3")
	assert(type(radius) == "number" and radius > 0, "FireNearby: radius must be a positive number")
	Envelope.assertEventName(eventName)
	local remotes = Transport.BindChannel(channelName)

	for _, player in Players:GetPlayers() do
		local playerPosition = characterPosition(player)
		if playerPosition ~= nil and (playerPosition - position).Magnitude <= radius then
			remotes.Reliable:FireClient(player, eventName, ...)
		end
	end
end

--[=[
	Fires `event` to every player within `radius` studs of `origin`'s
	character, including `origin` themselves (reliable).
]=]
function Transport.FireWithinRadius(channelName: string, origin: Player, radius: number, eventName: string, ...: any)
	assert(isPlayer(origin), "FireWithinRadius: origin must be a Player")
	local position = characterPosition(origin)
	if position == nil then
		return
	end
	Transport.FireNearby(channelName, position, radius, eventName, ...)
end

--[=[
	Fires `event` to every player in `list` (reliable).
]=]
function Transport.FireList(channelName: string, list: { Player }, eventName: string, ...: any)
	Envelope.assertEventName(eventName)
	local remotes = Transport.BindChannel(channelName)
	for _, player in list do
		assert(isPlayer(player), "FireList: list must contain only Players")
		remotes.Reliable:FireClient(player, eventName, ...)
	end
end

--[=[
	Registers the handler answering `event` invokes from clients on this
	channel. `handler(player, ...args)` returns the reply values; it may
	yield. One handler per event (duplicate registration errors). Handler
	errors reply a sanitized "Invoke handler error" and log the real error
	server-side. Schemas from Expect apply to invoke arguments.
]=]
function Transport.OnInvoke(channelName: string, eventName: string, handler: (player: Player, ...any) -> ...any)
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

--[=[
	Invokes `event` on one client. Returns a Promise resolving with the
	client's reply, or rejecting with "InvokeTimeout" after
	`options.Timeout` (default `Config.DefaultTimeout`) — a client that
	never answers can't hang server logic. No retries in this direction
	(the client may already have executed the handler). Cancelling the
	promise abandons the request.
]=]
function Transport.InvokeClient(
	channelName: string,
	player: Player,
	eventName: string,
	options: Types.InvokeOptions?,
	...: any
): Promise.Promise
	assert(isPlayer(player), "InvokeClient: player expected")
	Envelope.assertEventName(eventName)
	local remotes = Transport.BindChannel(channelName)
	local timeout = (if options then options.Timeout else nil) or Config.Get().DefaultTimeout

	nextInvokeId += 1
	local id = nextInvokeId
	local values = table.pack(...)
	local startedAt = os.clock()

	return Promise.new(function(resolve, reject, onCancel)
		pendingInvokes[id] = {
			player = player,
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
		remotes.Reliable:FireClient(player, "__invoke", id, eventName, table.unpack(values, 1, values.n))
	end)
end

-- Reject every pending invoke addressed to a leaving player.
Players.PlayerRemoving:Connect(function(player: Player)
	for id, pending in pendingInvokes do
		if (pending.player :: any) == player then
			pendingInvokes[id] = nil
			task.cancel(pending.timeoutThread)
			pending.reject("PlayerLeft")
		end
	end
end)

assert(RunService:IsServer() or RunService:IsStudio(), "ServerTransport required outside the server")

return Transport
