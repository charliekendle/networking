--!strict
--[=[
	@class Schema

	Typed codecs for **defined events** (`channel:Define`). Unlike
	`Network.Validators` (runtime gatekeepers only), a Schema codec does
	triple duty:

	1. **Wire format** — the payload is packed by the schema into a single
	   buffer (`u8` really is one byte on the wire).
	2. **Static types** — codecs carry a phantom type, so `Define`d handles
	   give real Luau inference on Fire/On.
	3. **Validation by construction** — decode bounds-checks every read; a
	   value that violates the schema cannot come out of it, so defined
	   events skip the runtime validator pass entirely.

	```lua
	local S = Network.Schema

	-- shared module, required by both server and client
	local AttackDef = Combat:Define("Attack", S.struct({
		Seq = S.u16,
		Direction = S.vec3,
		Power = S.int(0, 100),
	}))

	-- Server: value is fully typed
	AttackDef:On(function(player, value)
		print(value.Seq, value.Direction, value.Power)
	end)

	-- Client
	AttackDef:Fire({ Seq = 1, Direction = dir, Power = 55 })
	```

	Numbers: `f32`/`f64` and vector/CFrame components reject NaN/±inf on
	both encode and decode. `int(min, max)` picks the smallest integer width
	automatically and range-checks on decode — an out-of-range value from a
	hostile client is a decode error, dropped and striked upstream.
]=]

local BufferIO = require(script.Parent.Parent.Serialization.BufferIO)

local Schema = {}

export type Codec<T> = {
	__codec: true,
	check: (value: unknown) -> (boolean, string?),
	encode: (writer: BufferIO.Writer, value: T) -> (),
	decode: (reader: BufferIO.Reader) -> T,
}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function make<T>(
	check: (value: unknown) -> (boolean, string?),
	encode: (writer: BufferIO.Writer, value: T) -> (),
	decode: (reader: BufferIO.Reader) -> T
): Codec<T>
	return { __codec = true :: true, check = check, encode = encode, decode = decode }
end

--[=[ True if the value is a Schema codec. ]=]
function Schema.is(value: unknown): boolean
	return type(value) == "table" and (value :: any).__codec == true
end

-- Primitives ------------------------------------------------------------

Schema.boolean = make(function(value)
	if type(value) == "boolean" then
		return true
	end
	return false, `expected boolean, got {typeof(value)}`
end, function(writer, value: boolean)
	BufferIO.writeU8(writer, if value then 1 else 0)
end, function(reader): boolean
	local byte = BufferIO.readU8(reader)
	assert(byte == 0 or byte == 1, "Decode: invalid boolean")
	return byte == 1
end) :: Codec<boolean>

local function intCodec(min: number, max: number, write, read): Codec<number>
	return make(function(value)
		if type(value) ~= "number" or value % 1 ~= 0 or value ~= value then
			return false, `expected integer, got {typeof(value)}`
		end
		if (value :: number) < min or (value :: number) > max then
			return false, `expected {min}..{max}, got {value}`
		end
		return true
	end, function(writer, value: number)
		write(writer, value)
	end, function(reader): number
		local value = read(reader)
		assert(value >= min and value <= max, `Decode: {value} outside {min}..{max}`)
		return value
	end)
end

Schema.u8 = intCodec(0, 255, BufferIO.writeU8, BufferIO.readU8)
Schema.u16 = intCodec(0, 65535, BufferIO.writeU16, BufferIO.readU16)
Schema.u32 = intCodec(0, 4294967295, BufferIO.writeU32, BufferIO.readU32)
Schema.i16 = intCodec(-32768, 32767, BufferIO.writeI16, BufferIO.readI16)
Schema.i32 = intCodec(-2147483648, 2147483647, BufferIO.writeI32, BufferIO.readI32)

