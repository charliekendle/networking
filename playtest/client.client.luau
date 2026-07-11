--!strict
-- Client half of the play test. Global Ping x3 + Combat channel isolation.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(ReplicatedStorage:WaitForChild("Networking"))

Network.Configure({ LogLevel = "Debug", DebugMode = true })

local pongs = 0
Network.On("Pong", function(count)
	pongs += 1
	print(`[PlayTest/Client] Global Pong {count} received ({pongs}/3)`)
	if pongs == 3 then
		print("[PlayTest/Client] ALL GLOBAL PONGS RECEIVED — transport round-trip OK")
	end
end)

Network.On("Announce", function(message)
	print(`[PlayTest/Client] Announce: {message}`)
end)

local Combat = Network.Channel("Combat")
Combat:On("Pong", function(value)
	print(`[PlayTest/Client] Combat Pong {value} received — CHANNEL ISOLATION OK`)
end)

for count = 1, 3 do
	Network.Fire("Ping", count)
end
Network.FireUnreliable("UnreliablePing", 1)

-- Validation demo: only the first should reach the server handler.
-- The other three must produce "Rejected" warns server-side and nothing else.
Network.Fire("ValidatedPing", 5)          -- valid
Network.Fire("ValidatedPing", 999)        -- out of range -> rejected
Network.Fire("ValidatedPing", "not num")  -- wrong type -> rejected
Network.Fire("ValidatedPing", 5, "extra") -- extra arg -> rejected

-- Fires "Ping" on Combat: must reach ONLY the Combat listener server-side,
-- and its Pong must reach ONLY the Combat listener here (value 42 * 2 = 84).
Combat:Fire("Ping", 42)

-- Security demo LAST (drains the Global bucket): 200-packet burst.
-- Default limits (60/s + 20 burst) should let ~80 through and drop the rest,
-- firing SUSPICIOUS lines server-side. Legit traffic above already completed.
task.wait(1)
for _ = 1, 200 do
	Network.Fire("Spam")
end
task.wait(1.5) -- let the bucket refill so SpamDone itself isn't rate-limited
Network.Fire("SpamDone")
