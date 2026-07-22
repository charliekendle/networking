--!strict
-- Example: request/response shop with validated invokes.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(ReplicatedStorage.Packages.Networking)
local V = Network.Validators

local Shop = Network.Channel("Shop")

local CATALOG = {
	sword_01 = { price = 100, name = "Iron Sword" },
	shield_01 = { price = 80, name = "Oak Shield" },
}

-- Schemas apply to invoke arguments too.
Shop:Expect("GetCatalog", V.optional(V.stringMaxLength(30)))
Shop:OnInvoke("GetCatalog", function(_player, _category)
	return CATALOG
end)

Shop:Expect("Purchase", V.stringMaxLength(50))
Shop:OnInvoke("Purchase", function(player, itemId)
	local item = CATALOG[itemId]
	if item == nil then
		return false, "NoSuchItem"
	end
	-- ... check & deduct currency, grant item (may yield: DataStores etc.)
	print(`{player.Name} bought {item.name}`)
	return true, item.name
end)
