--!strict
--[=[
	@class Log

	Level-gated logger. All package output funnels through here so a game
	can silence the library entirely (`LogLevel = "None"`) or crank it up
	while debugging (`LogLevel = "Debug"`).

	Levels: Debug < Info < Warn < Error < None.
]=]

local RunService = game:GetService("RunService")

local Config = require(script.Parent.Parent.Config)
local Types = require(script.Parent.Parent.Types)

local LEVEL_ORDER: { [Types.LogLevel]: number } = {
	Debug = 1,
	Info = 2,
	Warn = 3,
	Error = 4,
	None = 5,
}

local CONTEXT = if RunService:IsServer() then "Server" else "Client"

local Log = {}

local function enabled(level: Types.LogLevel): boolean
	return LEVEL_ORDER[level] >= LEVEL_ORDER[Config.Get().LogLevel]
end

local function prefix(level: Types.LogLevel): string
	return `[Networking/{CONTEXT}][{level}]`
end

function Log.Debug(message: string, ...: any)
	if enabled("Debug") then
		print(prefix("Debug"), string.format(message, ...))
	end
end

function Log.Info(message: string, ...: any)
	if enabled("Info") then
		print(prefix("Info"), string.format(message, ...))
	end
end

function Log.Warn(message: string, ...: any)
	if enabled("Warn") then
		warn(prefix("Warn"), string.format(message, ...))
	end
end

--[=[
	Logs at Error level. Does not throw — callers decide whether a condition
	is fatal. Use `error()` directly for programmer errors.
]=]
function Log.Error(message: string, ...: any)
	if enabled("Error") then
		warn(prefix("Error"), string.format(message, ...))
	end
end

return Log
