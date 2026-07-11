--!strict
--[=[
	@class Envelope

	Defines the wire format and the rules for what may travel on it.

	Wire format: `(eventName: string, ...args)` — the event name rides as the
	first positional argument and the payload follows as raw varargs. No
	wrapper table is allocated per packet, so the hot path adds zero GC
	pressure on top of Roblox's own serialization.

	Event names starting with `__` are reserved for internal protocol traffic
	(request/response correlation lands in the Invoke step).
]=]

local Envelope = {}

local MAX_EVENT_NAME_LENGTH = 100
local RESERVED_PREFIX = "__"

--[=[
	True if `value` is a string a *remote peer* is allowed to use as an event
	name. Used on receive: anything failing this is dropped before dispatch.
]=]
function Envelope.isValidEventName(value: unknown): boolean
	return type(value) == "string"
		and #value > 0
		and #value <= MAX_EVENT_NAME_LENGTH
		and string.sub(value, 1, #RESERVED_PREFIX) ~= RESERVED_PREFIX
end

--[=[
	Asserts an event name supplied by *local* code (Fire/On). Errors loudly —
	a bad name here is a programmer mistake, not an attack.
]=]
function Envelope.assertEventName(value: unknown): string
	assert(type(value) == "string", "Event name must be a string")
	assert(#value > 0, "Event name cannot be empty")
	assert(#value <= MAX_EVENT_NAME_LENGTH, `Event name exceeds {MAX_EVENT_NAME_LENGTH} characters`)
	assert(
		string.sub(value, 1, #RESERVED_PREFIX) ~= RESERVED_PREFIX,
		`Event names starting with "{RESERVED_PREFIX}" are reserved`
	)
	return value
end

--[=[
	Asserts a channel name supplied by local code. Same rules as event names;
	channel names double as Instance names so they must also be Instance-safe.
]=]
function Envelope.assertChannelName(value: unknown): string
	local name = Envelope.assertEventName(value)
	assert(not string.find(name, "[/\\%.]"), "Channel names cannot contain '/', '\\' or '.'")
	return name
end

return Envelope
