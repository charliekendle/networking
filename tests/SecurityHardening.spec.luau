--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Networking.Shared.Config)
local RateLimiter = require(ReplicatedStorage.Networking.Shared.Security.RateLimiter)
local SecurityMonitor = require(ReplicatedStorage.Networking.Shared.Security.SecurityMonitor)
local Serializer = require(ReplicatedStorage.Networking.Shared.Serialization.Serializer)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

local function fakePlayer(name: string): Player
	return { Name = name, UserId = -1 } :: any
end

spec["per-channel rate limits override the global config"] = function(expect)
	Config.Reset()
	Config.Set({ RateLimit = { MaxPacketsPerSecond = 100, BurstAllowance = 0 } })
	RateLimiter.clearAll()
	RateLimiter.setChannelLimits("SpecShop", { MaxPacketsPerSecond = 3, BurstAllowance = 0 })
	local player = fakePlayer("Granular")

	local shopAllowed = 0
	for _ = 1, 10 do
		if RateLimiter.check(player, "SpecShop") then
			shopAllowed += 1
		end
	end
	expect.equal(shopAllowed, 3, "channel override applies")

	local combatAllowed = 0
	for _ = 1, 10 do
		if RateLimiter.check(player, "SpecCombat") then
			combatAllowed += 1
		end
	end
	expect.equal(combatAllowed, 10, "other channels use global config")

	RateLimiter.setChannelLimits("SpecShop", nil)
	local afterClear = 0
	for _ = 1, 10 do
		if RateLimiter.check(player, "SpecShop") then
			afterClear += 1
		end
	end
	expect.equal(afterClear, 10, "clearing restores global limits")

	expect.errors(function()
		RateLimiter.setChannelLimits("SpecShop", { MaxPacketsPerSecond = -5 })
	end)
	RateLimiter.clearAll()
	Config.Reset()
end

spec["onViolation fires per violation, unthresholded"] = function(expect)
	Config.Reset()
	SecurityMonitor.clearAll()
	local player = fakePlayer("Streamed")

	local fired = 0
	local lastKind
	local connection = SecurityMonitor.OnViolation:Connect(function(report)
		fired += 1
		lastKind = report.Kind
	end)
	SecurityMonitor.reportViolation(player, "Combat", nil, "RateLimit", "one")
	SecurityMonitor.reportViolation(player, "Combat", "Damage", "Validation", "two")
	task.wait()
	connection:Disconnect()

	expect.equal(fired, 2, "every violation, no threshold")
	expect.equal(lastKind, "Validation")
	SecurityMonitor.clearAll()
end

spec["deserialize rejects claimed-count memory bombs before allocating"] = function(expect)
	-- 10-byte buffer claiming a ~250M element array: must error, not allocate.
	local bomb = buffer.create(10)
	buffer.writeu8(bomb, 0, 8) -- TAG_TABLE
	-- varint arrayCount = 0xFF 0xFF 0xFF 0x7F  (~268M)
	buffer.writeu8(bomb, 1, 0xFF)
	buffer.writeu8(bomb, 2, 0xFF)
	buffer.writeu8(bomb, 3, 0xFF)
	buffer.writeu8(bomb, 4, 0x7F)
	buffer.writeu8(bomb, 5, 0) -- dictCount = 0
	local startedAt = os.clock()
	expect.errors(function()
		Serializer.deserialize(bomb)
	end)
	expect.truthy(os.clock() - startedAt < 0.05, "rejected instantly, no allocation")
end

spec["deserialize rejects nesting-depth bombs"] = function(expect)
	-- 300 nested single-element arrays: TAG_TABLE, count=1, dict=0, repeated.
	local depth = 300
	local bomb = buffer.create(depth * 3 + 1)
	local cursor = 0
	for _ = 1, depth do
		buffer.writeu8(bomb, cursor, 8) -- TAG_TABLE
		buffer.writeu8(bomb, cursor + 1, 1) -- arrayCount 1
		buffer.writeu8(bomb, cursor + 2, 0) -- dictCount 0
		cursor += 3
	end
	buffer.writeu8(bomb, cursor, 0) -- innermost nil
	expect.errors(function()
		Serializer.deserialize(bomb)
	end)
end

spec["maxPacketBytes config validates"] = function(expect)
	Config.Reset()
	expect.equal(Config.Get().MaxPacketBytes, 65536)
	Config.Set({ MaxPacketBytes = 1024 })
	expect.equal(Config.Get().MaxPacketBytes, 1024)
	expect.errors(function()
		Config.Set({ MaxPacketBytes = 0 })
	end)
	Config.Reset()
end

return spec
