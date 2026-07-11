--!strict
--[=[
	@class SecurityMonitor

	Tracks violations per player, fires the suspicious-activity hook, and
	keeps a bounded audit log.

	Strike model: every dropped packet (rate limit, validation failure,
	malformed envelope) adds a strike; a packet that passes cleanly resets
	the player's strikes to zero. When strikes reach
	`Config.RateLimit.PunishThreshold`, `OnSuspiciousActivity` fires with a
	report and the counter resets — sustained abuse re-fires every N
	violations rather than once ever.

	The package never punishes on its own: kicking/banning is a game
	decision, taken in the hook:

	```lua
	Network.OnSuspiciousActivity:Connect(function(report)
		warn(`{report.Player.Name} flagged: {report.Kind} x{report.Strikes} on {report.Channel}`)
		if report.Kind == "RateLimit" then
			report.Player:Kick("Network abuse detected")
		end
	end)
	```

	Violation logging is throttled to once per second per player so an
	exploiter cannot turn the limiter itself into console spam.
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Parent.Config)
local Signal = require(script.Parent.Parent.Signals.Signal)
local Types = require(script.Parent.Parent.Types)
local Log = require(script.Parent.Parent.Utilities.Log)

local AUDIT_LOG_CAPACITY = 256
local LOG_THROTTLE_SECONDS = 1

type PlayerRecord = {
	strikes: number,
	lastLogTime: number,
}

local SecurityMonitor = {}

--[=[
	@prop OnSuspiciousActivity Signal<SecurityReport>
	@within SecurityMonitor
	@server
	Fires when a player's consecutive violations reach the punish threshold.
]=]
SecurityMonitor.OnSuspiciousActivity = Signal.new() :: Signal.Signal<Types.SecurityReport>

local records: { [Player]: PlayerRecord } = {}
local auditLog: { Types.AuditEntry } = {}
local auditWriteIndex = 0
local auditCount = 0

local function getRecord(player: Player): PlayerRecord
	local record = records[player]
	if record == nil then
		record = { strikes = 0, lastLogTime = -math.huge }
		records[player] = record
	end
	return record
end

local function appendAudit(entry: Types.AuditEntry)
	auditWriteIndex = auditWriteIndex % AUDIT_LOG_CAPACITY + 1
	auditLog[auditWriteIndex] = entry
	auditCount = math.min(auditCount + 1, AUDIT_LOG_CAPACITY)
end

--[=[
	@server
	Records a dropped packet. Handles strikes, the audit log, throttled
	logging, and firing the hook at the threshold.
]=]
function SecurityMonitor.reportViolation(
	player: Player,
	channelName: string,
	eventName: string?,
	kind: Types.ViolationKind,
	reason: string
)
	local record = getRecord(player)
	record.strikes += 1

	appendAudit({
		Time = os.time(),
		UserId = player.UserId,
		PlayerName = player.Name,
		Channel = channelName,
		Event = eventName,
		Kind = kind,
		Reason = reason,
	})

	local now = os.clock()
	if now - record.lastLogTime >= LOG_THROTTLE_SECONDS then
		record.lastLogTime = now
		Log.Warn(
			"[%s] %s on channel %q%s: %s (strike %d)",
			kind,
			player.Name,
			channelName,
			if eventName then ` event "{eventName}"` else "",
			reason,
			record.strikes
		)
	end

	if record.strikes >= Config.Get().RateLimit.PunishThreshold then
		local report: Types.SecurityReport = {
			Player = player,
			Channel = channelName,
			Event = eventName,
			Kind = kind,
			Reason = reason,
			Strikes = record.strikes,
		}
		record.strikes = 0
		SecurityMonitor.OnSuspiciousActivity:Fire(report)
	end
end

--[=[
	@server
	Records a packet that passed all checks: resets the player's strikes.
]=]
function SecurityMonitor.reportSuccess(player: Player)
	local record = records[player]
	if record ~= nil and record.strikes ~= 0 then
		record.strikes = 0
	end
end

--[=[
	Current consecutive strike count for a player.
]=]
function SecurityMonitor.getStrikes(player: Player): number
	local record = records[player]
	return if record then record.strikes else 0
end

--[=[
	@server
	Returns the audit log, oldest entry first (bounded to the most recent
	256). The returned array is a copy — safe to hold or serialize.
]=]
function SecurityMonitor.getAuditLog(): { Types.AuditEntry }
	local result = table.create(auditCount)
	for offset = auditCount - 1, 0, -1 do
		local index = (auditWriteIndex - 1 - offset) % AUDIT_LOG_CAPACITY + 1
		table.insert(result, auditLog[index])
	end
	return result
end

--[=[
	Drops a player's record. Called automatically on PlayerRemoving.
]=]
function SecurityMonitor.clear(player: Player)
	records[player] = nil
end

--[=[
	Test-only: resets all records and the audit log.
]=]
function SecurityMonitor.clearAll()
	table.clear(records)
	table.clear(auditLog)
	auditWriteIndex = 0
	auditCount = 0
end

if RunService:IsServer() then
	Players.PlayerRemoving:Connect(SecurityMonitor.clear)
end

return SecurityMonitor
