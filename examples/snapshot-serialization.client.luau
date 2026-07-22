--!strict
-- Client half: always pcall deserialization of remote-supplied buffers.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(ReplicatedStorage:WaitForChild("Packages").Networking)

local World = Network.Channel("World")

World:On("Snapshot", function(blob: buffer)
	local ok, snapshot = pcall(function()
		return Network.Deserialize(Network.Decompress(blob))
	end)
	if not ok then
		warn("bad snapshot:", snapshot)
		return
	end
	local data = snapshot :: any
	print(`world snapshot v{data.version}: {#data.tiles} tiles`)
end)
