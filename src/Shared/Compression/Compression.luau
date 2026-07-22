--!strict
--[=[
	@class Compression

	LZW compression over buffers, exposed as `Network.Compress` /
	`Network.Decompress`. Pairs with the Serializer for large repetitive
	payloads:

	```lua
	local blob = Network.Compress(Network.Serialize(bigTable))
	Shop:Fire(player, "Snapshot", blob)

	-- receiving side
	local data = Network.Deserialize(Network.Decompress(blob))
	```

	Format: 1 header byte — `0` = stored raw, `1` = LZW (16-bit codes).
	If compression doesn't actually shrink the payload (random or already
	compact data), it is stored raw automatically, so `Compress` never makes
	things bigger than input + 1 byte. `Decompress` errors on corrupt input.

	When to bother: the Serializer's packing is already the big win for
	structured data. Compression pays off on top of it for payloads with
	heavy repetition — long strings, text, map/tile data — typically 1 KB
	and up. For small packets the header + CPU isn't worth it.
]=]

local Compression = {}

local MODE_RAW = 0
local MODE_LZW = 1

local MAX_CODE = 65535 -- 16-bit codes; dictionary stops growing when full
local FIRST_CODE = 256

--[=[
	Compresses a buffer (or string). Returns a new buffer: 1 header byte +
	payload. Falls back to raw storage when LZW wouldn't shrink the input.
]=]
function Compression.compress(input: buffer | string): buffer
	local source: string = if type(input) == "string" then input else buffer.tostring(input)
	local sourceLength = #source

	if sourceLength == 0 then
		local empty = buffer.create(1)
		buffer.writeu8(empty, 0, MODE_RAW)
		return empty
	end

	-- LZW encode into an array of 16-bit codes.
	local dictionary: { [string]: number } = {}
	for byte = 0, 255 do
		dictionary[string.char(byte)] = byte
	end
	local nextCode = FIRST_CODE

	local codes: { number } = {}
	local current = string.sub(source, 1, 1)

	for index = 2, sourceLength do
		local character = string.sub(source, index, index)
		local extended = current .. character
		if dictionary[extended] ~= nil then
			current = extended
		else
			table.insert(codes, dictionary[current])
			if nextCode <= MAX_CODE then
				dictionary[extended] = nextCode
				nextCode += 1
			end
			current = character
		end
	end
	table.insert(codes, dictionary[current])

	local compressedLength = 1 + #codes * 2
	if compressedLength >= 1 + sourceLength then
		-- Not worth it: store raw.
		local raw = buffer.create(1 + sourceLength)
		buffer.writeu8(raw, 0, MODE_RAW)
		buffer.writestring(raw, 1, source)
		return raw
	end

	local output = buffer.create(compressedLength)
	buffer.writeu8(output, 0, MODE_LZW)
	local cursor = 1
	for _, code in codes do
		buffer.writeu16(output, cursor, code)
		cursor += 2
	end
	return output
end

--[=[
	Reverses `compress`. Errors on corrupt or truncated input — wrap in
	pcall when the buffer came from a remote peer.
]=]
function Compression.decompress(input: buffer): buffer
	local length = buffer.len(input)
	assert(length >= 1, "Decompress: empty input")
	local mode = buffer.readu8(input, 0)

	if mode == MODE_RAW then
		local raw = buffer.create(length - 1)
		buffer.copy(raw, 0, input, 1, length - 1)
		return raw
	end
	assert(mode == MODE_LZW, `Decompress: unknown mode {mode}`)
	assert((length - 1) % 2 == 0 and length > 1, "Decompress: truncated code stream")

	local dictionary: { string } = table.create(FIRST_CODE)
	for byte = 0, 255 do
		dictionary[byte + 1] = string.char(byte) -- code N lives at index N+1
	end
	local nextCode = FIRST_CODE

	local pieces: { string } = {}
	local cursor = 1

	local firstCode = buffer.readu16(input, cursor)
	cursor += 2
	assert(firstCode < FIRST_CODE, "Decompress: invalid first code")
	local previous = dictionary[firstCode + 1]
	table.insert(pieces, previous)

	while cursor < length do
		local code = buffer.readu16(input, cursor)
		cursor += 2

		local entry: string
		if code < nextCode then
			entry = dictionary[code + 1]
		elseif code == nextCode and nextCode <= MAX_CODE then
			-- The classic KwKwK case: code refers to the entry being built.
			entry = previous .. string.sub(previous, 1, 1)
		else
			error("Decompress: corrupt code stream")
		end

		table.insert(pieces, entry)
		if nextCode <= MAX_CODE then
			dictionary[nextCode + 1] = previous .. string.sub(entry, 1, 1)
			nextCode += 1
		end
		previous = entry
	end

	return buffer.fromstring(table.concat(pieces))
end

return Compression
