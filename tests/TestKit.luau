--!strict
-- Minimal dependency-free test harness. Spec modules return
-- { [testName]: (expect) -> () }. Swapped for Jest-Lua in the Testing step
-- without changing spec structure.

export type Expect = {
	equal: (got: any, want: any, label: string?) -> (),
	truthy: (value: any, label: string?) -> (),
	falsy: (value: any, label: string?) -> (),
	errors: (fn: () -> (), label: string?) -> (),
}

export type Spec = { [string]: (expect: Expect) -> () }

local TestKit = {}

local function makeExpect(failures: { string }): Expect
	return {
		equal = function(got, want, label)
			if got ~= want then
				table.insert(failures, `{label or "equal"}: expected {tostring(want)}, got {tostring(got)}`)
			end
		end,
		truthy = function(value, label)
			if not value then
				table.insert(failures, `{label or "truthy"}: expected truthy, got {tostring(value)}`)
			end
		end,
		falsy = function(value, label)
			if value then
				table.insert(failures, `{label or "falsy"}: expected falsy, got {tostring(value)}`)
			end
		end,
		errors = function(fn, label)
			if pcall(fn) then
				table.insert(failures, `{label or "errors"}: expected function to error`)
			end
		end,
	}
end

function TestKit.run(specs: { [string]: Spec }): boolean
	local passed, failed = 0, 0

	for specName, spec in specs do
		for testName, test in spec do
			local failures: { string } = {}
			local ok, err = pcall(test :: (...any) -> ...any, makeExpect(failures))
			if not ok then
				table.insert(failures, `runtime error: {tostring(err)}`)
			end

			if #failures == 0 then
				passed += 1
				print(`  PASS  {specName} :: {testName}`)
			else
				failed += 1
				warn(`  FAIL  {specName} :: {testName}`)
				for _, failure in failures do
					warn(`        {failure}`)
				end
			end
		end
	end

	print(`Tests complete: {passed} passed, {failed} failed`)
	return failed == 0
end

return TestKit
