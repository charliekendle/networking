--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Networking.Shared.Config)
local SecurityMonitor = require(ReplicatedStorage.Networking.Shared.Security.SecurityMonitor)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

local function fakePlayer(name: string): Player
	return { Name = name, UserId = -1 } :: any
end

spec["hook fires at the punish threshold and resets"] = function(expect)
	Config.Reset()
	Config.Set({ RateLimit = { PunishThreshold = 3 } })
	SecurityMonitor.clearAll()
	local player = fakePlayer("Abuser")

	local reports = 0
	local lastStrikes = 0
	local connection = SecurityMonitor.OnSuspiciousActivity:Connect(function(report)
		reports += 1
		lastStrikes = report.Strikes
	end)

	for _ = 1, 6 do
		SecurityMonitor.reportViolation(player, "Combat", "Damage", "Validation", "test")
	end
	task.wait()
	connection:Disconnect()

	expect.equal(reports, 2, "fires every threshold crossing")
	expect.equal(lastStrikes, 3)
	expect.equal(SecurityMonitor.getStrikes(player), 0, "resets after firing")
	Config.Reset()
end

spec["success resets strikes"] = function(expect)
	Config.Reset()
	SecurityMonitor.clearAll()
	local player = fakePlayer("Redeemed")

	SecurityMonitor.reportViolation(player, "Combat", nil, "RateLimit", "test")
	SecurityMonitor.reportViolation(player, "Combat", nil, "RateLimit", "test")
	expect.equal(SecurityMonitor.getStrikes(player), 2)
	SecurityMonitor.reportSuccess(player)
	expect.equal(SecurityMonitor.getStrikes(player), 0)
end

spec["audit log records entries oldest-first with details"] = function(expect)
	SecurityMonitor.clearAll()
	local player = fakePlayer("Audited")

	SecurityMonitor.reportViolation(player, "Combat", "Damage", "Validation", "first")
	SecurityMonitor.reportViolation(player, "Trading", nil, "RateLimit", "second")

	local log = SecurityMonitor.getAuditLog()
	expect.equal(#log, 2)
	expect.equal(log[1].Reason, "first")
	expect.equal(log[1].Event, "Damage")
	expect.equal(log[1].Kind, "Validation")
	expect.equal(log[2].Reason, "second")
	expect.equal(log[2].Channel, "Trading")
	expect.equal(log[2].PlayerName, "Audited")
end

spec["audit log is bounded to capacity"] = function(expect)
	SecurityMonitor.clearAll()
	local player = fakePlayer("Flood")

	for index = 1, 300 do
		SecurityMonitor.reportViolation(player, "Combat", nil, "RateLimit", tostring(index))
	end
	local log = SecurityMonitor.getAuditLog()
	expect.equal(#log, 256, "capped at 256")
	expect.equal(log[1].Reason, "45", "oldest retained entry is #45")
	expect.equal(log[256].Reason, "300", "newest entry is last")
end

spec["strikes are per player"] = function(expect)
	SecurityMonitor.clearAll()
	local alice = fakePlayer("Alice")
	local bob = fakePlayer("Bob")

	SecurityMonitor.reportViolation(alice, "Combat", nil, "RateLimit", "test")
	expect.equal(SecurityMonitor.getStrikes(alice), 1)
	expect.equal(SecurityMonitor.getStrikes(bob), 0)
end

return spec
