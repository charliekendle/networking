--!strict
--[=[
	@class Validators

	Composable runtime validators (t-style). Every validator has the shape
	`(value: unknown) -> (boolean, string?)` — `true` on success, or
	`false, reason` on failure — so custom ones drop straight in.

	```lua
	local V = Network.Validators

	Combat:Expect("Damage", V.numberRange(0, 100))
	Shop:Expect("Purchase", V.string, V.optional(V.integer))
	Trade:Expect("Offer", V.strictInterface({
		ItemId = V.string,
		Amount = V.integerRange(1, 999),
	}))
	```

	Security notes baked in:
	- `number` rejects NaN and ±inf (exploiters' favourite payload).
	  `numberRaw` exists if you genuinely need them.
	- Vector/CFrame/UDim2 validators reject non-finite components.
	- `array` walks only contiguous 1..n keys and rejects anything else,
	  with an optional max length.
]=]

local Types = require(script.Parent.Parent.Types)

export type Validator = Types.Validator

local Validators = {}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------

--[=[ Accepts anything, including nil. ]=]
Validators.any = function(_value: unknown): (boolean, string?)
	return true
end :: Validator

Validators.boolean = function(value: unknown): (boolean, string?)
	if type(value) == "boolean" then
		return true
	end
	return false, `expected boolean, got {typeof(value)}`
end :: Validator

Validators.string = function(value: unknown): (boolean, string?)
	if type(value) == "string" then
		return true
	end
	return false, `expected string, got {typeof(value)}`
end :: Validator

--[=[ Finite number: rejects NaN and ±inf. ]=]
Validators.number = function(value: unknown): (boolean, string?)
	if type(value) ~= "number" then
		return false, `expected number, got {typeof(value)}`
	end
	if not isFinite(value) then
		return false, "expected finite number, got NaN/inf"
	end
	return true
end :: Validator

--[=[ Any number, NaN/inf included. Prefer `number`. ]=]
Validators.numberRaw = function(value: unknown): (boolean, string?)
	if type(value) == "number" then
		return true
	end
	return false, `expected number, got {typeof(value)}`
end :: Validator

--[=[ Finite whole number. ]=]
Validators.integer = function(value: unknown): (boolean, string?)
	local ok, reason = Validators.number(value)
	if not ok then
		return false, reason
	end
	if (value :: number) % 1 ~= 0 then
		return false, `expected integer, got {value}`
	end
	return true
end :: Validator

Validators.table = function(value: unknown): (boolean, string?)
	if type(value) == "table" then
		return true
	end
	return false, `expected table, got {typeof(value)}`
end :: Validator

Validators.buffer = function(value: unknown): (boolean, string?)
	if typeof(value) == "buffer" then
		return true
	end
	return false, `expected buffer, got {typeof(value)}`
end :: Validator

--------------------------------------------------------------------------------
-- Combinators
--------------------------------------------------------------------------------

--[=[ Passes when the value is nil or satisfies the inner validator. ]=]
function Validators.optional(inner: Validator): Validator
	return function(value: unknown): (boolean, string?)
		if value == nil then
			return true
		end
		return inner(value)
	end
end

--[=[ Passes when the value is rawequal to the given literal. ]=]
function Validators.literal(literal: unknown): Validator
	return function(value: unknown): (boolean, string?)
		if rawequal(value, literal) then
			return true
		end
		return false, `expected literal {tostring(literal)}, got {tostring(value)}`
	end
end

--[=[ Passes when any of the given validators passes. ]=]
function Validators.union(...: Validator): Validator
	local options = { ... }
	assert(#options >= 2, "union requires at least two validators")
	return function(value: unknown): (boolean, string?)
		for _, option in options do
			if option(value) then
				return true
			end
		end
		return false, `no union branch matched {typeof(value)}`
	end
end

--[=[
	Contiguous array (keys exactly 1..n) whose every element satisfies
	`element`. Rejects holes, string keys, and — when given — lengths
	above `maxLength`.
]=]
function Validators.array(element: Validator, maxLength: number?): Validator
	return function(value: unknown): (boolean, string?)
		if type(value) ~= "table" then
			return false, `expected array, got {typeof(value)}`
		end
		local length = #(value :: { unknown })
		if maxLength ~= nil and length > maxLength then
			return false, `array exceeds max length {maxLength} (got {length})`
		end
		local seen = 0
		for key, item in value :: { [unknown]: unknown } do
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
				return false, `non-array key {tostring(key)}`
			end
			seen += 1
			local ok, reason = element(item)
			if not ok then
				return false, `[{key}]: {reason or "invalid"}`
			end
		end
		if seen ~= length then
			return false, "array has holes"
		end
		return true
	end
end

--[=[ Dictionary whose every key/value satisfy the given validators. ]=]
function Validators.dict(key: Validator, value: Validator): Validator
	return function(target: unknown): (boolean, string?)
		if type(target) ~= "table" then
			return false, `expected dict, got {typeof(target)}`
		end
		for entryKey, entryValue in target :: { [unknown]: unknown } do
			local keyOk, keyReason = key(entryKey)
			if not keyOk then
				return false, `key {tostring(entryKey)}: {keyReason or "invalid"}`
			end
			local valueOk, valueReason = value(entryValue)
			if not valueOk then
				return false, `[{tostring(entryKey)}]: {valueReason or "invalid"}`
			end
		end
		return true
	end
end

local function makeInterface(shape: { [string]: Validator }, exact: boolean): Validator
	return function(value: unknown): (boolean, string?)
		if type(value) ~= "table" then
			return false, `expected table, got {typeof(value)}`
		end
		local target = value :: { [unknown]: unknown }
		for fieldName, fieldValidator in shape do
			local ok, reason = fieldValidator(target[fieldName])
			if not ok then
				return false, `.{fieldName}: {reason or "invalid"}`
			end
		end
		if exact then
			for key in target do
				if type(key) ~= "string" or shape[key] == nil then
					return false, `unexpected field {tostring(key)}`
				end
			end
		end
		return true
	end
end

--[=[ Table with at least the given fields. Extra fields allowed. ]=]
function Validators.interface(shape: { [string]: Validator }): Validator
	return makeInterface(shape, false)
end

--[=[ Table with exactly the given fields. Extra fields rejected — prefer this on remotes. ]=]
function Validators.strictInterface(shape: { [string]: Validator }): Validator
	return makeInterface(shape, true)
end

--------------------------------------------------------------------------------
-- Constrained numbers / strings
--------------------------------------------------------------------------------

function Validators.numberMin(min: number): Validator
	return function(value: unknown): (boolean, string?)
		local ok, reason = Validators.number(value)
		if not ok then
			return false, reason
		end
		if (value :: number) < min then
			return false, `expected >= {min}, got {value}`
		end
		return true
	end
end

function Validators.numberMax(max: number): Validator
	return function(value: unknown): (boolean, string?)
		local ok, reason = Validators.number(value)
		if not ok then
			return false, reason
		end
		if (value :: number) > max then
			return false, `expected <= {max}, got {value}`
		end
		return true
	end
end

--[=[ Finite number within [min, max]. ]=]
function Validators.numberRange(min: number, max: number): Validator
	assert(min <= max, "numberRange: min must be <= max")
	return function(value: unknown): (boolean, string?)
		local ok, reason = Validators.number(value)
		if not ok then
			return false, reason
		end
		local n = value :: number
		if n < min or n > max then
			return false, `expected {min}..{max}, got {n}`
		end
		return true
	end
end

--[=[ Whole number within [min, max]. ]=]
function Validators.integerRange(min: number, max: number): Validator
	assert(min <= max, "integerRange: min must be <= max")
	return function(value: unknown): (boolean, string?)
		local ok, reason = Validators.integer(value)
		if not ok then
			return false, reason
		end
		local n = value :: number
		if n < min or n > max then
			return false, `expected {min}..{max}, got {n}`
		end
		return true
	end
end

--[=[ String no longer than `maxLength`. Always cap client-supplied strings. ]=]
function Validators.stringMaxLength(maxLength: number): Validator
	return function(value: unknown): (boolean, string?)
		local ok, reason = Validators.string(value)
		if not ok then
			return false, reason
		end
		if #(value :: string) > maxLength then
			return false, `string exceeds max length {maxLength} (got {#(value :: string)})`
		end
		return true
	end
end

--[=[ String matching a Luau pattern (anchor it yourself: `^...$`). ]=]
function Validators.match(pattern: string): Validator
	return function(value: unknown): (boolean, string?)
		local ok, reason = Validators.string(value)
		if not ok then
			return false, reason
		end
		if string.match(value :: string, pattern) == nil then
			return false, `string does not match pattern {pattern}`
		end
		return true
	end
end

--------------------------------------------------------------------------------
-- Roblox datatypes
--------------------------------------------------------------------------------

--[=[ EnumItem belonging to the given Enum. ]=]
function Validators.enumItem(enum: Enum): Validator
	return function(value: unknown): (boolean, string?)
		if typeof(value) ~= "EnumItem" then
			return false, `expected EnumItem, got {typeof(value)}`
		end
		if (value :: EnumItem).EnumType ~= enum then
			return false, `expected {tostring(enum)}, got {tostring((value :: EnumItem).EnumType)}`
		end
		return true
	end
end

Validators.instance = function(value: unknown): (boolean, string?)
	if typeof(value) == "Instance" then
		return true
	end
	return false, `expected Instance, got {typeof(value)}`
end :: Validator

--[=[ Instance of (or inheriting) the given class. ]=]
function Validators.instanceIsA(className: string): Validator
	return function(value: unknown): (boolean, string?)
		if typeof(value) ~= "Instance" then
			return false, `expected Instance, got {typeof(value)}`
		end
		if not (value :: Instance):IsA(className) then
			return false, `expected {className}, got {(value :: Instance).ClassName}`
		end
		return true
	end
end

--[=[ Vector3 with finite components. ]=]
Validators.vector3 = function(value: unknown): (boolean, string?)
	if typeof(value) ~= "Vector3" then
		return false, `expected Vector3, got {typeof(value)}`
	end
	local vector = value :: Vector3
	if not (isFinite(vector.X) and isFinite(vector.Y) and isFinite(vector.Z)) then
		return false, "Vector3 has non-finite components"
	end
	return true
end :: Validator

--[=[ Vector2 with finite components. ]=]
Validators.vector2 = function(value: unknown): (boolean, string?)
	if typeof(value) ~= "Vector2" then
		return false, `expected Vector2, got {typeof(value)}`
	end
	local vector = value :: Vector2
	if not (isFinite(vector.X) and isFinite(vector.Y)) then
		return false, "Vector2 has non-finite components"
	end
	return true
end :: Validator

--[=[ CFrame with a finite position. ]=]
Validators.cframe = function(value: unknown): (boolean, string?)
	if typeof(value) ~= "CFrame" then
		return false, `expected CFrame, got {typeof(value)}`
	end
	local position = (value :: CFrame).Position
	if not (isFinite(position.X) and isFinite(position.Y) and isFinite(position.Z)) then
		return false, "CFrame has non-finite position"
	end
	return true
end :: Validator

Validators.color3 = function(value: unknown): (boolean, string?)
	if typeof(value) == "Color3" then
		return true
	end
	return false, `expected Color3, got {typeof(value)}`
end :: Validator

--[=[ UDim2 with finite scales/offsets. ]=]
Validators.udim2 = function(value: unknown): (boolean, string?)
	if typeof(value) ~= "UDim2" then
		return false, `expected UDim2, got {typeof(value)}`
	end
	local udim = value :: UDim2
	if
		not (
			isFinite(udim.X.Scale)
			and isFinite(udim.X.Offset)
			and isFinite(udim.Y.Scale)
			and isFinite(udim.Y.Offset)
		)
	then
		return false, "UDim2 has non-finite components"
	end
	return true
end :: Validator

--------------------------------------------------------------------------------
-- Escape hatch
--------------------------------------------------------------------------------

--[=[
	Wraps any `(value) -> boolean` or `(value) -> (boolean, string?)`
	function as a validator, with an optional name for failure messages.
]=]
function Validators.custom(fn: (value: unknown) -> (boolean, string?), name: string?): Validator
	assert(type(fn) == "function", "custom expects a function")
	return function(value: unknown): (boolean, string?)
		local ok, reason = fn(value)
		if ok then
			return true
		end
		return false, reason or `failed custom validator{if name then ` "{name}"` else ""}`
	end
end

return Validators
