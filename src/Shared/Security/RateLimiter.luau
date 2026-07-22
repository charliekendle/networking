--!strict
--[=[
	@class RateLimiter

	Token-bucket rate limiting, one bucket per `(player, channel)`.

	Bucket capacity = `MaxPacketsPerSecond + BurstAllowance`; refill rate =
	`MaxPacketsPerSecond` tokens/sec, computed lazily on access (no per-frame
	upkeep loop). A packet consumes one token; an empty bucket means the
	packet is dropped and reported as a violation.

	Per-channel buckets mean a spam flood on one channel cannot starve
	legitimate traffic on another. Config is read live, so limits can be
	tuned at runtime (e.g. from an admin command).
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Parent.Config)

type Bucket = {
	tokens: number,
	lastRefill: number,
}

export type ChannelLimits = {
	MaxPacketsPerSecond: number?,
	BurstAllowance: number?,
}

local RateLimiter = {}

local buckets: { [Player]: { [string]: Bucket } } = {}
local channelOverrides: { [string]: ChannelLimits } = {}

--[=[
	@server
	Consumes one token from the player's bucket for this channel.
	Returns true if the packet is within limits, false if it should drop.
]=]
function RateLimiter.check(player: Player, channelName: string): boolean
	local rateConfig = Config.Get().RateLimit
	local override = channelOverrides[channelName]
	local ratePerSecond = (override and override.MaxPacketsPerSecond) or rateConfig.MaxPacketsPerSecond
	local burst = (override and override.BurstAllowance) or rateConfig.BurstAllowance
	local capacity = ratePerSecond + burst
	local now = os.clock()

	local playerBuckets = buckets[player]
	if playerBuckets == nil then
		playerBuckets = {}
		buckets[player] = playerBuckets
	end

	local bucket = playerBuckets[channelName]
	if bucket == nil then
		bucket = { tokens = capacity, lastRefill = now }
		playerBuckets[channelName] = bucket
	else
		local elapsed = now - bucket.lastRefill
		if elapsed > 0 then
			bucket.tokens = math.min(capacity, bucket.tokens + elapsed * ratePerSecond)
			bucket.lastRefill = now
		end
	end

	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end
	return false
end

--[=[
	Sets per-channel limits overriding the global `Config.RateLimit`
	defaults for that channel only. Partial: omitted keys fall back to the
	global config. Pass nil to clear the override. Existing buckets for the
	channel are reset so the new limits apply immediately.

	```lua
	Combat:SetRateLimit({ MaxPacketsPerSecond = 120, BurstAllowance = 40 })
	Shop:SetRateLimit({ MaxPacketsPerSecond = 5 })
	```
]=]
function RateLimiter.setChannelLimits(channelName: string, limits: ChannelLimits?)
	if limits == nil then
		channelOverrides[channelName] = nil
	else
		assert(type(limits) == "table", "SetRateLimit expects a table or nil")
		if limits.MaxPacketsPerSecond ~= nil then
			assert(
				type(limits.MaxPacketsPerSecond) == "number" and limits.MaxPacketsPerSecond > 0,
				"MaxPacketsPerSecond must be > 0"
			)
		end
		if limits.BurstAllowance ~= nil then
			assert(
				type(limits.BurstAllowance) == "number" and limits.BurstAllowance >= 0,
				"BurstAllowance must be >= 0"
			)
		end
		channelOverrides[channelName] = { MaxPacketsPerSecond = limits.MaxPacketsPerSecond, BurstAllowance = limits.BurstAllowance }
	end
	-- Reset buckets on this channel so new limits take effect immediately.
	for _, playerBuckets in buckets do
		playerBuckets[channelName] = nil
	end
end

--[=[
	Drops all buckets for a player. Called automatically on PlayerRemoving.
]=]
function RateLimiter.clear(player: Player)
	buckets[player] = nil
end

--[=[
	Test-only: drops every bucket.
]=]
function RateLimiter.clearAll()
	table.clear(buckets)
	table.clear(channelOverrides)
end

if RunService:IsServer() then
	Players.PlayerRemoving:Connect(RateLimiter.clear)
end

return RateLimiter
