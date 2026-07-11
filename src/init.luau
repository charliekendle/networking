--!strict
--[=[
	@class Network

	Package entry point. Context-aware: requiring this module on the server
	exposes the server API, on the client the client API. Shared surface
	(Configure, Signal, Types) is identical on both.

	Step 1 exposes the foundation only. Core/Channels land in Step 2 and
	extend this surface without breaking it.

	```lua
	local Network = require(ReplicatedStorage.Packages.Networking)

	Network.Configure({ DebugMode = true })
	```
]=]

local Config = require(script.Shared.Config)
local Signal = require(script.Shared.Signals.Signal)
local Log = require(script.Shared.Utilities.Log)

-- Re-exported types. Consumers: `local Networking = require(...)` then
-- `type Packet = Networking.Packet` etc.
local Types = require(script.Shared.Types)
export type NetworkConfig = Types.NetworkConfig
export type PartialNetworkConfig = Types.PartialNetworkConfig
export type Packet = Types.Packet
export type Middleware = Types.Middleware
export type MiddlewareResult = Types.MiddlewareResult
export type Validator = Types.Validator
export type Connection = Types.Connection
export type LogLevel = Types.LogLevel
export type Signal<T...> = Signal.Signal<T...>

local Network = {}

--[=[
	@prop Version string
	@within Network
]=]
Network.Version = "0.1.0"

--[=[
	@prop Signal SignalConstructor
	@within Network
	Exposed so games can reuse the package's signal implementation.
]=]
Network.Signal = Signal

--[=[
	@prop ConfigChanged Signal<NetworkConfig>
	@within Network
]=]
Network.ConfigChanged = Config.Changed

--[=[
	Applies a partial configuration. See Config for keys and defaults.
]=]
function Network.Configure(patch: PartialNetworkConfig)
	Config.Set(patch)
end

--[=[
	Returns a read-only snapshot of the active configuration.
]=]
function Network.GetConfig(): NetworkConfig
	return Config.Get()
end

Log.Debug("Networking v%s loaded", Network.Version)

return Network
