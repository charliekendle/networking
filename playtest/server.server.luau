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

Players.PlayerAdded:Connect(function(player)
	task.wait(1)
	Network.FireAll("Announce", `Welcome {player.Name}`)
end)

print("[PlayTest/Server] Listening. Press F5 (Play) to run the client side.")
