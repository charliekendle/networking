--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local V = require(ReplicatedStorage.Networking.Shared.Validation.Validators)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

spec["primitives accept and reject correctly"] = function(expect)
	expect.truthy(V.boolean(true))
	expect.falsy(V.boolean(1))
	expect.truthy(V.string("hi"))
	expect.falsy(V.string(nil))
	expect.truthy(V.table({}))
	expect.falsy(V.table("no"))
	expect.truthy(V.any(nil))
	expect.truthy(V.buffer(buffer.create(4)))
	expect.falsy(V.buffer("no"))
end

spec["number rejects NaN and inf, numberRaw allows"] = function(expect)
	expect.truthy(V.number(5.5))
	expect.falsy(V.number(0 / 0), "NaN rejected")
	expect.falsy(V.number(math.huge), "inf rejected")
	expect.falsy(V.number(-math.huge), "-inf rejected")
	expect.truthy(V.numberRaw(0 / 0), "raw allows NaN")
	expect.truthy(V.integer(5))
	expect.falsy(V.integer(5.5))
end

spec["ranges enforce bounds"] = function(expect)
	local range = V.numberRange(0, 100)
	expect.truthy(range(0))
	expect.truthy(range(100))
	expect.falsy(range(-1))
	expect.falsy(range(101))
	expect.falsy(range(0 / 0), "NaN never passes a range")
	local intRange = V.integerRange(1, 10)
	expect.truthy(intRange(10))
	expect.falsy(intRange(5.5))
	expect.errors(function()
		V.numberRange(10, 1)
	end)
end

spec["string constraints"] = function(expect)
	expect.truthy(V.stringMaxLength(5)("abc"))
	expect.falsy(V.stringMaxLength(5)("abcdef"))
	expect.truthy(V.match("^%d+$")("12345"))
	expect.falsy(V.match("^%d+$")("12a45"))
end

spec["optional, literal, union"] = function(expect)
	local optionalNumber = V.optional(V.number)
	expect.truthy(optionalNumber(nil))
	expect.truthy(optionalNumber(5))
	expect.falsy(optionalNumber("no"))
	expect.truthy(V.literal("Buy")("Buy"))
	expect.falsy(V.literal("Buy")("Sell"))
	local action = V.union(V.literal("Buy"), V.literal("Sell"))
	expect.truthy(action("Sell"))
	expect.falsy(action("Steal"))
end

spec["array enforces contiguity, holes, and max length"] = function(expect)
	local numbers = V.array(V.number)
	expect.truthy(numbers({ 1, 2, 3 }))
	expect.truthy(numbers({}))
	expect.falsy(numbers({ 1, "two" :: any, 3 }))
	expect.falsy(numbers({ [1] = 1, [3] = 3 }), "holes rejected")
	expect.falsy(numbers({ x = 1 }), "string keys rejected")
	expect.falsy(V.array(V.number, 2)({ 1, 2, 3 }), "max length enforced")
end

spec["dict and interfaces"] = function(expect)
	local prices = V.dict(V.string, V.number)
	expect.truthy(prices({ apple = 1, pear = 2 }))
	expect.falsy(prices({ apple = "one" }))

	local offer = V.strictInterface({ ItemId = V.string, Amount = V.integer })
	expect.truthy(offer({ ItemId = "sword", Amount = 1 }))
	expect.falsy(offer({ ItemId = "sword" }), "missing field")
	expect.falsy(offer({ ItemId = "sword", Amount = 1, Extra = true }), "extra field rejected")

	local loose = V.interface({ ItemId = V.string })
	expect.truthy(loose({ ItemId = "sword", Extra = true }), "loose allows extras")
end

spec["roblox datatypes reject non-finite components"] = function(expect)
	expect.truthy(V.vector3(Vector3.new(1, 2, 3)))
	expect.falsy(V.vector3(Vector3.new(0 / 0, 0, 0)), "NaN Vector3")
	expect.falsy(V.vector3("no"))
	expect.truthy(V.vector2(Vector2.new(1, 2)))
	expect.truthy(V.cframe(CFrame.new(1, 2, 3)))
	expect.falsy(V.cframe(CFrame.new(math.huge, 0, 0)), "inf CFrame")
	expect.truthy(V.color3(Color3.new(1, 0, 0)))
	expect.truthy(V.udim2(UDim2.fromScale(1, 1)))
	expect.truthy(V.enumItem(Enum.Material)(Enum.Material.Grass))
	expect.falsy(V.enumItem(Enum.Material)(Enum.KeyCode.A))
	expect.truthy(V.instance(workspace))
	expect.truthy(V.instanceIsA("BasePart")(Instance.new("Part")))
	expect.falsy(V.instanceIsA("BasePart")(Instance.new("Folder")))
end

spec["custom wraps plain predicates"] = function(expect)
	local even = V.custom(function(value)
		return type(value) == "number" and value % 2 == 0
	end, "even")
	expect.truthy(even(4))
	local ok, reason = even(3)
	expect.falsy(ok)
	expect.truthy(reason and string.find(reason, "even"), "reason names the validator")
end

return spec
