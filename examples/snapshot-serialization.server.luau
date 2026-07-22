--!strict
-- Example: sending a large state snapshot as one packed (and compressed) buffer.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Network = require(ReplicatedStorage.Packages.Networking)

local World = Network.Channel("World")

local function buildSnapshot(): { [string]: any }
	local tiles = {}
	for index = 1, 500 do
		tiles[index] = { id = index, kind = "grass", height = index % 7 }
	end
	return { version = 3, tiles = tiles }
end

Players.PlayerAdded:Connect(function(player)
	local snapshot = buildSnapshot()
	-- Serialize packs it; Compress squeezes the repetition. One buffer arg.
	local blob = Network.Compress(Network.Serialize(snapshot))
	World:Fire(player, "Snapshot", blob)
end)
