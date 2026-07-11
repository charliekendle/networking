--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(ReplicatedStorage.Networking)
local Channel = require(ReplicatedStorage.Networking.Shared.Channels.Channel)
local Config = require(ReplicatedStorage.Networking.Shared.Config)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

spec["is memoized per name"] = function(expect)
	local first = Network.Channel("SpecCombat")
	local second = Network.Channel("SpecCombat")
	local other = Network.Channel("SpecTrading")
	expect.equal(first, second, "same name, same object")
	expect.truthy(first ~= other, "different names, different objects")
	expect.equal(first.Name, "SpecCombat")
end

spec["rejects invalid channel names"] = function(expect)
	expect.errors(function()
		Network.Channel("")
	end)
	expect.errors(function()
		Network.Channel("__reserved")
	end)
	expect.errors(function()
		Network.Channel("bad/name")
	end)
	expect.errors(function()
		Network.Channel(5 :: any)
	end)
end

spec["server access creates remotes eagerly"] = function(expect)
	Network.Channel("SpecEager")
	local root = ReplicatedStorage:FindFirstChild(Config.Get().RemoteFolderName)
	local folder = root and root:FindFirstChild("SpecEager")
	expect.truthy(folder, "channel folder exists without any Fire/On")
	expect.truthy(folder and folder:FindFirstChild("Reliable"))
	expect.truthy(folder and folder:FindFirstChild("Unreliable"))
	expect.truthy(folder and folder:FindFirstChild("Function"))
end

spec["is() identifies channels"] = function(expect)
	expect.truthy(Channel.is(Network.Channel("SpecCombat")))
	expect.falsy(Channel.is({}))
	expect.falsy(Channel.is("SpecCombat"))
end

spec["listeners and fires work through the channel surface"] = function(expect)
	local channel = Network.Channel("SpecSurface")
	local connection = channel:On("Thing", function() end)
	expect.truthy(connection.Connected)
	channel:Off("Thing")
	expect.falsy(connection.Connected, "Off disconnects listeners")
	channel:FireAll("Broadcast", 1, 2)
	channel:FireAllUnreliable("Broadcast")
	channel:FireExcept({}, "Broadcast")
	channel:FireList({}, "Broadcast")
	expect.errors(function()
		channel:FireAll("__reserved")
	end)
end

return spec
