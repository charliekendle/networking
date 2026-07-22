--!strict
-- Example: a locked-down combat channel — schema, permission gate, spatial fire.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(ReplicatedStorage.Packages.Networking)
local V = Network.Validators

local Combat = Network.Channel("Combat")

-- Every argument constrained; NaN/inf and extra args rejected automatically.
Combat:Expect("Attack", V.instanceIsA("Model"), V.numberRange(0, 100))

-- Permission gate: runs after rate limit + schema, before the handler.
Combat:Use(function(packet)
	local player = packet.Player
	if player and player:GetAttribute("Stunned") then
		return "Drop"
	end
	return "Continue"
end)

Combat:On("Attack", function(player, targetModel, damage)
	local humanoid = targetModel:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	humanoid:TakeDamage(damage)

	-- Only players near the hit see the effect — not the whole server.
	local root = targetModel.PrimaryPart
	if root then
		Combat:FireNearby(root.Position, 60, "HitEffect", root.Position, damage)
	end
end)
