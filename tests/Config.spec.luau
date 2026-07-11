--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Networking.Shared.Config)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

spec["defaults are sane"] = function(expect)
	Config.Reset()
	local config = Config.Get()
	expect.equal(config.ValidationEnabled, true)
	expect.equal(config.SecurityEnabled, true)
	expect.equal(config.DebugMode, false)
	expect.truthy(config.RateLimit.MaxPacketsPerSecond > 0)
end

spec["set deep-merges nested tables"] = function(expect)
	Config.Reset()
	Config.Set({ RateLimit = { MaxPacketsPerSecond = 5 } })
	local config = Config.Get()
	expect.equal(config.RateLimit.MaxPacketsPerSecond, 5)
	expect.equal(config.RateLimit.Enabled, true, "sibling keys preserved")
	Config.Reset()
end

spec["snapshot is read-only"] = function(expect)
	Config.Reset()
	local config = Config.Get()
	expect.errors(function()
		(config :: any).DebugMode = true
	end)
end

spec["unknown keys are rejected"] = function(expect)
	Config.Reset()
	expect.errors(function()
		Config.Set({ NotARealKey = true } :: any)
	end)
	expect.errors(function()
		Config.Set({ RateLimit = { Nope = 1 } } :: any)
	end)
end

spec["invalid values are rejected"] = function(expect)
	Config.Reset()
	expect.errors(function()
		Config.Set({ LogLevel = "Loud" } :: any)
	end)
	expect.errors(function()
		Config.Set({ DefaultTimeout = -1 })
	end)
end

spec["changed signal fires with new snapshot"] = function(expect)
	Config.Reset()
	local seen
	local connection = Config.Changed:Connect(function(config)
		seen = config.DebugMode
	end)
	Config.Set({ DebugMode = true })
	task.wait()
	connection:Disconnect()
	expect.equal(seen, true)
	Config.Reset()
end

return spec
