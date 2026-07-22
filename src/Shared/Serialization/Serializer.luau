--!strict
--[=[
	@class Serializer

	Packs a Luau value tree into a single compact buffer and back.
	Exposed as `Network.Serialize` / `Network.Deserialize`.

	Why: Roblox's generic argument serialization spends bytes on type tags
	and full-precision doubles for everything. For large payloads
	(inventories, map state, replicated snapshots) hand-packing into a
	buffer and sending one argument is dramatically smaller on the wire —
	and buffers are the cheapest type Roblox serializes.

	```lua
	local blob = Network.Serialize(bigInventoryTable)
	Shop:Fire(player, "InventorySnapshot", blob)

	-- receiving side
	Shop:On("InventorySnapshot", function(blob)
		local inventory = Network.Deserialize(blob)
	end)
	```

	Supported values: nil, boolean, number (f64; integers 0..255 /
	±32767 / ±2^31 stored in 1/2/4 bytes), string (≤ 4 GiB), buffer,
	table (arrays and dictionaries, nested), Vector3, Vector2, CFrame,
	Color3, UDim2, EnumItem.

	Not supported (errors on serialize): Instances (identity can't survive
	a byte stream — send them as normal arguments), functions, threads,
	metatables (ignored), cyclic tables (errors).
]=]

local Serializer = {}

-- Type tags -----------------------------------------------------------------
local TAG_NIL = 0
local TAG_FALSE = 1
local TAG_TRUE = 2
local TAG_U8 = 3
local TAG_I16 = 4
local TAG_I32 = 5
local TAG_F64 = 6
local TAG_STRING = 7
local TAG_TABLE = 8 -- array part count (u32) + dict pair count (u32)
local TAG_VECTOR3 = 9
local TAG_VECTOR2 = 10
local TAG_CFRAME = 11 -- position f32x3 + axis-angle f32x4
local TAG_COLOR3 = 12
local TAG_UDIM2 = 13
local TAG_ENUM = 14 -- enum name string + item value u16
local TAG_BUFFER = 15
local TAG_STRINGREF = 16 -- varint index into previously written strings

local INITIAL_CAPACITY = 128

type Writer = {
	buf: buffer,
	cursor: number,
	capacity: number,
}

type WriteContext = {
	seenTables: { [any]: boolean },
	stringIndex: { [string]: number },
	stringCount: number,
}

local function ensure(writer: Writer, bytes: number)
	local needed = writer.cursor + bytes
	if needed <= writer.capacity then
		return
	end
	local capacity = writer.capacity
	while capacity < needed do
		capacity *= 2
	end
	local grown = buffer.create(capacity)
	buffer.copy(grown, 0, writer.buf, 0, writer.cursor)
	writer.buf = grown
	writer.capacity = capacity
end

local function writeU8(writer: Writer, value: number)
	ensure(writer, 1)
	buffer.writeu8(writer.buf, writer.cursor, value)
	writer.cursor += 1
end

local function writeU16(writer: Writer, value: number)
	ensure(writer, 2)
	buffer.writeu16(writer.buf, writer.cursor, value)
	writer.cursor += 2
end

-- Unsigned LEB128: 7 bits per byte, high bit = continuation. Lengths,
-- counts, and string references are almost always tiny; this keeps them
-- to one byte instead of four.
local function writeVarint(writer: Writer, value: number)
	repeat
		local byte = value % 128
		value = (value - byte) / 128
		if value > 0 then
			byte += 128
		end
		writeU8(writer, byte)
	until value == 0
end

local function writeF32(writer: Writer, value: number)
	ensure(writer, 4)
	buffer.writef32(writer.buf, writer.cursor, value)
	writer.cursor += 4
end

local function writeF64(writer: Writer, value: number)
	ensure(writer, 8)
	buffer.writef64(writer.buf, writer.cursor, value)
	writer.cursor += 8
end

