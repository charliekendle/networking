--!strict
--[=[
	@class Types

	Central public type definitions for the Networking package.
	Every module imports its shared types from here so the public API
	surface stays consistent and refactors touch one file.
]=]

--[=[
	@type LogLevel "Debug" | "Info" | "Warn" | "Error" | "None"
	@within Types
]=]
export type LogLevel = "Debug" | "Info" | "Warn" | "Error" | "None"

--[=[
	@interface RateLimitConfig
	@within Types
	.Enabled boolean -- Master switch for automatic rate limiting
	.MaxPacketsPerSecond number -- Steady-state packets/sec allowed per player per channel
	.BurstAllowance number -- Extra packets tolerated in short bursts (token bucket depth)
	.PunishThreshold number -- Consecutive violations before OnSuspiciousActivity fires
]=]
export type RateLimitConfig = {
	Enabled: boolean,
	MaxPacketsPerSecond: number,
	BurstAllowance: number,
	PunishThreshold: number,
}

--[=[
	@interface NetworkConfig
	@within Types
	Complete runtime configuration. See Config module for defaults.
]=]
export type NetworkConfig = {
	DebugMode: boolean,
	LogLevel: LogLevel,
	ValidationEnabled: boolean,
	SecurityEnabled: boolean,
	CompressionEnabled: boolean,
	DefaultTimeout: number,
	DefaultRetries: number,
	RemoteFolderName: string,
	RateLimit: RateLimitConfig,
}

-- Partial mirror of NetworkConfig for Config.Set(). Every field optional.
export type PartialNetworkConfig = {
	DebugMode: boolean?,
	LogLevel: LogLevel?,
	ValidationEnabled: boolean?,
	SecurityEnabled: boolean?,
	CompressionEnabled: boolean?,
	DefaultTimeout: number?,
	DefaultRetries: number?,
	RemoteFolderName: string?,
	RateLimit: {
		Enabled: boolean?,
		MaxPacketsPerSecond: number?,
		BurstAllowance: number?,
		PunishThreshold: number?,
	}?,
}

--[=[
	@interface Connection
	@within Types
	Returned by every listener registration. Mirrors RBXScriptConnection.
]=]
export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

--[=[
	@type ValidatorResult (boolean, string?)
	@within Types
	Validators return `true` on success, or `false, reason` on failure.
]=]
export type Validator = (value: unknown) -> (boolean, string?)

--[=[
	@interface Packet
	@within Types
	Normalized packet passed through the middleware chain.
	.Channel string -- Channel name ("" for the global channel)
	.Event string -- Event name within the channel
	.Args {unknown} -- Positional payload
	.Player Player? -- Sender (server-side) or nil (client-side)
	.Kind "Event" | "UnreliableEvent" | "Invoke" | "Reply"
	.Timestamp number -- os.clock() at receipt
]=]
export type PacketKind = "Event" | "UnreliableEvent" | "Invoke" | "Reply"

export type Packet = {
	Channel: string,
	Event: string,
	Args: { unknown },
	Player: Player?,
	Kind: PacketKind,
	Timestamp: number,
}

--[=[
	@type ViolationKind "RateLimit" | "Validation" | "Envelope"
	@within Types
]=]
export type ViolationKind = "RateLimit" | "Validation" | "Envelope"

--[=[
	@interface SecurityReport
	@within Types
	Passed to OnSuspiciousActivity when a player crosses the punish threshold.
	.Player Player
	.Channel string
	.Event string? -- nil when the event name itself was malformed
	.Kind ViolationKind
	.Reason string
	.Strikes number -- consecutive violations at the moment of the report
]=]
export type SecurityReport = {
	Player: Player,
	Channel: string,
	Event: string?,
	Kind: ViolationKind,
	Reason: string,
	Strikes: number,
}

--[=[
	@interface AuditEntry
	@within Types
	One row of the bounded security audit log.
]=]
export type AuditEntry = {
	Time: number,
	UserId: number,
	PlayerName: string,
	Channel: string,
	Event: string?,
	Kind: ViolationKind,
	Reason: string,
}

--[=[
	@type MiddlewareResult "Continue" | "Drop"
	@within Types
]=]
export type MiddlewareResult = "Continue" | "Drop"

--[=[
	@type Middleware (packet: Packet) -> (MiddlewareResult, Packet?)
	@within Types
	Middleware may pass the packet on ("Continue"), optionally replacing it,
	or terminate processing ("Drop").
]=]
export type Middleware = (packet: Packet) -> (MiddlewareResult, Packet?)

return nil
