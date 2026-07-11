--!strict
-- End-to-end play test (Play mode in Studio, F5). Run mode: waits idle.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Network = require(ReplicatedStorage.Networking)

Network.Configure({ LogLevel = "Debug", DebugMode = true })

Network.On("Ping", function(player, count)
	print(`[PlayTest/Server] Ping {count} from {player.Name} — replying Pong`)
	Network.Fire(player, "Pong", count)
end)

Network.On("UnreliablePing", function(player, count)
	print(`[PlayTest/Server] UnreliablePing {count} from {player.Name}`)
end)

Players.PlayerAdded:Connect(function(player)
	task.wait(1)
	Network.FireAll("Announce", `Welcome {player.Name}`)
end)

print("[PlayTest/Server] Listening. Press F5 (Play) to run the client side.")
