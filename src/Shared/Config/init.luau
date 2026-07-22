--!strict
--[=[
	@class Config

	Centralized runtime configuration. Every subsystem (validation, security,
	compression, debug, logging) reads from here rather than owning private flags,
	so behaviour can be tuned from one place:

	```lua
	Network.Configure({
		DebugMode = true,
		RateLimit = { MaxPacketsPerSecond = 30 },
	})
	```

	`Config.Changed` fires after every successful `Config.Set`, letting
	subsystems react live (e.g. the debug monitor attaching/detaching).
]=]

local Types = require(script.Parent.Types)
local TableUtil = require(script.Parent.Utilities.TableUtil)
local Signal = require(script.Parent.Signals.Signal)

local VALID_LOG_LEVELS: { [string]: boolean } = {
	Debug = true,
	Info = true,
	Warn = true,
	Error = true,
	None = true,
}

local DEFAULTS: Types.NetworkConfig = {
	DebugMode = false,
	LogLevel = "Warn",
	ValidationEnabled = true,
	SecurityEnabled = true,
	CompressionEnabled = false,
	DefaultTimeout = 10,
	DefaultRetries = 0,
	RemoteFolderName = "_Networking",
	MaxPacketBytes = 65536, -- cap on incoming defined-event/serialized buffers
	RateLimit = {
		Enabled = true,
		MaxPacketsPerSecond = 60,
		BurstAllowance = 20,
		PunishThreshold = 5,
	},
}

local current: Types.NetworkConfig = TableUtil.deepCopy(DEFAULTS)

local Config = {}

--[=[
	@prop Changed Signal<NetworkConfig>
	@within Config
	Fires with the new (read-only snapshot) config after each Set/Reset.
]=]
Config.Changed = Signal.new() :: Signal.Signal<Types.NetworkConfig>

local function validatePatch(patch: Types.PartialNetworkConfig)
	assert(type(patch) == "table", "Config.Set expects a table")

	if patch.LogLevel ~= nil then
		assert(VALID_LOG_LEVELS[patch.LogLevel], `Invalid LogLevel "{patch.LogLevel}"`)
	end
	if patch.DefaultTimeout ~= nil then
		assert(type(patch.DefaultTimeout) == "number" and patch.DefaultTimeout > 0, "DefaultTimeout must be > 0")
	end
	if patch.DefaultRetries ~= nil then
		assert(
			type(patch.DefaultRetries) == "number" and patch.DefaultRetries >= 0,
			"DefaultRetries must be >= 0"
		)
	end
	if patch.MaxPacketBytes ~= nil then
		assert(
			type(patch.MaxPacketBytes) == "number" and patch.MaxPacketBytes > 0,
			"MaxPacketBytes must be > 0"
		)
	end
	if patch.RemoteFolderName ~= nil then
		assert(
			type(patch.RemoteFolderName) == "string" and #patch.RemoteFolderName > 0,
			"RemoteFolderName must be a non-empty string"
		)
	end

	local rateLimit = patch.RateLimit
	if rateLimit ~= nil then
		assert(type(rateLimit) == "table", "RateLimit must be a table")
		if rateLimit.MaxPacketsPerSecond ~= nil then
			assert(
				type(rateLimit.MaxPacketsPerSecond) == "number" and rateLimit.MaxPacketsPerSecond > 0,
				"RateLimit.MaxPacketsPerSecond must be > 0"
			)
		end
		if rateLimit.BurstAllowance ~= nil then
			assert(
				type(rateLimit.BurstAllowance) == "number" and rateLimit.BurstAllowance >= 0,
				"RateLimit.BurstAllowance must be >= 0"
			)
		end
		if rateLimit.PunishThreshold ~= nil then
			assert(
				type(rateLimit.PunishThreshold) == "number" and rateLimit.PunishThreshold >= 1,
				"RateLimit.PunishThreshold must be >= 1"
			)
		end
	end
end

--[=[
	Deep-merges a partial config over the current one. Unknown keys are
	rejected loudly rather than silently ignored — typos in config tables
	are a classic source of "why is validation still on" bugs.
]=]
function Config.Set(patch: Types.PartialNetworkConfig)
	validatePatch(patch)

	for key in patch :: { [string]: any } do
		assert((DEFAULTS :: any)[key] ~= nil, `Unknown config key "{key}"`)
	end
	local rateLimit = (patch :: any).RateLimit
	if type(rateLimit) == "table" then
		for key in rateLimit do
			assert((DEFAULTS.RateLimit :: any)[key] ~= nil, `Unknown config key "RateLimit.{key}"`)
		end
	end

	TableUtil.deepMerge(current :: any, patch :: any)
	Config.Changed:Fire(Config.Get())
end

--[=[
	Returns a read-only snapshot of the current config. Mutating the snapshot
	errors; use Config.Set.
]=]
function Config.Get(): Types.NetworkConfig
	return TableUtil.deepFreeze(current)
end

--[=[
	Restores factory defaults.
]=]
function Config.Reset()
	current = TableUtil.deepCopy(DEFAULTS)
	Config.Changed:Fire(Config.Get())
end

--[=[
	Read-only copy of the factory defaults, mainly for docs/tests.
]=]
function Config.GetDefaults(): Types.NetworkConfig
	return TableUtil.deepFreeze(DEFAULTS)
end

return Config
