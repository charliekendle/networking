--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Serializer = require(ReplicatedStorage.Networking.Shared.Serialization.Serializer)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

local function roundTrip(value: unknown): unknown
	return Serializer.deserialize(Serializer.serialize(value))
end

spec["primitives round-trip"] = function(expect)
	expect.equal(roundTrip(nil), nil)
	expect.equal(roundTrip(true), true)
	expect.equal(roundTrip(false), false)
	expect.equal(roundTrip(0), 0)
	expect.equal(roundTrip(255), 255)
	expect.equal(roundTrip(-30000), -30000)
	expect.equal(roundTrip(2000000000), 2000000000)
	expect.equal(roundTrip(3.14159), 3.14159)
	expect.equal(roundTrip(-1e100), -1e100)
	expect.equal(roundTrip("hello"), "hello")
	expect.equal(roundTrip(""), "")
end

spec["small integers pack small"] = function(expect)
	expect.equal(buffer.len(Serializer.serialize(200)), 2, "u8: tag + 1 byte")
	expect.equal(buffer.len(Serializer.serialize(30000)), 3, "i16: tag + 2 bytes")
	expect.equal(buffer.len(Serializer.serialize(100000)), 5, "i32: tag + 4 bytes")
	expect.equal(buffer.len(Serializer.serialize(1.5)), 9, "f64: tag + 8 bytes")
end

spec["tables round-trip with mixed array and dict parts"] = function(expect)
	local original = {
		1, 2, 3,
		name = "sword",
		stats = { damage = 40, tags = { "sharp", "rare" } },
	}
	local result = roundTrip(original) :: any
	expect.equal(result[1], 1)
	expect.equal(result[3], 3)
	expect.equal(result.name, "sword")
	expect.equal(result.stats.damage, 40)
	expect.equal(result.stats.tags[2], "rare")
end

spec["roblox datatypes round-trip"] = function(expect)
	local vector = roundTrip(Vector3.new(1, 2, 3)) :: Vector3
	expect.truthy((vector - Vector3.new(1, 2, 3)).Magnitude < 1e-4)

	local original = CFrame.new(10, 20, 30) * CFrame.Angles(0.5, 1, 0.25)
	local cframe = roundTrip(original) :: CFrame
	expect.truthy((cframe.Position - original.Position).Magnitude < 1e-3, "position preserved")
	local dot = cframe.LookVector:Dot(original.LookVector)
	expect.truthy(dot > 0.9999, "orientation preserved")

	expect.equal(roundTrip(Color3.fromRGB(255, 128, 0)), Color3.fromRGB(255, 128, 0))
	expect.equal(roundTrip(UDim2.new(0.5, 10, 1, -20)), UDim2.new(0.5, 10, 1, -20))
	expect.equal(roundTrip(Enum.Material.Neon), Enum.Material.Neon)
	expect.equal(roundTrip(Vector2.new(3, 4)), Vector2.new(3, 4))
end

spec["nested buffers round-trip"] = function(expect)
	local inner = buffer.create(4)
	buffer.writeu32(inner, 0, 0xDEADBEEF)
	local result = roundTrip({ blob = inner }) :: any
	expect.equal(buffer.readu32(result.blob, 0), 0xDEADBEEF)
end

spec["unsupported types error"] = function(expect)
	expect.errors(function()
		Serializer.serialize(workspace)
	end)
	expect.errors(function()
		Serializer.serialize(function() end)
	end)
end

spec["cyclic tables error"] = function(expect)
	local cyclic: any = {}
	cyclic.self = cyclic
	expect.errors(function()
		Serializer.serialize(cyclic)
	end)
end

spec["corrupt buffers error instead of crashing"] = function(expect)
	expect.errors(function()
		Serializer.deserialize(buffer.create(0))
	end)
	local truncated = buffer.create(1)
	buffer.writeu8(truncated, 0, 7) -- string tag with no length
	expect.errors(function()
		Serializer.deserialize(truncated)
	end)
	local badTag = buffer.create(1)
	buffer.writeu8(badTag, 0, 250)
	expect.errors(function()
		Serializer.deserialize(badTag)
	end)
end

spec["serialized form beats naive size on real payloads"] = function(expect)
	local inventory = {}
	for index = 1, 100 do
		inventory[index] = { id = index, count = index % 50, rarity = 3 }
	end
	local blob = Serializer.serialize(inventory)
	-- 100 entries * 3 small ints, keys interned: comfortably under 2KB.
	expect.truthy(buffer.len(blob) < 2048, `packed size {buffer.len(blob)} bytes`)
	local restored = Serializer.deserialize(blob) :: any
	expect.equal(restored[100].id, 100, "interned form round-trips")
	expect.equal(restored[37].count, 37, "values intact")
end

return spec
