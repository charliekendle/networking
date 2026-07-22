--!strict
-- Client half of the combat example.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(ReplicatedStorage:WaitForChild("Packages").Networking)

local Combat = Network.Channel("Combat")

Combat:On("HitEffect", function(position: Vector3, damage: number)
	-- spawn particles / damage number at `position`
	print(`hit for {damage} at {position}`)
end)

-- Somewhere in your input handling:
local function onAttackInput(target: Model)
	Combat:Fire("Attack", target, 25)
end

local _ = onAttackInput