--[=[
	Whole number within [min, max]. Picks the smallest wire width that fits
	the range (1, 2, or 4 bytes) and range-checks on decode — tighter than
	the raw width, so `int(0, 100)` rejects 200 even though it fits a u8.
]=]
function Schema.int(min: number, max: number): Codec<number>
	assert(min % 1 == 0 and max % 1 == 0 and min <= max, "int(min, max): integer bounds, min <= max")
	local write, read
	if min >= 0 and max <= 255 then
		write, read = BufferIO.writeU8, BufferIO.readU8
	elseif min >= -32768 and max <= 32767 then
		write, read = BufferIO.writeI16, BufferIO.readI16
	elseif min >= 0 and max <= 4294967295 then
		write, read = BufferIO.writeU32, BufferIO.readU32
	elseif min >= -2147483648 and max <= 2147483647 then
		write, read = BufferIO.writeI32, BufferIO.readI32
	else
		error("int(min, max): range exceeds 32-bit integers; use f64")
	end
	return intCodec(min, max, write, read)
end

local function floatCodec(write, read, bits: string): Codec<number>
	return make(function(value)
		if type(value) ~= "number" then
			return false, `expected number, got {typeof(value)}`
		end
		if not isFinite(value :: number) then
			return false, "expected finite number, got NaN/inf"
		end
		return true
	end, function(writer, value: number)
		write(writer, value)
	end, function(reader): number
		local value = read(reader)
		assert(isFinite(value), `Decode: non-finite {bits}`)
		return value
	end)
end

Schema.f32 = floatCodec(BufferIO.writeF32, BufferIO.readF32, "f32")
Schema.f64 = floatCodec(BufferIO.writeF64, BufferIO.readF64, "f64")

--[=[ UTF-8 string up to maxBytes (wire cost: varint length + bytes). ]=]
function Schema.str(maxBytes: number): Codec<string>
	assert(type(maxBytes) == "number" and maxBytes >= 0, "str(maxBytes)")
	return make(function(value)
		if type(value) ~= "string" then
			return false, `expected string, got {typeof(value)}`
		end
		if #(value :: string) > maxBytes then
			return false, `string exceeds {maxBytes} bytes (got {#(value :: string)})`
		end
		return true
	end, function(writer, value: string)
		BufferIO.writeRawString(writer, value)
	end, function(reader): string
		local length = BufferIO.readVarint(reader)
		assert(length <= maxBytes, `Decode: string exceeds {maxBytes} bytes`)
		BufferIO.need(reader, length)
		local value = buffer.readstring(reader.buf, reader.cursor, length)
		reader.cursor += length
		return value
	end)
end

--[=[ Raw buffer up to maxBytes. ]=]
function Schema.buf(maxBytes: number): Codec<buffer>
	assert(type(maxBytes) == "number" and maxBytes >= 0, "buf(maxBytes)")
	return make(function(value)
		if typeof(value) ~= "buffer" then
			return false, `expected buffer, got {typeof(value)}`
		end
		if buffer.len(value :: buffer) > maxBytes then
			return false, `buffer exceeds {maxBytes} bytes`
		end
		return true
	end, function(writer, value: buffer)
		BufferIO.writeVarint(writer, buffer.len(value))
		BufferIO.writeBytes(writer, value)
	end, function(reader): buffer
		local length = BufferIO.readVarint(reader)
		assert(length <= maxBytes, `Decode: buffer exceeds {maxBytes} bytes`)
		return BufferIO.readBytes(reader, length)
	end)
end

-- Roblox datatypes ------------------------------------------------------

local function finiteF32(reader: BufferIO.Reader, what: string): number
	local value = BufferIO.readF32(reader)
	assert(isFinite(value), `Decode: non-finite {what}`)
	return value
end

Schema.vec3 = make(function(value)
	if typeof(value) ~= "Vector3" then
		return false, `expected Vector3, got {typeof(value)}`
	end
	local vector = value :: Vector3
	if not (isFinite(vector.X) and isFinite(vector.Y) and isFinite(vector.Z)) then
		return false, "Vector3 has non-finite components"
	end
	return true
end, function(writer, value: Vector3)
	BufferIO.writeF32(writer, value.X)
	BufferIO.writeF32(writer, value.Y)
	BufferIO.writeF32(writer, value.Z)
end, function(reader): Vector3
	return Vector3.new(finiteF32(reader, "Vector3"), finiteF32(reader, "Vector3"), finiteF32(reader, "Vector3"))
end) :: Codec<Vector3>

