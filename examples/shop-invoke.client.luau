--!strict
-- Client half of the shop example: promise and await styles.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(ReplicatedStorage:WaitForChild("Packages").Networking)

local Shop = Network.Channel("Shop")

-- Promise style
Shop:Invoke("GetCatalog")
	:AndThen(function(catalog)
		for id, item in catalog :: { [string]: any } do
			print(id, item.name, item.price)
		end
	end)
	:Catch(warn)

-- Await style with explicit timeout + one retry
task.spawn(function()
	local ok, success, result = Shop:InvokeWithOptions({ Timeout = 5, Retries = 1 }, "Purchase", "sword_01"):Await()
	if not ok then
		warn("purchase failed:", success) -- transport-level: InvokeTimeout etc.
	elseif success then
		print("bought:", result)
	else
		print("shop said no:", result) -- application-level: NoSuchItem
	end
end)
