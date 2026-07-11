--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MiddlewareRegistry = require(ReplicatedStorage.Networking.Shared.Middleware.MiddlewareRegistry)
local Types = require(ReplicatedStorage.Networking.Shared.Types)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

local function makePacket(channel: string, event: string, args: { unknown }): Types.Packet
	return {
		Channel = channel,
		Event = event,
		Args = args,
		ArgCount = #args,
		Player = nil,
		Kind = "Event" :: Types.PacketKind,
		Timestamp = os.clock(),
	}
end

spec["global runs before channel, in registration order"] = function(expect)
	MiddlewareRegistry.clearAll()
	local order = {}
	MiddlewareRegistry.use(nil, function(packet)
		table.insert(order, "global1")
		return "Continue"
	end)
	MiddlewareRegistry.use(nil, function(packet)
		table.insert(order, "global2")
		return "Continue"
	end)
	MiddlewareRegistry.use("Combat", function(packet)
		table.insert(order, "combat")
		return "Continue"
	end)

	local result = MiddlewareRegistry.run(makePacket("Combat", "Thing", {}))
	expect.truthy(result, "packet continued")
	expect.equal(table.concat(order, ","), "global1,global2,combat")
	MiddlewareRegistry.clearAll()
end

spec["drop stops the chain and rejects the packet"] = function(expect)
	MiddlewareRegistry.clearAll()
	local reachedLater = false
	MiddlewareRegistry.use(nil, function()
		return "Drop"
	end)
	MiddlewareRegistry.use(nil, function()
		reachedLater = true
		return "Continue"
	end)

	local result = MiddlewareRegistry.run(makePacket("Combat", "Thing", {}))
	expect.falsy(result, "dropped")
	expect.falsy(reachedLater, "later middleware never ran")
	MiddlewareRegistry.clearAll()
end

spec["replacement packets flow downstream"] = function(expect)
	MiddlewareRegistry.clearAll()
	MiddlewareRegistry.use(nil, function(packet)
		packet.Args[1] = (packet.Args[1] :: number) + 100
		return "Continue", packet
	end)
	local seenDownstream
	MiddlewareRegistry.use("Combat", function(packet)
		seenDownstream = packet.Args[1]
		return "Continue"
	end)

	local result = MiddlewareRegistry.run(makePacket("Combat", "Thing", { 1 }))
	expect.truthy(result)
	expect.equal(seenDownstream, 101, "channel chain saw transformed value")
	expect.equal(result and result.Args[1], 101)
	MiddlewareRegistry.clearAll()
end

spec["channel chains are scoped"] = function(expect)
	MiddlewareRegistry.clearAll()
	local combatRuns = 0
	MiddlewareRegistry.use("Combat", function()
		combatRuns += 1
		return "Continue"
	end)

	MiddlewareRegistry.run(makePacket("Trading", "Thing", {}))
	expect.equal(combatRuns, 0, "other channel untouched")
	expect.falsy(MiddlewareRegistry.hasAny("Trading"))
	expect.truthy(MiddlewareRegistry.hasAny("Combat"))
	MiddlewareRegistry.run(makePacket("Combat", "Thing", {}))
	expect.equal(combatRuns, 1)
	MiddlewareRegistry.clearAll()
end

spec["errors fail closed"] = function(expect)
	MiddlewareRegistry.clearAll()
	MiddlewareRegistry.use(nil, function()
		error("intentional middleware error")
	end)
	local result = MiddlewareRegistry.run(makePacket("Combat", "Thing", {}))
	expect.falsy(result, "errored middleware drops the packet")
	MiddlewareRegistry.clearAll()
end

spec["invalid verdicts fail closed"] = function(expect)
	MiddlewareRegistry.clearAll()
	MiddlewareRegistry.use(nil, function()
		return "Maybe" :: any
	end)
	local result = MiddlewareRegistry.run(makePacket("Combat", "Thing", {}))
	expect.falsy(result)
	MiddlewareRegistry.clearAll()
end

spec["disconnect removes middleware, even mid-run"] = function(expect)
	MiddlewareRegistry.clearAll()
	local runs = 0
	local connection
	connection = MiddlewareRegistry.use(nil, function()
		runs += 1
		connection:Disconnect()
		return "Continue"
	end)
	local after = 0
	MiddlewareRegistry.use(nil, function()
		after += 1
		return "Continue"
	end)

	MiddlewareRegistry.run(makePacket("Combat", "Thing", {}))
	MiddlewareRegistry.run(makePacket("Combat", "Thing", {}))
	expect.equal(runs, 1, "self-disconnected after first run")
	expect.equal(after, 2, "sibling middleware unaffected both runs")
	expect.falsy(connection.Connected)
	MiddlewareRegistry.clearAll()
end

return spec
