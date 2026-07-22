--!strict
-- End-to-end play test (Play mode in Studio, F5). Run mode: waits idle.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Network = require(ReplicatedStorage.Networking)

Network.Configure({ LogLevel = "Debug", DebugMode = true })

-- Global channel round-trip
Network.On("Ping", function(player, count)
	print(`[PlayTest/Server] Ping {count} from {player.Name} — replying Pong`)
	Network.Fire(player, "Pong", count)
end)

Network.On("UnreliablePing", function(player, count)
	print(`[PlayTest/Server] UnreliablePing {count} from {player.Name}`)
end)

-- Channel isolation: same event name ("Ping") on an isolated channel.
local Combat = Network.Channel("Combat")
Combat:On("Ping", function(player, value)
	print(`[PlayTest/Server] Combat Ping from {player.Name} — replying on Combat only`)
	Combat:Fire(player, "Pong", value * 2)
end)

-- Validation: server drops anything that isn't a single number 1..10.
local V = Network.Validators
Network.Expect("ValidatedPing", V.numberRange(1, 10))
Network.On("ValidatedPing", function(player, value)
	print(`[PlayTest/Server] ValidatedPing {value} from {player.Name} — passed validation`)
end)

-- Middleware: global observer counts every dispatched packet; a Combat
-- middleware transforms MwPing's first arg (+100) before the handler.
local packetsSeen = 0
Network.Use(function(packet)
	packetsSeen += 1
	return "Continue"
end)

Combat:Use(function(packet)
	if packet.Event == "MwPing" then
		packet.Args[1] = (packet.Args[1] :: number) + 100
		return "Continue", packet
	end
	return "Continue"
end)

Combat:Expect("MwPing", V.number)
Combat:On("MwPing", function(player, value)
	print(`[PlayTest/Server] MwPing arrived as {value} (middleware added +100)`)
	Combat:Fire(player, "MwPong", value)
end)

-- Invoke: client->server request/response, plus error/timeout paths.
Network.OnInvoke("GetServerInfo", function(player, tag)
	return `hello {player.Name} ({tag})`, workspace:GetServerTimeNow()
end)
Network.OnInvoke("Explode", function()
	error("intentional invoke handler error")
end)
Network.OnInvoke("NeverAnswered", function()
	task.wait(30) -- deliberately slower than the client's 0.5s timeout
end)

-- Defined (typed) event: schema = wire format = type = validation.
local S = Network.Schema
local TypedAttack = Combat:Define("TypedAttack", S.struct({
	Seq = S.u16,
	Power = S.int(0, 100),
	Direction = S.vec3,
}))
TypedAttack:On(function(player, value)
	print(`[PlayTest/Server] TypedAttack seq={value.Seq} power={value.Power} dir={value.Direction} — DEFINED EVENT OK`)
end)

-- Serialization: client sends a packed inventory blob; unpack and verify.
Network.On("Snapshot", function(player, blob)
	local ok, data = pcall(Network.Deserialize, blob)
	if ok then
		local inventory = data :: any
		print(`[PlayTest/Server] Snapshot: {#inventory} items, [1].id={inventory[1].id} ({buffer.len(blob)} bytes on the wire) — SERIALIZER OK`)
	else
		warn(`[PlayTest/Server] Snapshot failed to deserialize: {data}`)
	end
end)

-- Server->client invoke once the player is in.
Players.PlayerAdded:Connect(function(player)
	task.wait(2)
	Network.InvokeClient(player, "GetClientInfo")
		:AndThen(function(fps)
			print(`[PlayTest/Server] InvokeClient reply: client fps ~{fps} — SERVER->CLIENT INVOKE OK`)
		end)
		:Catch(function(reason)
			warn(`[PlayTest/Server] InvokeClient failed: {reason}`)
		end)
end)

-- Security: count how much of a 200-packet spam burst actually gets through,
-- and watch the suspicious-activity hook fire.
local spamReceived = 0
Network.On("Spam", function()
	spamReceived += 1
end)
Network.On("SpamDone", function(player)
	task.wait(0.5)
	local audit = Network.GetAuditLog()
	print(`[PlayTest/Server] Spam burst: {spamReceived}/200 passed the rate limiter; audit log has {#audit} entries`)
	print(`[PlayTest/Server] Global middleware observed {packetsSeen} dispatched packets total`)
	local stats = Network.GetStats()
	print(`[PlayTest/Server] Stats: sent={stats.Sent} received={stats.Received} dropped={stats.Dropped} rtt={stats.AverageInvokeRtt}`)
end)

Network.OnSuspiciousActivity:Connect(function(report)
	print(`[PlayTest/Server] SUSPICIOUS: {report.Player.Name} {report.Kind} x{report.Strikes} on {report.Channel} — {report.Reason}`)
	-- A real game might kick here: report.Player:Kick("Network abuse")
end)

Players.PlayerAdded:Connect(function(player)
	task.wait(1)
	Network.FireAll("Announce", `Welcome {player.Name}`)
end)

print("[PlayTest/Server] Listening. Press F5 (Play) to run the client side.")