local function writeRawString(writer: Writer, value: string)
	writeVarint(writer, #value)
	ensure(writer, #value)
	buffer.writestring(writer.buf, writer.cursor, value)
	writer.cursor += #value
end

-- Interned: the first occurrence writes TAG_STRING + bytes; repeats write
-- TAG_STRINGREF + a varint index. Dictionary keys repeated across hundreds
-- of entries collapse to ~2 bytes each.
local function writeInternedString(writer: Writer, context: WriteContext, value: string)
	local existing = context.stringIndex[value]
	if existing ~= nil then
		writeU8(writer, TAG_STRINGREF)
		writeVarint(writer, existing)
		return
	end
	context.stringCount += 1
	context.stringIndex[value] = context.stringCount
	writeU8(writer, TAG_STRING)
	writeRawString(writer, value)
end

local writeValue -- forward declaration (recursive)

local function writeTable(writer: Writer, value: { [unknown]: unknown }, context: WriteContext)
	assert(not context.seenTables[value], "Serialize: cyclic table")
	context.seenTables[value] = true

	local arrayCount = #value
	local dictPairs: { { unknown } } = {}
	for key, entry in value do
		local isArrayKey = type(key) == "number" and key % 1 == 0 and key >= 1 and key <= arrayCount
		if not isArrayKey then
			table.insert(dictPairs, { key, entry })
		end
	end

	writeVarint(writer, arrayCount)
	writeVarint(writer, #dictPairs)
	for index = 1, arrayCount do
		writeValue(writer, value[index], context)
	end
	for _, pair in dictPairs do
		writeValue(writer, pair[1], context)
		writeValue(writer, pair[2], context)
	end

	context.seenTables[value] = nil
end

function writeValue(writer: Writer, value: unknown, context: WriteContext)
	if value == nil then
		writeU8(writer, TAG_NIL)
	elseif value == false then
		writeU8(writer, TAG_FALSE)
	elseif value == true then
		writeU8(writer, TAG_TRUE)
	elseif type(value) == "number" then
		local n = value :: number
		if n % 1 == 0 and n == n then
			if n >= 0 and n <= 255 then
				writeU8(writer, TAG_U8)
				writeU8(writer, n)
				return
			elseif n >= -32768 and n <= 32767 then
				writeU8(writer, TAG_I16)
				ensure(writer, 2)
				buffer.writei16(writer.buf, writer.cursor, n)
				writer.cursor += 2
				return
			elseif n >= -2147483648 and n <= 2147483647 then
				writeU8(writer, TAG_I32)
				ensure(writer, 4)
				buffer.writei32(writer.buf, writer.cursor, n)
				writer.cursor += 4
				return
			end
		end
		writeU8(writer, TAG_F64)
		writeF64(writer, n)
	elseif type(value) == "string" then
		writeInternedString(writer, context, value :: string)
	elseif type(value) == "table" then
		writeU8(writer, TAG_TABLE)
		writeTable(writer, value :: { [unknown]: unknown }, context)
	elseif typeof(value) == "Vector3" then
		local vector = value :: Vector3
		writeU8(writer, TAG_VECTOR3)
		writeF32(writer, vector.X)
		writeF32(writer, vector.Y)
		writeF32(writer, vector.Z)
	elseif typeof(value) == "Vector2" then
		local vector = value :: Vector2
		writeU8(writer, TAG_VECTOR2)
		writeF32(writer, vector.X)
		writeF32(writer, vector.Y)
	elseif typeof(value) == "CFrame" then
		local cframe = value :: CFrame
		writeU8(writer, TAG_CFRAME)
		local position = cframe.Position
		writeF32(writer, position.X)
		writeF32(writer, position.Y)
		writeF32(writer, position.Z)
		local axis, angle = cframe:ToAxisAngle()
		writeF32(writer, axis.X)
		writeF32(writer, axis.Y)
		writeF32(writer, axis.Z)
		writeF32(writer, angle)
	elseif typeof(value) == "Color3" then
		local color = value :: Color3
		writeU8(writer, TAG_COLOR3)
		writeU8(writer, math.clamp(math.floor(color.R * 255 + 0.5), 0, 255))
		writeU8(writer, math.clamp(math.floor(color.G * 255 + 0.5), 0, 255))
		writeU8(writer, math.clamp(math.floor(color.B * 255 + 0.5), 0, 255))
	elseif typeof(value) == "UDim2" then
		local udim = value :: UDim2
		writeU8(writer, TAG_UDIM2)
		writeF32(writer, udim.X.Scale)
		writeF32(writer, udim.X.Offset)
		writeF32(writer, udim.Y.Scale)
		writeF32(writer, udim.Y.Offset)
	elseif typeof(value) == "EnumItem" then
		local item = value :: EnumItem
		writeU8(writer, TAG_ENUM)
		writeRawString(writer, tostring(item.EnumType))
		writeU16(writer, item.Value)
	elseif typeof(value) == "buffer" then
		local blob = value :: buffer
		writeU8(writer, TAG_BUFFER)
		local length = buffer.len(blob)
		writeVarint(writer, length)
		ensure(writer, length)
		buffer.copy(writer.buf, writer.cursor, blob, 0, length)
		writer.cursor += length
	else
		error(`Serialize: unsupported type {typeof(value)} (Instances/functions cannot be serialized — send them as normal arguments)`)
	end
end

--[=[
	Serializes a value tree into a compact buffer.
]=]
function Serializer.serialize(value: unknown): buffer
	local writer: Writer = {
		buf = buffer.create(INITIAL_CAPACITY),
		cursor = 0,
		capacity = INITIAL_CAPACITY,
	}
	writeValue(writer, value, {
		seenTables = {},
		stringIndex = {},
		stringCount = 0,
	})

	local result = buffer.create(writer.cursor)
	buffer.copy(result, 0, writer.buf, 0, writer.cursor)
	return result
end

-- Reading ---------------------------------------------------------------

type Reader = {
	buf: buffer,
	cursor: number,
	length: number,
	strings: { string },
}

local function need(reader: Reader, bytes: number)
	assert(reader.cursor + bytes <= reader.length, "Deserialize: truncated buffer")
end

local function readU8(reader: Reader): number
	need(reader, 1)
	local value = buffer.readu8(reader.buf, reader.cursor)
	reader.cursor += 1
	return value
end

local function readF32(reader: Reader): number
	need(reader, 4)
	local value = buffer.readf32(reader.buf, reader.cursor)
	reader.cursor += 4
	return value
end

local function readVarint(reader: Reader): number
	local result = 0
	local shift = 1
	for _ = 1, 8 do
		local byte = readU8(reader)
		result += (byte % 128) * shift
		if byte < 128 then
			return result
		end
		shift *= 128
	end
	error("Deserialize: varint too long")
end

local function readRawString(reader: Reader): string
	local length = readVarint(reader)
	need(reader, length)
	local value = buffer.readstring(reader.buf, reader.cursor, length)
	reader.cursor += length
	return value
end

local readValue -- forward declaration (recursive)

function readValue(reader: Reader): unknown
	local tag = readU8(reader)

	if tag == TAG_NIL then
		return nil
	elseif tag == TAG_FALSE then
		return false
	elseif tag == TAG_TRUE then
		return true
	elseif tag == TAG_U8 then
		return readU8(reader)
	elseif tag == TAG_I16 then
		need(reader, 2)
		local value = buffer.readi16(reader.buf, reader.cursor)
		reader.cursor += 2
		return value
	elseif tag == TAG_I32 then
		need(reader, 4)
		local value = buffer.readi32(reader.buf, reader.cursor)
		reader.cursor += 4
		return value
	elseif tag == TAG_F64 then
		need(reader, 8)
		local value = buffer.readf64(reader.buf, reader.cursor)
		reader.cursor += 8
		return value
	elseif tag == TAG_STRING then
		local value = readRawString(reader)
		table.insert(reader.strings, value)
		return value
	elseif tag == TAG_STRINGREF then
		local index = readVarint(reader)
		local value = reader.strings[index]
		assert(value ~= nil, "Deserialize: string reference out of range")
		return value
	elseif tag == TAG_TABLE then
		local arrayCount = readVarint(reader)
		local dictCount = readVarint(reader)
		local result: { [unknown]: unknown } = table.create(arrayCount)
		for index = 1, arrayCount do
			result[index] = readValue(reader)
		end
		for _ = 1, dictCount do
			local key = readValue(reader)
			local value = readValue(reader)
			assert(key ~= nil, "Deserialize: nil table key")
			result[key] = value
		end
		return result
	elseif tag == TAG_VECTOR3 then
		return Vector3.new(readF32(reader), readF32(reader), readF32(reader))
	elseif tag == TAG_VECTOR2 then
		return Vector2.new(readF32(reader), readF32(reader))
	elseif tag == TAG_CFRAME then
		local position = Vector3.new(readF32(reader), readF32(reader), readF32(reader))
		local axis = Vector3.new(readF32(reader), readF32(reader), readF32(reader))
		local angle = readF32(reader)
		if axis.Magnitude < 1e-6 then
			return CFrame.new(position)
		end
		return CFrame.fromAxisAngle(axis.Unit, angle) + position
	elseif tag == TAG_COLOR3 then
		return Color3.fromRGB(readU8(reader), readU8(reader), readU8(reader))
	elseif tag == TAG_UDIM2 then
		return UDim2.new(readF32(reader), readF32(reader), readF32(reader), readF32(reader))
	elseif tag == TAG_ENUM then
		local enumName = readRawString(reader)
		need(reader, 2)
		local itemValue = buffer.readu16(reader.buf, reader.cursor)
		reader.cursor += 2
		local enum = (Enum :: any)[enumName] :: Enum
		for _, item in enum:GetEnumItems() do
			if item.Value == itemValue then
				return item
			end
		end
		error(`Deserialize: unknown enum item {enumName}:{itemValue}`)
	elseif tag == TAG_BUFFER then
		local length = readVarint(reader)
		need(reader, length)
		local blob = buffer.create(length)
		buffer.copy(blob, 0, reader.buf, reader.cursor, length)
		reader.cursor += length
		return blob
	end

	error(`Deserialize: unknown tag {tag} (corrupt or incompatible buffer)`)
end

--[=[
	Deserializes a buffer produced by `serialize`. Errors on truncated or
	corrupt input — wrap in pcall when the buffer came from a remote peer.
]=]
function Serializer.deserialize(blob: buffer): unknown
	local reader: Reader = {
		buf = blob,
		cursor = 0,
		length = buffer.len(blob),
		strings = {},
	}
	local value = readValue(reader)
	assert(reader.cursor == reader.length, "Deserialize: trailing bytes")
	return value
end

return Serializer
