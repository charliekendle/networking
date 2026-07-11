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

local Dispatcher = require(script.Parent.Parent.Shared.Core.Dispatcher)
local Envelope = require(script.Parent.Parent.Shared.Core.Envelope)
local RemoteRegistry = require(script.Parent.Parent.Shared.Core.RemoteRegistry)
local Log = require(script.Parent.Parent.Shared.Utilities.Log)

local Transport = {}

local dispatcher = Dispatcher.new()
local boundChannels: { [string]: boolean } = {}

local function isPlayer(value: unknown): boolean
	return typeof(value) == "Instance" and (value :: Instance):IsA("Player")
end

local function onIncoming(channelName: string, player: Player, eventName: unknown, ...: any)
	if not Envelope.isValidEventName(eventName) then
		Log.Warn("Dropped packet from %s on channel %q: invalid event name", player.Name, channelName)
		return
	end
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
			onIncoming(channelName, player, eventName, ...)
		end)
		remotes.Unreliable.OnServerEvent:Connect(function(player, eventName, ...)
			onIncoming(channelName, player, eventName, ...)
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
	Fires `event` to one player (reliable).
]=]
function Transport.Fire(channelName: string, player: Player, eventName: string, ...: any)
	assert(isPlayer(player), "Fire: first argument must be a Player")
	Envelope.assertEventName(eventName)
	Transport.BindChannel(channelName).Reliable:FireClient(player, eventName, ...)
end

--[=[
	Fires `event` to one player (unreliable — may drop, never resent; use for
	high-frequency cosmetic state).
]=]
function Transport.FireUnreliable(channelName: string, player: Player, eventName: string, ...: any)
	assert(isPlayer(player), "FireUnreliable: first argument must be a Player")
	Envelope.assertEventName(eventName)
	Transport.BindChannel(channelName).Unreliable:FireClient(player, eventName, ...)
end

--[=[
	Fires `event` to every connected player (reliable).
]=]
function Transport.FireAll(channelName: string, eventName: string, ...: any)
	Envelope.assertEventName(eventName)
	Transport.BindChannel(channelName).Reliable:FireAllClients(eventName, ...)
end

--[=[
	Fires `event` to every connected player (unreliable).
]=]
function Transport.FireAllUnreliable(channelName: string, eventName: string, ...: any)
	Envelope.assertEventName(eventName)
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

assert(RunService:IsServer() or RunService:IsStudio(), "ServerTransport required outside the server")

return Transport
