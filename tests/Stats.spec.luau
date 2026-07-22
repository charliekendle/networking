--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Networking.Shared.Config)
local Stats = require(ReplicatedStorage.Networking.Shared.Debug.Stats)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

spec["counters aggregate totals and per-channel"] = function(expect)
	Stats.clearAll()
	Stats.countSend("Combat", "A", 2, nil)
	Stats.countSend("Combat", "B", 0, nil)
	Stats.countReceive("Combat", "A", 2, "Alice")
	Stats.countDrop("Trading")

	local snapshot = Stats.getSnapshot()
	expect.equal(snapshot.Sent, 2)
	expect.equal(snapshot.Received, 1)
	expect.equal(snapshot.Dropped, 1)
	expect.equal(snapshot.PerChannel.Combat.Sent, 2)
	expect.equal(snapshot.PerChannel.Combat.Received, 1)
	expect.equal(snapshot.PerChannel.Trading.Dropped, 1)
	Stats.clearAll()
end

spec["packet log only records in debug mode"] = function(expect)
	Config.Reset()
	Stats.clearAll()
	Stats.countSend("Combat", "Quiet", 0, nil)
	expect.equal(#Stats.getPacketLog(), 0, "no log outside debug mode")

	Config.Set({ DebugMode = true })
	Stats.countSend("Combat", "Loud", 1, nil)
	Stats.countReceive("Combat", "Loud", 1, "Alice")
	local log = Stats.getPacketLog()
	expect.equal(#log, 2)
	expect.equal(log[1].Direction, "Send")
	expect.equal(log[2].Direction, "Receive")
	expect.equal(log[2].Player, "Alice")
	Config.Reset()
	Stats.clearAll()
end

spec["packet log is bounded"] = function(expect)
	Config.Set({ DebugMode = true })
	Stats.clearAll()
	for index = 1, 200 do
		Stats.countSend("Combat", tostring(index), 0, nil)
	end
	local log = Stats.getPacketLog()
	expect.equal(#log, 128)
	expect.equal(log[128].Event, "200", "newest kept")
	expect.equal(log[1].Event, "73", "oldest evicted")
	Config.Reset()
	Stats.clearAll()
end

spec["rtt averages over a rolling window"] = function(expect)
	Stats.clearAll()
	expect.equal(Stats.getSnapshot().AverageInvokeRtt, nil, "nil before samples")
	Stats.recordRtt(0.1)
	Stats.recordRtt(0.3)
	local average = Stats.getSnapshot().AverageInvokeRtt :: number
	expect.truthy(math.abs(average - 0.2) < 1e-9)
	Stats.clearAll()
end

return spec
