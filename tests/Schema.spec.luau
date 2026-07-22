--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local S = require(ReplicatedStorage.Networking.Shared.Schema.Schema)
local TestKit = require(script.Parent.TestKit)

local spec: TestKit.Spec = {}

local function roundTrip<T>(codec: S.Codec<T>, value: T): T
	return S.decode(codec, S.encode(codec, value))
end

spec["primitive codecs round-trip at exact sizes"] = function(expect)
	expect.equal(roundTrip(S.boolean, true), true)
	expect.equal(roundTrip(S.boolean, false), false)
	expect.equal(roundTrip(S.u8, 200), 200)
	expect.equal(buffer.len(S.encode(S.u8, 200)), 1, "u8 is exactly 1 byte")
	expect.equal(roundTrip(S.u16, 60000), 60000)
	expect.equal(roundTrip(S.i32, -2000000), -2000000)
	expect.equal(roundTrip(S.f64, 3.14159), 3.14159)
	expect.equal(roundTrip(S.str(20), "hello"), "hello")
	expect.equal(buffer.len(S.encode(S.str(20), "hello")), 6, "varint len + bytes")
end

spec["encode rejects values outside the schema"] = function(expect)
	expect.errors(function()
		S.encode(S.u8, 300)
	end)
	expect.errors(function()
		S.encode(S.u8, 1.5)
	end)
	expect.errors(function()
		S.encode(S.f32, 0 / 0)
	end)
	expect.errors(function()
		S.encode(S.str(3), "toolong")
	end)
	expect.errors(function()
		S.encode(S.boolean, 1 :: any)
	end)
end

spec["int picks minimal width and range-checks tighter than the width"] = function(expect)
	local power = S.int(0, 100)
	expect.equal(buffer.len(S.encode(power, 55)), 1, "0..100 packs to 1 byte")
	expect.equal(roundTrip(power, 100), 100)
	expect.errors(function()
		S.encode(power, 101)
	end)
	-- Hostile buffer: a raw byte of 200 fits u8 but violates 0..100 — decode must reject.
	local evil = buffer.create(1)
	buffer.writeu8(evil, 0, 200)
	expect.errors(function()
		S.decode(power, evil)
	end)
end

spec["decode rejects truncated, trailing, and non-finite input"] = function(expect)
	expect.errors(function()
		S.decode(S.u16, buffer.create(1)) -- truncated
	end)
	local trailing = buffer.create(3)
	buffer.writeu8(trailing, 0, 5)
	expect.errors(function()
		S.decode(S.u8, trailing) -- 2 trailing bytes
	end)
	local nanBuf = S.encode(S.f32, 1)
	buffer.writeu32(nanBuf, 0, 0x7FC00000) -- NaN bit pattern
	expect.errors(function()
		S.decode(S.f32, nanBuf)
	end)
	local badBool = buffer.create(1)
	buffer.writeu8(badBool, 0, 7)
	expect.errors(function()
		S.decode(S.boolean, badBool)
	end)
end

spec["roblox datatype codecs round-trip and stay finite"] = function(expect)
	local vector = roundTrip(S.vec3, Vector3.new(1, 2, 3))
	expect.truthy((vector - Vector3.new(1, 2, 3)).Magnitude < 1e-4)
	local original = CFrame.new(5, 6, 7) * CFrame.Angles(0.4, 0.9, 0.1)
	local cframe = roundTrip(S.cframe, original)
	expect.truthy((cframe.Position - original.Position).Magnitude < 1e-3)
	expect.truthy(cframe.LookVector:Dot(original.LookVector) > 0.9999)
	expect.equal(roundTrip(S.color3, Color3.fromRGB(10, 20, 30)), Color3.fromRGB(10, 20, 30))
	expect.errors(function()
		S.encode(S.vec3, Vector3.new(0 / 0, 0, 0))
	end)
end

spec["optional, array, literals"] = function(expect)
	local maybe = S.optional(S.u8)
	expect.equal(roundTrip(maybe, nil), nil)
	expect.equal(roundTrip(maybe, 9), 9)

	local list = S.array(S.u16, 5)
	local values = roundTrip(list, { 1, 2, 3 })
	expect.equal(values[3], 3)
	expect.errors(function()
		S.encode(list, { 1, 2, 3, 4, 5, 6 })
	end)
	-- Hostile count: claims 100 entries against max 5.
	local evil = buffer.create(1)
	buffer.writeu8(evil, 0, 100)
	expect.errors(function()
		S.decode(list, evil)
	end)

	local action = S.literals("Buy", "Sell")
	expect.equal(roundTrip(action, "Sell"), "Sell")
	expect.equal(buffer.len(S.encode(action, "Buy")), 1, "literal is 1 byte")
	expect.errors(function()
		S.encode(action, "Steal")
	end)
	local badIndex = buffer.create(1)
	buffer.writeu8(badIndex, 0, 9)
	expect.errors(function()
		S.decode(action, badIndex)
	end)
end

spec["struct packs fields without key names and stays strict"] = function(expect)
	local attack = S.struct({ Seq = S.u16, Power = S.int(0, 100), Direction = S.vec3 })
	local value = roundTrip(attack, { Seq = 7, Power = 55, Direction = Vector3.new(0, 1, 0) })
	expect.equal(value.Seq, 7)
	expect.equal(value.Power, 55)
	-- Wire cost: u16(2) + u8(1) + vec3(12) = 15 bytes, zero key overhead.
	expect.equal(buffer.len(S.encode(attack, { Seq = 7, Power = 55, Direction = Vector3.zero })), 15)
	expect.errors(function()
		S.encode(attack, { Seq = 7, Power = 55, Direction = Vector3.zero, Extra = true } :: any)
	end)
	expect.errors(function()
		S.encode(attack, { Seq = 7, Power = 55 } :: any) -- missing field
	end)
end

spec["nested composites round-trip"] = function(expect)
	local item = S.struct({ Id = S.str(30), Count = S.u16 })
	local snapshot = S.struct({ Version = S.u8, Items = S.array(item, 50) })
	local value = roundTrip(snapshot, {
		Version = 3,
		Items = { { Id = "sword", Count = 2 }, { Id = "shield", Count = 1 } },
	})
	expect.equal(value.Version, 3)
	expect.equal(value.Items[2].Id, "shield")
end

return spec
