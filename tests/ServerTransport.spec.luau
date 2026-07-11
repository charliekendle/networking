--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Transport = require(ReplicatedStorage.Networking.Server.Transport)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

spec["fireAll with zero players does not error"] = function(expect)
	Transport.FireAll("Global", "SpecBroadcast", 1, 2, 3)
	Transport.FireAllUnreliable("Global", "SpecBroadcast")
	expect.truthy(true)
end

spec["fire rejects non-player targets"] = function(expect)
	expect.errors(function()
		Transport.Fire("Global", {} :: any, "Event")
	end)
	expect.errors(function()
		Transport.Fire("Global", workspace :: any, "Event")
	end)
end

spec["local fires reject reserved event names"] = function(expect)
	expect.errors(function()
		Transport.FireAll("Global", "__internal")
	end)
	expect.errors(function()
		Transport.On("Global", "", function() end)
	end)
end

spec["on returns a working connection"] = function(expect)
	local connection = Transport.On("Global", "SpecListener", function() end)
	expect.truthy(connection.Connected)
	connection:Disconnect()
	expect.falsy(connection.Connected)
end

spec["fireExcept validates the exclusion argument"] = function(expect)
	Transport.FireExcept("Global", {}, "SpecBroadcast")
	expect.errors(function()
		Transport.FireExcept("Global", { 5 :: any }, "SpecBroadcast")
	end)
	expect.errors(function()
		Transport.FireExcept("Global", 5 :: any, "SpecBroadcast")
	end)
end

return spec
