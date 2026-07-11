--!strict
--[=[
	@class SchemaRegistry

	Stores positional argument schemas per `(channel, event)` and checks
	incoming varargs against them. Context-local singleton (the server's
	registry validates client→server traffic; the client's, server→client).

	Enforcement rules:
	- More arguments than validators → reject ("too many arguments").
	  Exploiters can't smuggle extra payload past a schema.
	- Fewer arguments than validators → each missing slot is validated as
	  nil, so trailing `optional(...)` validators express optional args.
	- First failing validator rejects the whole packet with a positional
	  reason (`arg #2: expected 0..100, got 999`).

	Checking allocates nothing: varargs are inspected via `select`, never
	packed into a table.
]=]

local Types = require(script.Parent.Parent.Types)

local SchemaRegistry = {}

local schemas: { [string]: { [string]: { Types.Validator } } } = {}

--[=[
	Registers (or replaces) the schema for `(channel, event)`.
]=]
function SchemaRegistry.set(channelName: string, eventName: string, validators: { Types.Validator })
	assert(type(validators) == "table" and #validators > 0, "Expect requires at least one validator")
	for index, validator in validators do
		assert(type(validator) == "function", `validator #{index} is not a function`)
	end

	local events = schemas[channelName]
	if events == nil then
		events = {}
		schemas[channelName] = events
	end
	events[eventName] = table.clone(validators)
end

--[=[
	Returns the schema for `(channel, event)`, or nil if none registered.
]=]
function SchemaRegistry.get(channelName: string, eventName: string): { Types.Validator }?
	local events = schemas[channelName]
	return if events then events[eventName] else nil
end

--[=[
	Removes the schema for `(channel, event)`.
]=]
function SchemaRegistry.clear(channelName: string, eventName: string)
	local events = schemas[channelName]
	if events then
		events[eventName] = nil
	end
end

--[=[
	Checks varargs against a schema. Returns `true`, or `false, reason`.
]=]
function SchemaRegistry.check(validators: { Types.Validator }, ...: unknown): (boolean, string?)
	local argCount = select("#", ...)
	local validatorCount = #validators

	if argCount > validatorCount then
		return false, `too many arguments (expected {validatorCount}, got {argCount})`
	end

	for index = 1, validatorCount do
		local value: unknown = if index <= argCount then (select(index, ...)) else nil
		local ok, reason = validators[index](value)
		if not ok then
			return false, `arg #{index}: {reason or "invalid"}`
		end
	end

	return true
end

return SchemaRegistry
