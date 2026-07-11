--!strict
-- Minimal Step 1 example: configuring the library and reacting to changes.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(ReplicatedStorage.Packages.Networking)

Network.ConfigChanged:Connect(function(config)
	print("Networking config updated; debug mode:", config.DebugMode)
end)

Network.Configure({
	DebugMode = true,
	LogLevel = "Debug",
	RateLimit = { MaxPacketsPerSecond = 30 },
})
