--!strict
-- Client half of the play test. Fires Ping x3, expects Pong x3 + Announce.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(ReplicatedStorage:WaitForChild("Networking"))

Network.Configure({ LogLevel = "Debug", DebugMode = true })

local pongs = 0
Network.On("Pong", function(count)
	pongs += 1
	print(`[PlayTest/Client] Pong {count} received ({pongs}/3)`)
	if pongs == 3 then
		print("[PlayTest/Client] ALL PONGS RECEIVED — transport round-trip OK")
	end
end)

Network.On("Announce", function(message)
	print(`[PlayTest/Client] Announce: {message}`)
end)

for count = 1, 3 do
	Network.Fire("Ping", count)
end
Network.FireUnreliable("UnreliablePing", 1)
