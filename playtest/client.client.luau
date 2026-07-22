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

-- Middleware demo: server-side Combat middleware adds +100 before the
-- handler; expect MwPong 101 back.
Combat:On("MwPong", function(value)
	if value == 101 then
		print(`[PlayTest/Client] MwPong {value} received — MIDDLEWARE TRANSFORM OK`)
	else
		warn(`[PlayTest/Client] MwPong {value} received — expected 101!`)
	end
end)
Combat:Fire("MwPing", 1)

-- Validation demo: only the first should reach the server handler.
-- The other three must produce "Rejected" warns server-side and nothing else.
Network.Fire("ValidatedPing", 5)          -- valid
Network.Fire("ValidatedPing", 999)        -- out of range -> rejected
Network.Fire("ValidatedPing", "not num")  -- wrong type -> rejected
Network.Fire("ValidatedPing", 5, "extra") -- extra arg -> rejected

-- Fires "Ping" on Combat: must reach ONLY the Combat listener server-side,
-- and its Pong must reach ONLY the Combat listener here (value 42 * 2 = 84).
Combat:Fire("Ping", 42)

-- Invoke demos: happy path, sanitized handler error, missing handler,
-- and a fast timeout.
Network.OnInvoke("GetClientInfo", function()
	return math.floor(1 / game:GetService("RunService").RenderStepped:Wait())
end)

Network.Invoke("GetServerInfo", "playtest")
	:AndThen(function(message, serverTime)
		print(`[PlayTest/Client] Invoke reply: "{message}" at {math.floor(serverTime)} — CLIENT->SERVER INVOKE OK`)
	end)
	:Catch(function(reason)
		warn(`[PlayTest/Client] GetServerInfo failed: {reason}`)
	end)

Network.Invoke("Explode"):Catch(function(reason)
	print(`[PlayTest/Client] Explode rejected with "{reason}" — SANITIZED ERROR OK`)
end)

Network.Invoke("NoSuchHandler"):Catch(function(reason)
	print(`[PlayTest/Client] NoSuchHandler rejected with "{reason}" — MISSING HANDLER OK`)
end)

Network.InvokeWithOptions({ Timeout = 0.5 }, "NeverAnswered"):Catch(function(reason)
	print(`[PlayTest/Client] NeverAnswered rejected with "{reason}" — TIMEOUT OK`)
end)

-- Serialization: pack 100 inventory rows into one buffer.
local inventory = {}
for index = 1, 100 do
	inventory[index] = { id = index, count = index % 50, rarity = 3 }
end
Network.Fire("Snapshot", Network.Serialize(inventory))

-- Security demo LAST (drains the Global bucket): 200-packet burst.
-- Default limits (60/s + 20 burst) should let ~80 through and drop the rest,
-- firing SUSPICIOUS lines server-side. Legit traffic above already completed.
task.wait(1)
for _ = 1, 200 do
	Network.Fire("Spam")
end
task.wait(1.5) -- let the bucket refill so SpamDone itself isn't rate-limited
Network.Fire("SpamDone")
