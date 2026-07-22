--!strict
--[=[
	@class BufferIO

	Shared growable buffer writer and bounds-checked reader used by both the
	generic Serializer and Schema codecs. Every read is bounds-checked — a
	truncated or hostile buffer errors cleanly instead of corrupting state.
]=]

local BufferIO = {}

export type Writer = {
	buf: buffer,
	cursor: number,
	capacity: number,
}

export type Reader = {
	buf: buffer,
	cursor: number,
	length: number,
}

local INITIAL_CAPACITY = 64

function BufferIO.newWriter(initialCapacity: number?): Writer
	local capacity = initialCapacity or INITIAL_CAPACITY
	return {
		buf = buffer.create(capacity),
		cursor = 0,
		capacity = capacity,
	}
end

--[=[ Returns a right-sized buffer containing exactly what was written. ]=]
function BufferIO.finish(writer: Writer): buffer
	local result = buffer.create(writer.cursor)
	buffer.copy(result, 0, writer.buf, 0, writer.cursor)
	return result
end

function BufferIO.ensure(writer: Writer, bytes: number)
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

function BufferIO.writeU8(writer: Writer, value: number)
	BufferIO.ensure(writer, 1)
	buffer.writeu8(writer.buf, writer.cursor, value)
	writer.cursor += 1
end

function BufferIO.writeU16(writer: Writer, value: number)
	BufferIO.ensure(writer, 2)
	buffer.writeu16(writer.buf, writer.cursor, value)
	writer.cursor += 2
end

function BufferIO.writeU32(writer: Writer, value: number)
	BufferIO.ensure(writer, 4)
	buffer.writeu32(writer.buf, writer.cursor, value)
	writer.cursor += 4
end

function BufferIO.writeI16(writer: Writer, value: number)
	BufferIO.ensure(writer, 2)
	buffer.writei16(writer.buf, writer.cursor, value)
	writer.cursor += 2
end

function BufferIO.writeI32(writer: Writer, value: number)
	BufferIO.ensure(writer, 4)
	buffer.writei32(writer.buf, writer.cursor, value)
	writer.cursor += 4
end

function BufferIO.writeF32(writer: Writer, value: number)
	BufferIO.ensure(writer, 4)
	buffer.writef32(writer.buf, writer.cursor, value)
	writer.cursor += 4
end

function BufferIO.writeF64(writer: Writer, value: number)
	BufferIO.ensure(writer, 8)
	buffer.writef64(writer.buf, writer.cursor, value)
	writer.cursor += 8
end

--[=[ Unsigned LEB128: 7 bits per byte, high bit = continuation. ]=]
function BufferIO.writeVarint(writer: Writer, value: number)
	repeat
		local byte = value % 128
		value = (value - byte) / 128
		if value > 0 then
			byte += 128
		end
		BufferIO.writeU8(writer, byte)
	until value == 0
end

function BufferIO.writeRawString(writer: Writer, value: string)
	BufferIO.writeVarint(writer, #value)
	BufferIO.ensure(writer, #value)
	buffer.writestring(writer.buf, writer.cursor, value)
	writer.cursor += #value
end

function BufferIO.writeBytes(writer: Writer, blob: buffer)
	local length = buffer.len(blob)
	BufferIO.ensure(writer, length)
	buffer.copy(writer.buf, writer.cursor, blob, 0, length)
	writer.cursor += length
end

-- Reader ---------------------------------------------------------------

function BufferIO.newReader(blob: buffer): Reader
	return {
		buf = blob,
		cursor = 0,
		length = buffer.len(blob),
	}
end

function BufferIO.need(reader: Reader, bytes: number)
	assert(reader.cursor + bytes <= reader.length, "Decode: truncated buffer")
end

function BufferIO.readU8(reader: Reader): number
	BufferIO.need(reader, 1)
	local value = buffer.readu8(reader.buf, reader.cursor)
	reader.cursor += 1
	return value
end

function BufferIO.readU16(reader: Reader): number
	BufferIO.need(reader, 2)
	local value = buffer.readu16(reader.buf, reader.cursor)
	reader.cursor += 2
	return value
end

function BufferIO.readU32(reader: Reader): number
	BufferIO.need(reader, 4)
	local value = buffer.readu32(reader.buf, reader.cursor)
	reader.cursor += 4
	return value
end

function BufferIO.readI16(reader: Reader): number
	BufferIO.need(reader, 2)
	local value = buffer.readi16(reader.buf, reader.cursor)
	reader.cursor += 2
	return value
end

function BufferIO.readI32(reader: Reader): number
	BufferIO.need(reader, 4)
	local value = buffer.readi32(reader.buf, reader.cursor)
	reader.cursor += 4
	return value
end

function BufferIO.readF32(reader: Reader): number
	BufferIO.need(reader, 4)
	local value = buffer.readf32(reader.buf, reader.cursor)
	reader.cursor += 4
	return value
end

function BufferIO.readF64(reader: Reader): number
	BufferIO.need(reader, 8)
	local value = buffer.readf64(reader.buf, reader.cursor)
	reader.cursor += 8
	return value
end

function BufferIO.readVarint(reader: Reader): number
	local result = 0
	local shift = 1
	for _ = 1, 8 do
		local byte = BufferIO.readU8(reader)
		result += (byte % 128) * shift
		if byte < 128 then
			return result
		end
		shift *= 128
	end
	error("Decode: varint too long")
end

function BufferIO.readRawString(reader: Reader): string
	local length = BufferIO.readVarint(reader)
	BufferIO.need(reader, length)
	local value = buffer.readstring(reader.buf, reader.cursor, length)
	reader.cursor += length
	return value
end

function BufferIO.readBytes(reader: Reader, length: number): buffer
	BufferIO.need(reader, length)
	local blob = buffer.create(length)
	buffer.copy(blob, 0, reader.buf, reader.cursor, length)
	reader.cursor += length
	return blob
end

--[=[ Asserts every byte was consumed — trailing bytes mean corruption. ]=]
function BufferIO.assertConsumed(reader: Reader)
	assert(reader.cursor == reader.length, "Decode: trailing bytes")
end

return BufferIO
