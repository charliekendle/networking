--!strict
--[=[
	@class MiddlewareRegistry

	Ordered middleware chains for incoming packets, global and per-channel.
	Context-local (the server's chains process client→server traffic and
	vice versa).

	A middleware receives a Packet and returns a verdict:

	```lua
	Network.Use(function(packet)
		-- observe
		print(packet.Channel, packet.Event, packet.ArgCount)
		return "Continue"
	end)

	Combat:Use(function(packet)
		-- gate (permissions, auth, feature flags...)
		if packet.Player and not canUseCombat(packet.Player) then
			return "Drop"
		end
		return "Continue"
	end)

	Combat:Use(function(packet)
		-- transform: return a (modified) packet alongside "Continue"
		packet.Args[1] = math.floor(packet.Args[1] :: any)
		return "Continue", packet
	end)
	```

	Execution order: global chain first (registration order), then the
	packet's channel chain. "Drop" anywhere stops processing; the packet
	never reaches handlers. A middleware that **errors** also drops the
	packet (fail closed) with an Error log — a crashed permission check must
	never fail open.

	Runs after rate limiting and schema validation, immediately before
	dispatch. The pipeline only allocates a Packet when at least one
	middleware could apply, so unused middleware costs nothing.
]=]

local Types = require(script.Parent.Parent.Types)
local Log = require(script.Parent.Parent.Utilities.Log)

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

type Entry = {
	fn: Types.Middleware,
	Connected: boolean,
	Disconnect: (self: Entry) -> (),
}

local MiddlewareRegistry = {}

local globalChain: { Entry } = {}
local channelChains: { [string]: { Entry } } = {}

local EntryClass = {}
EntryClass.__index = EntryClass

function EntryClass.Disconnect(self: any)
	if not self.Connected then
		return
	end
	self.Connected = false
	local chain: { Entry } = self._chain
	local index = table.find(chain, self)
	if index then
		table.remove(chain, index)
	end
end

local function addTo(chain: { Entry }, middleware: Types.Middleware): Connection
	assert(type(middleware) == "function", "Use expects a function")
	local entry = setmetatable({
		fn = middleware,
		Connected = true,
		_chain = chain,
	}, EntryClass)
	table.insert(chain, entry :: any)
	return (entry :: any) :: Connection
end

--[=[
	Registers middleware. `channelName = nil` → global chain (every channel);
	otherwise scoped to that channel. Returns a Connection; Disconnect
	removes it.
]=]
function MiddlewareRegistry.use(channelName: string?, middleware: Types.Middleware): Connection
	if channelName == nil then
		return addTo(globalChain, middleware)
	end
	local chain = channelChains[channelName]
	if chain == nil then
		chain = {}
		channelChains[channelName] = chain
	end
	return addTo(chain, middleware)
end

--[=[
	True if any middleware could apply to this channel. The transports use
	this to skip Packet allocation entirely when no middleware is registered.
]=]
function MiddlewareRegistry.hasAny(channelName: string): boolean
	if #globalChain > 0 then
		return true
	end
	local chain = channelChains[channelName]
	return chain ~= nil and #chain > 0
end

local function runChain(chain: { Entry }, packet: Types.Packet): Types.Packet?
	-- Snapshot before iterating: middleware may disconnect entries
	-- (including itself) mid-run; removals take effect from the next packet,
	-- and the Connected flag still short-circuits entries disconnected
	-- earlier in this same run.
	local snapshot = table.clone(chain)
	for index = 1, #snapshot do
		local entry = snapshot[index]
		if entry.Connected then
			local ok, verdict, replacement = pcall(entry.fn, packet)
			if not ok then
				Log.Error(
					"Middleware error on %q/%q — packet dropped (fail closed): %s",
					packet.Channel,
					packet.Event,
					tostring(verdict)
				)
				return nil
			end
			if verdict == "Drop" then
				return nil
			end
			if verdict ~= "Continue" then
				Log.Error(
					"Middleware returned invalid verdict %q on %q/%q — packet dropped (fail closed)",
					tostring(verdict),
					packet.Channel,
					packet.Event
				)
				return nil
			end
			if replacement ~= nil then
				packet = replacement
			end
		end
	end
	return packet
end

--[=[
	Runs the global chain then the packet's channel chain. Returns the
	(possibly replaced) packet, or nil if any middleware dropped it.
]=]
function MiddlewareRegistry.run(packet: Types.Packet): Types.Packet?
	local afterGlobal = runChain(globalChain, packet)
	if afterGlobal == nil then
		return nil
	end
	local chain = channelChains[afterGlobal.Channel]
	if chain == nil then
		return afterGlobal
	end
	return runChain(chain, afterGlobal)
end

--[=[
	Test-only: removes every registered middleware.
]=]
function MiddlewareRegistry.clearAll()
	for _, entry in globalChain do
		entry.Connected = false
	end
	table.clear(globalChain)
	for _, chain in channelChains do
		for _, entry in chain do
			entry.Connected = false
		end
	end
	table.clear(channelChains)
end

return MiddlewareRegistry
