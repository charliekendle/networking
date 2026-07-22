--!strict
-- Example: reacting to abuse and tightening limits live.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(ReplicatedStorage.Packages.Networking)

local strikesByUser: { [number]: number } = {}

Network.OnSuspiciousActivity:Connect(function(report)
	local count = (strikesByUser[report.Player.UserId] or 0) + 1
	strikesByUser[report.Player.UserId] = count

	warn(`[Security] {report.Player.Name}: {report.Kind} x{report.Strikes} on {report.Channel} — {report.Reason}`)

	-- Escalate: first report warn, repeated reports kick.
	if count >= 3 and report.Kind == "RateLimit" then
		report.Player:Kick("Network abuse detected")
	end
end)

-- Admin command hook: dump recent drops, tighten limits mid-incident.
local function onAdminAuditCommand()
	for _, entry in Network.GetAuditLog() do
		print(entry.Time, entry.PlayerName, entry.Channel, entry.Kind, entry.Reason)
	end
end

local function onAdminLockdownCommand()
	Network.Configure({ RateLimit = { MaxPacketsPerSecond = 15, BurstAllowance = 5 } })
end

local _, _ = onAdminAuditCommand, onAdminLockdownCommand
