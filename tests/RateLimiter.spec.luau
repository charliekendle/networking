--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Networking.Shared.Config)
local RateLimiter = require(ReplicatedStorage.Networking.Shared.Security.RateLimiter)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

local function fakePlayer(name: string): Player
	return { Name = name, UserId = -1 } :: any
end

spec["allows up to capacity, then blocks"] = function(expect)
	Config.Reset()
	Config.Set({ RateLimit = { MaxPacketsPerSecond = 8, BurstAllowance = 2 } })
	RateLimiter.clearAll()
	local player = fakePlayer("Cap")

	local allowed = 0
	for _ = 1, 15 do
		if RateLimiter.check(player, "SpecChan") then
			allowed += 1
		end
	end
	expect.equal(allowed, 10, "capacity = rate + burst")
	expect.falsy(RateLimiter.check(player, "SpecChan"), "empty bucket blocks")
	Config.Reset()
end

spec["tokens refill over time"] = function(expect)
	Config.Reset()
	Config.Set({ RateLimit = { MaxPacketsPerSecond = 20, BurstAllowance = 0 } })
	RateLimiter.clearAll()
	local player = fakePlayer("Refill")

	for _ = 1, 20 do
		RateLimiter.check(player, "SpecChan")
	end
	expect.falsy(RateLimiter.check(player, "SpecChan"), "drained")
	task.wait(0.15) -- ~3 tokens at 20/s
	expect.truthy(RateLimiter.check(player, "SpecChan"), "refilled after waiting")
	Config.Reset()
end

spec["buckets are per player and per channel"] = function(expect)
	Config.Reset()
	Config.Set({ RateLimit = { MaxPacketsPerSecond = 3, BurstAllowance = 0 } })
	RateLimiter.clearAll()
	local alice = fakePlayer("Alice")
	local bob = fakePlayer("Bob")

	for _ = 1, 3 do
		RateLimiter.check(alice, "Combat")
	end
	expect.falsy(RateLimiter.check(alice, "Combat"), "alice drained on Combat")
	expect.truthy(RateLimiter.check(alice, "Trading"), "other channel unaffected")
	expect.truthy(RateLimiter.check(bob, "Combat"), "other player unaffected")
	Config.Reset()
end

spec["clear resets a player"] = function(expect)
	Config.Reset()
	Config.Set({ RateLimit = { MaxPacketsPerSecond = 1, BurstAllowance = 0 } })
	RateLimiter.clearAll()
	local player = fakePlayer("Clear")

	RateLimiter.check(player, "SpecChan")
	expect.falsy(RateLimiter.check(player, "SpecChan"))
	RateLimiter.clear(player)
	expect.truthy(RateLimiter.check(player, "SpecChan"), "fresh bucket after clear")
	Config.Reset()
end

return spec