Schema.vec2 = make(function(value)
	if typeof(value) ~= "Vector2" then
		return false, `expected Vector2, got {typeof(value)}`
	end
	local vector = value :: Vector2
	if not (isFinite(vector.X) and isFinite(vector.Y)) then
		return false, "Vector2 has non-finite components"
	end
	return true
end, function(writer, value: Vector2)
	BufferIO.writeF32(writer, value.X)
	BufferIO.writeF32(writer, value.Y)
end, function(reader): Vector2
	return Vector2.new(finiteF32(reader, "Vector2"), finiteF32(reader, "Vector2"))
end) :: Codec<Vector2>

Schema.cframe = make(function(value)
	if typeof(value) ~= "CFrame" then
		return false, `expected CFrame, got {typeof(value)}`
	end
	local position = (value :: CFrame).Position
	if not (isFinite(position.X) and isFinite(position.Y) and isFinite(position.Z)) then
		return false, "CFrame has non-finite position"
	end
	return true
end, function(writer, value: CFrame)
	local position = value.Position
	BufferIO.writeF32(writer, position.X)
	BufferIO.writeF32(writer, position.Y)
	BufferIO.writeF32(writer, position.Z)
	local axis, angle = value:ToAxisAngle()
	BufferIO.writeF32(writer, axis.X)
	BufferIO.writeF32(writer, axis.Y)
	BufferIO.writeF32(writer, axis.Z)
	BufferIO.writeF32(writer, angle)
end, function(reader): CFrame
	local position = Vector3.new(finiteF32(reader, "CFrame"), finiteF32(reader, "CFrame"), finiteF32(reader, "CFrame"))
	local axis = Vector3.new(finiteF32(reader, "CFrame"), finiteF32(reader, "CFrame"), finiteF32(reader, "CFrame"))
	local angle = finiteF32(reader, "CFrame")
	if axis.Magnitude < 1e-6 then
		return CFrame.new(position)
	end
	return CFrame.fromAxisAngle(axis.Unit, angle) + position
end) :: Codec<CFrame>

Schema.color3 = make(function(value)
	if typeof(value) == "Color3" then
		return true
	end
	return false, `expected Color3, got {typeof(value)}`
end, function(writer, value: Color3)
	BufferIO.writeU8(writer, math.clamp(math.floor(value.R * 255 + 0.5), 0, 255))
	BufferIO.writeU8(writer, math.clamp(math.floor(value.G * 255 + 0.5), 0, 255))
	BufferIO.writeU8(writer, math.clamp(math.floor(value.B * 255 + 0.5), 0, 255))
end, function(reader): Color3
	return Color3.fromRGB(BufferIO.readU8(reader), BufferIO.readU8(reader), BufferIO.readU8(reader))
end) :: Codec<Color3>

-- Composites ------------------------------------------------------------

--[=[ Value may be nil (1 flag byte on the wire). ]=]
function Schema.optional<T>(inner: Codec<T>): Codec<T?>
	assert(Schema.is(inner), "optional expects a codec")
	return make(function(value)
		if value == nil then
			return true
		end
		return inner.check(value)
	end, function(writer, value: T?)
		if value == nil then
			BufferIO.writeU8(writer, 0)
		else
			BufferIO.writeU8(writer, 1)
			inner.encode(writer, value)
		end
	end, function(reader): T?
		local flag = BufferIO.readU8(reader)
		assert(flag == 0 or flag == 1, "Decode: invalid optional flag")
		if flag == 0 then
			return nil
		end
		return inner.decode(reader)
	end)
end

