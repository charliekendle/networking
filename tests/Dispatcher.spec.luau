--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Dispatcher = require(ReplicatedStorage.Networking.Shared.Core.Dispatcher)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

spec["routes by channel and event"] = function(expect)
	local dispatcher = Dispatcher.new()
	local got
	dispatcher:On("Combat", "Damage", function(amount)
		got = amount
	end)
	dispatcher:Fire("Combat", "Damage", 25)
	task.wait()
	expect.equal(got, 25)
end

spec["channels are isolated"] = function(expect)
	local dispatcher = Dispatcher.new()
	local combatHits, tradeHits = 0, 0
	dispatcher:On("Combat", "Ping", function()
		combatHits += 1
	end)
	dispatcher:On("Trading", "Ping", function()
		tradeHits += 1
	end)
	dispatcher:Fire("Combat", "Ping")
	task.wait()
	expect.equal(combatHits, 1)
	expect.equal(tradeHits, 0)
end

spec["fire with no listeners is a no-op"] = function(expect)
	local dispatcher = Dispatcher.new()
	dispatcher:Fire("Nowhere", "Nothing", 1, 2, 3)
	expect.truthy(true)
end

spec["off disconnects all listeners for an event"] = function(expect)
	local dispatcher = Dispatcher.new()
	local count = 0
	dispatcher:On("Global", "Tick", function()
		count += 1
	end)
	dispatcher:On("Global", "Tick", function()
		count += 1
	end)
	dispatcher:Off("Global", "Tick")
	dispatcher:Fire("Global", "Tick")
	task.wait()
	expect.equal(count, 0)
end

spec["hasListeners reflects connection state"] = function(expect)
	local dispatcher = Dispatcher.new()
	expect.falsy(dispatcher:HasListeners("Global", "Thing"))
	local connection = dispatcher:On("Global", "Thing", function() end)
	expect.truthy(dispatcher:HasListeners("Global", "Thing"))
	connection:Disconnect()
	expect.falsy(dispatcher:HasListeners("Global", "Thing"))
end

return spec
