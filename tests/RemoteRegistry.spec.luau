--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Networking.Shared.Config)
local RemoteRegistry = require(ReplicatedStorage.Networking.Shared.Core.RemoteRegistry)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

spec["creates the expected instance tree"] = function(expect)
	local remotes = RemoteRegistry.getServer("SpecChannel")
	expect.truthy(remotes.Reliable:IsA("RemoteEvent"), "Reliable class")
	expect.truthy(remotes.Unreliable:IsA("UnreliableRemoteEvent"), "Unreliable class")
	expect.truthy(remotes.Function:IsA("RemoteFunction"), "Function class")

	local root = ReplicatedStorage:FindFirstChild(Config.Get().RemoteFolderName)
	expect.truthy(root and root:IsA("Folder"), "root folder exists")
	local channelFolder = root and root:FindFirstChild("SpecChannel")
	expect.truthy(channelFolder and channelFolder:IsA("Folder"), "channel folder exists")
	expect.equal(remotes.Reliable.Parent, channelFolder)
end

spec["is idempotent"] = function(expect)
	local first = RemoteRegistry.getServer("SpecChannel")
	local second = RemoteRegistry.getServer("SpecChannel")
	expect.equal(first.Reliable, second.Reliable)
	expect.equal(first.Unreliable, second.Unreliable)
	expect.equal(first.Function, second.Function)
end

spec["cache clear rediscovers the same instances"] = function(expect)
	local before = RemoteRegistry.getServer("SpecChannel")
	RemoteRegistry.clearCache()
	local after = RemoteRegistry.getServer("SpecChannel")
	expect.equal(before.Reliable, after.Reliable, "adopts existing instances instead of duplicating")
end

return spec