--[=[ Contiguous array of `element`, up to maxLength (default 1000). ]=]
function Schema.array<T>(element: Codec<T>, maxLength: number?): Codec<{ T }>
	assert(Schema.is(element), "array expects a codec")
	local limit = maxLength or 1000
	return make(function(value)
		if type(value) ~= "table" then
			return false, `expected array, got {typeof(value)}`
		end
		local target = value :: { unknown }
		local length = #target
		if length > limit then
			return false, `array exceeds max length {limit}`
		end
		local seen = 0
		for key, item in target :: { [unknown]: unknown } do
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
				return false, `non-array key {tostring(key)}`
			end
			seen += 1
			local ok, reason = element.check(item)
			if not ok then
				return false, `[{key}]: {reason or "invalid"}`
			end
		end
		if seen ~= length then
			return false, "array has holes"
		end
		return true
	end, function(writer, value: { T })
		BufferIO.writeVarint(writer, #value)
		for _, item in value do
			element.encode(writer, item)
		end
	end, function(reader): { T }
		local count = BufferIO.readVarint(reader)
		assert(count <= limit, `Decode: array exceeds max length {limit}`)
		local result = table.create(count)
		for index = 1, count do
			result[index] = element.decode(reader)
		end
		return result
	end)
end

--[=[
	Fixed-shape table. Fields are encoded in deterministic (sorted key)
	order with no key names on the wire — a 3-field struct costs exactly its
	3 values. Extra fields are rejected on encode-side check; missing or
	wrong-typed fields fail their field codec.
]=]
function Schema.struct(shape: { [string]: Codec<any> }): Codec<{ [string]: any }>
	assert(type(shape) == "table", "struct expects a shape table")
	local keys: { string } = {}
	for key, codec in shape do
		assert(type(key) == "string", "struct keys must be strings")
		assert(Schema.is(codec), `struct field "{key}" is not a codec`)
		table.insert(keys, key)
	end
	assert(#keys > 0, "struct requires at least one field")
	table.sort(keys)

	return make(function(value)
		if type(value) ~= "table" then
			return false, `expected table, got {typeof(value)}`
		end
		local target = value :: { [unknown]: unknown }
		for _, key in keys do
			local ok, reason = shape[key].check(target[key])
			if not ok then
				return false, `.{key}: {reason or "invalid"}`
			end
		end
		for key in target do
			if type(key) ~= "string" or shape[key :: string] == nil then
				return false, `unexpected field {tostring(key)}`
			end
		end
		return true
	end, function(writer, value: { [string]: any })
		for _, key in keys do
			shape[key].encode(writer, value[key])
		end
	end, function(reader): { [string]: any }
		local result: { [string]: any } = {}
		for _, key in keys do
			result[key] = shape[key].decode(reader)
		end
		return result
	end)
end

--[=[
	One of a fixed set of string literals. Wire cost: 1 byte (index).
]=]
function Schema.literals(...: string): Codec<string>
	local options = { ... }
	assert(#options >= 1 and #options <= 255, "literals: 1..255 options")
	local indexOf: { [string]: number } = {}
	for index, option in options do
		assert(type(option) == "string", "literals expects strings")
		indexOf[option] = index
	end
	return make(function(value)
		if type(value) == "string" and indexOf[value :: string] ~= nil then
			return true
		end
		return false, `expected one of [{table.concat(options, ", ")}], got {tostring(value)}`
	end, function(writer, value: string)
		BufferIO.writeU8(writer, indexOf[value])
	end, function(reader): string
		local index = BufferIO.readU8(reader)
		local value = options[index]
		assert(value ~= nil, "Decode: invalid literal index")
		return value
	end)
end

-- Encode/decode entry points --------------------------------------------

--[=[
	Encodes a value with a codec into a right-sized buffer. Errors (with the
	check reason) if the value doesn't satisfy the schema — catching
	programmer mistakes at the send site.
]=]
function Schema.encode<T>(codec: Codec<T>, value: T): buffer
	local ok, reason = codec.check(value)
	assert(ok, `Schema encode: {reason or "value does not match schema"}`)
	local writer = BufferIO.newWriter()
	codec.encode(writer, value)
	return BufferIO.finish(writer)
end

--[=[
	Decodes a buffer with a codec. Errors on truncation, trailing bytes,
	out-of-range values, or non-finite floats — the transports pcall this
	and treat any error as a validation violation.
]=]
function Schema.decode<T>(codec: Codec<T>, blob: buffer): T
	local reader = BufferIO.newReader(blob)
	local value = codec.decode(reader)
	BufferIO.assertConsumed(reader)
	return value
end

return Schema
